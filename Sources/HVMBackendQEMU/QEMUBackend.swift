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
    /// swtpm 子进程(启用 TPM 时在 QEMU 之前拉起,QEMU 退出时连带清理)
    private var swtpmProcess: Process?

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

        // 启用 TPM: 先起 swtpm 子进程, 让它 listen 在 unix socket 上, QEMU 后面通过 chardev 连入
        var tpmSocketPath: String? = nil
        if config.boot.tpm {
            do {
                tpmSocketPath = try startSwtpm()
            } catch {
                setState(.error)
                throw error
            }
        }

        let args = try buildArguments(efiVars: efiVars, tpmSocketPath: tpmSocketPath)

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
            // QEMU 退出时连带杀掉 swtpm(swtpm 带 --ctrl ...,terminate 也会自动退, 这里是双保险)
            self?.terminateSwtpm()
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
            // 强制停止时 QEMU terminationHandler 可能来不及跑, 这里兜底
            terminateSwtpm()
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
    /// 注:本函数会 exec 替换当前进程, 所以提前拉起的 swtpm 会被自动"过继"给 init(pid=1),
    /// 但带 `--ctrl ...,terminate` 标志, QEMU 退出时 swtpm 仍会自己清理。
    public func execReplacing() throws {
        let efiVars = try prepareEFIVars()
        var tpmSocketPath: String? = nil
        if config.boot.tpm {
            tpmSocketPath = try startSwtpm()
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

    private func setState(_ new: VMState) {
        withStateLock { _state = new }
        stateContinuation.yield(new)
    }

    /// 生成 AutoUnattend.xml + 打包成小 ISO, 给 Win11 Setup 自动消费以绕过系统要求检查.
    /// 在 windowsPE pass 阶段预置 5 个 Bypass*Check DWORD=1, 安装器跑完它们再做硬件检查.
    /// ISO 只在缺失或 XML 变化时重新生成, 避免每次启动重打 ISO 浪费时间.
    private func prepareUnattendISO() throws {
        let xml = Self.unattendXML(autoInstallVirtioWin: config.boot.autoInstallVirtioWin)
        let stageDir = bundle.url.appendingPathComponent(".unattend-stage")
        /* 文件名三份都写: 不同版本 Windows Setup 对大小写的要求不统一.
         * - Autounattend.xml (A 大写, MS docs 官方)
         * - autounattend.xml (全小写, Win11 24H2 观察到更可靠)
         * - unattend.xml (兜底) */
        let canonicalURL = stageDir.appendingPathComponent("Autounattend.xml")
        let lowerURL = stageDir.appendingPathComponent("autounattend.xml")
        let shortURL = stageDir.appendingPathComponent("unattend.xml")
        let isoURL = bundle.unattendIsoURL

        let fm = FileManager.default

        // 如果 ISO 已存在且 XML 内容未变, 直接用
        if fm.fileExists(atPath: isoURL.path),
           fm.fileExists(atPath: canonicalURL.path),
           let existing = try? String(contentsOf: canonicalURL, encoding: .utf8),
           existing == xml {
            return
        }

        // 重建 stage 目录
        try? fm.removeItem(at: stageDir)
        try fm.createDirectory(at: stageDir, withIntermediateDirectories: true)
        try xml.write(to: canonicalURL, atomically: true, encoding: .utf8)
        try xml.write(to: lowerURL, atomically: true, encoding: .utf8)
        try xml.write(to: shortURL, atomically: true, encoding: .utf8)

        // 用 macOS 自带的 hdiutil makehybrid 打 ISO9660+UDF 混合(Win 两层都能读)
        try? fm.removeItem(at: isoURL)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        proc.arguments = [
            "makehybrid",
            "-udf", "-iso",
            "-iso-volume-name", "HELLVM_UNATTEND",
            "-udf-volume-name", "HELLVM_UNATTEND",
            "-o", isoURL.path,
            stageDir.path,
        ]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        try proc.run()
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                             encoding: .utf8) ?? ""
            throw VMError.startFailed("hdiutil makehybrid 失败 (status=\(proc.terminationStatus)): \(out)")
        }
        log.info(.qemu, "[bypassWin11Checks] 已生成 \(isoURL.path)")
    }

    /// AutoUnattend.xml 内容
    ///
    /// windowsPE pass:
    ///   跑 5 个 reg add, 写 HKLM\SYSTEM\Setup\LabConfig 下的 Bypass*Check DWORD=1。
    ///   这些值会让 Setup 的硬件检查模块跳过 TPM/SB/RAM/CPU/存储。
    ///
    /// oobeSystem pass (当 autoInstallVirtioWin=true 时才加):
    ///   FirstLogonCommands 在 OOBE 完成后首次登录时跑, 扫所有盘符找 virtio-win-gt-arm64.msi
    ///   静默安装. 装完 NetKVM / viostor / viogpudo / qemu-ga 等驱动。
    ///
    /// 该 XML 和 Microsoft 官方 unattend schema 兼容,Setup 自动扫描移动介质根目录.
    ///
    /// 格式约定:
    /// - 命令无引号, `/f` 放末尾(与 Microsoft docs 示例保持一致)
    /// - DWORD 值用 `0x1` 十六进制(某些 Setup 版本对十进制不识别)
    /// - 第一条先显式 create LabConfig 节, 避免并行 reg add 在 key 不存在时失败
    private static func unattendXML(autoInstallVirtioWin: Bool) -> String {
        var oobeBlock = ""
        if autoInstallVirtioWin {
            /* FirstLogonCommands 的 CommandLine 字段在 XML 里是字符串, 内部 cmd 要
             * 处理变量 %D 和 > 转义. 用 ^ 转义也行, 但实测直接 %D 在 unattend 的
             * CommandLine 正确识别; <> 则需用 &gt;/&lt;. 这里只用 %D, 安全.
             *
             * 逻辑: 枚举 C..Z 盘符, 遇到第一个有 virtio-win-gt-arm64.msi 的就装它.
             * msiexec /quiet /norestart 静默安装, 不弹 UAC 也不重启.
             * 日志写 C:\hellvm-viowin.log 便于用户排查.
             */
            oobeBlock = """
              <settings pass="oobeSystem">
                <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="arm64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
                  <FirstLogonCommands>
                    <SynchronousCommand wcm:action="add">
                      <Order>1</Order>
                      <CommandLine>cmd /c for %D in (C D E F G H I J K L M N O P Q R S T U V W X Y Z) do if exist %D:\\virtio-win-gt-arm64.msi start /wait msiexec /i %D:\\virtio-win-gt-arm64.msi /quiet /norestart /L*v C:\\hellvm-viowin.log</CommandLine>
                      <Description>HellVM auto-install virtio-win drivers (NetKVM, viostor, viogpudo, qemu-ga)</Description>
                      <RequiresUserInput>false</RequiresUserInput>
                    </SynchronousCommand>
                  </FirstLogonCommands>
                </component>
              </settings>
            """
        }

        return """
        <?xml version="1.0" encoding="utf-8"?>
        <unattend xmlns="urn:schemas-microsoft-com:unattend">
          <settings pass="windowsPE">
            <component name="Microsoft-Windows-Setup" processorArchitecture="arm64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
              <RunSynchronous>
                <RunSynchronousCommand wcm:action="add">
                  <Order>1</Order>
                  <Path>reg add HKLM\\System\\Setup\\LabConfig /f</Path>
                  <Description>create LabConfig</Description>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                  <Order>2</Order>
                  <Path>reg add HKLM\\System\\Setup\\LabConfig /v BypassTPMCheck /t REG_DWORD /d 0x1 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                  <Order>3</Order>
                  <Path>reg add HKLM\\System\\Setup\\LabConfig /v BypassSecureBootCheck /t REG_DWORD /d 0x1 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                  <Order>4</Order>
                  <Path>reg add HKLM\\System\\Setup\\LabConfig /v BypassRAMCheck /t REG_DWORD /d 0x1 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                  <Order>5</Order>
                  <Path>reg add HKLM\\System\\Setup\\LabConfig /v BypassCPUCheck /t REG_DWORD /d 0x1 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                  <Order>6</Order>
                  <Path>reg add HKLM\\System\\Setup\\LabConfig /v BypassStorageCheck /t REG_DWORD /d 0x1 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                  <Order>7</Order>
                  <Path>reg add HKLM\\System\\Setup\\MoSetup /v AllowUpgradesWithUnsupportedTPMOrCPU /t REG_DWORD /d 0x1 /f</Path>
                  <Description>legacy upgrade-path bypass</Description>
                </RunSynchronousCommand>
              </RunSynchronous>
            </component>
          </settings>
        \(oobeBlock)</unattend>
        """
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

    /// 查找 swtpm 可执行路径(Homebrew / MacPorts 常见安装位置)
    private func findSwtpmBinary() throws -> URL {
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

    /// 启动 swtpm 子进程, 返回它监听的 unix socket 路径
    ///
    /// socket 上用 `,terminate` 标志:当 QEMU 连上又断开(VM 关机)时 swtpm 自动退出,
    /// 避免需要从外部显式发信号。stateDir 内会生成 tpm2-00.permall 等持久化文件。
    private func startSwtpm() throws -> String {
        let swtpmURL = try findSwtpmBinary()
        let stateDir = bundle.tpmStateDirURL
        let sockURL = bundle.tpmSocketURL
        let logFile = bundle.logsDirURL.appendingPathComponent("swtpm.log")

        let fm = FileManager.default
        try fm.createDirectory(at: stateDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: bundle.logsDirURL, withIntermediateDirectories: true)
        try? fm.removeItem(at: sockURL)  // 陈旧 socket 清理

        let proc = Process()
        proc.executableURL = swtpmURL
        proc.arguments = [
            "socket",
            "--tpmstate", "dir=\(stateDir.path)",
            "--ctrl", "type=unixio,path=\(sockURL.path),terminate",
            "--tpm2",
            "--flags", "startup-clear",
            "--log", "level=5,file=\(logFile.path)",
        ]
        // swtpm 的 stdout/stderr 并入主 log, 方便排查启动失败
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil; return }
            if let s = String(data: data, encoding: .utf8) {
                for line in s.split(separator: "\n") {
                    log.warn(.qemu, "[swtpm] \(line)")
                }
            }
        }

        do {
            try proc.run()
        } catch {
            throw VMError.startFailed("swtpm 启动失败: \(error.localizedDescription)")
        }

        withStateLock { self.swtpmProcess = proc }

        // 等 socket 出现(最多 3 秒), 出不来说明 swtpm 挂了
        for _ in 0..<30 {
            if fm.fileExists(atPath: sockURL.path) {
                log.info(.qemu, "[swtpm] 已启动, socket=\(sockURL.path) state=\(stateDir.path)")
                return sockURL.path
            }
            usleep(100_000)  // 100ms
        }
        terminateSwtpm()
        throw VMError.startFailed("swtpm 启动 3 秒内未产生 socket, 请检查 \(logFile.path)")
    }

    /// 终止 swtpm 子进程(幂等)。QEMU 退出时 socket terminate 已会让 swtpm 自退出,
    /// 这里是双保险 / 异常路径清理。
    private func terminateSwtpm() {
        let proc: Process? = withStateLock {
            let p = self.swtpmProcess
            self.swtpmProcess = nil
            return p
        }
        guard let proc, proc.isRunning else { return }
        kill(proc.processIdentifier, SIGTERM)
    }

    /// 构造 qemu 命令行参数
    /// - Parameter tpmSocketPath: 若非 nil, 会加 `-chardev/-tpmdev/-device tpm-tis-device` 三件套
    private func buildArguments(efiVars: URL, tpmSocketPath: String? = nil) throws -> [String] {
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
        //
        // hellvm-lowram=on: 仅 Windows 11 ARM64 guest 开, 在 0x10000000 挂一小块 RAM
        // 骗 bootmgr 的硬编码内存假设. 要求配套打过 patch 的 EDK2 (patches/edk2/
        // 0001-ArmVirtPkg-extra-RAM-region-for-Win11-compat.patch). 没装 patched EDK2
        // 但开了这个选项 → EDK2 PEI ASSERT, 见 patch 0004 里的长注释.
        // 非 Windows (Linux/macOS/other) 不传这个选项 → stock EDK2 正常工作.
        var machineOpts = "virt,accel=hvf"
        if config.osType == .windows {
            machineOpts += ",hellvm-lowram=on"
        }
        args += ["-machine", machineOpts]
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

        // 主磁盘: 用 NVMe(Windows 内建支持 + UTM 验证过能跑 Win11; Linux 也支持)
        for (idx, disk) in config.disks.enumerated() {
            let path = bundle.resolve(disk.relativePath).path
            let driveId = "hd\(idx)"
            var driveOpts = "if=none,id=\(driveId),file=\(path),format=\(disk.format.rawValue)"
            if disk.readOnly { driveOpts += ",readonly=on" }
            args += ["-drive", driveOpts]
            args += ["-device", "nvme,drive=\(driveId),serial=hellvm-\(driveId)"]
        }

        // 图形模式先定义 USB 控制器; Win11 安装用的 usb-storage CD-ROM 也挂在这条总线
        if config.boot.graphical {
            args += ["-device", "qemu-xhci,id=usbbus"]
        }

        // 启动介质(ISO): 图形模式走 usb-storage(Win11 首选,对齐 UTM 经验证配置);
        // 非图形模式保留 virtio-scsi-cd
        //
        // bootFromDiskOnly=true 时跳过 ISO 挂载 —— 安装完成后的切换开关,
        // 避免 guest 再次看到安装盘。EFI NVRAM 里的 grub/bootmgr Boot entry
        // 已经写好, BDS 自动走硬盘。
        if let isoPath = config.boot.isoPath, !config.boot.bootFromDiskOnly {
            if config.boot.graphical {
                args += [
                    "-drive", "if=none,id=cdrom0,media=cdrom,file=\(isoPath),readonly=on",
                    "-device", "usb-storage,drive=cdrom0,removable=true,bootindex=0,bus=usbbus.0",
                ]
            } else {
                args += [
                    "-drive", "if=none,id=cdrom0,media=cdrom,file=\(isoPath),readonly=on",
                    "-device", "virtio-scsi-pci,id=scsi0",
                    "-device", "scsi-cd,drive=cdrom0,bootindex=1",
                ]
            }
        } else if config.boot.bootFromDiskOnly && config.boot.isoPath != nil {
            log.info(.qemu, "[bootFromDiskOnly] 跳过 ISO 挂载 (\(config.boot.isoPath ?? ""))")
        }

        // Win11 系统要求 bypass: 挂第二个小 CD, 只含 AutoUnattend.xml, Win Setup 自动识别
        if config.boot.bypassWin11Checks && config.boot.graphical {
            do {
                try prepareUnattendISO()
                args += [
                    "-drive", "if=none,id=cdrom_unattend,media=cdrom,file=\(bundle.unattendIsoURL.path),readonly=on",
                    "-device", "usb-storage,drive=cdrom_unattend,removable=true,bus=usbbus.0",
                ]
            } catch {
                log.warn(.qemu, "[bypassWin11Checks] 生成 unattend ISO 失败: \(error)")
            }
        }

        // virtio-win 驱动盘: 第三个 CD-ROM, 只读, Windows guest 装好后 AutoUnattend 的
        // FirstLogonCommands 会静默装 virtio-win-gt-arm64.msi (给 NetKVM / viostor /
        // viogpudo 等驱动上位). ISO 来自全局缓存, 多台 Win VM 共享.
        let vwPath = VMBundle.virtioWinCacheURL.path
        if config.boot.autoInstallVirtioWin && config.boot.graphical
            && FileManager.default.fileExists(atPath: vwPath) {
            args += [
                "-drive", "if=none,id=cdrom_vwin,media=cdrom,file=\(vwPath),readonly=on",
                "-device", "usb-storage,drive=cdrom_vwin,removable=true,bus=usbbus.0",
            ]
            log.info(.qemu, "[autoInstallVirtioWin] 已挂 virtio-win.iso \(vwPath)")
        } else if config.boot.autoInstallVirtioWin && config.boot.graphical {
            log.warn(.qemu, "[autoInstallVirtioWin] 开关已开但缓存不存在, 跳过: \(vwPath)")
        }

        // TPM 2.0(swtpm + tpm-crb-device): Windows 首选 CRB 接口
        // 我们已把 UTM 的 tpm_crb_sysbus 补丁 port 到 QEMU, 现在 aarch64 也支持 tpm-crb-device
        if let sockPath = tpmSocketPath {
            args += [
                "-chardev", "socket,id=chrtpm,path=\(sockPath)",
                "-tpmdev", "emulator,id=tpm0,chardev=chrtpm",
                "-device", "tpm-crb-device,tpmdev=tpm0",
            ]
        }

        // Windows 默认把硬件时钟视为本地时间(Linux 视为 UTC)。为 Win 安装提供正确时区
        args += ["-rtc", "base=localtime"]

        // 网络(user / vmnet* / none, 详见 NetworkConfig)
        args += buildNetArgs(config.networks)

        if config.boot.graphical {
            // 图形模式: 根据 display.virtioGpu 决定显示设备组合
            // - true (Linux/Asahi 等): virtio-gpu-pci + ramfb, 两 console, virtio-gpu 加速
            // - false (Windows): virtio-ramfb 融合设备(HellVM patch 0002+0003 port 自 UTM
            //   并修复上游 update_display 的 g->enable bug 以及 driver 接管后 ramfb
            //   旧数据回刷的问题)。单 PCI 设备单 console, bootmgr 走 ramfb facet 不挂死,
            //   装完 viogpudo 驱动后 scanout->resource_id != 0 自动切 virtio-gpu facet
            //   支持 dpy_set_ui_info 动态分辨率。
            if config.display.virtioGpu {
                args += ["-device", "virtio-gpu-pci"]
                args += ["-device", "ramfb"]
            } else {
                args += ["-device", "virtio-ramfb"]
            }
            // USB HID 键鼠(挂到前面已定义的 usbbus 上)
            args += ["-device", "usb-kbd,bus=usbbus.0"]
            args += ["-device", "usb-tablet,bus=usbbus.0"]
            if config.boot.serialDebug {
                // 诊断模式:guest 串口写到 edk2.log, 抓 EDK2 / bootmgr / kernel early debug
                // 每次启动前先清旧内容(QEMU -serial file: 是 append 模式, 不清就无限增长)
                try? FileManager.default.removeItem(at: bundle.edk2LogURL)
                try FileManager.default.createDirectory(at: bundle.logsDirURL, withIntermediateDirectories: true)
                args += ["-serial", "file:\(bundle.edk2LogURL.path)"]
            } else {
                // 默认: guest 串口丢弃, 避免不需要诊断时日志无限增长
                args += ["-serial", "null"]
            }
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

    /// 根据 NetworkConfig 列表产出 `-netdev` / `-device` / `-nic` 参数。
    /// 目前仅消费第一块网卡(多网卡 P6+);空数组或 .none 均视作禁用网络。
    private func buildNetArgs(_ networks: [NetworkConfig]) -> [String] {
        guard let net = networks.first, net.mode != .none else {
            // 禁用全部自动网卡(QEMU 不加 -nic none 时会隐式兜底一张 user)
            return ["-nic", "none"]
        }

        let netdevID = "net0"
        // 按配置选 NIC 型号: virtio-net-pci / e1000e / rtl8139
        // Windows 默认用 e1000e 开箱即有驱动; Linux 用 virtio 性能最好
        var deviceOpts = "\(net.deviceModel.qemuDeviceName),netdev=\(netdevID)"
        if let mac = net.macAddress, !mac.isEmpty {
            deviceOpts += ",mac=\(mac)"
        }

        var out: [String] = []
        switch net.mode {
        case .user:
            out += ["-netdev", "user,id=\(netdevID)"]
            out += ["-device", deviceOpts]
        case .vmnetShared, .vmnetHost, .vmnetBridged:
            // socket_vmnet 约定:QEMU 以 unix stream 连 helper socket, helper
            // 把以太网帧转进 vmnet.framework。helper 模式(shared/host/bridged)
            // 由 daemon 启动参数决定, 这里只负责指向对应 socket。
            let sock = net.effectiveSocketPath ?? "/var/run/socket_vmnet"
            out += ["-netdev", "stream,id=\(netdevID),addr.type=unix,addr.path=\(sock)"]
            out += ["-device", deviceOpts]
        case .none:
            break   // 已在 guard 里处理
        }
        return out
    }
}
