// 新建 VM 向导 —— Step 2: 详细配置 (名称/架构/CPU/内存/创建方式/网络/显示)
import SwiftUI
import UniformTypeIdentifiers
import HVMCore

struct NewVMWizardStepTwo: View {
    @Binding var draft: VMConfigDraft
    let errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            FieldLabel("名称")
            StyledTextField(placeholder: namePlaceholder, text: $draft.name)

            FieldLabel("架构")
            archPicker

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    FieldLabel("CPU 核心")
                    StepperCard(value: $draft.config.cpuCount, unit: "核",
                                range: 1...16, step: 1)
                }
                VStack(alignment: .leading, spacing: 8) {
                    FieldLabel("内存")
                    StepperCard(value: Binding(
                        get: { Int(draft.config.memoryMB) },
                        set: { draft.config.memoryMB = UInt64($0) }
                    ), unit: "MB", range: 256...65536, step: 512)
                }
            }

            FieldLabel("创建方式")
            creationModePicker

            switch draft.creationMode {
            case .installFromISO:
                installFromISOFields
            case .importImage:
                importImageFields
            }

            FieldLabel("显示模式")
            graphicalToggle

            FieldLabel("网络模式")
            networkPicker
            if draft.primaryNetworkMode == .vmnetBridged {
                bridgedInterfacePicker
            }
            if draft.primaryNetworkMode == .vmnetShared ||
               draft.primaryNetworkMode == .vmnetHost ||
               draft.primaryNetworkMode == .vmnetBridged {
                vmnetDaemonHint
            }

            if let errorText {
                errorBanner(errorText)
            }
        }
    }

    // MARK: - 名称占位符

    private var namePlaceholder: String {
        switch draft.config.osType {
        case .linux:   return "例如 ubuntu-24、openwrt-24 等"
        case .windows: return "Windows"
        case .macOS:   return "例如 macos-sonoma"
        case .other:   return "VM 名称"
        }
    }

    // MARK: - 架构

    private var archPicker: some View {
        HStack(spacing: 8) {
            archCard(.aarch64, title: "aarch64", subtitle: "Apple Silicon 主力", icon: "cpu")
            archCard(.x86_64,  title: "x86_64",  subtitle: "Intel / AMD",        icon: "cpu.fill")
            archCard(.riscv64, title: "riscv64", subtitle: "实验性",              icon: "bolt.fill")
        }
    }

    private func archCard(_ arch: VMArchitecture, title: String, subtitle: String, icon: String) -> some View {
        let selected = draft.config.architecture == arch
        return Button(action: { draft.config.architecture = arch }) {
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
            .background(RoundedRectangle(cornerRadius: 9)
                .fill(selected ? Theme.accent.opacity(0.12) : Theme.surfaceElevated))
            .overlay(RoundedRectangle(cornerRadius: 9)
                .stroke(selected ? Theme.accent : Color.clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: - 创建方式切换

    private var creationModePicker: some View {
        HStack(spacing: 8) {
            creationModeCard(.installFromISO,
                             title: "安装系统",
                             subtitle: "空盘 + 可选 ISO 安装器",
                             icon: "opticaldisc")
            creationModeCard(.importImage,
                             title: "从镜像导入",
                             subtitle: ".img / .qcow2 / .gz / .xz → qcow2",
                             icon: "square.and.arrow.down.fill")
        }
    }

    private func creationModeCard(_ mode: VMCreationMode,
                                  title: String, subtitle: String, icon: String) -> some View {
        let selected = isSameMode(draft.creationMode, mode)
        return Button(action: { draft.creationMode = mode }) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .font(.system(size: 14))
                        .foregroundStyle(selected ? Theme.accent : Theme.textSecondary)
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                }
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 9)
                .fill(selected ? Theme.accent.opacity(0.12) : Theme.surfaceElevated))
            .overlay(RoundedRectangle(cornerRadius: 9)
                .stroke(selected ? Theme.accent : Color.clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func isSameMode(_ a: VMCreationMode, _ b: VMCreationMode) -> Bool {
        switch (a, b) {
        case (.installFromISO, .installFromISO), (.importImage, .importImage): return true
        default: return false
        }
    }

    // MARK: - 磁盘 / ISO (installFromISO 模式)

    @ViewBuilder
    private var installFromISOFields: some View {
        FieldLabel("磁盘大小")
        StepperCard(value: $draft.firstDiskSizeGB, unit: "GB", range: 1...1024, step: 5)

        FieldLabel("ISO(可选)")
        HStack(spacing: 8) {
            StyledTextField(
                placeholder: "启动光盘路径",
                text: Binding(
                    get: { draft.config.boot.isoPath ?? "" },
                    set: { v in draft.config.boot.isoPath = v.isEmpty ? nil : v }
                ),
                monospaced: true
            )
            SecondaryButton(title: "选择…", systemImage: "folder") { pickISO() }
        }
    }

    // MARK: - 镜像导入 (importImage 模式)

    @ViewBuilder
    private var importImageFields: some View {
        FieldLabel("磁盘镜像")
        HStack(spacing: 8) {
            StyledTextField(
                placeholder: ".img / .qcow2 / .img.gz / .img.xz",
                text: $draft.importImagePath,
                monospaced: true
            )
            SecondaryButton(title: "选择…", systemImage: "folder") { pickImage() }
        }
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
            Text("镜像会被 qemu-img 转成 qcow2 作为启动盘; 安装步骤已在镜像里完成 (适合 OpenWrt / cloud-init 镜像)")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textTertiary)
            Spacer()
        }

        FieldLabel("目标磁盘大小(扩容)")
        StepperCard(value: $draft.importExpandToGB, unit: "GB", range: 0...2048, step: 1)
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
            Text(draft.importExpandToGB == 0
                 ? "0 = 保持镜像原始大小 (OpenWrt 默认 ~100MB)"
                 : "若镜像原始容量小于 \(draft.importExpandToGB) GB 则扩容, 否则保持原大小")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textTertiary)
            Spacer()
        }
    }

    // MARK: - 显示模式

    private var graphicalToggle: some View {
        HStack(spacing: 10) {
            ForEach([true, false], id: \.self) { g in
                let selected = draft.config.boot.graphical == g
                Button(action: {
                    draft.config.boot.graphical = g
                    draft.applyOSDefaults(graphical: g)
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: g ? "display" : "terminal")
                            .font(.system(size: 14))
                            .foregroundStyle(selected ? Theme.textPrimary : Theme.textTertiary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(g ? "图形" : "串口")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                            Text(g ? "virtio-gpu + 键鼠" : "-nographic 无图形")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.textTertiary)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8)
                        .fill(selected ? Theme.surfaceElevated : Theme.surface))
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .stroke(selected ? Theme.accent.opacity(0.6) : Color.clear, lineWidth: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - 网络

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
        let selected = draft.primaryNetworkMode == mode
        return Button(action: { draft.primaryNetworkMode = mode }) {
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
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(selected ? Theme.accent.opacity(0.15) : Theme.surfaceElevated))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(selected ? Theme.accent.opacity(0.6) : Color.clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var bridgedInterfacePicker: some View {
        let ifaces = HostNetworkInterfaces.list()
        VStack(alignment: .leading, spacing: 6) {
            FieldLabel("桥接接口")
            Menu {
                ForEach(ifaces, id: \.id) { iface in
                    Button(iface.displayLabel) { draft.primaryBridgedInterface = iface.name }
                }
                if ifaces.isEmpty {
                    Button("(扫描不到接口)") {}.disabled(true)
                }
            } label: {
                HStack {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .foregroundStyle(Theme.textSecondary)
                    Text(menuLabel(for: draft.primaryBridgedInterface, among: ifaces))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .foregroundStyle(Theme.textTertiary)
                        .font(.system(size: 10))
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surfaceElevated))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
        }
    }

    private func menuLabel(for name: String, among ifaces: [HostNetworkInterface]) -> String {
        if let hit = ifaces.first(where: { $0.name == name }) { return hit.displayLabel }
        return "\(name) — (当前不存在)"
    }

    @ViewBuilder
    private var vmnetDaemonHint: some View {
        let fakeNet = NetworkConfig(mode: draft.primaryNetworkMode,
                                    bridgedInterface: draft.primaryBridgedInterface)
        let status = VMnetSupervisor.status(for: fakeNet)
        let ok = status.socketExists
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: ok ? "checkmark.seal" : "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(ok ? Theme.success : Theme.warning)
            VStack(alignment: .leading, spacing: 2) {
                if ok {
                    Text("vmnet daemon 已就绪: \(status.socketPath ?? "-")")
                } else {
                    Text("vmnet daemon 缺失, 首次用需到 Settings → 网络 → 安装 daemon (需管理员密码)")
                }
            }
            .font(.system(size: 10))
            .foregroundStyle(Theme.textTertiary)
            Spacer()
        }
        .padding(.top, -8)
    }

    // MARK: - 错误提示

    private func errorBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.danger)
                .font(.system(size: 11))
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textPrimary.opacity(0.9))
                .textSelection(.enabled)
            Spacer()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.danger.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.danger.opacity(0.35), lineWidth: 1))
    }

    // MARK: - 文件选择

    private func pickISO() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [
            UTType(filenameExtension: "iso") ?? .data,
            UTType(filenameExtension: "img") ?? .data,
        ]
        if panel.runModal() == .OK, let url = panel.url {
            draft.config.boot.isoPath = url.path
        }
    }

    private func pickImage() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [
            UTType(filenameExtension: "img") ?? .data,
            UTType(filenameExtension: "qcow2") ?? .data,
            UTType(filenameExtension: "raw") ?? .data,
            UTType(filenameExtension: "gz") ?? .data,
            UTType(filenameExtension: "xz") ?? .data,
        ]
        if panel.runModal() == .OK, let url = panel.url {
            draft.importImagePath = url.path
        }
    }
}
