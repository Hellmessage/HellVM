// 运行日志 + 调试日志查看弹窗
import SwiftUI
import AppKit

struct LogSource: Hashable {
    let label: String
    let fileURL: URL
}

struct LogViewerModal: View {
    let title: String
    let sources: [LogSource]
    let onClose: () -> Void

    /// 便捷构造:单一日志
    init(title: String, fileURL: URL, onClose: @escaping () -> Void) {
        self.title = title
        self.sources = [LogSource(label: "QEMU 运行", fileURL: fileURL)]
        self.onClose = onClose
    }

    init(title: String, sources: [LogSource], onClose: @escaping () -> Void) {
        self.title = title
        self.sources = sources
        self.onClose = onClose
    }

    @State private var selectedIndex: Int = 0
    @State private var content: String = ""
    @State private var copied: Bool = false
    @State private var autoRefresh: Bool = true
    @State private var refreshTimer: Timer?

    private var currentURL: URL { sources[selectedIndex].fileURL }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.divider).frame(height: 1)
            if sources.count > 1 {
                sourcePicker
                Rectangle().fill(Theme.divider).frame(height: 1)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    Text(content.isEmpty ? "(日志为空)" : content)
                        .font(Font2.mono)
                        .foregroundStyle(content.isEmpty ? Theme.textTertiary : Theme.textPrimary.opacity(0.92))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(16)
                        .id("bottom")
                }
                .background(Theme.background)
                .onChange(of: content) { _, _ in
                    if autoRefresh {
                        withAnimation(.none) {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    }
                }
            }
            footer
        }
        .onAppear {
            refresh()
            startAutoRefresh()
        }
        .onDisappear { stopAutoRefresh() }
        .onChange(of: selectedIndex) { _, _ in refresh() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9)
                    .fill(Theme.accent.opacity(0.18))
                    .frame(width: 32, height: 32)
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(currentURL.path)
                    .font(Font2.mono)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            IconButton(systemImage: "xmark", action: onClose)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var sourcePicker: some View {
        HStack(spacing: 6) {
            ForEach(Array(sources.enumerated()), id: \.offset) { idx, src in
                Button(action: { selectedIndex = idx }) {
                    Text(src.label)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(idx == selectedIndex ? Theme.textPrimary : Theme.textSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(idx == selectedIndex ? Theme.surfaceElevated : Color.clear)
                        )
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Toggle(isOn: $autoRefresh) {
                Text("自动刷新 (1s)")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
            }
            .toggleStyle(.checkbox)
            .onChange(of: autoRefresh) { _, newValue in
                if newValue { startAutoRefresh() } else { stopAutoRefresh() }
            }

            Text("\(content.count) 字符")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textTertiary)

            Spacer()

            SecondaryButton(title: "刷新", systemImage: "arrow.clockwise", action: refresh)
            SecondaryButton(
                title: copied ? "已复制" : "复制",
                systemImage: copied ? "checkmark" : "doc.on.doc",
                tint: copied ? Theme.success : Theme.textPrimary
            ) {
                copy()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Theme.surface)
    }

    // MARK: - 行为

    private func refresh() {
        if let data = try? Data(contentsOf: currentURL),
           let text = String(data: data, encoding: .utf8) {
            content = text
        } else {
            content = ""
        }
    }

    private func copy() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(content, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            copied = false
        }
    }

    private func startAutoRefresh() {
        stopAutoRefresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            refresh()
        }
    }

    private func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }
}
