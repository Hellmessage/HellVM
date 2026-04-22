// InlineLogPane —— 详情页底部的实时日志 tail 面板(诊断用)
//
// 每 0.5 秒读取指定文件末尾 ~20KB, 自动滚到底部。
import SwiftUI

struct InlineLogPane: View {
    let title: String
    let path: String
    var maxBytes: Int = 20_000

    @State private var text: String = ""
    @State private var timer: Timer?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "terminal")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(Theme.textTertiary)
                Text(path)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary.opacity(0.7))
                Spacer()
                Button(action: clear) {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
                .help("清空本地日志文件")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Theme.surface)

            ScrollViewReader { reader in
                ScrollView {
                    Text(text.isEmpty ? "(空)" : text)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.textPrimary.opacity(0.85))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .id("logBottom")
                }
                .background(Color.black)
                .onChange(of: text) { _, _ in
                    reader.scrollTo("logBottom", anchor: .bottom)
                }
            }
        }
        .onAppear {
            load()
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                load()
            }
        }
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
    }

    private func load() {
        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url) else {
            text = ""
            return
        }
        let tail = data.count > maxBytes ? data.suffix(maxBytes) : data
        let new = String(data: Data(tail), encoding: .utf8) ?? ""
        if new != text { text = new }
    }

    private func clear() {
        try? Data().write(to: URL(fileURLWithPath: path))
        text = ""
    }
}
