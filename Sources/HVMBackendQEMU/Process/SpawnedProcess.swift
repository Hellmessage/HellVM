// SpawnedProcess —— 基于 posix_spawn 的独立 process group 子进程包装
//
// 替代 Foundation.Process 的原因:
//   Process.run() 返回时 exec 可能已完成, 父进程再 setpgid(pid, pid) 有 race,
//   macOS 会返回 EACCES. posix_spawn 支持 POSIX_SPAWN_SETPGROUP, 在 fork/exec
//   原子区间设置 pgid, 无 race.
//
// 用法:
//   1. QEMU 子进程体系里, 第一个起的进程传 joinPGID=nil → 自己当 pg leader
//   2. 后续相关进程传 joinPGID=firstProc.pgid → 加入同一个 pg
//   3. 外层要"一键清理"时调 firstProc.terminateProcessGroup(SIGKILL), 所有成员
//      (QEMU + swtpm) 一次性收走, 避免孤儿。
//
// 限制:
//   - 只用于不需要 TTY / controlling terminal 的后台进程。
//   - CLI 前台模式下 QEMU 继续走 execv (见 QEMUBackend.execReplacing).
import Foundation
import Darwin
import HVMCore

public final class SpawnedProcess: @unchecked Sendable {
    /// 子进程 pid
    public let pid: pid_t
    /// 所在 process group id
    ///   - 自己是 pg leader: pgid == pid
    ///   - 加入别人的 pg: pgid == 别人的 pid
    public let pgid: pid_t
    /// 可执行路径(仅做日志)
    public let executable: URL

    // stdout/stderr 父侧读端
    private let stdoutReadFD: Int32
    private let stderrReadFD: Int32
    private let stdoutHandle: FileHandle
    private let stderrHandle: FileHandle

    // 退出监听
    private let exitQueue = DispatchQueue(label: "hellvm.spawned.exit")
    private var exitSource: DispatchSourceProcess?

    private let exitLock = NSLock()
    private var exitStatus: Int32?
    private var continuations: [CheckedContinuation<Int32, Never>] = []

    /// 进程退出时回调, 参数是退出码(异常终止为 -1)
    public var terminationHandler: ((Int32) -> Void)?

    /// 是否还在运行(exit handler 尚未触发)
    public var isRunning: Bool {
        withLock { exitStatus } == nil
    }

    private init(pid: pid_t, pgid: pid_t, executable: URL, stdoutReadFD: Int32, stderrReadFD: Int32) {
        self.pid = pid
        self.pgid = pgid
        self.executable = executable
        self.stdoutReadFD = stdoutReadFD
        self.stderrReadFD = stderrReadFD
        self.stdoutHandle = FileHandle(fileDescriptor: stdoutReadFD, closeOnDealloc: false)
        self.stderrHandle = FileHandle(fileDescriptor: stderrReadFD, closeOnDealloc: false)
    }

    // MARK: - spawn

    /// 启动一个子进程。
    /// - Parameters:
    ///   - executable: 可执行文件绝对路径
    ///   - arguments: 参数列表(不含 argv[0], 内部补 executable.lastPathComponent)
    ///   - joinPGID: nil → 成为新 pg leader; 非 nil → 加入已有 pg
    ///   - lineHandler: 每读到一行调用一次 (按 \n 切行, 剥掉尾 \r)
    public static func spawn(
        executable: URL,
        arguments: [String],
        joinPGID: pid_t? = nil,
        lineHandler: @escaping (_ line: String, _ isStderr: Bool) -> Void
    ) throws -> SpawnedProcess {
        // ----- 开 stdout / stderr pipe -----
        var stdoutFDs: [Int32] = [-1, -1]
        var stderrFDs: [Int32] = [-1, -1]

        let rcOut = stdoutFDs.withUnsafeMutableBufferPointer { bp in
            Darwin.pipe(bp.baseAddress!)
        }
        guard rcOut == 0 else {
            throw VMError.startFailed("pipe() stdout 失败: \(errnoMessage())")
        }
        let rcErr = stderrFDs.withUnsafeMutableBufferPointer { bp in
            Darwin.pipe(bp.baseAddress!)
        }
        guard rcErr == 0 else {
            Darwin.close(stdoutFDs[0]); Darwin.close(stdoutFDs[1])
            throw VMError.startFailed("pipe() stderr 失败: \(errnoMessage())")
        }

        // ----- file_actions: stdin=/dev/null, stdout/stderr = pipe write end -----
        var fa: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fa)
        defer { posix_spawn_file_actions_destroy(&fa) }

        _ = "/dev/null".withCString { dn in
            posix_spawn_file_actions_addopen(&fa, 0, dn, O_RDONLY, 0)
        }
        posix_spawn_file_actions_adddup2(&fa, stdoutFDs[1], 1)
        posix_spawn_file_actions_adddup2(&fa, stderrFDs[1], 2)
        // dup 完子进程这些原 fd 就不需要了, 统一 close 避免泄漏
        posix_spawn_file_actions_addclose(&fa, stdoutFDs[0])
        posix_spawn_file_actions_addclose(&fa, stderrFDs[0])
        posix_spawn_file_actions_addclose(&fa, stdoutFDs[1])
        posix_spawn_file_actions_addclose(&fa, stderrFDs[1])

        // ----- attr: SETPGROUP 原子设置 pgid (无 race) -----
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attr, joinPGID ?? 0)  // 0 = 自己当 pg leader

        // ----- argv / envp -----
        let argv0 = executable.lastPathComponent
        let fullArgs = [argv0] + arguments
        var cArgv: [UnsafeMutablePointer<CChar>?] = fullArgs.map { strdup($0) }
        cArgv.append(nil)
        defer { for p in cArgv where p != nil { free(p) } }

        var cEnv: [UnsafeMutablePointer<CChar>?] = ProcessInfo.processInfo.environment.map {
            strdup("\($0.key)=\($0.value)")
        }
        cEnv.append(nil)
        defer { for p in cEnv where p != nil { free(p) } }

        // ----- spawn -----
        var childPid: pid_t = 0
        let rc: Int32 = executable.path.withCString { execPath in
            cArgv.withUnsafeMutableBufferPointer { argvBuf in
                cEnv.withUnsafeMutableBufferPointer { envBuf in
                    posix_spawn(&childPid, execPath, &fa, &attr, argvBuf.baseAddress, envBuf.baseAddress)
                }
            }
        }

        // 父进程关写端(无论 spawn 成功失败, 写端在父侧已不需要)
        Darwin.close(stdoutFDs[1])
        Darwin.close(stderrFDs[1])

        guard rc == 0 else {
            Darwin.close(stdoutFDs[0])
            Darwin.close(stderrFDs[0])
            throw VMError.startFailed("posix_spawn(\(executable.lastPathComponent)) 失败: \(String(cString: strerror(rc)))")
        }

        let actualPGID: pid_t = joinPGID ?? childPid
        let sp = SpawnedProcess(pid: childPid, pgid: actualPGID, executable: executable, stdoutReadFD: stdoutFDs[0], stderrReadFD: stderrFDs[0])
        sp.startReading(lineHandler: lineHandler)
        sp.startWatchingExit()
        return sp
    }

    // MARK: - 信号控制

    /// 向当前子进程发信号(不影响 pg 其他成员)
    public func sendSignal(_ sig: Int32) {
        _ = kill(pid, sig)
    }

    /// 向整个 process group 发信号(killpg). 用于一次性清掉 QEMU + swtpm。
    public func terminateProcessGroup(_ sig: Int32) {
        _ = killpg(pgid, sig)
    }

    // MARK: - 等待退出

    /// 异步等待进程退出, 返回退出码
    public func waitForExit() async -> Int32 {
        // 已经退出直接返回
        if let s = withLock({ exitStatus }) { return s }
        return await withCheckedContinuation { (cont: CheckedContinuation<Int32, Never>) in
            var immediate: Int32?
            withLock {
                if let s = exitStatus {
                    immediate = s
                } else {
                    continuations.append(cont)
                }
            }
            if let s = immediate { cont.resume(returning: s) }
        }
    }

    // MARK: - 内部

    private func startReading(lineHandler: @escaping (String, Bool) -> Void) {
        let outBuf = LineBufferPS()
        let errBuf = LineBufferPS()
        // 用 Swift throws 版 API read(upToCount:) 替代老式 availableData.
        // availableData 在 fd 关闭 / I/O 错时会 raise ObjC NSException,
        // Swift 层 do/try/catch 抓不住 ObjC 异常 → 直达 terminate → abort 整个 App.
        // race 场景: exit 时 readabilityHandler=nil 不是同步 barrier,
        //   dispatch 队列里已调度的 handler 可能在 fd 被关后再进来读一次, 之前会炸。
        // 改用 Swift throws API 后该场景只 throw CocoaError, catch 置 nil 即可。
        stdoutHandle.readabilityHandler = { h in
            let data: Data
            do {
                data = (try h.read(upToCount: 64 * 1024)) ?? Data()
            } catch {
                h.readabilityHandler = nil
                return
            }
            if data.isEmpty { h.readabilityHandler = nil; return }
            outBuf.append(data) { line in lineHandler(line, false) }
        }
        stderrHandle.readabilityHandler = { h in
            let data: Data
            do {
                data = (try h.read(upToCount: 64 * 1024)) ?? Data()
            } catch {
                h.readabilityHandler = nil
                return
            }
            if data.isEmpty { h.readabilityHandler = nil; return }
            errBuf.append(data) { line in lineHandler(line, true) }
        }
    }

    private func startWatchingExit() {
        let src = DispatchSource.makeProcessSource(
            identifier: pid, eventMask: .exit, queue: exitQueue)
        src.setEventHandler { [weak self] in
            guard let self = self else { return }
            var status: Int32 = 0
            _ = waitpid(self.pid, &status, 0)
            // 正常退出: (status & 0177) == 0 → exit code = (status >> 8) & 0xff
            // 被信号杀: 用 -1 代表异常
            let code: Int32 = (status & 0o177) == 0 ? (status >> 8) & 0xff : -1

            var conts: [CheckedContinuation<Int32, Never>] = []
            var handler: ((Int32) -> Void)?
            self.withLock {
                self.exitStatus = code
                conts = self.continuations
                self.continuations = []
                handler = self.terminationHandler
            }
            for c in conts { c.resume(returning: code) }

            // 关 pipe fd (readabilityHandler 已自退)
            self.stdoutHandle.readabilityHandler = nil
            self.stderrHandle.readabilityHandler = nil
            // 用 FileHandle.close() 而不是 Darwin.close(raw fd):
            // 前者让 FileHandle 内部标记 closed, 即便 in-flight readability handler
            // 还在调 read(upToCount:) 也只会 throw Swift error(被闭包 catch 置 nil),
            // 不会像 Darwin.close 后 availableData 那样 raise ObjC 异常。
            try? self.stdoutHandle.close()
            try? self.stderrHandle.close()
            src.cancel()

            handler?(code)
        }
        self.exitSource = src
        src.resume()
    }

    @inline(__always)
    private func withLock<T>(_ body: () -> T) -> T {
        exitLock.lock()
        defer { exitLock.unlock() }
        return body()
    }
}

// MARK: - 行缓冲

/// 按 \n 切行缓冲, 超长单行兜底
private final class LineBufferPS: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()

    func append(_ chunk: Data, emit: (String) -> Void) {
        lock.lock(); defer { lock.unlock() }
        data.append(chunk)
        while let nl = data.firstIndex(of: 0x0a) {
            let lineData = data[data.startIndex..<nl]
            data.removeSubrange(data.startIndex...nl)
            var line = String(data: Data(lineData), encoding: .utf8) ?? ""
            if line.hasSuffix("\r") { line.removeLast() }
            if !line.isEmpty { emit(line) }
        }
        // 无 \n 超长单行保护, 避免 buffer 无限增长
        if data.count > 64 * 1024 {
            let line = String(data: data, encoding: .utf8) ?? ""
            data.removeAll(keepingCapacity: true)
            if !line.isEmpty { emit(line) }
        }
    }
}

private func errnoMessage() -> String {
    String(cString: strerror(errno))
}
