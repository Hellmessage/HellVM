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

    // MARK: - 连接

    /// 连接并完成握手
    public func connect(socketPath: String) async throws {
        let fd = try Self.openUnixSocket(path: socketPath)
        self.socketFD = fd

        // 读 greeting(必须丢弃,不是命令响应)
        _ = try await readMessage()

        self.connected = true

        // 握手
        _ = try await execute("qmp_capabilities")
    }

    public func close() async {
        if socketFD >= 0 {
            Darwin.close(socketFD)
            socketFD = -1
        }
        connected = false
    }

    // MARK: - 命令

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

    /// 把阻塞 read 封装成 async(用后台 queue 避免卡 actor)
    private static func blockingRead(fd: Int32) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
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
