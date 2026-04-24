// 虚拟机配置模型 —— 持久化到 .hellvm bundle 内的 config.json
import Foundation

/// 一台 VM 的完整配置
public struct VMConfig: Codable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var architecture: VMArchitecture
    public var osType: GuestOSType
    public var cpuCount: Int
    /// 开机初始内存 (MB). 运行时可通过 QMP 热插 DIMM 上调, 上限由 maxMemoryMB 决定.
    public var memoryMB: UInt64
    /// 内存最大可扩到多少 MB —— 启动时决定 `-m X,slots=N,maxmem=Y` 的 Y.
    /// nil / <= memoryMB 表示不预留热插槽位(省 guest 资源; 不支持内存热插).
    /// 修改此字段需停机再启动才能生效, 不能热改。
    public var maxMemoryMB: UInt64?
    public var disks: [DiskConfig]
    public var networks: [NetworkConfig]
    public var display: DisplayConfig
    public var boot: BootConfig
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        architecture: VMArchitecture,
        osType: GuestOSType = .other,
        cpuCount: Int = 2,
        memoryMB: UInt64 = 2048,
        maxMemoryMB: UInt64? = nil,
        disks: [DiskConfig] = [],
        networks: [NetworkConfig] = [.init(mode: .user)],
        display: DisplayConfig = .default,
        boot: BootConfig = .init(),
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.architecture = architecture
        self.osType = osType
        self.cpuCount = cpuCount
        self.memoryMB = memoryMB
        self.maxMemoryMB = maxMemoryMB
        self.disks = disks
        self.networks = networks
        self.display = display
        self.boot = boot
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, architecture, osType
        case cpuCount, memoryMB, maxMemoryMB, disks, networks
        case display, boot, createdAt, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id           = try c.decode(UUID.self,           forKey: .id)
        self.name         = try c.decode(String.self,         forKey: .name)
        self.architecture = try c.decode(VMArchitecture.self, forKey: .architecture)
        self.osType       = try c.decodeOr(GuestOSType.self, forKey: .osType, default: .other)
        self.cpuCount     = try c.decode(Int.self,            forKey: .cpuCount)
        self.memoryMB     = try c.decode(UInt64.self,         forKey: .memoryMB)
        self.maxMemoryMB  = try c.decodeIfPresent(UInt64.self, forKey: .maxMemoryMB)
        self.disks        = try c.decode([DiskConfig].self,   forKey: .disks)
        self.networks     = try c.decode([NetworkConfig].self, forKey: .networks)
        self.display      = try c.decode(DisplayConfig.self,  forKey: .display)
        self.boot         = try c.decode(BootConfig.self,     forKey: .boot)
        self.createdAt    = try c.decode(Date.self,           forKey: .createdAt)
        self.updatedAt    = try c.decode(Date.self,           forKey: .updatedAt)
    }
}

/// 客户机操作系统类型 —— 新建向导决定 display/boot 合理默认
/// - linux:   virtio-gpu 加速, 无 TPM
/// - windows: 关闭 virtio-gpu (bootmgr 在 virtio-gpu 存在时挂死),
///            启用 TPM, 启用 Win11 检查绕过
/// - macOS:   保留占位, 当前仍按 Linux 默认处理
/// - other:   保持历史默认行为(virtio-gpu 开, 无 TPM), 旧 config 解码兜底
public enum GuestOSType: String, Codable, Sendable, CaseIterable {
    case linux
    case windows
    case macOS
    case other
}

/// 磁盘配置(路径相对于 bundle 根目录)
///
/// 第一个 disk (disks[0]) 作为主启动盘, 总是走 NVMe 挂载且 enabled 锁死 true.
/// 第二块起是数据盘, 走 virtio-blk-pci, 支持运行时 QMP 热插拔。
public struct DiskConfig: Codable, Sendable, Identifiable {
    public var id: UUID
    public var relativePath: String   // 例如 "disks/main.qcow2"
    public var sizeGB: UInt64
    public var format: Format
    public var readOnly: Bool
    /// 是否启用 —— false 时启动不挂, 运行中可通过 QMP 热插拔 attach/detach.
    /// 主盘(disks[0]) UI 里锁定为 true, 不允许禁用。
    public var enabled: Bool

    public enum Format: String, Codable, Sendable {
        case qcow2
        case raw
    }

    public init(
        id: UUID = UUID(),
        relativePath: String,
        sizeGB: UInt64,
        format: Format = .qcow2,
        readOnly: Bool = false,
        enabled: Bool = true
    ) {
        self.id = id
        self.relativePath = relativePath
        self.sizeGB = sizeGB
        self.format = format
        self.readOnly = readOnly
        self.enabled = enabled
    }

    private enum CodingKeys: String, CodingKey {
        case id, relativePath, sizeGB, format, readOnly, enabled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.relativePath = try c.decode(String.self, forKey: .relativePath)
        self.sizeGB = try c.decode(UInt64.self, forKey: .sizeGB)
        self.format = try c.decode(Format.self, forKey: .format)
        self.readOnly = try c.decodeIfPresent(Bool.self, forKey: .readOnly) ?? false
        // 兼容旧 config(无 enabled): 默认 true
        self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }

    /// 派生 QMP 稳定后缀(uuid 首 8 字符), 给 blockdev-add/device_add 当 id 后缀
    public var qemuStableSuffix: String {
        String(id.uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased())
    }
}

/// 网络配置
///
/// 后端一览:
/// - `.user` —— QEMU 内置 user-mode(NAT),零依赖,默认
/// - `.vmnetShared` / `.vmnetHost` / `.vmnetBridged` —— 走外部 socket_vmnet helper
///   (`brew install socket_vmnet` + `sudo brew services start socket_vmnet`)
/// - `.none` —— 禁用网络(`-nic none`)
public struct NetworkConfig: Codable, Sendable {
    public var mode: Mode
    public var macAddress: String?
    /// socket_vmnet unix socket 路径(仅 vmnet* 模式用,留空则按 mode 取默认值)
    public var socketVmnetPath: String?
    /// vmnetBridged 模式要桥接的宿主网卡(如 `en0`),其它模式忽略
    public var bridgedInterface: String?
    /// QEMU NIC 设备型号. Linux 默认 virtio(自带驱动), Windows 默认 e1000e
    /// (Windows ARM 开箱自带 e1000e 驱动; 装 NetKVM 驱动后可切 virtio 更快)
    public var deviceModel: NICModel
    /// 是否启用此网卡 —— false 时启动不挂, 运行中可通过 QMP 热插拔 attach/detach.
    /// 和删除的区别: 禁用保留配置(MAC/模式等), 后续再启用恢复同样的 NIC 身份。
    public var enabled: Bool

    public enum Mode: String, Codable, Sendable {
        case user          // -netdev user, 内置 NAT
        case vmnetShared   // socket_vmnet shared(NAT+DHCP, 走 vmnet.framework)
        case vmnetHost     // socket_vmnet host-only
        case vmnetBridged  // socket_vmnet bridged(真二层桥接)
        case none          // 无网络
    }

    public init(
        mode: Mode = .user,
        macAddress: String? = nil,
        socketVmnetPath: String? = nil,
        bridgedInterface: String? = nil,
        deviceModel: NICModel = .virtio,
        enabled: Bool = true
    ) {
        self.mode = mode
        self.macAddress = macAddress
        self.socketVmnetPath = socketVmnetPath
        self.bridgedInterface = bridgedInterface
        self.deviceModel = deviceModel
        self.enabled = enabled
    }

    /// 推导实际使用的 socket 路径(vmnet* 模式): 用户显式填 socketVmnetPath 优先,
    /// 否则走 SocketPaths 集中的标准约定。
    public var effectiveSocketPath: String? {
        if let p = socketVmnetPath, !p.isEmpty { return p }
        switch mode {
        case .vmnetShared:  return SocketPaths.vmnetShared
        case .vmnetHost:    return SocketPaths.vmnetHost
        case .vmnetBridged:
            let iface = (bridgedInterface?.isEmpty == false) ? bridgedInterface! : "en0"
            return SocketPaths.vmnetBridged(interface: iface)
        case .user, .none:  return nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case mode, macAddress, socketVmnetPath, bridgedInterface, deviceModel, enabled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // 兼容旧枚举名: nat → user, bridged → vmnetBridged, hostOnly → vmnetHost
        let raw = try c.decode(String.self, forKey: .mode)
        switch raw {
        case "user", "nat":             self.mode = .user
        case "vmnetShared":             self.mode = .vmnetShared
        case "vmnetHost", "hostOnly":   self.mode = .vmnetHost
        case "vmnetBridged", "bridged": self.mode = .vmnetBridged
        case "none":                    self.mode = .none
        default:                        self.mode = .user   // 未知值兜底为 user
        }
        self.macAddress       = try c.decodeIfPresent(String.self, forKey: .macAddress)
        self.socketVmnetPath  = try c.decodeIfPresent(String.self, forKey: .socketVmnetPath)
        self.bridgedInterface = try c.decodeIfPresent(String.self, forKey: .bridgedInterface)
        self.deviceModel      = try c.decodeOr(NICModel.self, forKey: .deviceModel, default: .virtio)
        self.enabled          = try c.decodeOr(Bool.self, forKey: .enabled, default: true)
    }

    /// QEMU 侧稳定 ID —— 热插拔要求添加/删除时 ID 一致. 用 MAC 去冒号做后缀,
    /// guest 看到的仍然是 NIC 顺序, 这里只是 host 端 QEMU 的内部句柄名。
    /// MAC 为空(极端情况)时返回 nil, 调用方应 fallback 到索引 ID。
    public var qemuStableSuffix: String? {
        guard let mac = macAddress, !mac.isEmpty else { return nil }
        return mac.replacingOccurrences(of: ":", with: "").lowercased()
    }
}

/// QEMU NIC 设备型号
/// - virtio:  virtio-net-pci, 需 guest 驱动(Linux 自带, Windows 需装 NetKVM)
/// - e1000e:  Intel 千兆网卡模拟, Windows ARM / macOS 自带驱动
/// - rtl8139: Realtek 老网卡, 兼容性最广但性能最差, 超老 guest 兜底
public enum NICModel: String, Codable, Sendable, CaseIterable {
    case virtio
    case e1000e
    case rtl8139

    /// 翻译成 QEMU `-device` 参数名
    public var qemuDeviceName: String {
        switch self {
        case .virtio:  return "virtio-net-pci"
        case .e1000e:  return "e1000e"
        case .rtl8139: return "rtl8139"
        }
    }
}

// MARK: - 随机 MAC 地址

extension NetworkConfig {
    /// 生成一个 locally-administered + unicast 的随机 MAC 地址.
    ///
    /// 规则:
    /// - OUI 固定用 QEMU 约定前缀 `52:54:00`(IEEE 分给 Qumranet/QEMU 虚拟网卡 OUI,
    ///   首字节 bit1=1 locally administered, bit0=0 unicast)
    /// - 后 3 字节随机, 碰撞概率 1/16M, 单主机上多 VM 足够
    ///
    /// 小写冒号分隔格式, 便于直接拼进 QEMU `mac=` 参数
    public static func generateRandomMAC() -> String {
        let tail = (0..<3).map { _ in UInt8.random(in: 0...255) }
        return String(format: "52:54:00:%02x:%02x:%02x", tail[0], tail[1], tail[2])
    }

    /// 简单校验 MAC 字符串合法性(6 组十六进制, 冒号分隔, 大小写不限)
    public static func isValidMAC(_ s: String) -> Bool {
        let pattern = #"^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$"#
        return s.range(of: pattern, options: .regularExpression) != nil
    }
}

/// 显示配置
public struct DisplayConfig: Codable, Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var enabled: Bool

    /// 启用 virtio-gpu-pci(在 ramfb 之外再挂一块 virtio-gpu):
    /// - Linux/Asahi 等 guest: 能用 virtio-gpu 驱动加速, 支持高分辨率 ✓
    /// - Windows ARM64 安装盘: **bootmgr 在 virtio-gpu 存在时会挂死**, 必须关
    ///   默认 true (Linux 友好); 装 Windows 的 VM 显式设为 false
    public var virtioGpu: Bool

    public static let `default` = DisplayConfig(width: 1280, height: 800, enabled: true, virtioGpu: true)

    public init(width: Int, height: Int, enabled: Bool, virtioGpu: Bool = true) {
        self.width = width
        self.height = height
        self.enabled = enabled
        self.virtioGpu = virtioGpu
    }

    private enum CodingKeys: String, CodingKey {
        case width, height, enabled, virtioGpu
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.width     = try c.decode(Int.self, forKey: .width)
        self.height    = try c.decode(Int.self, forKey: .height)
        self.enabled   = try c.decode(Bool.self, forKey: .enabled)
        self.virtioGpu = try c.decodeOr(Bool.self, forKey: .virtioGpu, default: true)
    }
}

/// 启动配置
public struct BootConfig: Codable, Sendable, Equatable {
    public var isoPath: String?         // 绝对路径(ISO 通常不复制进 bundle,节省空间)
    public var kernelPath: String?
    public var initrdPath: String?
    public var kernelCmdline: String?
    public var efi: Bool                // 是否使用 EFI 启动

    /// 图形显示: true = virtio-gpu + iosurface backend + 键鼠; false = 纯串口(-nographic),
    /// 适合无桌面的服务器镜像/云 init 等场景。默认 true。
    public var graphical: Bool

    /// TPM 2.0 模拟(swtpm + tpm-tis-device),Win11 安装硬依赖
    public var tpm: Bool

    /// 诊断开关:图形模式下把 guest 串口重定向到 logs/edk2.log,
    /// 用于抓 EDK2 固件 / Windows bootmgr / Linux kernel early 的 debug 输出。
    /// 默认 false — 串口丢弃,避免长时间运行日志无限增长。
    /// 排查启动问题时打开,日志来源:EDK2 PEI/DXE/BDS/bootmgr debug 文本。
    public var serialDebug: Bool

    /// 自动绕过 Win11 系统要求检查(CPU 白名单/Secure Boot/TPM/RAM/存储):
    /// 生成一个小 ISO 只放 `AutoUnattend.xml`, 挂为第二个 USB 存储. Win Setup
    /// 会自动扫描并在 windowsPE 阶段跑里面的 `reg add HKLM\...\LabConfig` 写入
    /// 5 个 Bypass*Check DWORD=1, 从而绕过所有硬件检查.
    /// 用户的原版 ISO 完全不动, 关掉此开关时不挂. 默认 false, Win11 VM 建议开.
    public var bypassWin11Checks: Bool

    /// 自动挂 virtio-win.iso 并通过 AutoUnattend 的 FirstLogonCommands 静默装
    /// virtio-win-gt-arm64.msi。装完后 Windows 获得 NetKVM / viostor / viogpudo
    /// 等一整套 virtio 驱动, 可以把 NIC 从 e1000e 切到 virtio-net 获得 10Gbps 级吞吐。
    ///
    /// 依赖:
    /// - ISO 存放在全局缓存 ~/Library/Application Support/HellVM/cache/virtio-win.iso
    /// - 启动前由 Swift 侧 VirtioWinManager 确认存在(不存在则跳过且警告)
    /// 默认 false, Windows 模板建议开。
    public var autoInstallVirtioWin: Bool

    /// 自动把 spice-guest-tools.exe 打进 AutoUnattend ISO, 首次登录时静默 NSIS
    /// 安装(`/S`)。装完 spice-vdagent 服务就位, Windows guest 能响应 host 的
    /// `VD_AGENT_MONITORS_CONFIG`, 在 HellVM 窗口拖拽 resize 时自动切分辨率。
    ///
    /// ARM64 Windows 注意: spice-guest-tools-latest.exe 是 x86 NSIS installer,
    /// Windows 11 ARM64 通过 x86 emulation 可以跑; 驱动部分(virtio-serial)走
    /// virtio-win.iso 里的 ARM64 包, 所以建议同时开启 autoInstallVirtioWin。
    ///
    /// 依赖:
    /// - installer 存放在全局缓存 ~/Library/Application Support/HellVM/cache/spice-guest-tools.exe
    /// - 启动前由 Swift 侧 SpiceToolsManager 确认存在(不存在则跳过且警告)
    /// - 只对**新建 VM** 生效(通过 FirstLogonCommands); 已装好的 Windows 需手动装
    /// 默认 false, Windows 模板建议开。
    public var autoInstallSpiceTools: Bool

    /// 安装完成后切换到"仅硬盘启动"模式: 启动时跳过 isoPath 的挂载, 不再暴露安装盘
    /// 给 guest. EFI NVRAM 里的 grub/bootmgr Boot#### entry 已经由安装程序写好,
    /// BDS 直接走硬盘。半自动安装完成流程的关键开关:
    /// - 首次装机: 保持 false, QEMU 挂 ISO, guest 启动进安装器
    /// - 安装完成后用户手动勾选 true → 下次启动仅硬盘
    /// - 需要重装时关掉 → 回到 ISO 挂载路径
    /// 默认 false, 不影响新建 VM 的正常装机流程。
    public var bootFromDiskOnly: Bool

    public init(
        isoPath: String? = nil,
        kernelPath: String? = nil,
        initrdPath: String? = nil,
        kernelCmdline: String? = nil,
        efi: Bool = true,
        graphical: Bool = true,
        tpm: Bool = false,
        serialDebug: Bool = false,
        bypassWin11Checks: Bool = false,
        autoInstallVirtioWin: Bool = false,
        autoInstallSpiceTools: Bool = false,
        bootFromDiskOnly: Bool = false
    ) {
        self.isoPath = isoPath
        self.kernelPath = kernelPath
        self.initrdPath = initrdPath
        self.kernelCmdline = kernelCmdline
        self.efi = efi
        self.graphical = graphical
        self.tpm = tpm
        self.serialDebug = serialDebug
        self.bypassWin11Checks = bypassWin11Checks
        self.autoInstallVirtioWin = autoInstallVirtioWin
        self.autoInstallSpiceTools = autoInstallSpiceTools
        self.bootFromDiskOnly = bootFromDiskOnly
    }

    private enum CodingKeys: String, CodingKey {
        case isoPath, kernelPath, initrdPath, kernelCmdline, efi, graphical, tpm, serialDebug
        case bypassWin11Checks, autoInstallVirtioWin, autoInstallSpiceTools, bootFromDiskOnly
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.isoPath               = try c.decodeIfPresent(String.self, forKey: .isoPath)
        self.kernelPath            = try c.decodeIfPresent(String.self, forKey: .kernelPath)
        self.initrdPath            = try c.decodeIfPresent(String.self, forKey: .initrdPath)
        self.kernelCmdline         = try c.decodeIfPresent(String.self, forKey: .kernelCmdline)
        self.efi                   = try c.decodeOr(Bool.self, forKey: .efi,                   default: true)
        self.graphical             = try c.decodeOr(Bool.self, forKey: .graphical,             default: true)
        self.tpm                   = try c.decodeOr(Bool.self, forKey: .tpm,                   default: false)
        self.serialDebug           = try c.decodeOr(Bool.self, forKey: .serialDebug,           default: false)
        self.bypassWin11Checks     = try c.decodeOr(Bool.self, forKey: .bypassWin11Checks,     default: false)
        self.autoInstallVirtioWin  = try c.decodeOr(Bool.self, forKey: .autoInstallVirtioWin,  default: false)
        self.autoInstallSpiceTools = try c.decodeOr(Bool.self, forKey: .autoInstallSpiceTools, default: false)
        self.bootFromDiskOnly      = try c.decodeOr(Bool.self, forKey: .bootFromDiskOnly,      default: false)
    }
}

// MARK: - 按 OS 类型计算 display / boot 合理默认

extension VMConfig {
    /// 依据客户机 OS 类型产出 display / boot / NIC model 的推荐默认值。
    /// 新建向导用,未来在 Settings 里按钮"应用 OS 默认"也可复用。
    public static func defaults(for osType: GuestOSType,
                                width: Int = 1280,
                                height: Int = 800,
                                graphical: Bool = true,
                                isoPath: String? = nil)
        -> (display: DisplayConfig, boot: BootConfig, nic: NICModel)
    {
        switch osType {
        case .windows:
            // Windows ARM64: 需要 TPM 2.0 和 Win11 硬件检查绕过.
            //
            // GPU: 默认开启 virtio-GPU 加速 = virtio-gpu-pci + ramfb 双 console.
            // 历史注释曾写"bootmgr 不能和 virtio-gpu 共存, 必须用 virtio-ramfb fusion",
            // 但 Win11 24H2 ARM64 ISO + 当前 EDK2 实测双 console 反而稳; fusion 路径
            // (patch 0002+0003) 在 PE 阶段观察到卡安装. 所以默认切到双 console, fusion
            // 仍保留作为可选 fallback(用户在 Settings 关掉 "virtio-GPU 加速" 即可切回)。
            //
            // 网卡: e1000e 开箱即可获得网络(Windows ARM 自带驱动). autoInstallVirtioWin
            // 在 FirstLogon 静默装 virtio-win-gt-arm64.msi, 装完用户可手动切到 virtio-net.
            let disp = DisplayConfig(width: width, height: height,
                                     enabled: graphical, virtioGpu: true)
            let boot = BootConfig(isoPath: isoPath, efi: true, graphical: graphical,
                                  tpm: true, bypassWin11Checks: true,
                                  autoInstallVirtioWin: true,
                                  autoInstallSpiceTools: true)
            return (disp, boot, .e1000e)
        case .linux:
            let disp = DisplayConfig(width: width, height: height,
                                     enabled: graphical, virtioGpu: true)
            let boot = BootConfig(isoPath: isoPath, efi: true, graphical: graphical)
            return (disp, boot, .virtio)
        case .macOS:
            // macOS guest 目前 QEMU/HVF 下跑不起来, 占位待后续接入 Virtualization.framework;
            // NIC 仍给 virtio 占位
            let disp = DisplayConfig(width: width, height: height,
                                     enabled: graphical, virtioGpu: true)
            let boot = BootConfig(isoPath: isoPath, efi: true, graphical: graphical)
            return (disp, boot, .virtio)
        case .other:
            // 未指定 OS: 保持历史默认(virtio-gpu 开), 避免对现有用户行为改变
            let disp = DisplayConfig(width: width, height: height,
                                     enabled: graphical, virtioGpu: true)
            let boot = BootConfig(isoPath: isoPath, efi: true, graphical: graphical)
            return (disp, boot, .virtio)
        }
    }
}

// MARK: - Decoding 小工具

extension KeyedDecodingContainer {
    /// 可选字段解码, 缺失/null → 返回 defaultValue.
    ///
    /// 用于保持对旧 config.json 的向前兼容 —— 新增字段时不需要写迁移脚本,
    /// 旧文件里没有的字段就取默认值. 比 `decodeIfPresent(...) ?? X` 意图更明确。
    func decodeOr<T: Decodable>(_ type: T.Type, forKey key: Key, default defaultValue: T) throws -> T {
        try decodeIfPresent(type, forKey: key) ?? defaultValue
    }
}
