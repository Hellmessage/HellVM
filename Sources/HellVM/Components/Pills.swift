// 徽章 / 信息 chip 类小组件
import SwiftUI

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
