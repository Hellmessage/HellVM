// 全局设计 Token —— 颜色 / 间距 / 圆角 / 字号
import SwiftUI

/// 颜色 Token
public enum Theme {
    // 背景层级(从深到浅)
    public static let background      = Color(red: 0.040, green: 0.042, blue: 0.048)   // #0A0B0C
    public static let surface         = Color(red: 0.075, green: 0.080, blue: 0.094)   // #131520
    public static let surfaceElevated = Color(red: 0.115, green: 0.120, blue: 0.138)   // #1D1F24
    public static let surfaceHover    = Color(red: 0.155, green: 0.162, blue: 0.188)   // #282934
    public static let divider         = Color(white: 1.0).opacity(0.06)

    // 文字层级
    public static let textPrimary     = Color(white: 0.96)
    public static let textSecondary   = Color(white: 0.66)
    public static let textTertiary    = Color(white: 0.46)
    public static let textDisabled    = Color(white: 0.32)

    // 强调 / 状态
    public static let accent          = Color(red: 1.00, green: 0.35, blue: 0.30)      // warm coral
    public static let accentHover     = Color(red: 1.00, green: 0.45, blue: 0.40)
    public static let success         = Color(red: 0.20, green: 0.78, blue: 0.35)      // #33C759
    public static let warning         = Color(red: 1.00, green: 0.62, blue: 0.04)      // #FF9F0A
    public static let danger          = Color(red: 1.00, green: 0.27, blue: 0.23)      // #FF453A
}

/// 字号 Token
public enum Font2 {
    public static let titleXL: Font = .system(size: 26, weight: .semibold, design: .default)
    public static let titleL:  Font = .system(size: 20, weight: .semibold)
    public static let titleM:  Font = .system(size: 15, weight: .semibold)
    public static let body:    Font = .system(size: 13)
    public static let caption: Font = .system(size: 11)
    public static let tiny:    Font = .system(size: 10, weight: .medium)
    public static let mono:    Font = .system(size: 11, design: .monospaced)
}

// MARK: - 公用组件

/// 状态徽章(RUNNING / STOPPED)
struct StatusPill: View {
    let running: Bool
    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(running ? Theme.success : Theme.textTertiary)
                .frame(width: 6, height: 6)
            Text(running ? "RUNNING" : "STOPPED")
                .font(.system(size: 9.5, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(running ? Theme.success : Theme.textTertiary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule().fill((running ? Theme.success : Theme.textTertiary).opacity(0.12))
        )
    }
}

/// 信息 chip(如 "2 CPU" / "2048 MB")
struct InfoPill: View {
    let icon: String?
    let text: String

    init(_ text: String, icon: String? = nil) {
        self.icon = icon
        self.text = text
    }

    var body: some View {
        HStack(spacing: 5) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6).fill(Theme.surfaceElevated)
        )
    }
}

/// Hover 可响应的通用容器
struct Hoverable<Content: View>: View {
    let content: (Bool) -> Content
    @State private var hovering: Bool = false

    init(@ViewBuilder content: @escaping (Bool) -> Content) {
        self.content = content
    }

    var body: some View {
        content(hovering)
            .onHover { hovering = $0 }
    }
}

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
                .frame(width: 22, height: 22)
                .background(Circle().fill(hovering ? Theme.surfaceHover : Theme.surfaceElevated))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
