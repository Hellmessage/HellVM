// 新建 VM 向导 —— 视觉打磨:大图标 + 分组表单 + accent 主按钮
import SwiftUI
import UniformTypeIdentifiers
import HVMCore

struct NewVMWizardView: View {
    let onCancel: () -> Void
    let onCreated: (String) -> Void

    @State private var name: String = ""
    @State private var architecture: VMArchitecture = .aarch64
    @State private var osType: GuestOSType = .linux
    @State private var cpuCount: Int = 2
    @State private var memoryMB: Int = 2048
    @State private var diskSizeGB: Int = 20
    @State private var isoPath: String = ""
    @State private var graphical: Bool = true
    @State private var networkMode: NetworkConfig.Mode = .user

    @State private var submitting: Bool = false
    @State private var errorText: String?

    var canSubmit: Bool {
        !name.isEmpty && cpuCount > 0 && memoryMB >= 128 && diskSizeGB > 0 && !submitting
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.divider).frame(height: 1)
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    FieldLabel("名称")
                    StyledTextField(placeholder: "例如 ubuntu-24", text: $name)

                    FieldLabel("架构")
                    archPicker

                    FieldLabel("客户机类型")
                    osTypePicker
                    osTypeHint

                    HStack(alignment: .top, spacing: 16) {
                        VStack(alignment: .leading, spacing: 8) {
                            FieldLabel("CPU 核心")
                            StepperCard(value: $cpuCount, unit: "核", range: 1...16, step: 1)
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            FieldLabel("内存")
                            StepperCard(value: $memoryMB, unit: "MB", range: 256...65536, step: 512)
                        }
                    }

                    FieldLabel("磁盘大小")
                    StepperCard(value: $diskSizeGB, unit: "GB", range: 1...1024, step: 5)

                    FieldLabel("ISO(可选)")
                    HStack(spacing: 8) {
                        StyledTextField(placeholder: "启动光盘路径", text: $isoPath, monospaced: true)
                        SecondaryButton(title: "选择…", systemImage: "folder") { pickISO() }
                    }

                    FieldLabel("显示模式")
                    graphicalToggle

                    FieldLabel("网络模式")
                    networkPicker

                    if let errorText {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(Theme.danger)
                                .font(.system(size: 11))
                            Text(errorText)
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.textPrimary.opacity(0.9))
                            Spacer()
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.danger.opacity(0.12)))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.danger.opacity(0.35), lineWidth: 1))
                    }
                }
                .padding(24)
            }
            footerBar
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9)
                    .fill(Theme.accent.opacity(0.2))
                    .frame(width: 32, height: 32)
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Theme.accent)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("新建虚拟机")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("配置并创建新 VM")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
            }
            Spacer()
            IconButton(systemImage: "xmark", action: onCancel)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    // MARK: - Footer

    private var footerBar: some View {
        HStack(spacing: 10) {
            Spacer()
            SecondaryButton(title: "取消", systemImage: nil, action: onCancel)
            PrimaryButton(title: submitting ? "创建中…" : "创建", systemImage: "checkmark", disabled: !canSubmit) {
                Task { await submit() }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(Theme.surface)
    }

    // MARK: - 架构选择

    private var archPicker: some View {
        HStack(spacing: 8) {
            archCard(.aarch64, title: "aarch64", subtitle: "Apple Silicon 主力", icon: "cpu")
            archCard(.x86_64, title: "x86_64", subtitle: "Intel / AMD", icon: "cpu.fill")
            archCard(.riscv64, title: "riscv64", subtitle: "实验性", icon: "bolt.fill")
        }
    }

    // MARK: - 客户机类型选择

    private var osTypePicker: some View {
        HStack(spacing: 8) {
            osCard(.linux,   title: "Linux",   subtitle: "virtio-gpu 加速",  icon: "terminal.fill")
            osCard(.windows, title: "Windows", subtitle: "virtio-ramfb + TPM", icon: "square.stack.fill")
            osCard(.macOS,   title: "macOS",   subtitle: "实验性",           icon: "apple.logo")
            osCard(.other,   title: "其他",    subtitle: "手动调",           icon: "questionmark.circle")
        }
    }

    private func osCard(_ type: GuestOSType, title: String, subtitle: String, icon: String) -> some View {
        let selected = osType == type
        return Button(action: { osType = type }) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(selected ? Theme.accent : Theme.textSecondary)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(selected ? Theme.accent.opacity(0.12) : Theme.surfaceElevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .stroke(selected ? Theme.accent : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var osTypeHint: some View {
        if osType == .windows {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                Text("用 virtio-ramfb 融合设备(bootmgr 不挂, 装 viogpudo 驱动后支持动态分辨率)、启用 TPM、自动绕过 Win11 硬件检查")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
            }
            .padding(.top, -12)
        }
    }

    private func archCard(_ arch: VMArchitecture, title: String, subtitle: String, icon: String) -> some View {
        let selected = architecture == arch
        return Button(action: { architecture = arch }) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(selected ? Theme.accent : Theme.textSecondary)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(selected ? Theme.accent.opacity(0.12) : Theme.surfaceElevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .stroke(selected ? Theme.accent : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var graphicalToggle: some View {
        HStack(spacing: 10) {
            ForEach([true, false], id: \.self) { g in
                let selected = graphical == g
                Button(action: { graphical = g }) {
                    HStack(spacing: 8) {
                        Image(systemName: g ? "display" : "terminal")
                            .font(.system(size: 14))
                            .foregroundStyle(selected ? Theme.textPrimary : Theme.textTertiary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(g ? "图形" : "串口")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                            Text(g ? "virtio-gpu + 键鼠" : "-nographic 无图形, 适合服务器镜像")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.textTertiary)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(selected ? Theme.surfaceElevated : Theme.surface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(selected ? Theme.accent.opacity(0.6) : Color.clear, lineWidth: 1)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - 网络模式选择

    private var networkPicker: some View {
        HStack(spacing: 6) {
            networkChip(.user,         title: "NAT",       icon: "network")
            networkChip(.vmnetShared,  title: "vmnet",     icon: "shared.with.you")
            networkChip(.vmnetBridged, title: "桥接",      icon: "antenna.radiowaves.left.and.right")
            networkChip(.vmnetHost,    title: "host-only", icon: "house")
            networkChip(.none,         title: "无",        icon: "xmark.octagon")
        }
    }

    private func networkChip(_ mode: NetworkConfig.Mode, title: String, icon: String) -> some View {
        let selected = networkMode == mode
        return Button(action: { networkMode = mode }) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundStyle(selected ? Theme.textPrimary : Theme.textTertiary)
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(selected ? Theme.accent.opacity(0.15) : Theme.surfaceElevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(selected ? Theme.accent.opacity(0.6) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - 提交

    private func submit() async {
        submitting = true
        errorText = nil
        defer { submitting = false }
        do {
            _ = try await VMController.create(
                name: name,
                architecture: architecture,
                osType: osType,
                cpu: cpuCount,
                memoryMB: UInt64(memoryMB),
                diskSizeGB: UInt64(diskSizeGB),
                isoPath: isoPath.isEmpty ? nil : isoPath,
                graphical: graphical,
                networkMode: networkMode
            )
            onCreated(name)
        } catch {
            errorText = "\(error)"
        }
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
            isoPath = url.path
        }
    }
}

