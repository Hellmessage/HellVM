// 新建 VM 向导 —— 两步骤编排骨架
//   Step 1:选择客户机类型 (见 NewVMWizardStepOne)
//   Step 2:填写名称 / 架构 / CPU / 内存 / 创建方式 / 网络 / 显示 (见 NewVMWizardStepTwo)
//
// 本文件只负责 header / step indicator / footer / 状态流 / 提交, 具体字段 UI 在子 View。
// 字段承接在 VMConfigDraft 上, 便于与 Settings 层共享默认值与校验逻辑。
import SwiftUI
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
                    case 1:
                        NewVMWizardStepOne(draft: $draft, virtioWin: virtioWin)
                    default:
                        NewVMWizardStepTwo(draft: $draft, errorText: errorText)
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
