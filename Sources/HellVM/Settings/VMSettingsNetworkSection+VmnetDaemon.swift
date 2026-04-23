// VMSettingsNetworkSection —— vmnet daemon 状态面板与安装/卸载
import SwiftUI
import HVMCore

extension VMSettingsNetworkSection {

    @ViewBuilder
    var vmnetDaemonPanel: some View {
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
}
