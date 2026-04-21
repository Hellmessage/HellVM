// 通用确认弹窗
import SwiftUI

struct ConfirmDialog: View {
    let title: String
    let message: String
    let confirmText: String
    let cancelText: String
    let destructive: Bool
    let onCancel: () -> Void
    let onConfirm: () -> Void

    init(
        title: String,
        message: String,
        confirmText: String = "确认",
        cancelText: String = "取消",
        destructive: Bool = false,
        onCancel: @escaping () -> Void,
        onConfirm: @escaping () -> Void
    ) {
        self.title = title
        self.message = message
        self.confirmText = confirmText
        self.cancelText = cancelText
        self.destructive = destructive
        self.onCancel = onCancel
        self.onConfirm = onConfirm
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textPrimary.opacity(0.85))
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 22)

            HStack(spacing: 8) {
                Spacer()
                SecondaryButton(title: cancelText, systemImage: nil, action: onCancel)
                if destructive {
                    Button(action: onConfirm) {
                        Text(confirmText)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: 7).fill(Theme.danger)
                            )
                    }
                    .buttonStyle(.plain)
                } else {
                    PrimaryButton(title: confirmText, systemImage: nil, action: onConfirm)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Theme.surface)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9)
                    .fill((destructive ? Theme.danger : Theme.accent).opacity(0.18))
                    .frame(width: 32, height: 32)
                Image(systemName: destructive ? "trash.fill" : "exclamationmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(destructive ? Theme.danger : Theme.accent)
            }
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            IconButton(systemImage: "xmark", action: onCancel)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }
}
