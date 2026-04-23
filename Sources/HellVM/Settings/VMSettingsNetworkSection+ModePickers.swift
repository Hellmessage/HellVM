// VMSettingsNetworkSection —— 模式下拉 + 桥接接口下拉
// 两个自绘下拉都是暗色主题定制, 不用系统 Menu.
import SwiftUI
import HVMCore

extension VMSettingsNetworkSection {

    // MARK: - 模式下拉 (自绘, 跟暗色主题一致)

    func networkModeMenu(at idx: Int) -> some View {
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
    func networkVmnetOptions(at idx: Int) -> some View {
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
}
