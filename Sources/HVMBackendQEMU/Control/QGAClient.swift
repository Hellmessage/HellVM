// QEMU Guest Agent (qga) 客户端
//
// 协议: 基于 unix socket + 每行一个 JSON 对象, 和 QMP 几乎一样, 但:
//   - 没有 greeting, 连上直接可发命令
//   - 不需要 capabilities 握手
//
// 服务端 qemu 参数:
//   -chardev socket,id=qga_chr,path=<path>,server=on,wait=off
//   -device virtserialport,bus=<bus>,chardev=qga_chr,name=org.qemu.guest_agent.0
//
// 常用命令:
//   guest-ping              —— 验证 guest 端 qemu-guest-agent 活着
//   guest-info              —— 列 guest agent 支持的命令
//   guest-exec              —— 在 guest 里跑一条命令, 返回 pid
//   guest-exec-status       —— 查询 pid 的退出状态 + 捕获的 stdout/stderr (base64)
//   guest-file-open/read/close —— 读 guest 里的任意文件
//
// 注意: guest 没装 qemu-guest-agent 时, socket 能 connect (QEMU 作 server),
// 但 guest 那端没 reader, 所有命令都会 read 超时。这时 ping 就是最廉价的探活。
import Foundation
import Darwin
import HVMCore

/// qga 客户端 —— actor 串行化所有 IO, 避免命令/响应错位
public actor QGAClient {
    private var socketFD: Int32 = -1
    private var readBuffer = Data()
    private var connected: Bool = false

    public init() {}

    // MARK: - 便捷会话

    /// 典型用法: 连一次 → 跑几条命令 → 关掉. 保证 close 一定执行。
    public static func withSession<T>(
        socketPath: String,
        _ body: (QGAClient) async throws -> T
    ) async throws -> T {
        let qga = QGAClient()
        do {
            try await qga.connect(socketPath: socketPath)
            let result = try await body(qga)
            await qga.close()
            return result
        } catch {
            await qga.close()
            throw error
        }
    }

    // MARK: - 连接

    public func connect(socketPath: String) async throws {
        let fd = try Self.openUnixSocket(path: socketPath)
        self.socketFD = fd
        self.connected = true
        // qga 无 greeting、无握手, 连上即可用
    }

    public func close() async {
        if socketFD >= 0 {
            Darwin.close(socketFD)
            socketFD = -1
        }
        connected = false
    }

    // MARK: - 高层命令(返回 Swift 强类型)

    /// guest-ping. guest agent 存活则返回 true, 超时/异常 → false.
    /// 不抛错, 让调用方"是否 ping 成功"当作判断依据。
    @discardableResult
    public func ping() async -> Bool {
        do {
            _ = try await executeRaw("guest-ping")
            return true
        } catch {
            return false
        }
    }

    /// 在 guest 里执行一条命令, 阻塞到退出, 返回 (exitCode, stdout, stderr).
    /// - Parameter path: 可执行文件绝对路径, 如 "/usr/bin/cat" 或 "powershell.exe"
    /// - Parameter args: 参数数组
    /// - Parameter input: 若非 nil, base64 写入 stdin
    /// - Parameter captureOutput: 捕获 stdout/stderr, 默认 true
    /// - Parameter pollIntervalMs: 轮询 exec-status 间隔
    /// - Parameter timeoutSeconds: 总超时, 超时抛错但 guest 侧可能仍在跑
    public func execAndWait(
        path: String,
        args: [String] = [],
        input: Data? = nil,
        captureOutput: Bool = true,
        pollIntervalMs: Int = 200,
        timeoutSeconds: Double = 60
    ) async throws -> (exitCode: Int, stdout: Data, stderr: Data) {
        var execArgs: [String: Any] = [
            "path": path,
            "arg": args,
            "capture-output": captureOutput,
        ]
        if let input, !input.isEmpty {
            execArgs["input-data"] = input.base64EncodedString()
        }
        let ret = try await executeRaw("guest-exec", arguments: execArgs)
        guard let dict = ret as? [String: Any], let pid = dict["pid"] as? Int else {
            throw VMError.backendUnavailable("guest-exec 返回缺 pid: \(ret)")
        }

        let start = Date()
        // statusAttempts: 连续失败的 status 查询计数. guest-agent 有时会短暂
        // 打嗝(系统忙/服务重启), 单次 status 失败就抛错会让 execAndWait
        // 在 guest 命令还在跑的时候就误报失败, 所以容忍 N 次连续失败再放弃。
        var statusAttempts = 0
        let maxStatusAttempts = 5
        while true {
            if Date().timeIntervalSince(start) > timeoutSeconds {
                throw VMError.backendUnavailable("guest-exec 超时 (pid=\(pid), >\(timeoutSeconds)s)")
            }
            let statusRet: Any
            do {
                statusRet = try await executeRaw("guest-exec-status", arguments: ["pid": pid])
                statusAttempts = 0
            } catch {
                statusAttempts += 1
                if statusAttempts >= maxStatusAttempts {
                    throw VMError.backendUnavailable(
                        "guest-exec-status 连续 \(maxStatusAttempts) 次失败 (pid=\(pid)): \(error.localizedDescription)")
                }
                log.warn(.qemu,
                    "guest-exec-status 第 \(statusAttempts)/\(maxStatusAttempts) 次失败, 继续重试: \(error)")
                try? await Task.sleep(nanoseconds: UInt64(pollIntervalMs) * 1_000_000)
                continue
            }
            guard let s = statusRet as? [String: Any] else {
                throw VMError.backendUnavailable("guest-exec-status 返回非 dict: \(statusRet)")
            }
            let exited = s["exited"] as? Bool ?? false
            if exited {
                let exitCode = (s["exitcode"] as? Int) ?? -1
                let stdout = Self.decodeBase64Field(s["out-data"] as? String) ?? Data()
                let stderr = Self.decodeBase64Field(s["err-data"] as? String) ?? Data()
                return (exitCode, stdout, stderr)
            }
            try? await Task.sleep(nanoseconds: UInt64(pollIntervalMs) * 1_000_000)
        }
    }

    /// 读 guest 里的文件, 一次读完返回 Data.
    /// 内部自动分块读, 直到 EOF。
    public func readFile(path: String, chunkBytes: Int = 48 * 1024) async throws -> Data {
        // guest-file-open mode=r → handle
        let openRet = try await executeRaw("guest-file-open",
                                           arguments: ["path": path, "mode": "r"])
        guard let handle = openRet as? Int else {
            throw VMError.backendUnavailable("guest-file-open 返回非 int handle: \(openRet)")
        }
        defer {
            // close 尽力而为, 失败不影响数据返回
            Task { [handle] in
                _ = try? await executeRaw("guest-file-close", arguments: ["handle": handle])
            }
        }

        var out = Data()
        while true {
            let chunk = try await executeRaw("guest-file-read",
                                             arguments: ["handle": handle, "count": chunkBytes])
            guard let d = chunk as? [String: Any] else {
                throw VMError.backendUnavailable("guest-file-read 返回非 dict: \(chunk)")
            }
            if let b64 = d["buf-b64"] as? String, let data = Data(base64Encoded: b64) {
                out.append(data)
            }
            let eof = d["eof"] as? Bool ?? false
            let count = d["count"] as? Int ?? 0
            if eof || count == 0 { break }
        }
        return out
    }

    // MARK: - 低层命令

    /// 发一条 qga 命令, 返回 `return` 字段原值(可能是 dict/int/array/bool)。
    @discardableResult
    public func executeRaw(_ command: String, arguments: [String: Any] = [:]) async throws -> Any {
        guard socketFD >= 0 else {
            throw VMError.backendUnavailable("qga 未连接")
        }
        var req: [String: Any] = ["execute": command]
        if !arguments.isEmpty {
            req["arguments"] = arguments
        }
        try await writeJSON(req)
        while true {
            let msg = try await readMessage()
            if let err = msg["error"] as? [String: Any] {
                let desc = err["desc"] as? String ?? "未知 qga 错误"
                throw VMError.backendUnavailable("qga 命令 \(command) 失败:\(desc)")
            }
            if let ret = msg["return"] {
                return ret
            }
        }
    }

    // MARK: - 底层 IO(和 QMPClient 的实现一致, 保留独立以解耦)

    private func writeJSON(_ obj: [String: Any]) async throws {
        var data = try JSONSerialization.data(withJSONObject: obj)
        data.append(0x0a) // '\n'
        try await Self.blockingWrite(fd: socketFD, data: data)
    }

    /// 单行 JSON 上限: guest-file-read 最大 chunk 48KB, base64 膨胀 1.33x,
    /// 加上协议开销单响应 ~65KB. 10MB 超宽松, 防 OOM。
    private static let maxReadBufferBytes = 10 * 1024 * 1024

    private func readMessage() async throws -> [String: Any] {
        while true {
            if let nlIdx = readBuffer.firstIndex(of: 0x0a) {
                let line = readBuffer[readBuffer.startIndex..<nlIdx]
                readBuffer.removeSubrange(readBuffer.startIndex...nlIdx)
                if line.isEmpty { continue }
                let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] ?? [:]
                return obj
            }
            let chunk = try await Self.blockingRead(fd: socketFD)
            if chunk.isEmpty {
                throw VMError.backendUnavailable("qga 连接关闭")
            }
            readBuffer.append(chunk)
            if readBuffer.count > Self.maxReadBufferBytes {
                throw VMError.backendUnavailable(
                    "qga readBuffer 超过 \(Self.maxReadBufferBytes) bytes 仍未见换行, 协议可能错乱")
            }
        }
    }

    // MARK: - 静态辅助

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

    /// qga 有些命令要跑很久(exec 脚本), 默认超时开到 30s.
    /// 单次 read 系统调用的超时, 不等于整体命令超时(execAndWait 自己有 timeoutSeconds)。
    private static let readTimeoutMs: Int32 = 30000

    private static func blockingRead(fd: Int32) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let pollRc = withUnsafeMutablePointer(to: &pfd) { ptr in
                    Darwin.poll(ptr, 1, readTimeoutMs)
                }
                if pollRc == 0 {
                    cont.resume(throwing: VMError.backendUnavailable(
                        "qga read 超时 (\(readTimeoutMs)ms), guest 侧 agent 可能未跑"))
                    return
                }
                if pollRc < 0 {
                    cont.resume(throwing: VMError.backendUnavailable(
                        "poll() 失败:\(String(cString: strerror(errno)))"))
                    return
                }
                var buf = [UInt8](repeating: 0, count: 4096)
                let n = buf.withUnsafeMutableBufferPointer { bp -> Int in
                    Darwin.read(fd, bp.baseAddress, bp.count)
                }
                if n > 0 {
                    cont.resume(returning: Data(buf.prefix(n)))
                } else if n == 0 {
                    cont.resume(returning: Data())
                } else {
                    cont.resume(throwing: VMError.backendUnavailable(
                        "read() 失败:\(String(cString: strerror(errno)))"))
                }
            }
        }
    }

    private static func blockingWrite(fd: Int32, data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                var offset = 0
                let total = data.count
                let result: Result<Void, Error> = data.withUnsafeBytes { rawBuf -> Result<Void, Error> in
                    guard let base = rawBuf.baseAddress else { return .success(()) }
                    while offset < total {
                        let n = Darwin.write(fd, base.advanced(by: offset), total - offset)
                        if n <= 0 {
                            return .failure(VMError.backendUnavailable(
                                "write() 失败:\(String(cString: strerror(errno)))"))
                        }
                        offset += n
                    }
                    return .success(())
                }
                cont.resume(with: result)
            }
        }
    }

    private static func decodeBase64Field(_ b64: String?) -> Data? {
        guard let b64, !b64.isEmpty else { return nil }
        return Data(base64Encoded: b64)
    }
}
