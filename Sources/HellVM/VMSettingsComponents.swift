// VMSettingsEditor 与其各子区块共用的 UI 基元
// - VMSection: 带标题的分组容器
// - VMSectionKV: 只读的键值对行(运行中视图)
// - VMSettingsDivider: section 之间的分隔线
// - VMTogglePair: 二选一带图标的开关对
// - VMIconButton: 小图标按钮(磁盘操作用)
// - VMRunningBanner / VMErrorBanner: 顶部横幅
import SwiftUI
import HVMCore

struct VMSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(Theme.textTertiary)
                .padding(.top, 22)
            VStack(alignment: .leading, spacing: 10, content: content)
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct VMSectionKV: View {
    let label: String
    let value: String
    var mono: Bool = false

    var body: some View {
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
}

struct VMSettingsDivider: View {
    var body: some View {
        Rectangle().fill(Theme.divider).frame(height: 1)
            .padding(.horizontal, 32)
    }
}

/// 带图标的二选一切换 (用于启用/关闭 + 图形/串口 等)
struct VMTogglePair: View {
    let label: String
    let on: (String, String)   // (标题, SF Symbol)
    let off: (String, String)
    @Binding var value: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            FieldLabel(label)
            HStack(spacing: 8) {
                ForEach([true, false], id: \.self) { v in
                    let sel = value == v
                    Button(action: { value = v }) {
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
}

/// 磁盘操作的小图标按钮 (上下移、调整、转换等)
struct VMIconButton: View {
    let systemImage: String
    var tint: Color = Theme.textSecondary
    var disabled: Bool = false
    let action: () -> Void

    var body: some View {
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
}

struct VMRunningBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(Theme.warning)
            Text("VM 运行中 · 仅网络支持 QMP 热插拔, 其它设置需停机才能改")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textPrimary.opacity(0.85))
            Spacer()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.warning.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.warning.opacity(0.35), lineWidth: 1))
        .padding(.horizontal, 32).padding(.top, 16)
    }
}

struct VMErrorBanner: View {
    let text: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.danger)
                .font(.system(size: 11))
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textPrimary.opacity(0.9))
                .textSelection(.enabled)
            Spacer()
            Button(action: onDismiss) {
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
}
