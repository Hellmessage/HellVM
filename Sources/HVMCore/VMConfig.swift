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
        networks: [NetworkConfig] = [.init(mode: .nat)],
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
public struct NetworkConfig: Codable, Sendable {
    public var mode: Mode
    public var macAddress: String?

    public enum Mode: String, Codable, Sendable {
        case nat        // NAT(共享宿主机网络)
        case bridged    // 桥接
        case hostOnly   // 仅宿主机
        case none       // 无网络
    }

    public init(mode: Mode, macAddress: String? = nil) {
        self.mode = mode
        self.macAddress = macAddress
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
public struct BootConfig: Codable, Sendable {
    public var isoPath: String?         // 相对 bundle
    public var kernelPath: String?
    public var initrdPath: String?
    public var kernelCmdline: String?
    public var efi: Bool                // 是否使用 EFI 启动(VZ macOS/Linux)

    public init(
        isoPath: String? = nil,
        kernelPath: String? = nil,
        initrdPath: String? = nil,
        kernelCmdline: String? = nil,
        efi: Bool = true
    ) {
        self.isoPath = isoPath
        self.kernelPath = kernelPath
        self.initrdPath = initrdPath
        self.kernelCmdline = kernelCmdline
        self.efi = efi
    }
}
