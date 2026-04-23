// 虚拟机配置模型 —— 持久化到 .hellvm bundle 内的 config.json
import Foundation

/// 一台 VM 的完整配置
public struct VMConfig: Codable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var architecture: VMArchitecture
    public var cpuCount: Int
    public var memoryMB: UInt64
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
        cpuCount: Int = 2,
        memoryMB: UInt64 = 2048,
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
        self.cpuCount = cpuCount
        self.memoryMB = memoryMB
        self.disks = disks
        self.networks = networks
        self.display = display
        self.boot = boot
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// 磁盘配置(路径相对于 bundle 根目录)
public struct DiskConfig: Codable, Sendable, Identifiable {
    public var id: UUID
    public var relativePath: String   // 例如 "disks/main.qcow2"
    public var sizeGB: UInt64
    public var format: Format
    public var readOnly: Bool

    public enum Format: String, Codable, Sendable {
        case qcow2
        case raw
    }

    public init(
        id: UUID = UUID(),
        relativePath: String,
        sizeGB: UInt64,
        format: Format = .qcow2,
        readOnly: Bool = false
    ) {
        self.id = id
        self.relativePath = relativePath
        self.sizeGB = sizeGB
        self.format = format
        self.readOnly = readOnly
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
        bridgedInterface: String? = nil
    ) {
        self.mode = mode
        self.macAddress = macAddress
        self.socketVmnetPath = socketVmnetPath
        self.bridgedInterface = bridgedInterface
    }

    /// 推导实际使用的 socket 路径(vmnet* 模式): 用户显式填 socketVmnetPath 优先,
    /// 否则按模式约定:
    ///   shared  → /var/run/socket_vmnet
    ///   host    → /var/run/socket_vmnet.host
    ///   bridged → /var/run/socket_vmnet.bridged.<iface>
    public var effectiveSocketPath: String? {
        if let p = socketVmnetPath, !p.isEmpty { return p }
        switch mode {
        case .vmnetShared:  return "/var/run/socket_vmnet"
        case .vmnetHost:    return "/var/run/socket_vmnet.host"
        case .vmnetBridged:
            let iface = (bridgedInterface?.isEmpty == false) ? bridgedInterface! : "en0"
            return "/var/run/socket_vmnet.bridged.\(iface)"
        case .user, .none:  return nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case mode, macAddress, socketVmnetPath, bridgedInterface
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
    }
}

/// 显示配置
public struct DisplayConfig: Codable, Sendable {
    public var width: Int
    public var height: Int
    public var enabled: Bool

    public static let `default` = DisplayConfig(width: 1280, height: 800, enabled: true)

    public init(width: Int, height: Int, enabled: Bool) {
        self.width = width
        self.height = height
        self.enabled = enabled
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

    public init(
        isoPath: String? = nil,
        kernelPath: String? = nil,
        initrdPath: String? = nil,
        kernelCmdline: String? = nil,
        efi: Bool = true,
        graphical: Bool = true,
        tpm: Bool = false,
        serialDebug: Bool = false
    ) {
        self.isoPath = isoPath
        self.kernelPath = kernelPath
        self.initrdPath = initrdPath
        self.kernelCmdline = kernelCmdline
        self.efi = efi
        self.graphical = graphical
        self.tpm = tpm
        self.serialDebug = serialDebug
    }

    private enum CodingKeys: String, CodingKey {
        case isoPath, kernelPath, initrdPath, kernelCmdline, efi, graphical, tpm, serialDebug
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.isoPath       = try c.decodeIfPresent(String.self, forKey: .isoPath)
        self.kernelPath    = try c.decodeIfPresent(String.self, forKey: .kernelPath)
        self.initrdPath    = try c.decodeIfPresent(String.self, forKey: .initrdPath)
        self.kernelCmdline = try c.decodeIfPresent(String.self, forKey: .kernelCmdline)
        self.efi           = try c.decodeIfPresent(Bool.self,   forKey: .efi)       ?? true
        // 兼容旧 config(无 graphical 字段): 默认 true
        self.graphical     = try c.decodeIfPresent(Bool.self,   forKey: .graphical) ?? true
        // 兼容旧 config(无 tpm 字段): 默认 false
        self.tpm           = try c.decodeIfPresent(Bool.self,   forKey: .tpm)       ?? false
        // 兼容旧 config(无 serialDebug 字段): 默认 false
        self.serialDebug   = try c.decodeIfPresent(Bool.self,   forKey: .serialDebug) ?? false
    }
}
