// DisplayChannel —— iosurface socket 客户端
//
// 协议语义(见 iosurface.m):
// - 所有消息: [MsgHeader(8) | payload(...) ]
// - SURFACE 消息附带一个 SCM_RIGHTS fd (framebuffer shm 的 fd)
// - 其他消息无附带 fd
//
// Darwin SOCK_STREAM 的 SCM_RIGHTS 边界: 带 cmsg 的 sendmsg 不会与后续
// 消息合并到同一次 recvmsg. 据此设计流解析器:
// - 用 hvm_recvmsg_with_fd 循环 recvmsg
// - 每次 recvmsg 返回的 bytes 追加到 accumulator
// - 按 header.payload_len 切分一条条消息并 dispatch
// - 出现 fd 时记住, 在遇到下一个 SURFACE 消息时消费

import Foundation
import Darwin
import HVMCore
import HVMDisplayC

public final class DisplayChannel: @unchecked Sendable {
    private var sockFD: Int32 = -1
    private var readTask: Task<Void, Never>?

    private let continuation: AsyncStream<DisplayEvent>.Continuation
    public let events: AsyncStream<DisplayEvent>

    public init() {
        var cont: AsyncStream<DisplayEvent>.Continuation!
        self.events = AsyncStream { cont = $0 }
        self.continuation = cont
    }

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

        try sendHello()

        // readTask 持 fd 快照, 循环内用局部 fd + self.sockFD 双重校验,
        // 避免 close() 之后 int 值被 kernel 分给新 socket 时 recv 读错位。
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
        continuation.finish()
    }

    deinit { close() }

    // MARK: - 发送

    /// 请求 guest 改分辨率。通过 QEMU 的 dpy_set_ui_info 推给 virtio-gpu 驱动,
    /// guest 内核响应后会重新分配 framebuffer, 触发新的 SURFACE 消息回传。
    public func requestResize(width: UInt32, height: UInt32) {
        guard sockFD >= 0 else {
            log.warn(.display, "requestResize drop: sockFD<0 (\(width)x\(height))")
            return
        }
        var header = MsgHeader(type: MessageType.resizeReq.rawValue,
                               payloadLen: UInt32(MemoryLayout<ResizeReqPayload>.size))
        var payload = ResizeReqPayload(width: width, height: height)

        let total = MemoryLayout<MsgHeader>.size + MemoryLayout<ResizeReqPayload>.size
        var buf = [UInt8](repeating: 0, count: total)
        buf.withUnsafeMutableBufferPointer { b in
            memcpy(b.baseAddress!, &header, MemoryLayout<MsgHeader>.size)
            memcpy(b.baseAddress! + MemoryLayout<MsgHeader>.size,
                   &payload, MemoryLayout<ResizeReqPayload>.size)
        }
        let written = buf.withUnsafeBufferPointer { p in
            Darwin.send(sockFD, p.baseAddress, p.count, 0)
        }
        if written != total {
            log.warn(.display,
                "requestResize short send \(written)/\(total) errno=\(errno) (\(width)x\(height))")
        } else {
            log.debug(.display, "requestResize socket sent \(total)B (\(width)x\(height))")
        }
    }

    private func sendHello() throws {
        var header = MsgHeader(type: MessageType.hello.rawValue,
                               payloadLen: UInt32(MemoryLayout<HelloPayload>.size))
        var payload = HelloPayload(protocolVersion: protocolVersion)

        let total = MemoryLayout<MsgHeader>.size + MemoryLayout<HelloPayload>.size
        var buf = [UInt8](repeating: 0, count: total)
        buf.withUnsafeMutableBufferPointer { b in
            memcpy(b.baseAddress!, &header, MemoryLayout<MsgHeader>.size)
            memcpy(b.baseAddress! + MemoryLayout<MsgHeader>.size,
                   &payload, MemoryLayout<HelloPayload>.size)
        }
        let written = buf.withUnsafeBufferPointer { p in
            Darwin.send(sockFD, p.baseAddress, p.count, 0)
        }
        guard written == total else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
    }

    // MARK: - 读循环

    private func runReadLoop(localFD: Int32) {
        var accum = [UInt8]()
        accum.reserveCapacity(64 * 1024)
        var pendingFD: Int32 = -1

        let recvBufSize = 64 * 1024
        var recvBuf = [UInt8](repeating: 0, count: recvBufSize)

        // sockFD 在 close() 里会被改成 -1, 一旦不匹配 localFD 就说明已关,
        // 立即退出 loop, 避免旧 int 被 kernel 复用后读到陌生 socket 的数据。
        while !Task.isCancelled && sockFD == localFD {
            var fd: Int32 = -1
            let n = recvBuf.withUnsafeMutableBufferPointer { p -> ssize_t in
                hvm_recvmsg_with_fd(localFD, p.baseAddress, p.count, &fd)
            }
            if n == 0 {
                emitDisconnect("EOF")
                return
            }
            if n < 0 {
                emitDisconnect("recv errno=\(errno)")
                return
            }
            if fd >= 0 {
                // 新 fd; 若上一个 pendingFD 没被消费(协议错乱), 释放避免泄漏
                if pendingFD >= 0 {
                    Darwin.close(pendingFD)
                }
                pendingFD = fd
            }
            accum.append(contentsOf: recvBuf[0..<Int(n)])

            // 切消息
            while true {
                guard accum.count >= MemoryLayout<MsgHeader>.size else { break }
                var header = MsgHeader(type: 0, payloadLen: 0)
                _ = accum.withUnsafeBufferPointer { src in
                    memcpy(&header, src.baseAddress!, MemoryLayout<MsgHeader>.size)
                }
                let payloadLen = Int(header.payloadLen)
                let needed = MemoryLayout<MsgHeader>.size + payloadLen
                guard accum.count >= needed else { break }

                let payload = Array(accum[MemoryLayout<MsgHeader>.size ..< needed])
                accum.removeFirst(needed)

                let type = MessageType(rawValue: header.type)
                let consumedFD: Int32
                if type == .surface {
                    consumedFD = pendingFD
                    pendingFD = -1
                } else {
                    consumedFD = -1
                }
                dispatch(type: type, payload: payload, fd: consumedFD)
            }
        }

        if pendingFD >= 0 { Darwin.close(pendingFD) }
    }

    // MARK: - dispatch

    private func dispatch(type: MessageType?, payload: [UInt8], fd: Int32) {
        switch type {
        case .surface where payload.count == MemoryLayout<SurfacePayload>.size:
            guard fd >= 0 else {
                // SURFACE 没带 fd, 协议错误 — 丢弃
                return
            }
            var p = SurfacePayload(width: 0, height: 0, stride: 0, format: 0)
            _ = payload.withUnsafeBufferPointer { src in
                memcpy(&p, src.baseAddress!, MemoryLayout<SurfacePayload>.size)
            }
            // 合理性检查 + 溢出防御: UInt32*UInt32 在 Int 乘法里可能溢出,
            // 先用 UInt64 算完再判断。上限 8192x8192@8bpp = 512MB 充分覆盖
            // 未来高分屏场景, 超过就视为错乱或恶意, 关 fd 丢消息。
            let maxDim: UInt32 = 8192
            let maxStride: UInt32 = 8192 * 8
            let size64 = UInt64(p.stride) * UInt64(p.height)
            guard p.width > 0, p.width <= maxDim,
                  p.height > 0, p.height <= maxDim,
                  p.stride > 0, p.stride <= maxStride,
                  size64 > 0, size64 <= UInt64(512 * 1024 * 1024) else {
                log.warn(.display,
                    "SURFACE 参数超限/非法 \(p.width)x\(p.height) stride=\(p.stride), 丢弃")
                Darwin.close(fd)
                return
            }
            let size = Int(size64)
            guard let ptr = mmap(nil, size, PROT_READ, MAP_SHARED, fd, 0),
                  ptr != MAP_FAILED else {
                Darwin.close(fd)
                return
            }
            let fb = SharedFramebuffer(
                width: Int(p.width),
                height: Int(p.height),
                stride: Int(p.stride),
                format: p.format,
                shmFD: fd,
                pointer: ptr,
                size: size
            )
            continuation.yield(.surface(fb))

        case .updateHint where payload.count == MemoryLayout<UpdateHintPayload>.size:
            var p = UpdateHintPayload(x: 0, y: 0, w: 0, h: 0, seq: 0)
            _ = payload.withUnsafeBufferPointer { src in
                memcpy(&p, src.baseAddress!, MemoryLayout<UpdateHintPayload>.size)
            }
            continuation.yield(.updateHint(
                x: Int(p.x), y: Int(p.y), w: Int(p.w), h: Int(p.h), seq: p.seq
            ))

        case .cursor where payload.count >= 16:
            var hotX: Int32 = 0, hotY: Int32 = 0
            var w: UInt32 = 0, h: UInt32 = 0
            payload.withUnsafeBufferPointer { src in
                memcpy(&hotX, src.baseAddress!,      4)
                memcpy(&hotY, src.baseAddress! + 4,  4)
                memcpy(&w,    src.baseAddress! + 8,  4)
                memcpy(&h,    src.baseAddress! + 12, 4)
            }
            // cursor 合理尺寸最大 256x256; 1024 已经极度宽松。防止 w*h*4 溢出。
            let maxCursorDim: UInt32 = 1024
            guard w > 0, w <= maxCursorDim, h > 0, h <= maxCursorDim else {
                log.warn(.display, "cursor 尺寸超限 \(w)x\(h), 丢弃")
                return
            }
            let pixelBytes = Int(w) * Int(h) * 4
            guard payload.count == 16 + pixelBytes else { return }
            let bgra = payload.withUnsafeBufferPointer { src in
                Data(bytes: src.baseAddress! + 16, count: pixelBytes)
            }
            continuation.yield(.cursor(.init(
                hotX: hotX, hotY: hotY, width: Int(w), height: Int(h), bgra: bgra
            )))

        case .mouseSet where payload.count == MemoryLayout<MouseSetPayload>.size:
            var p = MouseSetPayload(x: 0, y: 0, visible: 0)
            _ = payload.withUnsafeBufferPointer { src in
                memcpy(&p, src.baseAddress!, MemoryLayout<MouseSetPayload>.size)
            }
            continuation.yield(.mouseSet(x: p.x, y: p.y, visible: p.visible != 0))

        case .ledState where payload.count == MemoryLayout<LedStatePayload>.size:
            var p = LedStatePayload(ledstate: 0)
            _ = payload.withUnsafeBufferPointer { src in
                memcpy(&p, src.baseAddress!, MemoryLayout<LedStatePayload>.size)
            }
            continuation.yield(.ledState(GuestLEDState(raw: p.ledstate)))

        default:
            // 未知消息 / size 不匹配, 丢弃(若附带 fd 记得关)
            if fd >= 0 { Darwin.close(fd) }
        }
    }

    private func emitDisconnect(_ reason: String?) {
        continuation.yield(.disconnected(reason))
        continuation.finish()
    }
}
