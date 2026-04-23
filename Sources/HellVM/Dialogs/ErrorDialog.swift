// 通用错误弹窗 —— 单按钮确认
// 与 ConfirmDialog 并列使用:后者做"确认/取消"双按钮,这里做只读错误提示
import SwiftUI

struct ErrorDialog: View {
    let title: String
    let message: String
    let closeText: String
    let onClose: () -> Void

    init(
        title: String = "发生错误",
        message: String,
        closeText: String = "好的",
        onClose: @escaping () -> Void
    ) {
        self.title = title
        self.message = message
        self.closeText = closeText
        self.onClose = onClose
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textPrimary.opacity(0.85))
                .lineSpacing(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 22)

            HStack(spacing: 8) {
                Spacer()
                PrimaryButton(title: closeText, systemImage: nil, action: onClose)
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
                    .fill(Theme.danger.opacity(0.18))
                    .frame(width: 32, height: 32)
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.danger)
            }
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            IconButton(systemImage: "xmark", action: onClose)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }
}
