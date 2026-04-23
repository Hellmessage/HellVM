// 表单输入组件 —— FieldLabel / StyledTextField / StepperCard
import SwiftUI

/// 小标题(表单字段标签)
struct FieldLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .bold))
            .tracking(0.6)
            .foregroundStyle(Theme.textTertiary)
    }
}

/// 带圆角卡片风格的文本输入
struct StyledTextField: View {
    let placeholder: String
    @Binding var text: String
    var monospaced: Bool = false
    var disabled: Bool = false

    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(monospaced ? Font2.mono : Font2.body)
            .foregroundStyle(disabled ? Theme.textDisabled : Theme.textPrimary)
            .disabled(disabled)
            .focused($focused)
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 8).fill(Theme.surfaceElevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(focused ? Theme.accent.opacity(0.6) : Color.clear, lineWidth: 1)
            )
    }
}

/// ± 步进卡片(整数,带范围与步长)
struct StepperCard: View {
    @Binding var value: Int
    let unit: String
    let range: ClosedRange<Int>
    let step: Int
    var disabled: Bool = false

    var body: some View {
        HStack(spacing: 0) {
            Button(action: decrement) {
                Image(systemName: "minus")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(disabled ? Theme.textDisabled : Theme.textSecondary)
                    .frame(width: 44, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(disabled || value <= range.lowerBound)

            Rectangle().fill(Theme.divider).frame(width: 1, height: 16)

            Text("\(value) \(unit)")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(disabled ? Theme.textDisabled : Theme.textPrimary)
                .frame(maxWidth: .infinity)

            Rectangle().fill(Theme.divider).frame(width: 1, height: 16)

            Button(action: increment) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(disabled ? Theme.textDisabled : Theme.textSecondary)
                    .frame(width: 44, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(disabled || value >= range.upperBound)
        }
        .background(
            RoundedRectangle(cornerRadius: 8).fill(Theme.surfaceElevated)
        )
    }

    private func increment() { value = min(range.upperBound, value + step) }
    private func decrement() { value = max(range.lowerBound, value - step) }
}
