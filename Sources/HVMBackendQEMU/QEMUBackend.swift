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

        // GUI 模式: stdin 丢 /dev/null; stdout/stderr 走 Pipe, 逐行送 Logger(.qemu)
        // 日志统一落到 <bundle>/logs/hellvm.log(Logger 管理 + 10MB 滚动), 不再
        // 单独维护 qemu.log。
        proc.standardInput = FileHandle(forReadingAtPath: "/dev/null")

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError  = stderrPipe

        let outBuffer = LineBuffer()
        stdoutPipe.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            if data.isEmpty {
                h.readabilityHandler = nil
                return
            }
            outBuffer.append(data)
            outBuffer.drainLines { line in log.info(.qemu, line) }
        }
        let errBuffer = LineBuffer()
        stderrPipe.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            if data.isEmpty {
                h.readabilityHandler = nil
                return
            }
            errBuffer.append(data)
            errBuffer.drainLines { line in log.warn(.qemu, line) }
        }

        proc.terminationHandler = { [weak self] p in
            // 关闭 pipe handler, 避免僵尸 readability callback
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
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

    /// 流式切行 buffer: 类而非 inout Data, 避免并发闭包里捕获 var 的警告
    private final class LineBuffer: @unchecked Sendable {
        private var data = Data()

        func append(_ chunk: Data) { data.append(chunk) }

        /// 每凑出一行(不含 \n)就回调
        func drainLines(_ emit: (String) -> Void) {
            while let nlIdx = data.firstIndex(of: 0x0a) {
                let lineData = data[data.startIndex..<nlIdx]
                data.removeSubrange(data.startIndex...nlIdx)
                var line = String(data: Data(lineData), encoding: .utf8) ?? ""
                if line.hasSuffix("\r") { line.removeLast() }
                if !line.isEmpty { emit(line) }
            }
            // 超长单行保护(无 \n), 避免 buffer 无限增长
            if data.count > 64 * 1024 {
                let line = String(data: data, encoding: .utf8) ?? ""
                data.removeAll(keepingCapacity: true)
                if !line.isEmpty { emit(line) }
            }
        }
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

        // 运行时控制通道:PID 文件 + 两个 QMP socket
        //   qmp.sock       控制(start/stop/pause/resume, VMController)
        //   qmp-input.sock 键鼠注入(InputForwarder 长连接, 与控制互不干扰)
        // 先清理陈旧的文件(qemu 不会覆盖已存在的 socket)
        bundle.cleanupRuntimeFiles()
        args += ["-pidfile", bundle.pidFileURL.path]
        args += ["-qmp", "unix:\(bundle.qmpSocketURL.path),server=on,wait=off"]
        args += ["-qmp", "unix:\(bundle.qmpInputSocketURL.path),server=on,wait=off"]

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

        if config.boot.graphical {
            // 图形模式: virtio-gpu + USB HID + iosurface backend
            args += ["-device", "virtio-gpu-pci"]
            // USB HID 键鼠: UEFI 只内置 USB 驱动, 不识别 virtio-kbd/tablet
            args += ["-device", "qemu-xhci,id=usbbus"]
            args += ["-device", "usb-kbd,bus=usbbus.0"]
            args += ["-device", "usb-tablet,bus=usbbus.0"]
            // guest 串口丢弃(QEMU 自身日志走 Process stdout/stderr -> Logger)
            args += ["-serial", "null"]
            args += ["-vga", "none"]
            // IOSurface 后端: 每 VM 独占一个 unix socket
            args += ["-display", "iosurface,socket=\(bundle.iosurfaceSocketURL.path)"]
        } else {
            // 非图形模式(-nographic): 适合无桌面服务器镜像/云 init
            // guest 串口直接写入 serial.log, 详情页 Console tab tail 显示
            args += ["-serial", "file:\(bundle.serialLogURL.path)"]
            args += ["-nographic"]
            // 不加 iosurface / virtio-gpu / USB HID
        }

        return args
    }
}
