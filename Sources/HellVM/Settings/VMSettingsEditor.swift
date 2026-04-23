// VM 设置编辑器 —— 详情页 Settings tab 的入口
//
// 设计要点:
// - 基本信息(CPU/内存) / 启动 / 网络 统一用本地 draft 承接编辑, 底部栏显示「保存 / 放弃」
// - 磁盘增删改查立即生效(涉及 qemu-img 子进程), 不走 draft
// - VM 运行中时字段切只读(网络除外, 保存时热插拔生效)
//
// 实际 UI 被拆到独立文件:
// - VMSettingsComponents.swift:共用的 VMSection / VMSectionKV / VMTogglePair 等
// - VMSettingsDisksSection.swift:磁盘区
// - VMSettingsNetworkSection.swift:网络区 + vmnet daemon + 热插拔 helper
// - VMSettingsBootSection.swift:启动区 + virtio-win 面板
import SwiftUI
import HVMCore
import HVMBackendQEMU

struct VMSettingsEditor: View {
    let store: VMListStore
    let item: VMListItem

    // draft 承接 CPU / 内存 / 启动 / 网络 四块字段的编辑, 磁盘不在其中
    @State private var draft: VMConfig
    @State private var errorText: String?
    @State private var busy: Bool = false

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
        !vmSettingsNetworksEqual(draft.networks, item.config.networks)
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                if readOnly {
                    VMRunningBanner()
                }
                if let errorText {
                    VMErrorBanner(text: errorText, onDismiss: { self.errorText = nil })
                        .padding(.horizontal, 32).padding(.top, 16)
                }

                basicSection
                VMSettingsDivider()
                VMSettingsDisksSection(item: item, store: store, readOnly: readOnly,
                                       busy: $busy, errorText: $errorText)
                VMSettingsDivider()
                VMSettingsNetworkSection(draft: $draft, item: item)
                VMSettingsDivider()
                VMSettingsBootSection(item: item, draft: $draft, readOnly: readOnly)

                // 运行中也显示 saveBar, 但只有网络脏(会热插拔)才有意义;
                // 其它字段因为 readOnly 不会变, 保存按钮自然 dirty=false 灰掉
                saveBar
            }
            .padding(.bottom, 32)
        }
    }

    // MARK: - 基本信息

    private var basicSection: some View {
        VMSection(title: "基本信息") {
            VMSectionKV(label: "架构", value: item.config.architecture.rawValue)
            if readOnly {
                VMSectionKV(label: "CPU 核心", value: "\(item.config.cpuCount)")
                VMSectionKV(label: "内存",     value: "\(item.config.memoryMB) MB")
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
            VMSectionKV(label: "Bundle 路径", value: item.bundle.url.path, mono: true)
        }
    }

    // MARK: - 保存栏

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
            SecondaryButton(title: "放弃", systemImage: "arrow.uturn.backward",
                            disabled: !dirty || busy) {
                draft = item.config
            }
            PrimaryButton(title: busy ? "保存中…" : "保存",
                          systemImage: "checkmark.circle",
                          disabled: !dirty || busy) {
                runTaskAsync {
                    // 保存前快照旧 networks, 用于运行时热插拔 diff
                    let oldNetworks = item.config.networks
                    let wasRunning = item.bundle.isRunning()
                    try VMController.updateConfig(
                        item, store: store,
                        allowWhenRunning: wasRunning   // 运行中仅网络差异会通过校验
                    ) { cfg in
                        // 运行中只允许改 networks. 其他字段即使赋值, 由于 readOnly
                        // draft 仍等于原值, updateConfig 的 hot-safe 比对会放行.
                        cfg.cpuCount  = draft.cpuCount
                        cfg.memoryMB  = draft.memoryMB
                        cfg.boot      = draft.boot
                        cfg.display   = draft.display
                        cfg.networks  = draft.networks
                    }
                    if wasRunning {
                        if let err = await vmSettingsApplyNetworkHotplug(
                            item: item, old: oldNetworks, new: draft.networks) {
                            errorText = err
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 32).padding(.top, 14)
    }

    // MARK: - 异步操作包装

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
}
