// VMSettings 的网络子区块
//
// 设计要点:
// - 网络改动写入 draft, 保存时父 saveBar 调 applyNetworkHotplug 做 QMP 热插拔
// - 多 NIC 折叠卡片, 默认全部折叠, 新加的自动展开
// - 模式选择用自绘下拉, 和暗色主题一致 (不走系统 Menu)
// - vmnet daemon 状态面板在任一 NIC 走 vmnet 时显示, 一键装/卸
import SwiftUI
import HVMCore
import HVMBackendQEMU

struct VMSettingsNetworkSection: View {
    @Binding var draft: VMConfig
    let item: VMListItem

    /// 多网卡卡片折叠状态
    @State private var expandedNICs: Set<Int> = []
    /// 每个 NIC 的模式下拉展开状态
    @State private var openModeMenus: Set<Int> = []
    /// 每个 NIC 的桥接接口下拉展开状态
    @State private var openIfaceMenus: Set<Int> = []
    /// vmnet daemon 安装/卸载状态
    @State private var vmnetBusy: Bool = false
    @State private var vmnetError: String?
    /// 安装/卸载后 bump, 强制 vmnetDaemonPanel 重读 socket 状态
    @State private var vmnetRefreshToken: UInt64 = 0

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

    // MARK: - 单块 NIC 卡片

    @ViewBuilder
    private func nicCard(at idx: Int) -> some View {
        if idx < draft.networks.count {
            let expanded = expandedNICs.contains(idx)
            let enabled = draft.networks[idx].enabled
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Button(action: { toggleNICExpanded(idx) }) {
                        HStack(spacing: 8) {
                            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Theme.textTertiary)
                                .frame(width: 10)
                            Image(systemName: "network")
                                .font(.system(size: 12))
                                .foregroundStyle(enabled ? Theme.accent : Theme.textTertiary)
                            Text("NIC \(idx)")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(enabled ? Theme.textPrimary : Theme.textTertiary)
                            Text(nicSummary(at: idx))
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.textSecondary.opacity(enabled ? 1.0 : 0.5))
                                .lineLimit(1)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Toggle("", isOn: Binding(
                        get: { draft.networks[idx].enabled },
                        set: { new in draft.networks[idx].enabled = new }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .help(enabled ? "点击禁用此网卡(保留配置, 启动时不挂)" : "点击启用此网卡")

                    Button(action: { removeNIC(at: idx) }) {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.danger)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.danger.opacity(0.10)))
                    }
                    .buttonStyle(.plain)
                    .help("删除此网卡")
                }
                .padding(.horizontal, 12).padding(.vertical, 10)

                if expanded {
                    Rectangle().fill(Theme.divider).frame(height: 1)
                    VStack(alignment: .leading, spacing: 10) {
                        networkModeMenu(at: idx)
                        nicModelPicker(at: idx)
                        let mode = draft.networks[idx].mode
                        if mode == .vmnetBridged {
                            networkVmnetOptions(at: idx)
                        }
                        networkMacField(at: idx)
                    }
                    .padding(12)
                }
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.divider, lineWidth: 1))
        }
    }

    /// 折叠状态下的摘要行
    private func nicSummary(at idx: Int) -> String {
        let net = draft.networks[idx]
        var parts: [String] = []
        if !net.enabled {
            parts.append("已禁用")
        }
        var modeStr = displayName(of: net.mode)
        if net.mode == .vmnetBridged, let iface = net.bridgedInterface, !iface.isEmpty {
            modeStr += "(\(iface))"
        }
        parts.append(modeStr)
        parts.append(net.deviceModel.rawValue)
        if let mac = net.macAddress, mac.count >= 8 {
            parts.append("…\(mac.suffix(8))")
        }
        return parts.joined(separator: " · ")
    }

    private func toggleNICExpanded(_ idx: Int) {
        if expandedNICs.contains(idx) { expandedNICs.remove(idx) } else { expandedNICs.insert(idx) }
    }

    // MARK: - 模式下拉 (自绘, 跟暗色主题一致)

    private func networkModeMenu(at idx: Int) -> some View {
        let current = draft.networks[idx].mode
        let isOpen = openModeMenus.contains(idx)
        return VStack(alignment: .leading, spacing: 6) {
            FieldLabel("模式")
            Button(action: { toggleModeMenu(idx) }) {
                HStack {
                    Image(systemName: modeIcon(current))
                        .foregroundStyle(modeColor(current))
                        .font(.system(size: 12))
                    Text(displayName(of: current))
                        .foregroundStyle(Theme.textPrimary)
                        .font(.system(size: 12, weight: .medium))
                    Text(modeSubtitle(current))
                        .foregroundStyle(Theme.textTertiary)
                        .font(.system(size: 10))
                    Spacer()
                    Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                        .foregroundStyle(Theme.textTertiary)
                        .font(.system(size: 10))
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surfaceElevated))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .stroke(isOpen ? Theme.accent.opacity(0.4) : Color.clear, lineWidth: 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isOpen {
                VStack(spacing: 4) {
                    modeOption(.user,         title: "user (NAT)",        subtitle: "QEMU 内置, 零依赖, 不支持 ICMP/ping", current: current, idx: idx)
                    modeOption(.vmnetShared,  title: "vmnet · shared",    subtitle: "NAT + DHCP (socket_vmnet 默认模式)", current: current, idx: idx)
                    modeOption(.vmnetHost,    title: "vmnet · host-only", subtitle: "仅宿主机互通, 无外网",                current: current, idx: idx)
                    modeOption(.vmnetBridged, title: "vmnet · bridged",   subtitle: "真二层桥接, 获取同局域网 IP",          current: current, idx: idx)
                    Rectangle().fill(Theme.divider).frame(height: 1).padding(.vertical, 2)
                    modeOption(.none,         title: "暂时禁用",           subtitle: "保留配置, 启动时不挂这块 NIC",         current: current, idx: idx)
                }
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surface))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.divider, lineWidth: 1))
            }
        }
    }

    private func modeOption(_ mode: NetworkConfig.Mode,
                            title: String, subtitle: String,
                            current: NetworkConfig.Mode, idx: Int) -> some View {
        let selected = current == mode
        return Button(action: {
            setMode(mode, at: idx)
            openModeMenus.remove(idx)
        }) {
            HStack(spacing: 10) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(selected ? Theme.accent : Theme.textTertiary)
                Image(systemName: modeIcon(mode))
                    .font(.system(size: 11))
                    .foregroundStyle(selected ? modeColor(mode) : Theme.textTertiary)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(selected ? Theme.accent.opacity(0.10) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func toggleModeMenu(_ idx: Int) {
        if openModeMenus.contains(idx) { openModeMenus.remove(idx) } else { openModeMenus.insert(idx) }
    }

    // MARK: - 桥接接口选择

    @ViewBuilder
    private func networkVmnetOptions(at idx: Int) -> some View {
        let mode = draft.networks[idx].mode
        VStack(alignment: .leading, spacing: 8) {
            if mode == .vmnetBridged {
                FieldLabel("桥接网卡")
                bridgedInterfacePicker(at: idx)
            }
        }
    }

    private func bridgedInterfacePicker(at idx: Int) -> some View {
        let ifaces = HostNetworkInterfaces.list()
        let current = draft.networks[idx].bridgedInterface ?? HostNetworkInterfaces.recommendedDefault()
        let isOpen = openIfaceMenus.contains(idx)
        return VStack(alignment: .leading, spacing: 4) {
            Button(action: { toggleIfaceMenu(idx) }) {
                HStack {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .foregroundStyle(Theme.accent)
                        .font(.system(size: 12))
                    Text(labelFor(iface: current, among: ifaces))
                        .foregroundStyle(Theme.textPrimary)
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                        .foregroundStyle(Theme.textTertiary)
                        .font(.system(size: 10))
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surfaceElevated))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .stroke(isOpen ? Theme.accent.opacity(0.4) : Color.clear, lineWidth: 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isOpen {
                VStack(spacing: 2) {
                    if ifaces.isEmpty {
                        Text("(扫描不到可桥接接口)")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                    } else {
                        ForEach(ifaces, id: \.id) { iface in
                            ifaceOption(iface, current: current, idx: idx)
                        }
                    }
                }
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surface))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.divider, lineWidth: 1))
            }
        }
    }

    private func ifaceOption(_ iface: HostNetworkInterface,
                             current: String, idx: Int) -> some View {
        let selected = iface.name == current
        return Button(action: {
            updateNet(at: idx) { $0.bridgedInterface = iface.name }
            openIfaceMenus.remove(idx)
        }) {
            HStack(spacing: 8) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12))
                    .foregroundStyle(selected ? Theme.accent : Theme.textTertiary)
                Circle()
                    .fill(iface.isActive ? Theme.success : Theme.textTertiary)
                    .frame(width: 6, height: 6)
                Text(iface.name)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular, design: .monospaced))
                    .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                if let ip = iface.ipv4 {
                    Text(ip)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.textTertiary)
                } else {
                    Text("(未连接)")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(selected ? Theme.accent.opacity(0.10) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func toggleIfaceMenu(_ idx: Int) {
        if openIfaceMenus.contains(idx) { openIfaceMenus.remove(idx) } else { openIfaceMenus.insert(idx) }
    }

    private func labelFor(iface name: String, among ifaces: [HostNetworkInterface]) -> String {
        if let hit = ifaces.first(where: { $0.name == name }) { return hit.displayLabel }
        return "\(name) — (当前不存在)"
    }

    // MARK: - NIC 型号

    private func nicModelPicker(at idx: Int) -> some View {
        let current = draft.networks[idx].deviceModel
        return VStack(alignment: .leading, spacing: 6) {
            FieldLabel("NIC 型号")
            HStack(spacing: 6) {
                nicChip(.virtio,  title: "virtio",  subtitle: "Linux 最快", current: current, idx: idx)
                nicChip(.e1000e,  title: "e1000e",  subtitle: "Win 开箱",   current: current, idx: idx)
                nicChip(.rtl8139, title: "rtl8139", subtitle: "老系统兜底", current: current, idx: idx)
            }
        }
    }

    private func nicChip(_ m: NICModel, title: String, subtitle: String,
                         current: NICModel, idx: Int) -> some View {
        let selected = current == m
        return Button(action: { updateNet(at: idx) { $0.deviceModel = m } }) {
            VStack(spacing: 3) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                Text(subtitle)
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.textTertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 7)
                .fill(selected ? Theme.accent.opacity(0.12) : Theme.surfaceElevated))
            .overlay(RoundedRectangle(cornerRadius: 7)
                .stroke(selected ? Theme.accent.opacity(0.6) : Color.clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: - MAC 字段

    private func networkMacField(at idx: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            FieldLabel("MAC 地址")
            HStack(spacing: 8) {
                StyledTextField(
                    placeholder: "52:54:00:xx:xx:xx",
                    text: Binding(
                        get: { draft.networks[idx].macAddress ?? "" },
                        set: { v in updateNet(at: idx) { $0.macAddress = v.isEmpty ? nil : v } }
                    ),
                    monospaced: true
                )
                SecondaryButton(title: "重新生成", systemImage: "arrow.clockwise") {
                    updateNet(at: idx) { $0.macAddress = NetworkConfig.generateRandomMAC() }
                }
            }
        }
    }

    // MARK: - vmnet daemon 面板

    @ViewBuilder
    private var vmnetDaemonPanel: some View {
        let vmnetNets = draft.networks.filter {
            $0.mode == .vmnetShared || $0.mode == .vmnetHost || $0.mode == .vmnetBridged
        }
        if !vmnetNets.isEmpty {
            let sockets = VMnetSupervisor.presentSockets()
            let missing = vmnetNets.compactMap { net -> String? in
                let st = VMnetSupervisor.status(for: net)
                return st.socketExists ? nil : (st.socketPath ?? "?")
            }
            VStack(alignment: .leading, spacing: 6) {
                FieldLabel("vmnet daemon")
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: missing.isEmpty ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(missing.isEmpty ? Theme.success : Theme.warning)
                    VStack(alignment: .leading, spacing: 3) {
                        if missing.isEmpty {
                            Text("所有 NIC 需要的 socket 均已就绪")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.textSecondary)
                        } else {
                            Text("缺失 socket: \(missing.joined(separator: ", "))")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.textPrimary.opacity(0.9))
                        }
                        Text("已装: shared=\(sockets.shared ? "✓" : "✗") · host=\(sockets.host ? "✓" : "✗") · bridged=[\(sockets.bridged.joined(separator: ", "))]")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    Spacer()
                }
                HStack(spacing: 8) {
                    SecondaryButton(title: vmnetBusy ? "正在安装…" : "安装 / 更新 daemon",
                                    systemImage: "lock.shield",
                                    disabled: vmnetBusy) {
                        Task { await installVmnet() }
                    }
                    SecondaryButton(title: "卸载全部", systemImage: "trash",
                                    disabled: vmnetBusy) {
                        Task { await uninstallVmnet() }
                    }
                    Spacer()
                }
                if let err = vmnetError {
                    Text(err).font(.system(size: 10)).foregroundStyle(Theme.danger)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.divider, lineWidth: 1))
            .id(vmnetRefreshToken)  // bump 后强制重算 sockets/missing
        }
    }

    @MainActor
    private func installVmnet() async {
        vmnetBusy = true
        vmnetError = nil
        defer { vmnetBusy = false }
        do {
            let extra = draft.networks.compactMap { net -> String? in
                guard net.mode == .vmnetBridged,
                      let i = net.bridgedInterface, !i.isEmpty else { return nil }
                return i
            }
            try await VMnetSupervisor.installAllDaemons(extraBridgedInterfaces: extra)
            vmnetRefreshToken &+= 1
        } catch {
            vmnetError = "安装失败: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func uninstallVmnet() async {
        vmnetBusy = true
        vmnetError = nil
        defer { vmnetBusy = false }
        do {
            try await VMnetSupervisor.uninstallAllDaemons()
            vmnetRefreshToken &+= 1
        } catch {
            vmnetError = "卸载失败: \(error.localizedDescription)"
        }
    }

    // MARK: - NIC 增删与字段更新

    private func setMode(_ m: NetworkConfig.Mode, at idx: Int) {
        guard idx < draft.networks.count else { return }
        draft.networks[idx].mode = m
        if m == .user || m == .none {
            draft.networks[idx].socketVmnetPath = nil
            draft.networks[idx].bridgedInterface = nil
        }
    }

    private func updateNet(at idx: Int, _ mutate: (inout NetworkConfig) -> Void) {
        guard idx < draft.networks.count else { return }
        mutate(&draft.networks[idx])
    }

    private func addNIC() {
        let (_, _, nic) = VMConfig.defaults(for: draft.osType)
        draft.networks.append(NetworkConfig(
            mode: .user,
            macAddress: NetworkConfig.generateRandomMAC(),
            deviceModel: nic
        ))
        expandedNICs.insert(draft.networks.count - 1)
    }

    private func removeNIC(at idx: Int) {
        guard idx < draft.networks.count else { return }
        draft.networks.remove(at: idx)
        var newSet: Set<Int> = []
        for e in expandedNICs {
            if e < idx { newSet.insert(e) }
            else if e > idx { newSet.insert(e - 1) }
        }
        expandedNICs = newSet
    }

    private func displayName(of m: NetworkConfig.Mode) -> String {
        switch m {
        case .user:         return "user (NAT)"
        case .vmnetShared:  return "vmnet shared"
        case .vmnetHost:    return "vmnet host-only"
        case .vmnetBridged: return "vmnet bridged"
        case .none:         return "无网络"
        }
    }

    private func modeIcon(_ m: NetworkConfig.Mode) -> String {
        switch m {
        case .user:         return "network"
        case .vmnetShared:  return "shared.with.you"
        case .vmnetHost:    return "house"
        case .vmnetBridged: return "antenna.radiowaves.left.and.right"
        case .none:         return "pause.circle"
        }
    }

    private func modeColor(_ m: NetworkConfig.Mode) -> Color {
        m == .none ? Theme.textTertiary : Theme.accent
    }

    private func modeSubtitle(_ m: NetworkConfig.Mode) -> String {
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
           x.deviceModel != y.deviceModel {
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
