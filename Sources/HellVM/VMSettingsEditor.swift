// VM 设置编辑器 —— 详情页 Settings tab 的实际内容
//
// 设计要点:
// - 基本信息(CPU/内存) / 启动(EFI/图形/ISO) / 网络(模式/socket/iface/MAC)
//   统一用本地 draft 承接编辑,底部栏显示「保存 / 放弃」
// - 磁盘增删改查立即生效(涉及 qemu-img 子进程),不走 draft
// - VM 运行中时整个编辑器切成只读视图,避免误改下次启动才生效的字段产生困惑
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import HVMCore

struct VMSettingsEditor: View {
    let store: VMListStore
    let item: VMListItem

    // draft 承接 CPU / 内存 / 启动 / 网络 四块字段的编辑,磁盘不在其中
    @State private var draft: VMConfig
    @State private var errorText: String?
    @State private var busy: Bool = false

    // 磁盘局部 UI 状态
    @State private var addingDisk: Bool = false
    @State private var newDiskSizeGB: Int = 20
    @State private var newDiskFormat: DiskConfig.Format = .qcow2
    @State private var resizingIndex: Int?
    @State private var resizeSizeGB: Int = 0
    @State private var removingIndex: Int?

    // vmnet daemon 安装/卸载状态
    @State private var vmnetBusy: Bool = false
    @State private var vmnetError: String?
    /// 安装/卸载后 bump 一下, 强制 vmnetDaemonPanel 重读 socket 状态
    @State private var vmnetRefreshToken: UInt64 = 0

    // virtio-win.iso 下载状态
    @StateObject private var virtioWin = VirtioWinManager.shared

    init(store: VMListStore, item: VMListItem) {
        self.store = store
        self.item = item
        _draft = State(initialValue: item.config)
    }

    private var readOnly: Bool { item.isRunning }

    private var dirty: Bool {
        draft.cpuCount  != item.config.cpuCount  ||
        draft.memoryMB  != item.config.memoryMB  ||
        draft.boot      != item.config.boot      ||
        draft.display   != item.config.display   ||
        !networksEqual(draft.networks, item.config.networks)
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                if readOnly {
                    runningBanner
                }
                if let errorText {
                    errorBanner(errorText)
                        .padding(.horizontal, 32).padding(.top, 16)
                }

                basicSection
                divider()
                disksSection
                divider()
                networkSection
                divider()
                bootSection

                if !readOnly {
                    saveBar
                }
            }
            .padding(.bottom, 32)
        }
    }

    // MARK: - 基本信息

    private var basicSection: some View {
        section(title: "基本信息") {
            keyValue("架构", value: item.config.architecture.rawValue)
            if readOnly {
                keyValue("CPU 核心", value: "\(item.config.cpuCount)")
                keyValue("内存",   value: "\(item.config.memoryMB) MB")
            } else {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        FieldLabel("CPU 核心")
                        StepperCard(value: Binding(
                            get: { draft.cpuCount },
                            set: { draft.cpuCount = $0 }
                        ), unit: "核", range: 1...64, step: 1)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        FieldLabel("内存")
                        StepperCard(value: Binding(
                            get: { Int(draft.memoryMB) },
                            set: { draft.memoryMB = UInt64($0) }
                        ), unit: "MB", range: 128...262144, step: 512)
                    }
                }
            }
            keyValue("Bundle 路径", value: item.bundle.url.path, mono: true)
        }
    }

    // MARK: - 磁盘

    private var disksSection: some View {
        section(title: "磁盘") {
            if item.config.disks.isEmpty {
                keyValue("—", value: "无磁盘")
            } else {
                VStack(spacing: 8) {
                    ForEach(Array(item.config.disks.enumerated()), id: \.element.id) { idx, disk in
                        diskRow(index: idx, disk: disk)
                    }
                }
            }

            if !readOnly {
                if addingDisk {
                    addDiskForm
                        .padding(.top, 6)
                } else {
                    HStack {
                        SecondaryButton(title: "添加磁盘", systemImage: "plus", disabled: busy) {
                            addingDisk = true
                            newDiskSizeGB = 20
                            newDiskFormat = .qcow2
                        }
                        Spacer()
                    }
                    .padding(.top, 4)
                }
            }
        }
    }

    private func diskRow(index: Int, disk: DiskConfig) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                // 序号 + 启动盘标识
                Text(index == 0 ? "#0 BOOT" : "#\(index)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(index == 0 ? Theme.accent : Theme.textTertiary)
                    .frame(width: 66, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(disk.relativePath)
                        .font(Font2.mono)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1).truncationMode(.middle)
                    Text("\(disk.sizeGB) GB · \(disk.format.rawValue)\(disk.readOnly ? " · 只读" : "")")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer(minLength: 8)

                if !readOnly {
                    diskActions(index: index, disk: disk)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 7).fill(Theme.surfaceElevated)
            )

            // 扩容 / 删除 的内联确认
            if resizingIndex == index {
                resizeInline(index: index, disk: disk)
                    .padding(.horizontal, 10).padding(.top, 6)
            }
            if removingIndex == index {
                removeInline(index: index, disk: disk)
                    .padding(.horizontal, 10).padding(.top, 6)
            }
        }
    }

    @ViewBuilder
    private func diskActions(index: Int, disk: DiskConfig) -> some View {
        HStack(spacing: 4) {
            iconBtn("arrow.up", disabled: busy || index == 0) {
                runTask { try VMController.moveDisk(item, store: store, from: index, to: index - 1) }
            }
            iconBtn("arrow.down", disabled: busy || index == item.config.disks.count - 1) {
                runTask { try VMController.moveDisk(item, store: store, from: index, to: index + 1) }
            }
            iconBtn("arrow.up.and.down.and.arrow.left.and.right", disabled: busy) {
                resizingIndex = (resizingIndex == index) ? nil : index
                resizeSizeGB = Int(disk.sizeGB) + 10
                removingIndex = nil
            }
            Menu {
                ForEach([DiskConfig.Format.qcow2, .raw], id: \.self) { fmt in
                    Button {
                        runTaskAsync {
                            try await VMController.convertDisk(item, store: store, at: index, to: fmt)
                        }
                    } label: {
                        HStack {
                            Text("转为 \(fmt.rawValue)")
                            if fmt == disk.format {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    .disabled(fmt == disk.format)
                }
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(busy ? Theme.textDisabled : Theme.textSecondary)
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.surface))
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .disabled(busy)
            .frame(width: 26, height: 26)
            iconBtn("trash", tint: Theme.danger, disabled: busy || item.config.disks.count <= 1) {
                removingIndex = (removingIndex == index) ? nil : index
                resizingIndex = nil
            }
        }
    }

    private func resizeInline(index: Int, disk: DiskConfig) -> some View {
        HStack(spacing: 10) {
            FieldLabel("扩容至")
            StepperCard(value: $resizeSizeGB, unit: "GB",
                        range: max(Int(disk.sizeGB) + 1, 1)...8192, step: 5)
                .frame(width: 160)
            Spacer()
            SecondaryButton(title: "取消", systemImage: nil, disabled: busy) {
                resizingIndex = nil
            }
            PrimaryButton(title: "确认", systemImage: "checkmark", disabled: busy) {
                let target = UInt64(resizeSizeGB)
                runTaskAsync {
                    try await VMController.resizeDisk(item, store: store, at: index, newSizeGB: target)
                }
                resizingIndex = nil
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.surface))
    }

    private func removeInline(index: Int, disk: DiskConfig) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.danger)
            Text("将永久删除文件 \(disk.relativePath),此操作无法撤销")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textPrimary.opacity(0.85))
            Spacer()
            SecondaryButton(title: "取消", systemImage: nil, disabled: busy) {
                removingIndex = nil
            }
            Button {
                runTask { try VMController.removeDisk(item, store: store, at: index) }
                removingIndex = nil
            } label: {
                Text("删除")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Theme.danger))
            }
            .buttonStyle(.plain)
            .disabled(busy)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Theme.danger.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(Theme.danger.opacity(0.35), lineWidth: 1)
        )
    }

    private var addDiskForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel("大小")
                    StepperCard(value: $newDiskSizeGB, unit: "GB", range: 1...8192, step: 5)
                        .frame(width: 160)
                }
                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel("格式")
                    formatSegment($newDiskFormat)
                }
                Spacer()
            }
            HStack {
                Spacer()
                SecondaryButton(title: "取消", systemImage: nil, disabled: busy) {
                    addingDisk = false
                }
                PrimaryButton(title: busy ? "创建中…" : "创建", systemImage: "plus", disabled: busy) {
                    let size = UInt64(newDiskSizeGB)
                    let fmt = newDiskFormat
                    runTaskAsync {
                        try await VMController.addDisk(
                            item, store: store, sizeGB: size, format: fmt
                        )
                    }
                    addingDisk = false
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surface))
    }

    private func formatSegment(_ binding: Binding<DiskConfig.Format>) -> some View {
        HStack(spacing: 6) {
            ForEach([DiskConfig.Format.qcow2, .raw], id: \.self) { fmt in
                let selected = binding.wrappedValue == fmt
                Button(action: { binding.wrappedValue = fmt }) {
                    Text(fmt.rawValue)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 6)
                            .fill(selected ? Theme.accent.opacity(0.2) : Theme.surfaceElevated))
                        .overlay(RoundedRectangle(cornerRadius: 6)
                            .stroke(selected ? Theme.accent : Color.clear, lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - 网络

    private var networkSection: some View {
        section(title: "网络") {
            if readOnly {
                let net = item.config.networks.first
                keyValue("模式", value: net.map { displayName(of: $0.mode) } ?? "无")
                if let nic = net?.deviceModel {
                    keyValue("NIC 型号", value: nic.rawValue)
                }
                if let s = net?.effectiveSocketPath {
                    keyValue("socket", value: s, mono: true)
                }
                if let iface = net?.bridgedInterface, !iface.isEmpty {
                    keyValue("桥接网卡", value: iface, mono: true)
                }
                if let mac = net?.macAddress, !mac.isEmpty {
                    keyValue("MAC", value: mac, mono: true)
                }
            } else {
                networkModePicker
                nicModelPicker
                if case .some(let m) = draft.networks.first?.mode,
                   m == .vmnetShared || m == .vmnetHost || m == .vmnetBridged {
                    networkVmnetOptions
                }
                networkMacField
                vmnetDaemonPanel
            }
        }
    }

    private var networkModePicker: some View {
        let current: NetworkConfig.Mode = draft.networks.first?.mode ?? .user
        return VStack(alignment: .leading, spacing: 6) {
            FieldLabel("模式")
            VStack(spacing: 6) {
                netModeRow(.user,          title: "user (NAT)",       subtitle: "QEMU 内置, 零依赖, 不支持 ICMP/ping", current: current)
                netModeRow(.vmnetShared,   title: "vmnet · shared",   subtitle: "NAT + DHCP (socket_vmnet 默认模式)", current: current)
                netModeRow(.vmnetHost,     title: "vmnet · host-only",subtitle: "仅宿主机互通, 无外网",                current: current)
                netModeRow(.vmnetBridged,  title: "vmnet · bridged",  subtitle: "真二层桥接, 获取同局域网 IP",          current: current)
                netModeRow(.none,          title: "无网络",            subtitle: "-nic none, 完全禁用",                 current: current)
            }
        }
    }

    private func netModeRow(_ mode: NetworkConfig.Mode,
                            title: String,
                            subtitle: String,
                            current: NetworkConfig.Mode) -> some View {
        let selected = current == mode
        return Button(action: { setMode(mode) }) {
            HStack(spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(selected ? Theme.accent : Theme.textTertiary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 7)
                .fill(selected ? Theme.accent.opacity(0.08) : Theme.surfaceElevated))
            .overlay(RoundedRectangle(cornerRadius: 7)
                .stroke(selected ? Theme.accent.opacity(0.6) : Color.clear, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var networkVmnetOptions: some View {
        let mode = draft.networks.first?.mode ?? .user
        VStack(alignment: .leading, spacing: 8) {
            if mode == .vmnetBridged {
                FieldLabel("桥接网卡")
                bridgedInterfacePicker
            }
        }
    }

    private var bridgedInterfacePicker: some View {
        let ifaces = HostNetworkInterfaces.list()
        let current = draft.networks.first?.bridgedInterface ?? HostNetworkInterfaces.recommendedDefault()
        return Menu {
            ForEach(ifaces, id: \.id) { iface in
                Button(iface.displayLabel) {
                    updateFirstNet { $0.bridgedInterface = iface.name }
                }
            }
            if ifaces.isEmpty {
                Button("(扫描不到接口)") {}.disabled(true)
            }
        } label: {
            HStack {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .foregroundStyle(Theme.textSecondary)
                Text(labelFor(iface: current, among: ifaces))
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

    private func labelFor(iface name: String, among ifaces: [HostNetworkInterface]) -> String {
        if let hit = ifaces.first(where: { $0.name == name }) { return hit.displayLabel }
        return "\(name) — (当前不存在)"
    }

    /// NIC 设备型号选择(virtio / e1000e / rtl8139)
    private var nicModelPicker: some View {
        let current = draft.networks.first?.deviceModel ?? .virtio
        return VStack(alignment: .leading, spacing: 6) {
            FieldLabel("NIC 型号")
            HStack(spacing: 6) {
                nicChip(.virtio,  title: "virtio",  subtitle: "Linux 最快", current: current)
                nicChip(.e1000e,  title: "e1000e",  subtitle: "Win 开箱",   current: current)
                nicChip(.rtl8139, title: "rtl8139", subtitle: "老系统兜底", current: current)
            }
        }
    }

    private func nicChip(_ m: NICModel, title: String, subtitle: String, current: NICModel) -> some View {
        let selected = current == m
        return Button(action: { updateFirstNet { $0.deviceModel = m } }) {
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

    /// MAC 地址字段 + 重新生成按钮
    private var networkMacField: some View {
        VStack(alignment: .leading, spacing: 6) {
            FieldLabel("MAC 地址")
            HStack(spacing: 8) {
                StyledTextField(
                    placeholder: "52:54:00:xx:xx:xx",
                    text: Binding(
                        get: { draft.networks.first?.macAddress ?? "" },
                        set: { v in updateFirstNet { $0.macAddress = v.isEmpty ? nil : v } }
                    ),
                    monospaced: true
                )
                SecondaryButton(title: "重新生成", systemImage: "arrow.clockwise") {
                    updateFirstNet { $0.macAddress = NetworkConfig.generateRandomMAC() }
                }
            }
        }
    }

    /// vmnet daemon 状态面板: 状态行 + 安装 / 卸载按钮
    @ViewBuilder
    private var vmnetDaemonPanel: some View {
        let mode = draft.networks.first?.mode ?? .user
        if mode == .vmnetShared || mode == .vmnetHost || mode == .vmnetBridged {
            let sockets = VMnetSupervisor.presentSockets()
            let draftNet = draft.networks.first ?? NetworkConfig()
            let st = VMnetSupervisor.status(for: draftNet)
            VStack(alignment: .leading, spacing: 6) {
                FieldLabel("vmnet daemon")
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: st.socketExists ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(st.socketExists ? Theme.success : Theme.warning)
                    VStack(alignment: .leading, spacing: 3) {
                        if st.socketExists {
                            Text("当前模式 socket 已就绪: \(st.socketPath ?? "-")")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.textSecondary)
                        } else {
                            Text("当前模式 socket 不存在: \(st.socketPath ?? "-")")
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
                    Text(err)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.danger)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.divider, lineWidth: 1))
        }
    }

    // MARK: - vmnet daemon 安装操作

    @MainActor
    private func installVmnet() async {
        vmnetBusy = true
        vmnetError = nil
        defer { vmnetBusy = false }
        do {
            let extra = (draft.networks.first?.bridgedInterface).map { [$0] } ?? []
            try await VMnetSupervisor.installAllDaemons(extraBridgedInterfaces: extra)
            // 装完后 socket 会在 1-2 秒后出现, 触发一次视图刷新
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

    // MARK: - 启动

    private var bootSection: some View {
        section(title: "启动") {
            if readOnly {
                keyValue("UEFI", value: item.config.boot.efi ? "启用" : "关闭")
                keyValue("显示模式", value: item.config.boot.graphical
                         ? "图形(virtio-gpu + 键鼠)" : "串口(-nographic)")
                if item.config.boot.graphical {
                    keyValue("virtio-GPU 加速",
                             value: item.config.display.virtioGpu ? "启用" : "关闭")
                }
                if item.config.osType == .windows {
                    keyValue("virtio-win 自动装驱动",
                             value: item.config.boot.autoInstallVirtioWin ? "启用" : "关闭")
                }
                if let iso = item.config.boot.isoPath {
                    keyValue("ISO", value: iso, mono: true)
                } else {
                    keyValue("ISO", value: "(无)")
                }
            } else {
                togglePair(label: "UEFI",
                           on:  ("启用", "efi.bubble"),
                           off: ("关闭", "minus.circle"),
                           value: Binding(get: { draft.boot.efi },
                                          set: { draft.boot.efi = $0 }))
                togglePair(label: "显示模式",
                           on:  ("图形",  "display"),
                           off: ("串口",  "terminal"),
                           value: Binding(get: { draft.boot.graphical },
                                          set: { draft.boot.graphical = $0 }))
                if draft.boot.graphical {
                    // virtio-GPU 加速开关:
                    // - 开: virtio-gpu-pci + ramfb 双 console (Linux 建议, 能加速)
                    // - 关: virtio-ramfb 融合设备, 单 console (Windows 必选,
                    //       bootmgr 不挂死, 装 viogpudo 驱动后支持动态分辨率)
                    togglePair(label: "virtio-GPU 加速",
                               on:  ("启用", "bolt.fill"),
                               off: ("关闭", "bolt.slash"),
                               value: Binding(get: { draft.display.virtioGpu },
                                              set: { draft.display.virtioGpu = $0 }))
                    if !draft.display.virtioGpu {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "info.circle")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.textTertiary)
                            Text("改用 virtio-ramfb —— Windows 客户机推荐, 装 viogpudo 驱动后可动态适应窗口大小")
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
                    togglePair(label: "仅从硬盘启动",
                               on:  ("已装机", "internaldrive.fill"),
                               off: ("挂 ISO", "opticaldisc"),
                               value: Binding(get: { draft.boot.bootFromDiskOnly },
                                              set: { draft.boot.bootFromDiskOnly = $0 }))
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
                    togglePair(label: "自动装 virtio-win 驱动",
                               on:  ("启用", "shippingbox.fill"),
                               off: ("关闭", "shippingbox"),
                               value: Binding(get: { draft.boot.autoInstallVirtioWin },
                                              set: { draft.boot.autoInstallVirtioWin = $0 }))
                    if draft.boot.autoInstallVirtioWin {
                        virtioWinPanel
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

    private func formatMB(_ bytes: Int64?) -> String {
        guard let b = bytes else { return "?" }
        return String(format: "%.0f MB", Double(b) / 1024 / 1024)
    }

    private func togglePair(label: String,
                            on: (String, String), off: (String, String),
                            value: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            FieldLabel(label)
            HStack(spacing: 8) {
                ForEach([true, false], id: \.self) { v in
                    let sel = value.wrappedValue == v
                    Button(action: { value.wrappedValue = v }) {
                        HStack(spacing: 6) {
                            Image(systemName: v ? on.1 : off.1)
                                .font(.system(size: 11))
                            Text(v ? on.0 : off.0)
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(sel ? Theme.textPrimary : Theme.textSecondary)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 7)
                            .fill(sel ? Theme.accent.opacity(0.15) : Theme.surfaceElevated))
                        .overlay(RoundedRectangle(cornerRadius: 7)
                            .stroke(sel ? Theme.accent.opacity(0.6) : Color.clear, lineWidth: 1))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - 保存栏 / 运行中提示 / 错误

    private var saveBar: some View {
        HStack(spacing: 10) {
            if dirty {
                Image(systemName: "pencil")
                    .foregroundStyle(Theme.warning)
                Text("有未保存的改动")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            SecondaryButton(title: "放弃", systemImage: "arrow.uturn.backward", disabled: !dirty || busy) {
                draft = item.config
            }
            PrimaryButton(title: busy ? "保存中…" : "保存", systemImage: "checkmark.circle", disabled: !dirty || busy) {
                runTask {
                    try VMController.updateConfig(item, store: store) { cfg in
                        cfg.cpuCount  = draft.cpuCount
                        cfg.memoryMB  = draft.memoryMB
                        cfg.boot      = draft.boot
                        cfg.display   = draft.display
                        cfg.networks  = draft.networks
                    }
                }
            }
        }
        .padding(.horizontal, 32).padding(.top, 14)
    }

    private var runningBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(Theme.warning)
            Text("VM 运行中 · 设置只读,停机后可编辑")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textPrimary.opacity(0.85))
            Spacer()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.warning.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.warning.opacity(0.35), lineWidth: 1))
        .padding(.horizontal, 32).padding(.top, 16)
    }

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
            Button(action: { errorText = nil }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.danger.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.danger.opacity(0.35), lineWidth: 1))
    }

    // MARK: - 辅助

    /// 包装一个同步操作,统一 busy / error / 刷新
    private func runTask(_ work: @escaping () throws -> Void) {
        errorText = nil
        busy = true
        // 用 Task 让 SwiftUI 先渲染 busy=true
        Task { @MainActor in
            defer { busy = false }
            do {
                try work()
                // 保存成功后 draft 对齐最新配置(避免 dirty 假阳性)
                if let latest = store.items.first(where: { $0.id == item.id }) {
                    draft = latest.config
                }
            } catch {
                errorText = "\(error)"
            }
        }
    }

    /// 包装一个异步操作
    private func runTaskAsync(_ work: @escaping () async throws -> Void) {
        errorText = nil
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                try await work()
                if let latest = store.items.first(where: { $0.id == item.id }) {
                    draft = latest.config
                }
            } catch {
                errorText = "\(error)"
            }
        }
    }

    private func setMode(_ m: NetworkConfig.Mode) {
        if draft.networks.isEmpty {
            draft.networks = [NetworkConfig(mode: m)]
        } else {
            draft.networks[0].mode = m
            // 切到非 vmnet* 模式时清掉无关字段
            if m == .user || m == .none {
                draft.networks[0].socketVmnetPath = nil
                draft.networks[0].bridgedInterface = nil
            }
        }
    }

    private func updateFirstNet(_ mutate: (inout NetworkConfig) -> Void) {
        if draft.networks.isEmpty {
            draft.networks = [NetworkConfig(mode: .user)]
        }
        mutate(&draft.networks[0])
    }

    private func displayName(of m: NetworkConfig.Mode) -> String {
        switch m {
        case .user:          return "user (NAT)"
        case .vmnetShared:   return "vmnet shared"
        case .vmnetHost:     return "vmnet host-only"
        case .vmnetBridged:  return "vmnet bridged"
        case .none:          return "无网络"
        }
    }

    private func iconBtn(_ systemImage: String,
                         tint: Color = Theme.textSecondary,
                         disabled: Bool = false,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(disabled ? Theme.textDisabled : tint)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.surface))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
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

    // MARK: - 容器样式(与 VMDetailPane 主样式保持一致)

    private func section<V: View>(title: String, @ViewBuilder content: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(Theme.textTertiary)
                .padding(.top, 22)
            VStack(alignment: .leading, spacing: 10) {
                content()
            }
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func keyValue(_ label: String, value: String, mono: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 100, alignment: .leading)
            Text(value)
                .font(mono ? Font2.mono : Font2.body)
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func divider() -> some View {
        Rectangle().fill(Theme.divider).frame(height: 1)
            .padding(.horizontal, 32)
    }
}

/// 比较两份 networks 是否等价(dirty 检测用,字段数少,手写足够)
private func networksEqual(_ a: [NetworkConfig], _ b: [NetworkConfig]) -> Bool {
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
