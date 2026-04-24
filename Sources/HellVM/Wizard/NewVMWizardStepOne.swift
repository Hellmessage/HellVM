// 新建 VM 向导 —— Step 1: OS 类型选择 + virtio-win 驱动盘状态
import SwiftUI
import HVMCore

struct NewVMWizardStepOne: View {
    @Binding var draft: VMConfigDraft
    @ObservedObject var virtioWin: VirtioWinManager
    @StateObject private var spiceTools = SpiceToolsManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            FieldLabel("客户机类型")
            osTypeGrid
            osTypeHint
            if draft.config.osType == .windows {
                virtioWinStatusRow
                spiceToolsStatusRow
            }
        }
    }

    // MARK: - OS 类型网格

    private var osTypeGrid: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                bigOSCard(.linux,   title: "Linux",   subtitle: "GPU",  icon: "terminal.fill")
                bigOSCard(.windows, title: "Windows", subtitle: "GPU+TPM", icon: "square.stack.fill")
            }
            HStack(spacing: 10) {
                bigOSCard(.macOS, title: "macOS", subtitle: "实验性",   icon: "apple.logo")
                bigOSCard(.other, title: "其他",  subtitle: "手动配置", icon: "questionmark.circle")
            }
        }
    }

    private func bigOSCard(_ type: GuestOSType,
                           title: String, subtitle: String, icon: String) -> some View {
        let selected = draft.config.osType == type
        return Button(action: {
            draft.config.osType = type
            // 选中即应用该 OS 的默认值 (CPU/内存/名称/NIC/display/boot)
            draft.applyOSDefaults(graphical: draft.config.boot.graphical)
        }) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(selected ? Theme.accent : Theme.textSecondary)
                    .frame(width: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.accent)
                        .font(.system(size: 18))
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10)
                .fill(selected ? Theme.accent.opacity(0.12) : Theme.surfaceElevated))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(selected ? Theme.accent : Color.clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
    }

    // MARK: - OS 说明

    @ViewBuilder
    private var osTypeHint: some View {
        switch draft.config.osType {
        case .windows:
            infoHint("virtio-GPU 加速 · TPM 启用 · Win11 硬件检查绕过 · 默认 4核/4GB")
        case .linux:
            infoHint("virtio-gpu 加速 · 默认 2核/2GB · 适合 Ubuntu/OpenWrt/Debian 等")
        case .macOS:
            infoHint("实验性: macOS guest 目前 QEMU/HVF 下未稳定支持, 占位待 Virtualization.framework 接入")
        case .other:
            infoHint("保持默认 (virtio-gpu 开), 各字段可在 Settings 手动调")
        }
    }

    private func infoHint(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
            Text(text)
                .font(.system(size: 10))
                .foregroundStyle(Theme.textTertiary)
            Spacer()
        }
    }

    // MARK: - virtio-win 状态

    /// virtio-win.iso 状态 + 下载按钮(Step 1 Windows 选中后显示)
    @ViewBuilder
    private var virtioWinStatusRow: some View {
        let status = VirtioWinManager.status()
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: status.exists ? "checkmark.seal.fill"
                      : (virtioWin.downloadProgress != nil ? "arrow.down.circle" : "shippingbox"))
                    .font(.system(size: 11))
                    .foregroundStyle(status.exists ? Theme.success : Theme.warning)
                VStack(alignment: .leading, spacing: 2) {
                    if status.exists {
                        Text("virtio-win 驱动盘已就绪 (\(formatMB(status.sizeBytes)))")
                            .font(.system(size: 11, weight: .medium))
                    } else if let p = virtioWin.downloadProgress {
                        Text(String(format: "正在下载 virtio-win.iso … %.0f%%", p * 100))
                            .font(.system(size: 11, weight: .medium))
                    } else {
                        Text("virtio-win 驱动盘未下载")
                            .font(.system(size: 11, weight: .medium))
                    }
                    Text("装完 Windows 后 FirstLogon 会静默装 NetKVM/viostor/viogpudo 驱动, 可切 virtio-net 跑全速")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)
                    if let err = virtioWin.lastError {
                        Text(err).font(.system(size: 10)).foregroundStyle(Theme.danger)
                    }
                }
                Spacer()
                if !status.exists && virtioWin.downloadProgress == nil {
                    SecondaryButton(title: "下载", systemImage: "arrow.down.circle") {
                        Task { try? await virtioWin.downloadIfNeeded() }
                    }
                } else if virtioWin.downloadProgress != nil {
                    SecondaryButton(title: "取消", systemImage: "xmark.circle") {
                        virtioWin.cancelDownload()
                    }
                }
            }
            if let p = virtioWin.downloadProgress {
                ProgressView(value: p).progressViewStyle(.linear).tint(Theme.accent)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surfaceElevated))
    }

    // MARK: - spice-guest-tools 状态

    /// spice-guest-tools.exe 状态 + 下载按钮 (结构和 virtioWinStatusRow 镜像).
    /// 装完 spice-vdagent 服务, Windows 拖 HellVM 窗口时会自动切分辨率。
    @ViewBuilder
    private var spiceToolsStatusRow: some View {
        let status = SpiceToolsManager.status()
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: status.exists ? "checkmark.seal.fill"
                      : (spiceTools.downloadProgress != nil ? "arrow.down.circle" : "arrow.up.left.and.arrow.down.right"))
                    .font(.system(size: 11))
                    .foregroundStyle(status.exists ? Theme.success : Theme.warning)
                VStack(alignment: .leading, spacing: 2) {
                    if status.exists {
                        Text("spice-guest-tools 已就绪 (\(formatMB(status.sizeBytes)))")
                            .font(.system(size: 11, weight: .medium))
                    } else if let p = spiceTools.downloadProgress {
                        Text(String(format: "正在下载 spice-guest-tools.exe … %.0f%%", p * 100))
                            .font(.system(size: 11, weight: .medium))
                    } else {
                        Text("spice-guest-tools 未下载")
                            .font(.system(size: 11, weight: .medium))
                    }
                    Text("装完后 spice-vdagent 服务自启, 拖 HellVM 窗口 Windows 会自动改分辨率")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)
                    if let err = spiceTools.lastError {
                        Text(err).font(.system(size: 10)).foregroundStyle(Theme.danger)
                    }
                }
                Spacer()
                if !status.exists && spiceTools.downloadProgress == nil {
                    SecondaryButton(title: "下载", systemImage: "arrow.down.circle") {
                        Task { try? await spiceTools.downloadIfNeeded() }
                    }
                } else if spiceTools.downloadProgress != nil {
                    SecondaryButton(title: "取消", systemImage: "xmark.circle") {
                        spiceTools.cancelDownload()
                    }
                }
            }
            if let p = spiceTools.downloadProgress {
                ProgressView(value: p).progressViewStyle(.linear).tint(Theme.accent)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surfaceElevated))
    }

    private func formatMB(_ bytes: Int64?) -> String {
        guard let b = bytes else { return "?" }
        return String(format: "%.0f MB", Double(b) / 1024 / 1024)
    }
}
