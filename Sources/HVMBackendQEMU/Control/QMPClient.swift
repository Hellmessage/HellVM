// QMP (QEMU Machine Protocol) 客户端
// 协议:基于 unix socket + 每行一个 JSON 对象
// 服务端 qemu 参数:-qmp unix:<path>,server=on,wait=off
// 典型交互:
//   1. 客户端连接后,服务端推送 greeting {"QMP":{...}}
//   2. 客户端发送 {"execute":"qmp_capabilities"} 完成握手
//   3. 之后可发送命令,服务端响应 {"return":{...}} 或 {"error":{...}}
//   4. 服务端可随时推送事件 {"event":"...","data":{...}}
import Foundation
import Darwin
import HVMCore

/// QMP 客户端 —— actor 串行化所有 IO,避免消息错位
public actor QMPClient {
    private var socketFD: Int32 = -1
    private var readBuffer = Data()
    private var connected: Bool = false

    public init() {}

    // MARK: - 便捷会话

    /// 典型 QMP 用法:连一次、执行几条命令、关掉。
    /// 把 connect/close 样板收到一起,调用方只写闭包里的命令。
    /// 即使 body 抛异常,close 也会被执行。
    public static func withSession<T>(
        socketPath: String,
        _ body: (QMPClient) async throws -> T
    ) async throws -> T {
        let qmp = QMPClient()
        do {
            try await qmp.connect(socketPath: socketPath)
            let result = try await body(qmp)
            await qmp.close()
            return result
        } catch {
            await qmp.close()
            throw error
        }
    }

    // MARK: - 连接

    /// 连接并完成握手
    public func connect(socketPath: String) async throws {
        let fd = try Self.openUnixSocket(path: socketPath)
        self.socketFD = fd
        // 握手任一步失败都要把 fd 关掉并复位, 否则调用方(比如在 catch 后
        // 又尝试 execute)会用到已半死状态的 fd, 行为不确定.
        do {
            // 读 greeting(必须丢弃,不是命令响应)
            _ = try await readMessage()
            self.connected = true
            _ = try await execute("qmp_capabilities")
        } catch {
            Darwin.close(fd)
            self.socketFD = -1
            self.connected = false
            self.readBuffer.removeAll(keepingCapacity: false)
            throw error
        }
    }

    public func close() async {
        if socketFD >= 0 {
            Darwin.close(socketFD)
            socketFD = -1
        }
        connected = false
    }

    // MARK: - 命令

    /// 执行一条 QMP 命令, 返回 return 字段原始类型 (可能是 [String:Any] / [[String:Any]] / Bool 等).
    /// 不做类型断言, 调用方自行解读。适合 query-pci 等返回数组的命令。
    @discardableResult
    public func executeRaw(_ command: String, arguments: [String: Any] = [:]) async throws -> Any {
        guard socketFD >= 0 else {
            throw VMError.backendUnavailable("QMP 未连接")
        }
        var req: [String: Any] = ["execute": command]
        if !arguments.isEmpty {
            req["arguments"] = arguments
        }
        try await writeJSON(req)
        while true {
            let msg = try await readMessage()
            if let err = msg["error"] as? [String: Any] {
                let desc = err["desc"] as? String ?? "未知 QMP 错误"
                throw VMError.backendUnavailable("QMP 命令 \(command) 失败:\(desc)")
            }
            if let ret = msg["return"] {
                return ret
            }
        }
    }

    /// 执行一条 QMP 命令,返回 return 字段(通常是 dict 或 nil)
    @discardableResult
    public func execute(_ command: String, arguments: [String: Any] = [:]) async throws -> [String: Any] {
        guard socketFD >= 0 else {
            throw VMError.backendUnavailable("QMP 未连接")
        }

        var req: [String: Any] = ["execute": command]
        if !arguments.isEmpty {
            req["arguments"] = arguments
        }
        try await writeJSON(req)

        // 跳过 event 消息,等到 return/error
        while true {
            let msg = try await readMessage()
            if let err = msg["error"] as? [String: Any] {
                let desc = err["desc"] as? String ?? "未知 QMP 错误"
                throw VMError.backendUnavailable("QMP 命令 \(command) 失败:\(desc)")
            }
            if let ret = msg["return"] {
                return ret as? [String: Any] ?? [:]
            }
            // event 或 greeting,继续等
        }
    }

    // MARK: - 底层 IO

    private func writeJSON(_ obj: [String: Any]) async throws {
        var data = try JSONSerialization.data(withJSONObject: obj)
        data.append(0x0a) // '\n'
        try await Self.blockingWrite(fd: socketFD, data: data)
    }

    /// 单行 JSON 上限: QMP 正常响应只有几 KB, 10MB 足以覆盖极端 query-*
    /// 返回大数组场景; 超过就视为协议错乱或攻击, 抛错防止 OOM.
    private static let maxReadBufferBytes = 10 * 1024 * 1024

    private func readMessage() async throws -> [String: Any] {
        while true {
            // buffer 里有完整一行?
            if let nlIdx = readBuffer.firstIndex(of: 0x0a) {
                let line = readBuffer[readBuffer.startIndex..<nlIdx]
                readBuffer.removeSubrange(readBuffer.startIndex...nlIdx)
                if line.isEmpty { continue }
                let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] ?? [:]
                return obj
            }
            // 读更多
            let chunk = try await Self.blockingRead(fd: socketFD)
            if chunk.isEmpty {
                throw VMError.backendUnavailable("QMP 连接关闭")
            }
            readBuffer.append(chunk)
            if readBuffer.count > Self.maxReadBufferBytes {
                throw VMError.backendUnavailable(
                    "QMP readBuffer 超过 \(Self.maxReadBufferBytes) bytes 仍未见换行, 协议可能错乱")
            }
        }
    }

    // MARK: - 静态辅助

    /// 打开 unix socket 并连接到指定路径
    private static func openUnixSocket(path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw VMError.backendUnavailable("socket() 失败:\(String(cString: strerror(errno)))")
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let sunPathSize = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < sunPathSize else {
            Darwin.close(fd)
            throw VMError.backendUnavailable("socket 路径过长:\(path)")
        }
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { sunPathPtr in
            sunPathPtr.withMemoryRebound(to: CChar.self, capacity: sunPathSize) { cptr in
                path.withCString { src in
                    strlcpy(cptr, src, sunPathSize)
                }
            }
        }

        let rc = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else {
            let err = String(cString: strerror(errno))
            Darwin.close(fd)
            throw VMError.backendUnavailable("connect(\(path)) 失败:\(err)")
        }
        return fd
    }

    /// 读 socket 的超时(毫秒)。QEMU 半死(socket 半开、不 flush) 时兜底,
    /// 避免 Task 永远 hang。默认 5 秒足以覆盖正常命令响应。
    private static let readTimeoutMs: Int32 = 5000

    /// 把阻塞 read 封装成 async(用后台 queue 避免卡 actor)
    /// 用 poll() 先等可读事件, 超时抛 VMError.backendUnavailable
    private static func blockingRead(fd: Int32) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let pollRc = withUnsafeMutablePointer(to: &pfd) { ptr in
                    Darwin.poll(ptr, 1, readTimeoutMs)
                }
                if pollRc == 0 {
                    cont.resume(throwing: VMError.backendUnavailable(
                        "QMP read 超时 (\(readTimeoutMs)ms), QEMU 可能已死"))
                    return
                }
                if pollRc < 0 {
                    cont.resume(throwing: VMError.backendUnavailable(
                        "poll() 失败:\(String(cString: strerror(errno)))"))
                    return
                }
                // POLLHUP / POLLERR 也会让 poll 返回 >0, 后面 read 会返回 0 或 -1
                var buf = [UInt8](repeating: 0, count: 4096)
                let n = buf.withUnsafeMutableBufferPointer { bp -> Int in
                    Darwin.read(fd, bp.baseAddress, bp.count)
                }
                if n > 0 {
                    cont.resume(returning: Data(buf.prefix(n)))
                } else if n == 0 {
                    cont.resume(returning: Data()) // EOF
                } else {
                    cont.resume(throwing: VMError.backendUnavailable("read() 失败:\(String(cString: strerror(errno)))"))
                }
            }
        }
    }

    /// 把阻塞 write 封装成 async,确保全部写入
    private static func blockingWrite(fd: Int32, data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                var offset = 0
                let total = data.count
                let result: Result<Void, Error> = data.withUnsafeBytes { rawBuf -> Result<Void, Error> in
                    guard let base = rawBuf.baseAddress else {
                        return .success(())
                    }
                    while offset < total {
                        let n = Darwin.write(fd, base.advanced(by: offset), total - offset)
                        if n <= 0 {
                            return .failure(VMError.backendUnavailable("write() 失败:\(String(cString: strerror(errno)))"))
                        }
                        offset += n
                    }
                    return .success(())
                }
                cont.resume(with: result)
            }
        }
    }
}
