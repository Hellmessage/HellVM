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
    private var process: Process?

    public var state: VMState {
        withStateLock { _state }
    }

    private let stateContinuation: AsyncStream<VMState>.Continuation
    public let stateStream: AsyncStream<VMState>

    public init(config: VMConfig, bundle: VMBundle, paths: QEMUPaths) throws {
        self.config = config
        self.bundle = bundle
        self.paths = paths
        var cont: AsyncStream<VMState>.Continuation!
        self.stateStream = AsyncStream { cont = $0 }
        self.stateContinuation = cont
    }

    // MARK: - 生命周期(GUI 异步模式用)

    public func start() async throws {
        try ensureState(.stopped, action: "start")
        setState(.starting)

        let efiVars = try prepareEFIVars()
        let args = try buildArguments(efiVars: efiVars)

        let qemuURL = paths.qemuSystem(config.architecture)
        guard FileManager.default.isExecutableFile(atPath: qemuURL.path) else {
            setState(.error)
            throw VMError.startFailed("找不到 qemu 可执行文件:\(qemuURL.path)")
        }

        let proc = Process()
        proc.executableURL = qemuURL
        proc.arguments = args

        // GUI 模式:stdin 丢 /dev/null,stdout+stderr 写到 bundle/qemu.log,方便排障
        // (P4 会接入 IOSurface,不再依赖 stdio)
        proc.standardInput = FileHandle(forReadingAtPath: "/dev/null")
        let logURL = bundle.qemuLogURL
        try? "".write(to: logURL, atomically: true, encoding: .utf8)
        if let logHandle = try? FileHandle(forWritingTo: logURL) {
            logHandle.seekToEndOfFile()
            proc.standardOutput = logHandle
            proc.standardError = logHandle
        }

        proc.terminationHandler = { [weak self] p in
            self?.setState(.stopped)
        }

        do {
            try proc.run()
        } catch {
            setState(.error)
            throw VMError.startFailed("启动 qemu 失败:\(error.localizedDescription)")
        }

        withStateLock { self.process = proc }
        setState(.running)
    }

    public func stop(force: Bool) async throws {
        let proc: Process? = withStateLock {
            guard let p = self.process, self._state == .running || self._state == .starting else {
                return nil
            }
            self._state = .stopping
            return p
        }
        guard let proc else { return }
        stateContinuation.yield(.stopping)

        if force {
            kill(proc.processIdentifier, SIGKILL)
        } else {
            // 优先走 QMP system_powerdown,失败再退回 SIGTERM
            if !(await gracefulPowerdown()) {
                kill(proc.processIdentifier, SIGTERM)
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
        proc?.waitUntilExit()
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
        let qmp = QMPClient()
        try await qmp.connect(socketPath: bundle.qmpSocketURL.path)
        _ = try await qmp.execute(command)
        await qmp.close()
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
    public func execReplacing() throws {
        let efiVars = try prepareEFIVars()
        let args = try buildArguments(efiVars: efiVars)
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
    private func buildArguments(efiVars: URL) throws -> [String] {
        var args: [String] = []

        // 运行时控制通道:PID 文件 + QMP unix socket
        // 先清理陈旧的文件(qemu 不会覆盖已存在的 socket)
        bundle.cleanupRuntimeFiles()
        args += ["-pidfile", bundle.pidFileURL.path]
        args += ["-qmp", "unix:\(bundle.qmpSocketURL.path),server=on,wait=off"]

        // machine / 加速 / cpu / smp / 内存
        args += ["-machine", "virt,accel=hvf"]
        args += ["-cpu", "host"]
        args += ["-smp", String(config.cpuCount)]
        args += ["-m", "\(config.memoryMB)M"]

        // EFI 固件(代码只读 + 每 VM 独立变量)
        if config.boot.efi {
            args += [
                "-drive", "if=pflash,format=raw,readonly=on,file=\(paths.edk2AArch64Code.path)",
                "-drive", "if=pflash,format=raw,file=\(efiVars.path)",
            ]
        }

        // 主磁盘(virtio)
        for disk in config.disks {
            let path = bundle.resolve(disk.relativePath).path
            var opts = "if=virtio,file=\(path),format=\(disk.format.rawValue)"
            if disk.readOnly { opts += ",readonly=on" }
            args += ["-drive", opts]
        }

        // 启动介质(ISO)
        if let isoPath = config.boot.isoPath {
            args += [
                "-drive", "if=none,id=cdrom0,media=cdrom,file=\(isoPath),readonly=on",
                "-device", "virtio-scsi-pci,id=scsi0",
                "-device", "scsi-cd,drive=cdrom0,bootindex=1",
            ]
        }

        // 用户态网络(NAT)
        args += ["-netdev", "user,id=net0"]
        args += ["-device", "virtio-net-pci,netdev=net0"]

        // virtio-gpu 作为主显卡(P4)
        args += ["-device", "virtio-gpu-pci"]

        // guest 串口先丢弃(QEMU 自身日志走 Process stdout/stderr -> qemu.log)
        args += ["-serial", "null"]

        // 禁用默认 PCI VGA, 避免和 virtio-gpu 冲突
        args += ["-vga", "none"]

        // IOSurface 显示后端(P4): 每 VM 独占一个 unix socket
        args += ["-display", "iosurface,socket=\(bundle.iosurfaceSocketURL.path)"]

        return args
    }
}
