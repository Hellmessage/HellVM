// LogSettingsView —— 日志管理器的设置 modal
// 控制全局 Logger 的启用/等级/文件输出/stderr/分类 override
// 遵守 CLAUDE.md: 只能通过右上角 X 关闭
import SwiftUI
import HVMCore

struct LogSettingsView: View {
    @Binding var isPresented: Bool

    @State private var enabled: Bool = Logger.shared.isEnabled
    @State private var globalLevel: LogLevel = Logger.shared.globalLevel
    @State private var fileEnabled: Bool = Logger.shared.fileEnabled
    @State private var stderrEnabled: Bool = Logger.shared.stderrEnabled
    @State private var categoryLevels: [String: LogLevel] = {
        var d: [String: LogLevel] = [:]
        for c in LogCategory.known {
            d[c.name] = Logger.shared.level(for: c)
        }
        return d
    }()

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    globalSection
                    Rectangle().fill(Theme.divider).frame(height: 1)
                    categorySection
                    Rectangle().fill(Theme.divider).frame(height: 1)
                    sinkSection
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 20)
            }
        }
        .frame(width: 520, height: 560)
        .background(Theme.background)
    }

    private var titleBar: some View {
        HStack {
            Text("日志设置")
                .font(Font2.titleL)
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Button(action: { isPresented = false }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.textTertiary)
            }
            .buttonStyle(.plain)
            .help("关闭")
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .background(Theme.surface)
    }

    // MARK: - 全局

    private var globalSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("全局")

            Toggle(isOn: $enabled) {
                Text("启用日志")
                    .font(Font2.body)
                    .foregroundStyle(Theme.textPrimary)
            }
            .onChange(of: enabled) { _, new in
                Logger.shared.isEnabled = new
            }

            HStack {
                Text("默认等级")
                    .font(Font2.body)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Picker("", selection: $globalLevel) {
                    ForEach(LogLevel.allCases, id: \.self) { lv in
                        Text(lv.label).tag(lv)
                    }
                }
                .labelsHidden()
                .frame(width: 160)
                .onChange(of: globalLevel) { _, new in
                    Logger.shared.globalLevel = new
                    // 同步刷新分类显示值(未 override 的会显示新默认)
                    for c in LogCategory.known where categoryLevels[c.name] == nil {
                        categoryLevels[c.name] = new
                    }
                }
            }
        }
    }

    // MARK: - 分类

    private var categorySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("分类 override")
            Text("对具体分类设置独立等级;选 \"跟随默认\" 去除 override")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textTertiary)

            ForEach(LogCategory.known, id: \.name) { cat in
                HStack {
                    Text(cat.name)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(width: 100, alignment: .leading)
                    Spacer()
                    let hasOverride = Logger.shared.allCategoryOverrides[cat.name] != nil
                    Picker("", selection: Binding<String>(
                        get: {
                            hasOverride ? String(categoryLevels[cat.name]!.rawValue) : "follow"
                        },
                        set: { newValue in
                            if newValue == "follow" {
                                Logger.shared.setLevel(nil, for: cat)
                                categoryLevels[cat.name] = Logger.shared.globalLevel
                            } else if let raw = Int(newValue), let lv = LogLevel(rawValue: raw) {
                                Logger.shared.setLevel(lv, for: cat)
                                categoryLevels[cat.name] = lv
                            }
                        }
                    )) {
                        Text("跟随默认").tag("follow")
                        ForEach(LogLevel.allCases, id: \.self) { lv in
                            Text(lv.label).tag(String(lv.rawValue))
                        }
                    }
                    .labelsHidden()
                    .frame(width: 160)
                }
            }
        }
    }

    // MARK: - sink

    private var sinkSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("输出目标")
            Toggle(isOn: $fileEnabled) {
                Text("写入文件(全局 + 当前 VM, 各 10MB 滚动)")
                    .font(Font2.body)
                    .foregroundStyle(Theme.textPrimary)
            }
            .onChange(of: fileEnabled) { _, new in
                Logger.shared.fileEnabled = new
            }

            Toggle(isOn: $stderrEnabled) {
                Text("同时输出到 stderr")
                    .font(Font2.body)
                    .foregroundStyle(Theme.textPrimary)
            }
            .onChange(of: stderrEnabled) { _, new in
                Logger.shared.stderrEnabled = new
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("全局日志:")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
                Text(Logger.shared.globalLogURL.path)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled)

                if let vm = Logger.shared.activeVMLogURL {
                    Text("当前 VM 日志:")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.top, 4)
                    Text(vm.path)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                        .textSelection(.enabled)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.surface))
        }
    }

    private func sectionTitle(_ t: String) -> some View {
        Text(t)
            .font(.system(size: 11, weight: .bold))
            .tracking(0.8)
            .foregroundStyle(Theme.textTertiary)
    }
}
