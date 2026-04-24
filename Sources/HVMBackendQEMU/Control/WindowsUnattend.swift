// Windows 自动安装配置 —— 生成 AutoUnattend.xml 并打包成 ISO
//
// 用途: Win11 Setup 检测 TPM/SecureBoot/RAM/CPU/存储, 默认机型通不过。
// 这里在 windowsPE pass 预置 LabConfig\Bypass*Check=1, 让 Setup 跳过硬件检查。
// 可选 oobeSystem pass 在首次登录时静默安装 virtio-win 驱动 (NetKVM / viostor / viogpudo / qemu-ga)。
//
// 和 QEMUBackend 解耦: 本文件不依赖 backend 状态, 只依赖 VMBundle 的路径。
import Foundation
import HVMCore
import HVMBundle

/// Windows 自动应答 ISO 生成器 —— 纯命名空间, 无状态
enum WindowsUnattend {

    /// 确保 bundle 下有最新 AutoUnattend ISO (幂等):
    /// - XML 未变且 payload(spice-guest-tools.exe)存在性未变 → 直接复用
    /// - 任一条件变化 → 重建 stage 目录 + hdiutil makehybrid
    ///
    /// - Parameters:
    ///   - autoInstallVirtioWin: true 时 FirstLogonCommands 加 virtio-win MSI 静默装
    ///   - autoInstallSpiceTools: true 且缓存里有 spice-guest-tools.exe 时, 打进 ISO 并在
    ///     FirstLogonCommands 里 `/S` 静默装。缓存缺失会被当作 false 处理(fail-soft + 日志警告)。
    static func ensureISO(bundle: VMBundle,
                          autoInstallVirtioWin: Bool,
                          autoInstallSpiceTools: Bool) throws {
        // 判断是否真能带上 spice-guest-tools.exe: 缓存缺失时降级为 false, 免得 XML
        // 里写了命令但光盘里找不到文件, guest 进 OOBE 会空转一段时间。
        let spiceSrcURL = VMBundle.spiceToolsCacheURL
        let spiceAvailable = autoInstallSpiceTools
            && FileManager.default.fileExists(atPath: spiceSrcURL.path)
        if autoInstallSpiceTools && !spiceAvailable {
            log.warn(.qemu, "[autoInstallSpiceTools] 开关已开但缓存不存在, 跳过: \(spiceSrcURL.path)")
        }

        let xml = unattendXML(autoInstallVirtioWin: autoInstallVirtioWin,
                              autoInstallSpiceTools: spiceAvailable)
        let stageDir = bundle.url.appendingPathComponent(".unattend-stage")
        /* 文件名三份都写: 不同版本 Windows Setup 对大小写的要求不统一.
         * - Autounattend.xml (A 大写, MS docs 官方)
         * - autounattend.xml (全小写, Win11 24H2 观察到更可靠)
         * - unattend.xml (兜底) */
        let canonicalURL = stageDir.appendingPathComponent("Autounattend.xml")
        let lowerURL = stageDir.appendingPathComponent("autounattend.xml")
        let shortURL = stageDir.appendingPathComponent("unattend.xml")
        let spiceStageURL = stageDir.appendingPathComponent("spice-guest-tools.exe")
        let isoURL = bundle.unattendIsoURL

        let fm = FileManager.default

        // 幂等: 如果 ISO 存在, XML 未变, 且 spice 载荷的存在性也对得上, 就复用
        let spiceAlreadyStaged = fm.fileExists(atPath: spiceStageURL.path)
        if fm.fileExists(atPath: isoURL.path),
           fm.fileExists(atPath: canonicalURL.path),
           let existing = try? String(contentsOf: canonicalURL, encoding: .utf8),
           existing == xml,
           spiceAlreadyStaged == spiceAvailable {
            return
        }

        // 重建 stage 目录
        fm.removeIfExists(stageDir, label: "unattend stage 目录", category: .qemu)
        try fm.createDirectory(at: stageDir, withIntermediateDirectories: true)
        try xml.write(to: canonicalURL, atomically: true, encoding: .utf8)
        try xml.write(to: lowerURL, atomically: true, encoding: .utf8)
        try xml.write(to: shortURL, atomically: true, encoding: .utf8)
        if spiceAvailable {
            try fm.copyItem(at: spiceSrcURL, to: spiceStageURL)
            log.info(.qemu, "[autoInstallSpiceTools] 已把 spice-guest-tools.exe 放入 unattend stage")
        }

        // 用 macOS 自带的 hdiutil makehybrid 打 ISO9660+UDF 混合(Win 两层都能读)
        fm.removeIfExists(isoURL, label: "旧 unattend ISO", category: .qemu)
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

    // MARK: - XML 构造

    /// AutoUnattend.xml 内容
    ///
    /// windowsPE pass:
    ///   跑 5 个 reg add, 写 HKLM\SYSTEM\Setup\LabConfig 下的 Bypass*Check DWORD=1。
    ///   这些值会让 Setup 的硬件检查模块跳过 TPM/SB/RAM/CPU/存储。
    ///
    /// oobeSystem pass (当至少一个 autoInstall* 为 true 时才加):
    ///   FirstLogonCommands 在 OOBE 完成后首次登录时跑, 扫所有盘符找对应 payload
    ///   - virtio-win-gt-arm64.msi  → 静默装 NetKVM / viostor / viogpudo / qemu-ga 驱动
    ///   - spice-guest-tools.exe     → NSIS /S 静默装 spice-vdagent 服务(给 resize 用)
    ///   两个命令互相独立, 任一开关单独开都能跑; 都开时按顺序执行(virtio-win 先装,
    ///   确保 vioserial 驱动就位后再装 spice-vdagent, 避免服务启动时找不到 virtio-serial 通道)。
    ///
    /// 该 XML 和 Microsoft 官方 unattend schema 兼容,Setup 自动扫描移动介质根目录.
    ///
    /// 格式约定:
    /// - 命令无引号, `/f` 放末尾(与 Microsoft docs 示例保持一致)
    /// - DWORD 值用 `0x1` 十六进制(某些 Setup 版本对十进制不识别)
    /// - 第一条先显式 create LabConfig 节, 避免并行 reg add 在 key 不存在时失败
    static func unattendXML(autoInstallVirtioWin: Bool,
                            autoInstallSpiceTools: Bool) -> String {
        /* FirstLogonCommands 的 CommandLine 字段在 XML 里是字符串, 内部 cmd 要
         * 处理变量 %D 和 > 转义. 用 ^ 转义也行, 但实测直接 %D 在 unattend 的
         * CommandLine 正确识别; <> 则需用 &gt;/&lt;. 这里只用 %D, 安全. */
        var commands: [String] = []

        if autoInstallVirtioWin {
            /* 枚举 C..Z 盘符, 遇到第一个有 virtio-win-gt-arm64.msi 的就装它.
             * msiexec /quiet /norestart 静默安装, 不弹 UAC 也不重启.
             * 日志写 C:\hellvm-viowin.log 便于用户排查. */
            commands.append(
                "cmd /c for %D in (C D E F G H I J K L M N O P Q R S T U V W X Y Z) do if exist %D:\\virtio-win-gt-arm64.msi start /wait msiexec /i %D:\\virtio-win-gt-arm64.msi /quiet /norestart /L*v C:\\hellvm-viowin.log")
        }
        if autoInstallSpiceTools {
            /* spice-guest-tools-latest.exe 是 NSIS installer, /S 大写表示 Silent mode,
             * /D=... 指定安装目录(NSIS 约定必须是最后一个参数, 无引号, 无转义).
             * 装完 spice-vdagent 服务会自动起, Windows 此时就能响应 MONITORS_CONFIG。
             * ARM64 Windows 通过 x86 emulation 跑 x86 NSIS installer, 社区验证 ok。 */
            commands.append(
                "cmd /c for %D in (C D E F G H I J K L M N O P Q R S T U V W X Y Z) do if exist %D:\\spice-guest-tools.exe start /wait %D:\\spice-guest-tools.exe /S")
        }

        var oobeBlock = ""
        if !commands.isEmpty {
            var synchronousCommands = ""
            for (idx, cmd) in commands.enumerated() {
                synchronousCommands += """
                    <SynchronousCommand wcm:action="add">
                      <Order>\(idx + 1)</Order>
                      <CommandLine>\(cmd)</CommandLine>
                      <Description>HellVM auto-install payload #\(idx + 1)</Description>
                      <RequiresUserInput>false</RequiresUserInput>
                    </SynchronousCommand>

                """
            }
            oobeBlock = """
              <settings pass="oobeSystem">
                <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="arm64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
                  <FirstLogonCommands>
            \(synchronousCommands)      </FirstLogonCommands>
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

}
