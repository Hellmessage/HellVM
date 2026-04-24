// VMSettings 的启动子区块
//
// 包含:
// - UEFI / 显示模式 / virtio-GPU 加速 三组二选一
// - ISO 路径 + 仅从硬盘启动 切换
// - Windows 客户机:autoInstallVirtioWin + virtio-win.iso 下载面板
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import HVMCore

struct VMSettingsBootSection: View {
    let item: VMListItem
    @Binding var draft: VMConfig
    let readOnly: Bool

    @StateObject private var virtioWin = VirtioWinManager.shared
    @StateObject private var spiceTools = SpiceToolsManager.shared

    var body: some View {
        VMSection(title: "启动") {
            if readOnly {
                VMSectionKV(label: "UEFI", value: item.config.boot.efi ? "启用" : "关闭")
                VMSectionKV(label: "显示模式",
                            value: item.config.boot.graphical
                                   ? "图形(virtio-gpu + 键鼠)" : "串口(-nographic)")
                if item.config.boot.graphical {
                    VMSectionKV(label: "virtio-GPU 加速",
                                value: item.config.display.virtioGpu ? "启用" : "关闭")
                }
                if item.config.osType == .windows {
                    VMSectionKV(label: "virtio-win 自动装驱动",
                                value: item.config.boot.autoInstallVirtioWin ? "启用" : "关闭")
                    VMSectionKV(label: "spice 工具自动装(拖窗口 resize)",
                                value: item.config.boot.autoInstallSpiceTools ? "启用" : "关闭")
                }
                if let iso = item.config.boot.isoPath {
                    VMSectionKV(label: "ISO", value: iso, mono: true)
                } else {
                    VMSectionKV(label: "ISO", value: "(无)")
                }
            } else {
                VMTogglePair(label: "UEFI",
                             on:  ("启用", "efi.bubble"),
                             off: ("关闭", "minus.circle"),
                             value: $draft.boot.efi)
                VMTogglePair(label: "显示模式",
                             on:  ("图形",  "display"),
                             off: ("串口",  "terminal"),
                             value: $draft.boot.graphical)
                if draft.boot.graphical {
                    // virtio-GPU 加速开关:
                    // - 开: virtio-gpu-pci + ramfb 双 console.  Linux 原生支持; Win11 24H2
                    //       ARM64 实测也稳, 推荐默认开.
                    // - 关: virtio-ramfb 融合设备, 单 console (patch 0002+0003).  早期 Win11
                    //       ISO / 老 EDK2 为避免 bootmgr 挂死所用, 当前新 ISO 已不需要;
                    //       反而在 PE 阶段可能卡安装. 仅作可选 fallback 保留。
                    VMTogglePair(label: "virtio-GPU 加速",
                                 on:  ("启用", "bolt.fill"),
                                 off: ("关闭", "bolt.slash"),
                                 value: $draft.display.virtioGpu)
                    if !draft.display.virtioGpu {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.warning)
                            Text("改用 virtio-ramfb 融合设备(fallback). Win11 24H2 ARM64 新 ISO 实测在此模式下 PE 阶段会卡安装, 除非你明确需要它, 否则保持启用。")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.textTertiary)
                            Spacer()
                        }
                        .padding(.top, -4)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel("ISO(可选)")
                    HStack(spacing: 8) {
                        StyledTextField(
                            placeholder: "启动光盘路径",
                            text: Binding(
                                get: { draft.boot.isoPath ?? "" },
                                set: { v in draft.boot.isoPath = v.isEmpty ? nil : v }
                            ),
                            monospaced: true
                        )
                        SecondaryButton(title: "选择…", systemImage: "folder") { pickISO() }
                        if draft.boot.isoPath != nil {
                            SecondaryButton(title: "移除", systemImage: "xmark") {
                                draft.boot.isoPath = nil
                            }
                        }
                    }
                }
                // 安装完成后切换: 保留 isoPath 以便将来重装, 启动时不挂载光盘
                if draft.boot.isoPath != nil {
                    VMTogglePair(label: "仅从硬盘启动",
                                 on:  ("已装机", "internaldrive.fill"),
                                 off: ("挂 ISO", "opticaldisc"),
                                 value: $draft.boot.bootFromDiskOnly)
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                        Text(draft.boot.bootFromDiskOnly
                             ? "下次启动跳过 ISO 挂载, 直接从硬盘走 grub/bootmgr. 需重装时关回挂 ISO."
                             : "启动时把 ISO 挂为 USB 光驱. 装完系统后打开上面的开关, 避免再次进安装器.")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textTertiary)
                        Spacer()
                    }
                    .padding(.top, -4)
                }
                // Windows 客户机: 自动装 virtio-win 驱动 toggle + iso 状态
                if draft.osType == .windows && draft.boot.graphical {
                    VMTogglePair(label: "自动装 virtio-win 驱动",
                                 on:  ("启用", "shippingbox.fill"),
                                 off: ("关闭", "shippingbox"),
                                 value: $draft.boot.autoInstallVirtioWin)
                    if draft.boot.autoInstallVirtioWin {
                        virtioWinPanel
                    }
                    // Windows 拖窗口自动 resize 依赖 spice-vdagent, 走 NSIS /S 静默装.
                    // 只影响**新建** VM(走 FirstLogonCommands); 已装好的 Windows 请手动装.
                    VMTogglePair(label: "自动装 Spice 工具(拖窗口 resize)",
                                 on:  ("启用", "arrow.up.left.and.arrow.down.right"),
                                 off: ("关闭", "arrow.up.left.and.arrow.down.right"),
                                 value: $draft.boot.autoInstallSpiceTools)
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                        Text("只对新建 Win VM 生效(走 FirstLogon). 已装好的 Win 需手动跑 spice-guest-tools-latest.exe /S")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textTertiary)
                        Spacer()
                    }
                    .padding(.top, -4)
                    if draft.boot.autoInstallSpiceTools {
                        spiceToolsPanel
                    }
                }
            }
        }
    }

    /// virtio-win.iso 缓存状态 + 下载按钮
    @ViewBuilder
    private var virtioWinPanel: some View {
        let status = VirtioWinManager.status()
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: status.exists ? "checkmark.seal.fill"
                      : (virtioWin.downloadProgress != nil ? "arrow.down.circle" : "exclamationmark.triangle.fill"))
                    .font(.system(size: 11))
                    .foregroundStyle(status.exists ? Theme.success : Theme.warning)
                VStack(alignment: .leading, spacing: 2) {
                    if status.exists {
                        Text("已缓存 virtio-win.iso (\(formatMB(status.sizeBytes)))")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textSecondary)
                    } else if let p = virtioWin.downloadProgress {
                        Text(String(format: "下载中 %.0f%%", p * 100))
                            .font(.system(size: 10, weight: .medium))
                    } else {
                        Text("缓存缺失, 启动时会跳过驱动自动安装")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.warning)
                    }
                    Text(status.path)
                        .font(.system(size: 9, design: .monospaced))
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
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.divider, lineWidth: 1))
    }

    /// spice-guest-tools.exe 缓存状态 + 下载按钮 (结构和 virtioWinPanel 完全镜像)
    @ViewBuilder
    private var spiceToolsPanel: some View {
        let status = SpiceToolsManager.status()
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: status.exists ? "checkmark.seal.fill"
                      : (spiceTools.downloadProgress != nil ? "arrow.down.circle" : "exclamationmark.triangle.fill"))
                    .font(.system(size: 11))
                    .foregroundStyle(status.exists ? Theme.success : Theme.warning)
                VStack(alignment: .leading, spacing: 2) {
                    if status.exists {
                        Text("已缓存 spice-guest-tools.exe (\(formatMB(status.sizeBytes)))")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textSecondary)
                    } else if let p = spiceTools.downloadProgress {
                        Text(String(format: "下载中 %.0f%%", p * 100))
                            .font(.system(size: 10, weight: .medium))
                    } else {
                        Text("缓存缺失, 启动时会跳过 spice-vdagent 自动安装")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.warning)
                    }
                    Text(status.path)
                        .font(.system(size: 9, design: .monospaced))
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
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.divider, lineWidth: 1))
    }

    private func formatMB(_ bytes: Int64?) -> String {
        guard let b = bytes else { return "?" }
        return String(format: "%.0f MB", Double(b) / 1024 / 1024)
    }

    private func pickISO() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [
            UTType(filenameExtension: "iso") ?? .data,
            UTType(filenameExtension: "img") ?? .data,
        ]
        if panel.runModal() == .OK, let url = panel.url {
            draft.boot.isoPath = url.path
        }
    }
}
