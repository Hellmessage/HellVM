// 新建 VM 向导 —— 两步骤
//   Step 1:选择客户机类型 (Linux / Windows / macOS / 其它)
//   Step 2:填写名称 / 架构 / CPU / 内存 / 创建方式 (安装 or 导入镜像) / 网络 / 显示
//
// 字段承接在 VMConfigDraft 上, 便于与 Settings 层共享默认值与校验逻辑。
import SwiftUI
import UniformTypeIdentifiers
import HVMCore

struct NewVMWizardView: View {
    let onCancel: () -> Void
    let onCreated: (String) -> Void

    /// 当前 step: 1 = OS 类型, 2 = 详细信息
    @State private var step: Int = 1
    @State private var draft: VMConfigDraft = .forNewVM()
    @State private var submitting: Bool = false
    @State private var submitPhase: String = ""
    @State private var errorText: String?

    @StateObject private var virtioWin = VirtioWinManager.shared

    var canSubmit: Bool { draft.canSubmit && !submitting }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.divider).frame(height: 1)
            stepIndicator
            Rectangle().fill(Theme.divider).frame(height: 1)
            ScrollView(showsIndicators: false) {
                Group {
                    switch step {
                    case 1: stepOneContent
                    default: stepTwoContent
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
                Text(step == 1 ? "第 1 步:选择客户机类型" : "第 2 步:填写配置")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
            }
            Spacer()
            IconButton(systemImage: "xmark", action: onCancel)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    // MARK: - Step indicator

    private var stepIndicator: some View {
        HStack(spacing: 8) {
            stepPill(n: 1, label: "类型")
            Rectangle().fill(Theme.divider).frame(height: 1).frame(maxWidth: 20)
            stepPill(n: 2, label: "配置")
            Spacer()
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
    }

    private func stepPill(n: Int, label: String) -> some View {
        let active = step == n
        let done = step > n
        return HStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(active || done ? Theme.accent : Theme.surfaceElevated)
                    .frame(width: 20, height: 20)
                if done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Text("\(n)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(active ? .white : Theme.textTertiary)
                }
            }
            Text(label)
                .font(.system(size: 11, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? Theme.textPrimary : Theme.textTertiary)
        }
    }

    // MARK: - Footer

    private var footerBar: some View {
        HStack(spacing: 10) {
            if submitting && step == 2 {
                ProgressView().controlSize(.small)
                Text(submitPhase.isEmpty ? "创建中…" : submitPhase)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            SecondaryButton(title: "取消", systemImage: nil, disabled: submitting,
                            action: onCancel)
            if step == 2 {
                SecondaryButton(title: "上一步", systemImage: "chevron.left",
                                disabled: submitting) { step = 1 }
            }
            if step == 1 {
                PrimaryButton(title: "下一步", systemImage: "chevron.right",
                              disabled: false) {
                    // 进入 step 2 前,基于当前 osType 应用默认值 (CPU/内存/名称/设备)
                    draft.applyOSDefaults(graphical: draft.config.boot.graphical)
                    step = 2
                }
            } else {
                PrimaryButton(title: submitting ? "创建中…" : "创建",
                              systemImage: "checkmark", disabled: !canSubmit) {
                    Task { await submit() }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(Theme.surface)
    }

    // MARK: - Step 1: 选择 OS 类型

    @ViewBuilder
    private var stepOneContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            FieldLabel("客户机类型")
            osTypeGrid
            osTypeHint
            if draft.config.osType == .windows {
                virtioWinStatusRow
            }
        }
    }

    private var osTypeGrid: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                bigOSCard(.linux,   title: "Linux",   subtitle: "开箱 virtio-gpu 加速",  icon: "terminal.fill")
                bigOSCard(.windows, title: "Windows", subtitle: "GPU + TPM", icon: "square.stack.fill")
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

    // MARK: - Step 2: 详细配置

    @ViewBuilder
    private var stepTwoContent: some View {
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
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.danger)
                        .font(.system(size: 11))
                    Text(errorText)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textPrimary.opacity(0.9))
                        .textSelection(.enabled)
                    Spacer()
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.danger.opacity(0.12)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.danger.opacity(0.35), lineWidth: 1))
            }
        }
    }

    private var namePlaceholder: String {
        switch draft.config.osType {
        case .linux:   return "例如 ubuntu-24、openwrt-24 等"
        case .windows: return "Windows"
        case .macOS:   return "例如 macos-sonoma"
        case .other:   return "VM 名称"
        }
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
                            Text(g ? "virtio-gpu + 键鼠" : "-nographic 无图形, 适合服务器/OpenWrt 等")
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

    // MARK: - OS 类型提示 / virtio-win 状态

    @ViewBuilder
    private var osTypeHint: some View {
        switch draft.config.osType {
        case .windows:
            infoHint("virtio-ramfb 融合 (bootmgr 不挂) · TPM 启用 · Win11 硬件检查绕过 · 默认 4核/4GB")
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

    private func formatMB(_ bytes: Int64?) -> String {
        guard let b = bytes else { return "?" }
        return String(format: "%.0f MB", Double(b) / 1024 / 1024)
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

    // MARK: - 提交

    private func submit() async {
        submitting = true
        errorText = nil
        defer { submitting = false; submitPhase = "" }
        do {
            switch draft.creationMode {
            case .installFromISO:
                submitPhase = "创建 bundle 与空盘…"
                _ = try await VMController.create(
                    name: draft.name,
                    architecture: draft.config.architecture,
                    osType: draft.config.osType,
                    cpu: draft.config.cpuCount,
                    memoryMB: draft.config.memoryMB,
                    diskSizeGB: UInt64(draft.firstDiskSizeGB),
                    isoPath: draft.config.boot.isoPath,
                    graphical: draft.config.boot.graphical,
                    networkMode: draft.primaryNetworkMode,
                    bridgedInterface: draft.primaryNetworkMode == .vmnetBridged
                        ? draft.primaryBridgedInterface : nil
                )
            case .importImage:
                submitPhase = "转换镜像为 qcow2,可能需要几分钟…"
                let target: UInt64? = draft.importExpandToGB > 0
                    ? UInt64(draft.importExpandToGB) : nil
                _ = try await VMController.createFromImage(
                    name: draft.name,
                    architecture: draft.config.architecture,
                    osType: draft.config.osType,
                    cpu: draft.config.cpuCount,
                    memoryMB: draft.config.memoryMB,
                    imagePath: draft.importImagePath,
                    expandToGB: target,
                    graphical: draft.config.boot.graphical,
                    networkMode: draft.primaryNetworkMode,
                    bridgedInterface: draft.primaryNetworkMode == .vmnetBridged
                        ? draft.primaryBridgedInterface : nil
                )
            }
            onCreated(draft.name)
        } catch {
            errorText = "\(error)"
        }
    }
}
