// VMSettingsNetworkSection —— 单 NIC 卡片 + NIC 型号 + MAC 字段
import SwiftUI
import HVMCore

extension VMSettingsNetworkSection {

    // MARK: - 单块 NIC 卡片

    @ViewBuilder
    func nicCard(at idx: Int) -> some View {
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

    // MARK: - NIC 型号

    func nicModelPicker(at idx: Int) -> some View {
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

    func networkMacField(at idx: Int) -> some View {
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
}
