// VMConfigDraft —— 新建/编辑 VM 时 UI 层承接字段的可变模型
//
// 目标: Wizard 与 Settings 用同一份配置结构承接, 便于集中校验与字段默认值。
// - 核心配置走 VMConfig (Wizard 和 Settings 共享字段)
// - Wizard 独有字段 (name / firstDiskSizeGB) 单独保留
//
// 当前 Settings 仍直接以 VMConfig 做 draft(见 VMSettingsEditor), 本模型主要
// 被 Wizard 使用; 结构设计为后续 Settings 接入保留了空间。
import Foundation
import HVMCore

struct VMConfigDraft {
    /// 核心 VM 配置 —— Wizard / Settings 共享字段集中在此
    var config: VMConfig

    /// 向导步骤输入的 VM 名称 (Settings 里从 VMConfig.name 读)
    var name: String

    /// 向导首次创建时的初始磁盘容量 —— Settings 里走 VMController.addDisk / removeDisk
    var firstDiskSizeGB: Int

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
        return VMConfigDraft(config: cfg, name: "", firstDiskSizeGB: 20)
    }

    // MARK: - 校验

    /// 是否可以提交 (名称非空 + 数值在合法区间)
    var canSubmit: Bool {
        !name.isEmpty &&
        config.cpuCount > 0 &&
        config.memoryMB >= 128 &&
        firstDiskSizeGB > 0
    }

    // MARK: - OS 类型切换

    /// 切换 osType 后应用推荐默认值: 重算 display/boot/第一块 NIC 的型号
    /// 用户已改过 cpuCount/memoryMB 不覆盖 (尊重用户输入)
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
