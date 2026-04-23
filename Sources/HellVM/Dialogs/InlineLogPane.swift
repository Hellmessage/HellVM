// InlineLogPane —— 详情页底部的实时日志 tail 面板
//
// 每 0.5 秒读取指定 URL 末尾 ~40KB, 自动滚到底部。
// URL 通常是 Logger 当前 active VM 的日志文件(<bundle>/logs/hellvm.log)。
import SwiftUI
import HVMCore

struct InlineLogPane: View {
    let title: String
    let fileURL: URL?
    var maxBytes: Int = 40_000
    var onOpenSettings: (() -> Void)? = nil
    var onClose: (() -> Void)? = nil

    @State private var text: String = ""
    @State private var timer: Timer?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

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
        .onAppear { startTimer() }
        .onDisappear { stopTimer() }
        .onChange(of: fileURL) { _, _ in
            text = ""
            load()
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textTertiary)
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(Theme.textTertiary)
            if let url = fileURL {
                Text(url.path)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary.opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text("(无 VM)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary.opacity(0.5))
            }
            Spacer()
            if let onOpenSettings {
                miniIconButton(system: "gearshape", help: "日志设置", action: onOpenSettings)
            }
            miniIconButton(system: "folder", help: "在 Finder 中显示", action: reveal)
            miniIconButton(system: "trash", help: "清空日志", action: clear)
            if let onClose {
                miniIconButton(system: "xmark", help: "隐藏日志面板", action: onClose)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Theme.surface)
    }

    private func miniIconButton(system: String,
                                help: String,
                                action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 26, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func startTimer() {
        load()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            load()
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func load() {
        guard let url = fileURL,
              let data = try? Data(contentsOf: url) else {
            if !text.isEmpty { text = "" }
            return
        }
        let tail = data.count > maxBytes ? data.suffix(maxBytes) : data
        let new = String(data: Data(tail), encoding: .utf8) ?? ""
        if new != text { text = new }
    }

    private func reveal() {
        guard let url = fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func clear() {
        guard let url = fileURL else { return }
        try? Data().write(to: url)
        text = ""
    }
}
