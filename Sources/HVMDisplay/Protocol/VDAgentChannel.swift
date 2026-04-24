// VDAgentChannel —— spice-vdagent 桥接通道客户端
//
// 负责连接 QEMU virtio-serial chardev socket (port "com.redhat.spice.0"),
// 按 spice-vdagent 协议发消息给 Windows/Linux guest 里的 spice-vdagent 服务,
// 用于驱动 Windows guest 在 host 窗口拖拽 resize 时自动切换分辨率。
//
// 连接成功后主动发一次 ANNOUNCE_CAPABILITIES (request=0) 宣告 host 能力。
// 若 guest 主动发 ANNOUNCE_CAPABILITIES (request=1) 询问, 同样回一次。
// 收到 guest 任何消息都当作 agent 已就绪, 之后的 resize 请求才会真正发出。
//
// 未就绪前的 resize 请求会缓存"最后一次 size", ready 时再发送, 避免启动期
// 的多次拖拽丢失最终目标尺寸。

import Foundation
import Darwin
import HVMCore

public final class VDAgentChannel: @unchecked Sendable {
    private var sockFD: Int32 = -1
    private var readTask: Task<Void, Never>?

    /// agent 是否握过手; false 时 sendMonitorsConfig 只缓存不发
    private let stateLock = NSLock()
    private var _agentReady = false
    private var _pendingSize: (UInt32, UInt32)?

    public init() {}

    // MARK: - 生命周期

    public func connect(socketPath: String) throws {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        let maxPath = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count <= maxPath else {
            Darwin.close(fd)
            throw POSIXError(.E2BIG)
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            pathBytes.withUnsafeBufferPointer { src in
                _ = memcpy(dst.baseAddress!, src.baseAddress!, src.count)
            }
        }

        let rc = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else {
            let e = errno
            Darwin.close(fd)
            throw POSIXError(.init(rawValue: e) ?? .EIO)
        }

        self.sockFD = fd
        log.info(.display, "vdagent connected: \(socketPath)")

        // 启动就主动宣告 host 能力, spice-vdagent-win 收到后会响应自己的能力,
        // 同时进入可发 MONITORS_CONFIG 的状态。
        sendCapabilities(request: 0)

        readTask = Task.detached(priority: .userInitiated) { [weak self] in
            self?.runReadLoop()
        }
    }

    public func close() {
        if sockFD >= 0 {
            let fd = sockFD
            sockFD = -1
            Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
        readTask?.cancel()
        stateLock.lock()
        _agentReady = false
        _pendingSize = nil
        stateLock.unlock()
    }

    deinit { close() }

    // MARK: - 发送

    /// 请求 guest 切换到指定分辨率(单显示器, 0 偏移, 32bit 色深)。
    /// 若 agent 尚未就绪, 只缓存"最后一次尺寸", 握手完成时自动发送。
    public func sendMonitorsConfig(width: UInt32, height: UInt32) {
        stateLock.lock()
        let ready = _agentReady
        if !ready {
            _pendingSize = (width, height)
            stateLock.unlock()
            log.debug(.display, "vdagent not ready, cache pending \(width)x\(height)")
            return
        }
        stateLock.unlock()
        sendMonitorsConfigNow(width: width, height: height)
    }

    private func sendMonitorsConfigNow(width: UInt32, height: UInt32) {
        let payloadSize = MemoryLayout<VDAgentMonitorsConfigHeader>.size
                        + MemoryLayout<VDAgentMonConfig>.size
        var buf = Data(capacity: payloadSize)

        var cfg = VDAgentMonitorsConfigHeader(numOfMonitors: 1, flags: 0)
        withUnsafeBytes(of: &cfg) { buf.append(contentsOf: $0) }

        var mon = VDAgentMonConfig(
            height: height, width: width, depth: 32, x: 0, y: 0
        )
        withUnsafeBytes(of: &mon) { buf.append(contentsOf: $0) }

        log.info(.display, "vdagent send MONITORS_CONFIG \(width)x\(height)")
        sendMessage(type: .monitorsConfig, payload: buf)
    }

    /// 发一次 ANNOUNCE_CAPABILITIES. request=0 表示"告知", request=1 表示"询问"。
    /// caps bitmap 用一个 uint32, 声明 HellVM 支持的能力集合。
    private func sendCapabilities(request: UInt32) {
        var caps: UInt32 = 0
        caps |= 1 << VDAgentCap.monitorsConfig.rawValue
        caps |= 1 << VDAgentCap.monitorsConfigPosition.rawValue
        caps |= 1 << VDAgentCap.sparseMonitorsConfig.rawValue
        caps |= 1 << VDAgentCap.reply.rawValue

        let payloadSize = MemoryLayout<VDAgentAnnounceCapabilitiesHeader>.size
                        + MemoryLayout<UInt32>.size
        var buf = Data(capacity: payloadSize)
        var hdr = VDAgentAnnounceCapabilitiesHeader(request: request)
        withUnsafeBytes(of: &hdr) { buf.append(contentsOf: $0) }
        withUnsafeBytes(of: &caps) { buf.append(contentsOf: $0) }

        log.debug(.display, "vdagent send ANNOUNCE_CAPABILITIES request=\(request) caps=0x\(String(caps, radix: 16))")
        sendMessage(type: .announceCapabilities, payload: buf)
    }

    /// 封装: VDIChunkHeader + VDAgentMessageHeader + payload, 一次 send
    private func sendMessage(type: VDAgentMessageType, payload: Data) {
        guard sockFD >= 0 else {
            log.warn(.display, "vdagent sendMessage drop: sockFD<0 (type=\(type))")
            return
        }
        let msgHdrSize = MemoryLayout<VDAgentMessageHeader>.size
        let chunkHdrSize = MemoryLayout<VDIChunkHeader>.size
        let chunkSize = UInt32(msgHdrSize + payload.count)
        let total = chunkHdrSize + Int(chunkSize)

        var out = Data(capacity: total)
        var chunk = VDIChunkHeader(port: vdiClientPort, size: chunkSize)
        withUnsafeBytes(of: &chunk) { out.append(contentsOf: $0) }

        var msg = VDAgentMessageHeader(
            protocol: vdAgentProtocol,
            type: type.rawValue,
            opaque: 0,
            size: UInt32(payload.count)
        )
        withUnsafeBytes(of: &msg) { out.append(contentsOf: $0) }
        out.append(payload)

        let written = out.withUnsafeBytes { raw -> ssize_t in
            Darwin.send(sockFD, raw.baseAddress, raw.count, 0)
        }
        if written != total {
            log.warn(.display,
                "vdagent short send \(written)/\(total) errno=\(errno) (type=\(type))")
        }
    }

    // MARK: - 读循环

    private func runReadLoop() {
        var accum = Data()
        let recvBufSize = 4096
        var recvBuf = [UInt8](repeating: 0, count: recvBufSize)

        while !Task.isCancelled && sockFD >= 0 {
            let n = recvBuf.withUnsafeMutableBufferPointer { p -> ssize_t in
                Darwin.recv(sockFD, p.baseAddress, p.count, 0)
            }
            if n == 0 {
                log.info(.display, "vdagent read EOF")
                return
            }
            if n < 0 {
                if errno == EINTR { continue }
                log.warn(.display, "vdagent recv errno=\(errno)")
                return
            }
            accum.append(recvBuf, count: Int(n))

            // chunk 切分
            let chunkHdrSize = MemoryLayout<VDIChunkHeader>.size
            while accum.count >= chunkHdrSize {
                var chunk = VDIChunkHeader(port: 0, size: 0)
                _ = withUnsafeMutableBytes(of: &chunk) { dst in
                    accum.copyBytes(to: dst.bindMemory(to: UInt8.self),
                                    from: 0..<chunkHdrSize)
                }
                let needed = chunkHdrSize + Int(chunk.size)
                if accum.count < needed { break }
                let chunkPayload = accum.subdata(in: chunkHdrSize..<needed)
                accum.removeSubrange(0..<needed)
                handleChunk(payload: chunkPayload)
            }
        }
    }

    private func handleChunk(payload: Data) {
        let msgHdrSize = MemoryLayout<VDAgentMessageHeader>.size
        guard payload.count >= msgHdrSize else { return }

        var msg = VDAgentMessageHeader(protocol: 0, type: 0, opaque: 0, size: 0)
        _ = withUnsafeMutableBytes(of: &msg) { dst in
            payload.copyBytes(to: dst.bindMemory(to: UInt8.self),
                              from: 0..<msgHdrSize)
        }
        let body = payload.subdata(in: msgHdrSize..<payload.count)
        let type = VDAgentMessageType(rawValue: msg.type)
        log.debug(.display,
            "vdagent recv msg type=\(msg.type) (\(type.map(String.init(describing:)) ?? "?")) size=\(msg.size)")

        switch type {
        case .announceCapabilities:
            // agent 就绪: 一旦双方握过手, 就可以真正发 MONITORS_CONFIG
            stateLock.lock()
            let wasReady = _agentReady
            _agentReady = true
            let pending = _pendingSize
            _pendingSize = nil
            stateLock.unlock()

            // 若对端在询问 (request=1) 我们回一次
            if body.count >= MemoryLayout<VDAgentAnnounceCapabilitiesHeader>.size {
                var hdr = VDAgentAnnounceCapabilitiesHeader(request: 0)
                _ = withUnsafeMutableBytes(of: &hdr) { dst in
                    body.copyBytes(to: dst.bindMemory(to: UInt8.self),
                                   from: 0..<MemoryLayout<VDAgentAnnounceCapabilitiesHeader>.size)
                }
                if hdr.request != 0 {
                    log.debug(.display, "vdagent guest asked caps, replying")
                    sendCapabilities(request: 0)
                }
            }

            if !wasReady {
                log.info(.display, "vdagent agent ready")
                if let (w, h) = pending {
                    log.info(.display, "vdagent flush pending \(w)x\(h)")
                    sendMonitorsConfigNow(width: w, height: h)
                }
            }

        default:
            // 暂时不关心其它消息(clipboard/file-xfer 等)
            break
        }
    }
}
