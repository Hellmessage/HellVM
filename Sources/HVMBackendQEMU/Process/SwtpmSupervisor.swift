// swtpm 子进程监管器 —— 从 QEMUBackend 抽出来, 独立管理 swtpm 的生命周期
//
// 设计:
// - swtpm 先起, 自己当 process-group leader; QEMU 后 spawn 时 joinPGID 加入同 pg.
//   这样 stop(force:true) 只需 killpg 一次就能原子清掉 swtpm+QEMU 两者, 不会留孤儿。
// - `--ctrl ...,terminate` 让 swtpm 在 QEMU 断开 control socket 时自退出, 正常路径
//   不依赖显式 SIGTERM。terminate() 只是双保险 / 异常清理。
// - start() 同步阻塞最多 3 秒等 socket 文件出现, 出不来说明 swtpm 挂了。
import Foundation
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
            "--ctrl", "type=unixio,path=\(sockURL.path),terminate",
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

        // 等 swtpm 监听的 unix socket 出现, 超时说明进程挂了
        let timeoutMs = 3_000
        let pollMs: UInt32 = 100
        for _ in 0..<(timeoutMs / Int(pollMs)) {
            if fm.fileExists(atPath: sockURL.path) {
                log.info(.qemu, "[swtpm] 已启动, pid=\(spawned.pid) socket=\(sockURL.path) state=\(stateDir.path)")
                return sockURL.path
            }
            usleep(pollMs * 1_000)
        }
        terminate()
        throw VMError.startFailed("swtpm 启动 \(timeoutMs)ms 内未产生 socket, 请检查 \(logFile.path)")
    }

    /// 幂等终止 swtpm. 正常路径上 QEMU 退出时 `,terminate` 会让 swtpm 自退,
    /// 这里只是双保险和异常路径清理。
    func terminate() {
        let proc: SpawnedProcess? = {
            lock.lock(); defer { lock.unlock() }
            let p = self.spawned
            self.spawned = nil
            return p
        }()
        guard let proc, proc.isRunning else { return }
        proc.sendSignal(SIGTERM)
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
