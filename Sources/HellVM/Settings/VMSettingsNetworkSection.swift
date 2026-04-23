// VMSettings 的网络子区块 —— 主骨架
//
// 设计要点:
// - 网络改动写入 draft, 保存时父 saveBar 调 applyNetworkHotplug 做 QMP 热插拔
// - 多 NIC 折叠卡片, 默认全部折叠, 新加的自动展开
// - 模式选择用自绘下拉, 和暗色主题一致 (不走系统 Menu)
// - vmnet daemon 状态面板在任一 NIC 走 vmnet 时显示, 一键装/卸
//
// 子 UI 拆到 extension 文件:
//   - VMSettingsNetworkSection+NICCard      单 NIC 卡片 / NIC 型号 / MAC 字段
//   - VMSettingsNetworkSection+ModePickers  模式下拉 / 桥接接口下拉
//   - VMSettingsNetworkSection+VmnetDaemon  vmnet daemon 状态面板与装卸
import SwiftUI
import HVMCore
import HVMBackendQEMU

struct VMSettingsNetworkSection: View {
    @Binding var draft: VMConfig
    let item: VMListItem

    /// 多网卡卡片折叠状态
    @State var expandedNICs: Set<Int> = []
    /// 每个 NIC 的模式下拉展开状态
    @State var openModeMenus: Set<Int> = []
    /// 每个 NIC 的桥接接口下拉展开状态
    @State var openIfaceMenus: Set<Int> = []
    /// vmnet daemon 安装/卸载状态
    @State var vmnetBusy: Bool = false
    @State var vmnetError: String?
    /// 安装/卸载后 bump, 强制 vmnetDaemonPanel 重读 socket 状态
    @State var vmnetRefreshToken: UInt64 = 0

    var body: some View {
        VMSection(title: "网络") {
            ForEach(draft.networks.indices, id: \.self) { idx in
                nicCard(at: idx)
            }
            HStack(spacing: 8) {
                SecondaryButton(title: "添加网卡", systemImage: "plus") { addNIC() }
                Text(item.bundle.isRunning()
                     ? "VM 运行中 —— 保存时会 QMP 热插拔应用改动"
                     : "多网卡允许同一 VM 同时用不同网络(例: shared 上网 + bridged 暴露服务)")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
            }
            vmnetDaemonPanel
        }
    }

    // MARK: - NIC 增删与字段更新

    func setMode(_ m: NetworkConfig.Mode, at idx: Int) {
        guard idx < draft.networks.count else { return }
        draft.networks[idx].mode = m
        if m == .user || m == .none {
            draft.networks[idx].socketVmnetPath = nil
            draft.networks[idx].bridgedInterface = nil
        }
    }

    func updateNet(at idx: Int, _ mutate: (inout NetworkConfig) -> Void) {
        guard idx < draft.networks.count else { return }
        mutate(&draft.networks[idx])
    }

    func addNIC() {
        let (_, _, nic) = VMConfig.defaults(for: draft.osType)
        draft.networks.append(NetworkConfig(
            mode: .user,
            macAddress: NetworkConfig.generateRandomMAC(),
            deviceModel: nic
        ))
        expandedNICs.insert(draft.networks.count - 1)
    }

    func removeNIC(at idx: Int) {
        guard idx < draft.networks.count else { return }
        draft.networks.remove(at: idx)
        var newSet: Set<Int> = []
        for e in expandedNICs {
            if e < idx { newSet.insert(e) }
            else if e > idx { newSet.insert(e - 1) }
        }
        expandedNICs = newSet
    }

    // MARK: - Mode 展示辅助 (跨 extension 共用)

    func displayName(of m: NetworkConfig.Mode) -> String {
        switch m {
        case .user:         return "user (NAT)"
        case .vmnetShared:  return "vmnet shared"
        case .vmnetHost:    return "vmnet host-only"
        case .vmnetBridged: return "vmnet bridged"
        case .none:         return "无网络"
        }
    }

    func modeIcon(_ m: NetworkConfig.Mode) -> String {
        switch m {
        case .user:         return "network"
        case .vmnetShared:  return "shared.with.you"
        case .vmnetHost:    return "house"
        case .vmnetBridged: return "antenna.radiowaves.left.and.right"
        case .none:         return "pause.circle"
        }
    }

    func modeColor(_ m: NetworkConfig.Mode) -> Color {
        m == .none ? Theme.textTertiary : Theme.accent
    }

    func modeSubtitle(_ m: NetworkConfig.Mode) -> String {
        switch m {
        case .user:         return "零依赖, 不支持 ICMP"
        case .vmnetShared:  return "默认模式"
        case .vmnetHost:    return "仅宿主机互通"
        case .vmnetBridged: return "真二层桥接"
        case .none:         return "不挂载"
        }
    }
}

// MARK: - 公共工具: networks 等价比较(dirty 检测用, 被主 View 复用)

func vmSettingsNetworksEqual(_ a: [NetworkConfig], _ b: [NetworkConfig]) -> Bool {
    guard a.count == b.count else { return false }
    for (x, y) in zip(a, b) {
        if x.mode != y.mode ||
           x.macAddress != y.macAddress ||
           x.socketVmnetPath != y.socketVmnetPath ||
           x.bridgedInterface != y.bridgedInterface ||
           x.deviceModel != y.deviceModel ||
           x.enabled != y.enabled {
            return false
        }
    }
    return true
}

/// 网络热插拔:对比 old / new 两份 networks, 通过 QMP 应用差异
/// (detach 掉不再启用的, attach 新启用或字段变化的). 非 fatal: 单张 NIC 失败不影响其他。
@MainActor
func vmSettingsApplyNetworkHotplug(
    item: VMListItem,
    old: [NetworkConfig],
    new: [NetworkConfig]
) async -> String? {
    let (toAttach, toDetach) = NICHotplug.diff(old: old, new: new)
    guard !toAttach.isEmpty || !toDetach.isEmpty else { return nil }

    let qmp = QMPClient()
    do {
        try await qmp.connect(socketPath: item.bundle.qmpSocketURL.path)
    } catch {
        return "QMP 连接失败, 热插拔未生效: \(error.localizedDescription)"
    }
    defer { Task { await qmp.close() } }

    for net in toDetach {
        do {
            try await NICHotplug.detach(net, via: qmp)
            log.info(.backend, "hotplug: detached \(NICHotplug.deviceID(for: net) ?? "?")")
        } catch {
            log.warn(.backend, "hotplug: detach failed: \(error)")
        }
    }
    var lastError: String?
    for net in toAttach {
        do {
            try await NICHotplug.attach(net, via: qmp)
            log.info(.backend, "hotplug: attached \(NICHotplug.deviceID(for: net) ?? "?")")
        } catch {
            lastError = "热插拔 \(NICHotplug.deviceID(for: net) ?? "?") 失败: \(error.localizedDescription)"
            log.warn(.backend, "hotplug: attach failed: \(error)")
        }
    }
    return lastError
}
