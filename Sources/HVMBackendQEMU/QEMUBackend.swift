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
    /// swtpm 子进程 —— 启用 TPM 时先拉起, 作为 pg leader, QEMU 加入同 pg
    /// 这样 stop(force:true) 一次 killpg 就能原子清掉两者, 不会留孤儿
    private var swtpmProcess: SpawnedProcess?

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
        var swtpmStarted: SpawnedProcess? = nil
        if config.boot.tpm {
            do {
                tpmSocketPath = try startSwtpm()
                swtpmStarted = withStateLock { self.swtpmProcess }
            } catch {
                setState(.error)
                throw error
            }
        }

        let args: [String]
        do {
            args = try buildArguments(efiVars: efiVars, tpmSocketPath: tpmSocketPath)
        } catch {
            if swtpmStarted != nil { terminateSwtpm() }
            setState(.error)
            throw error
        }

        let qemuURL = paths.qemuSystem(config.architecture)
        guard FileManager.default.isExecutableFile(atPath: qemuURL.path) else {
            if swtpmStarted != nil { terminateSwtpm() }
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
                joinPGID: swtpmStarted?.pgid,
                lineHandler: { line, isStderr in
                    if isStderr {
                        log.warn(.qemu, line)
                    } else {
                        log.info(.qemu, line)
                    }
                }
            )
        } catch {
            if swtpmStarted != nil { terminateSwtpm() }
            setState(.error)
            throw VMError.startFailed("启动 qemu 失败:\(error.localizedDescription)")
        }

        spawned.terminationHandler = { [weak self] _ in
            guard let self = self else { return }
            // QEMU 退出时连带杀掉 swtpm(swtpm 的 ,terminate 标志也会自退, 双保险)
            self.terminateSwtpm()
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

    /// 清理可能存在的路径(文件或目录,幂等)
    /// 不存在直接跳过, 存在但删除失败写 warn 日志, 不抛错(清理路径是 best-effort).
    /// - Parameter label: 用于日志里识别清理对象的人类可读描述
    private func removeIfExists(_ url: URL, label: String) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        do {
            try fm.removeItem(at: url)
        } catch {
            log.warn(.qemu, "清理 \(label) 失败 (\(url.path)): \(error.localizedDescription)")
        }
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
        removeIfExists(stageDir, label: "unattend stage 目录")
        try fm.createDirectory(at: stageDir, withIntermediateDirectories: true)
        try xml.write(to: canonicalURL, atomically: true, encoding: .utf8)
        try xml.write(to: lowerURL, atomically: true, encoding: .utf8)
        try xml.write(to: shortURL, atomically: true, encoding: .utf8)

        // 用 macOS 自带的 hdiutil makehybrid 打 ISO9660+UDF 混合(Win 两层都能读)
        removeIfExists(isoURL, label: "旧 unattend ISO")
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
        removeIfExists(sockURL, label: "陈旧 swtpm socket")

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

        withStateLock { self.swtpmProcess = spawned }

        // 等 socket 出现(最多 3 秒), 出不来说明 swtpm 挂了
        for _ in 0..<30 {
            if fm.fileExists(atPath: sockURL.path) {
                log.info(.qemu, "[swtpm] 已启动, pid=\(spawned.pid) socket=\(sockURL.path) state=\(stateDir.path)")
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
        let proc: SpawnedProcess? = withStateLock {
            let p = self.swtpmProcess
            self.swtpmProcess = nil
            return p
        }
        guard let proc, proc.isRunning else { return }
        proc.sendSignal(SIGTERM)
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
                try prepareUnattendISO()
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
            logRemover: { [weak self] url, label in self?.removeIfExists(url, label: label) }
        ).build()

        return args
    }
}
