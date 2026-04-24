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

    /// guest 端传来剪贴板文本时的回调(UTF8_TEXT, 已解码成 String).
    /// 回调在独立的读循环线程上被同步调用, 实现方不要在里面长阻塞。
    public var onClipboardText: (@Sendable (String) -> Void)?

    /// 自动在收到 CLIPBOARD_GRAB 后立刻发 REQUEST(UTF8_TEXT), 抓 guest 剪贴板。
    /// 默认 true, hvmdbg watch/get 依赖这个默认值。
    public var autoRequestClipboardOnGrab: Bool = true

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

        // 持 fd 快照, 循环内双重校验 self.sockFD == localFD, 防止 close 后
        // int 值被复用导致 recv 读到陌生 socket 的数据。
        readTask = Task.detached(priority: .userInitiated) { [weak self, localFD = fd] in
            self?.runReadLoop(localFD: localFD)
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
        // 声明剪贴板能力: guest 复制时会发 GRAB, 我们收到后 REQUEST 拿 UTF8_TEXT.
        // clipboardByDemand: guest 按需发数据(不主动 push 全部), 对大块内容更友好。
        caps |= 1 << VDAgentCap.clipboard.rawValue
        caps |= 1 << VDAgentCap.clipboardByDemand.rawValue

        let payloadSize = MemoryLayout<VDAgentAnnounceCapabilitiesHeader>.size
                        + MemoryLayout<UInt32>.size
        var buf = Data(capacity: payloadSize)
        var hdr = VDAgentAnnounceCapabilitiesHeader(request: request)
        withUnsafeBytes(of: &hdr) { buf.append(contentsOf: $0) }
        withUnsafeBytes(of: &caps) { buf.append(contentsOf: $0) }

        log.debug(.display, "vdagent send ANNOUNCE_CAPABILITIES request=\(request) caps=0x\(String(caps, radix: 16))")
        sendMessage(type: .announceCapabilities, payload: buf)
    }

    /// 主动向 guest 请求指定类型的剪贴板数据。
    /// 通常不需要直接调用: 我们默认在收到 GRAB 后自动 REQUEST, 流程就走通了。
    /// 留 public 是为了"尝试 pull 当前剪贴板"这类实验场景。
    public func requestClipboard(type: VDAgentClipboardType = .utf8Text) {
        var typeVal = type.rawValue
        var buf = Data(capacity: MemoryLayout<UInt32>.size)
        withUnsafeBytes(of: &typeVal) { buf.append(contentsOf: $0) }
        log.debug(.display, "vdagent send CLIPBOARD_REQUEST type=\(type)")
        sendMessage(type: .clipboardRequest, payload: buf)
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

    /// 单个 VDIChunk 的最大尺寸. spice-vdagent 实际上 chunk 很小 (~2KB),
    /// 这里设 10MB 纯防御, 防止对端/攻击者发巨大 size 让 host OOM。
    private static let maxChunkPayload: UInt32 = 10 * 1024 * 1024

    /// 单条 VDAgentMessage 的最大尺寸. CLIPBOARD 可能 MB 级 (大段文本/图片),
    /// 但 20MB 绝对够用, 超过就当攻击或协议错乱, 整段丢弃。
    private static let maxMessagePayload: UInt32 = 20 * 1024 * 1024

    private func runReadLoop(localFD: Int32) {
        var chunkAccum = Data()
        // msgAccum: 跨 VDIChunk 累积的 VDAgentMessage buffer. 一条 message
        // 的 payload 可以被 spice-vdagent 拆成多个 VDIChunk, 必须按 msg.size
        // 拼完再 dispatch。这是大剪贴板能跨过 ~2KB chunk 上限的关键。
        var msgAccum = Data()
        let recvBufSize = 4096
        var recvBuf = [UInt8](repeating: 0, count: recvBufSize)

        while !Task.isCancelled && sockFD == localFD {
            let n = recvBuf.withUnsafeMutableBufferPointer { p -> ssize_t in
                Darwin.recv(localFD, p.baseAddress, p.count, 0)
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
            chunkAccum.append(recvBuf, count: Int(n))

            // chunk 切分: 把 VDIChunkHeader 剥掉, payload 喂给 msgAccum
            let chunkHdrSize = MemoryLayout<VDIChunkHeader>.size
            while chunkAccum.count >= chunkHdrSize {
                var chunk = VDIChunkHeader(port: 0, size: 0)
                withUnsafeMutableBytes(of: &chunk) { dst in
                    chunkAccum.copyBytes(to: dst.bindMemory(to: UInt8.self),
                                         from: 0..<chunkHdrSize)
                }
                // chunk size 上限防御
                if chunk.size > Self.maxChunkPayload {
                    log.warn(.display,
                        "vdagent chunk size 超限 \(chunk.size)B, 关闭通道")
                    return
                }
                let needed = chunkHdrSize + Int(chunk.size)
                if chunkAccum.count < needed { break }
                let chunkPayload = chunkAccum.subdata(in: chunkHdrSize..<needed)
                chunkAccum.removeSubrange(0..<needed)
                // VDIChunk 层只做分流。port=1 (vdiClientPort) 是主通道,
                // 其它端口暂时不关心, 直接丢。
                if chunk.port == vdiClientPort {
                    msgAccum.append(chunkPayload)
                    drainMessages(accum: &msgAccum)
                }
            }
        }
    }

    /// 从累积 buffer 中取出所有完整的 VDAgentMessage 并 dispatch。
    /// 不完整的尾部留在 accum 里等下一批 chunk。
    private func drainMessages(accum: inout Data) {
        let msgHdrSize = MemoryLayout<VDAgentMessageHeader>.size
        while accum.count >= msgHdrSize {
            var msg = VDAgentMessageHeader(protocol: 0, type: 0, opaque: 0, size: 0)
            withUnsafeMutableBytes(of: &msg) { dst in
                accum.copyBytes(to: dst.bindMemory(to: UInt8.self),
                               from: 0..<msgHdrSize)
            }
            // msg size 上限防御: 超限的 accum 整段丢弃, 继续消费后续 chunk。
            // (继续使用 accum 也不安全, 因为我们无法知道合法 msg 的边界在哪。)
            if msg.size > Self.maxMessagePayload {
                log.warn(.display,
                    "vdagent msg.size 超限 \(msg.size)B, 重置累积 buffer")
                accum.removeAll()
                return
            }
            let needed = msgHdrSize + Int(msg.size)
            if accum.count < needed { break }
            let body = accum.subdata(in: msgHdrSize..<needed)
            accum.removeSubrange(0..<needed)
            dispatchMessage(header: msg, body: body)
        }
    }

    private func dispatchMessage(header msg: VDAgentMessageHeader, body: Data) {
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
                withUnsafeMutableBytes(of: &hdr) { dst in
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

        case .clipboardGrab:
            // guest 宣告 "我复制了一段, 有这些类型可选". payload: [type(uint32) ...]
            // 我们挑 UTF8_TEXT, 立刻回 REQUEST, 等 guest 后续 CLIPBOARD 消息把数据送过来。
            let typeSize = MemoryLayout<UInt32>.size
            let count = body.count / typeSize
            var offered: [VDAgentClipboardType] = []
            for i in 0..<count {
                var t: UInt32 = 0
                withUnsafeMutableBytes(of: &t) { dst in
                    body.copyBytes(to: dst.bindMemory(to: UInt8.self),
                                   from: (i * typeSize)..<((i + 1) * typeSize))
                }
                if let kind = VDAgentClipboardType(rawValue: t) {
                    offered.append(kind)
                }
            }
            log.debug(.display, "vdagent recv CLIPBOARD_GRAB types=\(offered)")
            if autoRequestClipboardOnGrab, offered.contains(.utf8Text) {
                requestClipboard(type: .utf8Text)
            }

        case .clipboard:
            // guest 回应 REQUEST, 送来数据. payload: [type(uint32) + data]
            let typeSize = MemoryLayout<UInt32>.size
            guard body.count >= typeSize else {
                log.warn(.display, "vdagent CLIPBOARD payload too short (\(body.count)B)")
                return
            }
            var rawType: UInt32 = 0
            withUnsafeMutableBytes(of: &rawType) { dst in
                body.copyBytes(to: dst.bindMemory(to: UInt8.self),
                               from: 0..<typeSize)
            }
            let payload = body.subdata(in: typeSize..<body.count)
            switch VDAgentClipboardType(rawValue: rawType) {
            case .some(.utf8Text):
                if let text = String(data: payload, encoding: .utf8) {
                    log.info(.display, "vdagent recv CLIPBOARD utf8Text (\(payload.count)B)")
                    onClipboardText?(text)
                } else {
                    log.warn(.display, "vdagent CLIPBOARD utf8Text decode 失败 (\(payload.count)B)")
                }
            case .some(let other):
                log.debug(.display, "vdagent recv CLIPBOARD 忽略非文本类型: \(other) (\(payload.count)B)")
            case nil:
                log.warn(.display, "vdagent recv CLIPBOARD 未知类型 raw=\(rawType)")
            }

        case .clipboardRelease:
            // guest 放弃当前剪贴板所有权. 仅调试日志, 不需要任何动作。
            log.debug(.display, "vdagent recv CLIPBOARD_RELEASE")

        default:
            // 其它消息(file-xfer / audio-volume 等)暂不处理
            break
        }
    }
}
