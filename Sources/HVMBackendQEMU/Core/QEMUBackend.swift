// QEMU 后端 —— 通过子进程启动 qemu-system-<arch>,以 HVF 加速
// P1:串口引导 + execv CLI 前台模式
// P2:QMP 控制通道(stop/pause/resume 通过 system_powerdown / stop / cont 实现)+ PID 文件
// P4:接入共享内存 framebuffer 做图形显示
import Foundation
import HVMCore
import HVMBundle

/// 基于 QEMU 子进程的 VM 后端
public final class QEMUBackend: VMBackend, @unchecked Sendable {
    public let config: VMConfig
    public let bundle: VMBundle
    public let paths: QEMUPaths

    private let stateLock = NSLock()
    private var _state: VMState = .stopped
    /// QEMU 子进程, 走 posix_spawn + 独立 process group
    private var process: SpawnedProcess?
    /// swtpm 子进程监管 —— 启用 TPM 时先拉起作 pg leader, QEMU 加入同 pg.
    /// 这样 stop(force:true) 一次 killpg 就能原子清掉两者, 不会留孤儿.
    private let swtpm: SwtpmSupervisor

    public var state: VMState {
        withStateLock { _state }
    }

    private let stateContinuation: AsyncStream<VMState>.Continuation
    public let stateStream: AsyncStream<VMState>

    public init(config: VMConfig, bundle: VMBundle, paths: QEMUPaths) throws {
        self.config = config
        self.bundle = bundle
        self.paths = paths
        self.swtpm = SwtpmSupervisor(bundle: bundle)
        var cont: AsyncStream<VMState>.Continuation!
        self.stateStream = AsyncStream { cont = $0 }
        self.stateContinuation = cont
    }

    // MARK: - 生命周期(GUI 异步模式用)

    public func start() async throws {
        // 允许从 .stopped 或 .error 重试启动: .error 是上一次启动失败的终态,
        // 用户看到错误提示后点"重启"应该能直接再来, 不需要额外 reset 操作。
        try ensureStateIn([.stopped, .error], action: "start")
        setState(.starting)

        let efiVars: URL
        do {
            efiVars = try prepareEFIVars()
        } catch {
            setState(.error)
            throw error
        }

        // 启用 TPM: 先起 swtpm 子进程, 让它 listen 在 unix socket 上, QEMU 后面通过 chardev 连入
        // swtpm 作 pg leader, QEMU 加入同 pg → stop(force) 时 killpg 一次清干净
        var tpmSocketPath: String? = nil
        if config.boot.tpm {
            do {
                tpmSocketPath = try swtpm.start()
            } catch {
                setState(.error)
                throw error
            }
        }

        let args: [String]
        do {
            args = try buildArguments(efiVars: efiVars, tpmSocketPath: tpmSocketPath)
        } catch {
            swtpm.terminate()
            setState(.error)
            throw error
        }

        let qemuURL = paths.qemuSystem(config.architecture)
        guard FileManager.default.isExecutableFile(atPath: qemuURL.path) else {
            swtpm.terminate()
            setState(.error)
            throw VMError.startFailed("找不到 qemu 可执行文件:\(qemuURL.path)")
        }

        // GUI 模式: stdin=/dev/null, stdout/stderr 逐行送 Logger(.qemu).
        // 日志统一落到 <bundle>/logs/hellvm.log (Logger 10MB 滚动).
        let spawned: SpawnedProcess
        do {
            spawned = try SpawnedProcess.spawn(
                executable: qemuURL,
                arguments: args,
                joinPGID: swtpm.pgid,
                lineHandler: { line, isStderr in
                    if isStderr {
                        log.warn(.qemu, line)
                    } else {
                        log.info(.qemu, line)
                    }
                }
            )
        } catch {
            swtpm.terminate()
            setState(.error)
            throw VMError.startFailed("启动 qemu 失败:\(error.localizedDescription)")
        }

        spawned.terminationHandler = { [weak self] _ in
            guard let self = self else { return }
            // QEMU 退出时连带杀掉 swtpm(swtpm 的 ,terminate 标志也会自退, 双保险)
            self.swtpm.terminate()
            self.withStateLock { self.process = nil }
            self.setState(.stopped)
        }

        withStateLock { self.process = spawned }
        setState(.running)
    }

    public func stop(force: Bool) async throws {
        let proc: SpawnedProcess? = withStateLock {
            guard let p = self.process, self._state == .running || self._state == .starting else {
                return nil
            }
            self._state = .stopping
            return p
        }
        guard let proc else { return }
        stateContinuation.yield(.stopping)

        if force {
            // killpg 一次清掉整个 pg (QEMU + swtpm 原子, 不会留孤儿).
            // 若未启 TPM, pg 只有 QEMU 自己, 等价于 kill(qemu, SIGKILL).
            proc.terminateProcessGroup(SIGKILL)
        } else {
            // 优先走 QMP system_powerdown, 失败再退回 SIGTERM
            if !(await gracefulPowerdown()) {
                proc.sendSignal(SIGTERM)
            }
        }
    }

    public func pause() async throws {
        try await qmpCommand("stop")
    }

    public func resume() async throws {
        try await qmpCommand("cont")
    }

    /// 阻塞等待 VM 进程退出(GUI 异步模式使用)
    public func waitUntilExit() async {
        let proc = withStateLock { self.process }
        if let p = proc { _ = await p.waitForExit() }
    }

    // MARK: - QMP 便捷方法

    private func gracefulPowerdown() async -> Bool {
        do {
            try await qmpCommand("system_powerdown")
            return true
        } catch {
            return false
        }
    }

    private func qmpCommand(_ command: String) async throws {
        try await QMPClient.withSession(socketPath: bundle.qmpSocketURL.path) { qmp in
            _ = try await qmp.execute(command)
        }
    }

    // MARK: - 同步状态锁辅助

    @inline(__always)
    private func withStateLock<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    /// CLI 前台模式:用 execv 替换当前进程为 qemu。
    /// 成功时不返回(process image 被替换),失败时抛错。
    /// 这样 qemu 直接继承用户终端的 TTY / controlling terminal / 所有 FD,
    /// 绕开 Swift Foundation.Process + posix_spawn 在 TTY 继承上的行为差异。
    /// 注:本函数会 exec 替换当前进程, 所以提前拉起的 swtpm 会被自动"过继"给 init(pid=1),
    /// 但带 `--ctrl ...,terminate` 标志, QEMU 退出时 swtpm 仍会自己清理。
    public func execReplacing() throws {
        let efiVars = try prepareEFIVars()
        var tpmSocketPath: String? = nil
        if config.boot.tpm {
            tpmSocketPath = try swtpm.start()
        }
        let args = try buildArguments(efiVars: efiVars, tpmSocketPath: tpmSocketPath)
        let qemuURL = paths.qemuSystem(config.architecture)
        guard FileManager.default.isExecutableFile(atPath: qemuURL.path) else {
            throw VMError.startFailed("找不到 qemu 可执行文件:\(qemuURL.path)")
        }

        // 构造 argv:argv[0] 是程序名,不含路径
        var cArgv: [UnsafeMutablePointer<CChar>?] = []
        cArgv.append(strdup(qemuURL.lastPathComponent))
        for a in args {
            cArgv.append(strdup(a))
        }
        cArgv.append(nil)

        cArgv.withUnsafeMutableBufferPointer { buf in
            _ = execv(qemuURL.path, buf.baseAddress)
        }

        // execv 只在失败时返回
        let errMsg = String(cString: strerror(errno))
        for p in cArgv { if let p = p { free(p) } }
        throw VMError.startFailed("execv 失败:\(errMsg)")
    }

    // MARK: - 内部

    private func ensureState(_ expected: VMState, action: String) throws {
        if state != expected {
            throw VMError.startFailed("当前状态为 \(state),不能执行 \(action)")
        }
    }

    private func ensureStateIn(_ allowed: Set<VMState>, action: String) throws {
        if !allowed.contains(state) {
            throw VMError.startFailed("当前状态为 \(state),不能执行 \(action)")
        }
    }

    private func setState(_ new: VMState) {
        withStateLock { _state = new }
        stateContinuation.yield(new)
    }

    /// 每个 VM 有自己的 EFI 变量存储(首次启动时从模板复制)
    private func prepareEFIVars() throws -> URL {
        let dst = bundle.efiDirURL.appendingPathComponent("vars.fd")
        if !FileManager.default.fileExists(atPath: dst.path) {
            try FileManager.default.createDirectory(
                at: bundle.efiDirURL, withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(at: paths.edk2ArmVars, to: dst)
        }
        return dst
    }

    /// 构造 qemu 命令行参数
    ///
    /// 实际拼装逻辑按语义段拆到 QEMUArgBuilders.swift 的各 struct。本函数
    /// 只负责顺序组装 + 需要 self 的副作用(陈旧文件清理、unattend ISO 生成、
    /// serialDebug 目录创建)。
    ///
    /// - Parameter tpmSocketPath: 若非 nil, 会加 `-chardev/-tpmdev/-device tpm-crb-device` 三件套
    private func buildArguments(efiVars: URL, tpmSocketPath: String? = nil) throws -> [String] {
        // 清理陈旧 pid/socket(qemu 不会覆盖已存在的 unix socket, 必须先删)
        bundle.cleanupRuntimeFiles()

        var args: [String] = []
        args += ControlChannelArgsBuilder(bundle: bundle).build()
        args += MachineArgsBuilder(config: config).build()
        // PCIe root ports 必须在后面所有 -device 之前定义, 否则 hot-plug target 不存在
        args += PCIeRootPortsArgsBuilder().build()
        args += EFIArgsBuilder(config: config, paths: paths, efiVars: efiVars).build()
        args += MainDiskArgsBuilder(config: config, bundle: bundle).build()
        args += USBControllerArgsBuilder(config: config).build()
        args += BootMediaArgsBuilder(config: config).build()
        if config.boot.bootFromDiskOnly, let iso = config.boot.isoPath {
            log.info(.qemu, "[bootFromDiskOnly] 跳过 ISO 挂载 (\(iso))")
        }

        // Unattend ISO: 必须先生成 (副作用), 失败 fail-soft 只记日志
        if config.boot.bypassWin11Checks && config.boot.graphical {
            do {
                try WindowsUnattend.ensureISO(
                    bundle: bundle,
                    autoInstallVirtioWin: config.boot.autoInstallVirtioWin,
                    autoInstallSpiceTools: config.boot.autoInstallSpiceTools
                )
                args += UnattendISOArgsBuilder(bundle: bundle).build()
            } catch {
                log.warn(.qemu, "[bypassWin11Checks] 生成 unattend ISO 失败: \(error)")
            }
        }

        args += VirtioWinArgsBuilder(config: config).build()
        args += TPMArgsBuilder(socketPath: tpmSocketPath).build()
        // Windows 默认把硬件时钟视为本地时间(Linux 视为 UTC)。为 Win 安装提供正确时区
        args += ["-rtc", "base=localtime"]
        args += NetworkArgsBuilder(networks: config.networks).build()
        args += try DisplayArgsBuilder(
            config: config,
            bundle: bundle,
            logRemover: { url, label in
                FileManager.default.removeIfExists(url, label: label, category: .qemu)
            }
        ).build()
        // qga 必须在 DisplayArgsBuilder 之后: 图形模式下它复用 virtioserial0 bus,
        // 这个 bus 是 DisplayArgsBuilder 创建的, 顺序不能倒。
        args += GuestAgentArgsBuilder(config: config, bundle: bundle).build()

        return args
    }
}
