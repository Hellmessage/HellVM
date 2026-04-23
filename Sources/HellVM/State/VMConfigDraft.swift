// VMConfigDraft —— 新建/编辑 VM 时 UI 层承接字段的可变模型
//
// 目标: Wizard 与 Settings 用同一份配置结构承接, 便于集中校验与字段默认值。
// - 核心配置走 VMConfig (Wizard 和 Settings 共享字段)
// - Wizard 独有字段 (name / firstDiskSizeGB / creationMode / imagePath) 单独保留
//
// 当前 Settings 仍直接以 VMConfig 做 draft(见 VMSettingsEditor), 本模型主要
// 被 Wizard 使用; 结构设计为后续 Settings 接入保留了空间。
import Foundation
import HVMCore

/// Wizard 的 VM 创建方式
public enum VMCreationMode {
    /// 空盘 + 可选 ISO 安装器 —— 装新系统
    case installFromISO
    /// 导入已有磁盘镜像 (OpenWrt .img / cloud image .qcow2 等已装好的系统)
    /// 镜像会被 qemu-img convert 成 qcow2, 可选扩容
    case importImage
}

struct VMConfigDraft {
    /// 核心 VM 配置 —— Wizard / Settings 共享字段集中在此
    var config: VMConfig

    /// 向导步骤输入的 VM 名称 (Settings 里从 VMConfig.name 读)
    var name: String

    /// 创建方式 (installFromISO / importImage)
    var creationMode: VMCreationMode

    /// installFromISO 模式:首次创建时的初始磁盘容量
    var firstDiskSizeGB: Int

    /// importImage 模式:镜像文件路径 (.img / .qcow2 / .raw / .gz / .xz)
    var importImagePath: String

    /// importImage 模式:转换后扩容到的目标大小 (GB). 0 或 < 镜像原大小时不扩。
    var importExpandToGB: Int

    /// 新建向导的默认值:aarch64 + Linux + 2C/2G + 20G 磁盘 + user 模式 NIC
    static func forNewVM() -> VMConfigDraft {
        let osType: GuestOSType = .linux
        let (display, boot, nic) = VMConfig.defaults(for: osType, graphical: true)
        let cfg = VMConfig(
            name: "",
            architecture: .aarch64,
            osType: osType,
            cpuCount: 2,
            memoryMB: 2048,
            disks: [],  // Wizard 提交时由 VMController.create 补磁盘, 这里留空
            networks: [NetworkConfig(
                mode: .user,
                macAddress: NetworkConfig.generateRandomMAC(),
                bridgedInterface: HostNetworkInterfaces.recommendedDefault(),
                deviceModel: nic
            )],
            display: display,
            boot: boot
        )
        return VMConfigDraft(
            config: cfg,
            name: "",
            creationMode: .installFromISO,
            firstDiskSizeGB: 20,
            importImagePath: "",
            importExpandToGB: 8
        )
    }

    // MARK: - 校验

    /// 是否可以提交 (名称非空 + 数值在合法区间, 按创建方式区分)
    var canSubmit: Bool {
        guard !name.isEmpty,
              config.cpuCount > 0,
              config.memoryMB >= 128 else { return false }
        switch creationMode {
        case .installFromISO:
            return firstDiskSizeGB > 0
        case .importImage:
            return !importImagePath.isEmpty
        }
    }

    // MARK: - OS 类型切换

    /// 切换 osType 后应用推荐默认值:
    /// - display/boot/第一块 NIC 型号:按 OS 推荐
    /// - CPU/内存/名称:按 OS 推荐默认 (Windows 4C/4G/名="Windows"; Linux 2C/2G/名="")
    ///
    /// 覆盖当前值 —— 用户明确切 OS 时重置字段合理;若用户想保留自己调的数,
    /// 可在 OS 选择后再进 Step 2 调整。
    mutating func applyOSDefaults(graphical: Bool) {
        let (display, boot, nic) = VMConfig.defaults(
            for: config.osType,
            graphical: graphical,
            isoPath: config.boot.isoPath
        )
        config.display = display
        config.boot = boot
        if config.networks.isEmpty {
            config.networks = [NetworkConfig(mode: .user,
                                             macAddress: NetworkConfig.generateRandomMAC(),
                                             deviceModel: nic)]
        } else {
            config.networks[0].deviceModel = nic
        }

        // CPU / 内存 / 名称 / 默认盘大小 按 OS 类型预设
        // (firstDiskSizeGB 是 Wizard installFromISO 模式的初始盘容量, 不属于 VMConfig)
        switch config.osType {
        case .windows:
            config.cpuCount = 4
            config.memoryMB = 4096
            firstDiskSizeGB = 64       // Win11 安装至少 20G, 留足空间给应用
            if name.isEmpty { name = "Windows" }
        case .linux:
            config.cpuCount = 2
            config.memoryMB = 2048
            firstDiskSizeGB = 20
            // name 保持空, 让用户自己填 (如 ubuntu-24, openwrt-24 等)
        case .macOS, .other:
            config.cpuCount = 2
            config.memoryMB = 2048
            firstDiskSizeGB = 20
        }
    }

    // MARK: - Wizard 单 NIC 便捷访问 (只管第一块)

    var primaryNetworkMode: NetworkConfig.Mode {
        get { config.networks.first?.mode ?? .user }
        set {
            ensureFirstNIC()
            config.networks[0].mode = newValue
            if newValue == .user || newValue == .none {
                config.networks[0].socketVmnetPath = nil
                config.networks[0].bridgedInterface = nil
            }
        }
    }

    var primaryBridgedInterface: String {
        get {
            config.networks.first?.bridgedInterface
                ?? HostNetworkInterfaces.recommendedDefault()
        }
        set {
            ensureFirstNIC()
            config.networks[0].bridgedInterface = newValue
        }
    }

    private mutating func ensureFirstNIC() {
        if config.networks.isEmpty {
            config.networks.append(NetworkConfig(
                mode: .user,
                macAddress: NetworkConfig.generateRandomMAC()
            ))
        }
    }
}
