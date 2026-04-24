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

    /// 长连接 QMP 事件订阅任务(连 qmp-event.sock, 监听 SHUTDOWN 等异步事件).
    /// QEMU 退出或主动 stop 时会自动因 socket 断开而结束, 不需要显式 cancel。
    private var eventSubscriberTask: Task<Void, Never>?

    /// guest 活性探测任务 —— 定期采 QEMU 进程 CPU time, 连续低于阈值
    /// 判定 guest 已 halt/shutdown(Windows ARM64 关机不经 QEMU 时的兜底)。
    private var livenessProbeTask: Task<Void, Never>?

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
            self.withStateLock {
                self.process = nil
                self.eventSubscriberTask?.cancel()
                self.eventSubscriberTask = nil
                self.livenessProbeTask?.cancel()
                self.livenessProbeTask = nil
            }
            self.setState(.stopped)
        }

        withStateLock { self.process = spawned }
        setState(.running)

        // 启动 QMP 事件订阅, 监听 guest 发出的关机/重启等异步事件。
        // 某些 guest(尤其是正常 Linux)关机时 QEMU 默认 action=shutdown=poweroff
        // 会让进程直接退出, terminationHandler 搞定;但也有 guest(Windows ARM64)
        // 的 ACPI shutdown 信号不一定能让 QEMU 进程退出 —— 这时 QMP SHUTDOWN 事件
        // 仍然会发, 我们捕获后主动 stop 兜底。
        startEventSubscriber()

        // 启动 guest 活性探测 —— Windows ARM64 关机时 QEMU 既不退出、也不发
        // SHUTDOWN 事件(ACPI shutdown 信号没到 QEMU), 是 event subscriber 覆盖
        // 不到的盲区。通过定期采 QEMU 进程 CPU 时间, 连续低于阈值判为 guest halted
        // 主动清理。阈值严到 idle guest 也不会误触发。
        startLivenessProbe(pid: spawned.pid)
    }

    /// 连 qmp-event.sock, loop 读事件。识别到 SHUTDOWN / GUEST_PANICKED 等
    /// "guest 结束运行"的事件时, 主动发起非强制 stop, 让 QEMU 优雅退出。
    private func startEventSubscriber() {
        let sockPath = bundle.qmpEventSocketURL.path
        let task = Task.detached(priority: .utility) { [weak self] in
            // QEMU 启动 → qmp-event.sock server 就绪 需要几百毫秒, 轮询等就绪
            let connectDeadline = Date().addingTimeInterval(5)
            let qmp = QMPClient()
            while !Task.isCancelled {
                do {
                    try await qmp.connect(socketPath: sockPath)
                    break
                } catch {
                    if Date() >= connectDeadline {
                        log.warn(.backend, "qmp-event subscriber: 连接超时, 放弃监听事件")
                        return
                    }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
            defer { Task { await qmp.close() } }

            while !Task.isCancelled {
                let event: (name: String, data: [String: Any], timestamp: Double?)
                do {
                    event = try await qmp.nextEvent()
                } catch {
                    // QEMU 退出 / socket 关闭时 readMessage 抛 "QMP 连接关闭" —— 正常终止
                    return
                }

                log.info(.backend, "qmp event: \(event.name)")
                switch event.name {
                case "SHUTDOWN", "GUEST_PANICKED":
                    // guest 请求关机或 panic, QEMU 未必自己退出(特别是 Windows ARM 的某些
                    // ACPI 路径), 主动 stop 兜底。force=false 让 QEMU 优雅退,
                    // 内部若已有 stop 进行中会无 op。
                    guard let self = self else { return }
                    Task.detached { [weak self] in
                        try? await self?.stop(force: false)
                    }
                default:
                    // RESET / STOP / RESUME 等不需要改 backend 状态
                    break
                }
            }
        }
        withStateLock { self.eventSubscriberTask = task }
    }

    /// 每 5 秒采样 QEMU 进程累计 CPU 时间, 用 60 秒滑动窗口判定 guest 是否已 halt。
    /// 阈值设得非常严 (60s 内 CPU 增长 < 100ms ≈ 0.17% CPU), 正常 idle 的 guest
    /// 不会触发(Linux idle 一般 1-3%, Windows idle 一般 1-5%), 只有 vCPU 真正
    /// 全部 WFI/halt 住 (guest 已关机但 QEMU 没收到 shutdown 信号) 才会触发。
    private func startLivenessProbe(pid: pid_t) {
        let task = Task.detached(priority: .background) { [weak self] in
            // 采样 12 次 = 60 秒窗口
            let sampleIntervalNs: UInt64 = 5_000_000_000
            let windowSamples = 12
            let haltThresholdNs: UInt64 = 100_000_000  // 60s 内 < 100ms CPU
            var samples: [UInt64] = []

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: sampleIntervalNs)
                if Task.isCancelled { return }

                guard let cpu = Self.processCPUTimeNanos(pid: pid) else {
                    // 进程已消失(可能正在退出) — 让 terminationHandler 处理
                    return
                }
                samples.append(cpu)
                if samples.count > windowSamples {
                    let delta = samples.last! &- samples.first!
                    samples.removeFirst()
                    if delta < haltThresholdNs {
                        log.warn(.backend,
                            "liveness probe: QEMU pid=\(pid) 在 \(windowSamples * Int(sampleIntervalNs/1_000_000_000)) 秒内仅消耗 \(delta/1_000_000)ms CPU, 判定 guest 已 halt/shutdown, 强制清理")
                        try? await self?.stop(force: true)
                        return
                    }
                }
            }
        }
        withStateLock { self.livenessProbeTask = task }
    }

    /// 通过 proc_pid_rusage 拿指定进程累计 (user + system) CPU 时间, 转换成纳秒。
    /// 失败返回 nil(例如进程已退出)。
    private static func processCPUTimeNanos(pid: pid_t) -> UInt64? {
        // Swift 把 `rusage_info_t` 导入成 UnsafeMutableRawPointer(C 里 typedef 为 void*),
        // 函数签名的 out-param 就变成 UnsafeMutablePointer<rusage_info_t?>。
        // 需要把 &info 重绑到 rusage_info_t?.self 再传。
        var info = rusage_info_current()
        let rv = withUnsafeMutablePointer(to: &info) { ptr -> Int32 in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { reboundPtr in
                proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, reboundPtr)
            }
        }
        guard rv == 0 else { return nil }
        // rusage_info_v* 的 ri_user_time / ri_system_time 单位是 mach absolute time,
        // 不是纳秒, 需要通过 timebase 换算。
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        let mach = info.ri_user_time &+ info.ri_system_time
        return mach &* UInt64(tb.numer) / UInt64(tb.denom)
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
