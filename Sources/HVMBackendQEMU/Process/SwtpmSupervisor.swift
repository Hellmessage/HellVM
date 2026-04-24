// swtpm 子进程监管器 —— 从 QEMUBackend 抽出来, 独立管理 swtpm 的生命周期
//
// 设计:
// - swtpm 先起, 自己当 process-group leader; QEMU 后 spawn 时 joinPGID 加入同 pg.
//   这样 stop(force:true) 只需 killpg 一次就能原子清掉 swtpm+QEMU 两者, 不会留孤儿。
// - swtpm 的 `,terminate` 选项**故意不加**: 该选项会让 swtpm 在 control socket
//   连接关闭时立即自退, 与 start() 里的 canConnect() 探测(连上立刻 close)冲突 ——
//   swtpm 误把探测当成 "QEMU 断开" 自退, 于是 socket 消失, 随后 QEMU 真正连接时
//   ENOENT 启动失败。改为不带 terminate, swtpm 生命周期全由 killpg 原子清理。
// - start() 同步阻塞最多 3 秒等 socket 可被 connect, 出不来或进程先死说明 swtpm 挂了。
import Foundation
import Darwin
import HVMCore
import HVMBundle

final class SwtpmSupervisor: @unchecked Sendable {
    private let bundle: VMBundle
    private let lock = NSLock()
    private var spawned: SpawnedProcess?

    init(bundle: VMBundle) {
        self.bundle = bundle
    }

    /// 当前 swtpm 的 pg leader pgid —— QEMU spawn 时传 joinPGID 加入同 pg.
    /// 未启动时返回 nil, 此时 QEMU 会自己当 pg leader(等价于没有 TPM 的情况)。
    var pgid: pid_t? {
        lock.lock(); defer { lock.unlock() }
        return spawned?.pgid
    }

    /// 是否已启动(有未退出的子进程)
    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return spawned?.isRunning ?? false
    }

    /// 启动 swtpm 子进程并等它监听的 unix socket 出现.
    /// - Returns: socket 绝对路径
    func start() throws -> String {
        let swtpmURL = try Self.findBinary()
        let stateDir = bundle.tpmStateDirURL
        let sockURL = bundle.tpmSocketURL
        let logFile = bundle.logsDirURL.appendingPathComponent("swtpm.log")

        let fm = FileManager.default
        try fm.createDirectory(at: stateDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: bundle.logsDirURL, withIntermediateDirectories: true)
        fm.removeIfExists(sockURL, label: "陈旧 swtpm socket", category: .qemu)

        let swtpmArgs = [
            "socket",
            "--tpmstate", "dir=\(stateDir.path)",
            "--ctrl", "type=unixio,path=\(sockURL.path)",
            "--tpm2",
            "--flags", "startup-clear",
            "--log", "level=5,file=\(logFile.path)",
        ]

        // swtpm 先起 → 自己当 pg leader; QEMU 后加入同 pg, 便于 killpg 原子清理.
        // stdout/stderr 并入主 log, 方便排查启动失败.
        let spawned: SpawnedProcess
        do {
            spawned = try SpawnedProcess.spawn(
                executable: swtpmURL,
                arguments: swtpmArgs,
                joinPGID: nil,
                lineHandler: { line, _ in
                    log.warn(.qemu, "[swtpm] \(line)")
                }
            )
        } catch {
            throw VMError.startFailed("swtpm 启动失败: \(error.localizedDescription)")
        }

        lock.lock()
        self.spawned = spawned
        lock.unlock()

        // 等 swtpm 监听的 unix socket 能被真正 connect.
        // 仅检查文件存在不够: 文件可能是前一个 swtpm 残留, 或进程刚创建完 socket
        // 但还没 listen, 这时 QEMU 尝试连会 ECONNREFUSED 启动失败, 日志又不清晰。
        // 这里主动 connect 一下, 能连上才算真就绪。同时每轮先检查进程存活,
        // 进程已死就立即抛错, 不等满超时。
        let timeoutMs = 3_000
        let pollMs: UInt32 = 100
        for _ in 0..<(timeoutMs / Int(pollMs)) {
            if !spawned.isRunning {
                let pid = spawned.pid
                self.terminate()
                throw VMError.startFailed(
                    "swtpm 进程 pid=\(pid) 启动后立即退出, 请检查 \(logFile.path)")
            }
            if fm.fileExists(atPath: sockURL.path),
               Self.canConnect(socketPath: sockURL.path) {
                log.info(.qemu, "[swtpm] 已就绪, pid=\(spawned.pid) socket=\(sockURL.path) state=\(stateDir.path)")
                return sockURL.path
            }
            usleep(pollMs * 1_000)
        }
        terminate()
        throw VMError.startFailed("swtpm 启动 \(timeoutMs)ms 内 socket 仍不可连, 请检查 \(logFile.path)")
    }

    /// 尝试 connect 指定 unix socket 一下, 立刻断开. 仅用于"活性探测",
    /// 不读写数据。连得上说明对端(swtpm)已经 listen 并 accept 了。
    private static func canConnect(socketPath: String) -> Bool {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxPath = MemoryLayout.size(ofValue: addr.sun_path)
        guard socketPath.utf8.count < maxPath else { return false }
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { sunPathPtr in
            sunPathPtr.withMemoryRebound(to: CChar.self, capacity: maxPath) { cptr in
                socketPath.withCString { src in
                    strlcpy(cptr, src, maxPath)
                }
            }
        }
        let rc = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return rc == 0
    }

    /// 幂等终止 swtpm.
    /// 因为我们不再带 `,terminate` 标志 (见文件头注释), swtpm 不会随
    /// control 断开自退, 必须显式 kill。实测 swtpm 对 SIGTERM 响应慢或
    /// 会忽略, 所以 SIGTERM 等 500ms 仍存活则 SIGKILL 兜底, 保证不残留孤儿。
    func terminate() {
        let proc: SpawnedProcess? = {
            lock.lock(); defer { lock.unlock() }
            let p = self.spawned
            self.spawned = nil
            return p
        }()
        guard let proc, proc.isRunning else { return }
        proc.sendSignal(SIGTERM)
        for _ in 0..<10 {  // 最多等 500ms
            if !proc.isRunning { return }
            usleep(50_000)
        }
        if proc.isRunning {
            log.warn(.qemu, "[swtpm] SIGTERM 后 500ms 未退, SIGKILL 兜底 pid=\(proc.pid)")
            proc.sendSignal(SIGKILL)
        }
    }

    // MARK: - 内部

    /// 查找 swtpm 可执行文件(Homebrew / MacPorts 常见安装位置)
    private static func findBinary() throws -> URL {
        let candidates = [
            "/opt/homebrew/bin/swtpm",
            "/usr/local/bin/swtpm",
            "/opt/local/bin/swtpm",
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        throw VMError.startFailed("swtpm 未安装, 请执行: brew install swtpm")
    }
}
