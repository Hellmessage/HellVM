// 统一风格按钮 —— SecondaryButton / PrimaryButton / IconButton
import SwiftUI

/// 统一风格的次级按钮
struct SecondaryButton: View {
    let title: String
    let systemImage: String?
    var tint: Color = Theme.textPrimary
    var disabled: Bool = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(disabled ? Theme.textDisabled : tint)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(hovering && !disabled ? Theme.surfaceHover : Theme.surfaceElevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(Color.white.opacity(hovering && !disabled ? 0.08 : 0), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hovering = $0 }
    }
}

/// 主要按钮(accent 实色)
struct PrimaryButton: View {
    let title: String
    let systemImage: String?
    var disabled: Bool = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(disabled ? Theme.textDisabled : .white)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(disabled ? Theme.surfaceElevated : (hovering ? Theme.accentHover : Theme.accent))
            )
            .shadow(color: (disabled ? Color.clear : Theme.accent).opacity(hovering ? 0.35 : 0), radius: 8, y: 2)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hovering = $0 }
    }
}

/// SF Symbol 圆形小按钮(用于关闭等)
struct IconButton: View {
    let systemImage: String
    var tint: Color = Theme.textSecondary
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(hovering ? Theme.textPrimary : tint)
                .frame(width: 28, height: 28)
                .background(Circle().fill(hovering ? Theme.surfaceHover : Theme.surfaceElevated))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
