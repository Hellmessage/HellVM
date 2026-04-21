// VM 详情面板 —— 大字号 Hero + Pill 横排 + flat 分段
import SwiftUI
import HVMCore

struct VMDetailPane: View {
    let store: VMListStore
    let item: VMListItem?
    let onDelete: (VMListItem) -> Void
    let onShowLog: (VMListItem) -> Void

    @State private var lastError: String?

    var body: some View {
        ZStack {
            Theme.background
            if let item {
                content(for: item)
            } else {
                emptyState
            }
        }
    }

    // MARK: - 空状态

    private var emptyState: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(Theme.surface)
                    .frame(width: 120, height: 120)
                Image(systemName: "cube.transparent")
                    .font(.system(size: 52, weight: .thin))
                    .foregroundStyle(Theme.textTertiary)
            }
            VStack(spacing: 6) {
                Text("HellVM")
                    .font(Font2.titleL)
                    .foregroundStyle(Theme.textPrimary)
                Text("选择左侧虚拟机,或点击 + 新建")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }

    // MARK: - 详情

    private func content(for item: VMListItem) -> some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                hero(for: item)
                    .padding(.horizontal, 32)
                    .padding(.top, 32)
                    .padding(.bottom, 24)

                if let err = lastError {
                    errorBanner(err)
                        .padding(.horizontal, 32)
                        .padding(.bottom, 16)
                }

                Rectangle().fill(Theme.divider).frame(height: 1)
                    .padding(.horizontal, 32)

                section(title: "基本信息") {
                    keyValue("架构", value: item.config.architecture.rawValue)
                    keyValue("CPU 核心", value: "\(item.config.cpuCount)")
                    keyValue("内存", value: "\(item.config.memoryMB) MB")
                    keyValue("Bundle 路径", value: item.bundle.url.path, mono: true)
                }

                Rectangle().fill(Theme.divider).frame(height: 1)
                    .padding(.horizontal, 32)

                section(title: "磁盘") {
                    if item.config.disks.isEmpty {
                        keyValue("—", value: "无磁盘")
                    } else {
                        ForEach(item.config.disks, id: \.id) { d in
                            keyValue(d.relativePath, value: "\(d.sizeGB) GB · \(d.format.rawValue)", mono: true)
                        }
                    }
                }

                Rectangle().fill(Theme.divider).frame(height: 1)
                    .padding(.horizontal, 32)

                section(title: "启动") {
                    keyValue("UEFI", value: item.config.boot.efi ? "启用" : "关闭")
                    if let iso = item.config.boot.isoPath {
                        keyValue("ISO", value: iso, mono: true)
                    } else {
                        keyValue("ISO", value: "(无)")
                    }
                }
            }
            .padding(.bottom, 32)
        }
    }

    // MARK: - Hero

    private func hero(for item: VMListItem) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(archBackground(item))
                        .frame(width: 62, height: 62)
                    Image(systemName: archIcon(item))
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.config.name)
                        .font(Font2.titleXL)
                        .foregroundStyle(Theme.textPrimary)
                    HStack(spacing: 6) {
                        StatusPill(running: item.isRunning)
                        Text(item.bundle.url.lastPathComponent)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                Spacer()
            }

            // Chip 横排
            HStack(spacing: 6) {
                InfoPill("\(item.config.architecture.rawValue)", icon: "cpu")
                InfoPill("\(item.config.cpuCount) 核", icon: "square.stack.3d.up.fill")
                InfoPill("\(item.config.memoryMB) MB", icon: "memorychip")
                if let disk = item.config.disks.first {
                    InfoPill("\(disk.sizeGB) GB", icon: "externaldrive")
                }
                Spacer()
            }

            // 动作行
            actionBar(for: item)
        }
    }

    private func actionBar(for item: VMListItem) -> some View {
        HStack(spacing: 8) {
            if item.isRunning {
                SecondaryButton(title: "暂停", systemImage: "pause.fill") {
                    Task { await runAction { try await VMController.pause(item) } }
                }
                SecondaryButton(title: "恢复", systemImage: "play.fill") {
                    Task { await runAction { try await VMController.resume(item) } }
                }
                SecondaryButton(title: "停止", systemImage: "stop.fill", tint: Theme.warning) {
                    Task { await runAction { try await VMController.stop(item, store: store, force: false) } }
                }
                SecondaryButton(title: "断电", systemImage: "bolt.slash.fill", tint: Theme.danger) {
                    Task { await runAction { try await VMController.stop(item, store: store, force: true) } }
                }
            } else {
                PrimaryButton(title: "启动", systemImage: "play.fill") {
                    dbg("UI: start button clicked for \(item.config.name)")
                    Task { await runAction { try await VMController.start(item, store: store) } }
                }
            }
            Spacer()
            SecondaryButton(title: "日志", systemImage: "doc.text") {
                onShowLog(item)
            }
            SecondaryButton(title: "删除", systemImage: "trash", tint: Theme.danger, disabled: item.isRunning) {
                onDelete(item)
            }
        }
    }

    // MARK: - Section / KV

    private func section(title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(Theme.textTertiary)
                .padding(.top, 22)
            VStack(alignment: .leading, spacing: 10) {
                content()
            }
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func keyValue(_ label: String, value: String, mono: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 100, alignment: .leading)
            Text(value)
                .font(mono ? Font2.mono : Font2.body)
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func errorBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.danger)
                .font(.system(size: 11))
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textPrimary.opacity(0.9))
                .textSelection(.enabled)
            Spacer()
            Button(action: { lastError = nil }) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8).fill(Theme.danger.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8).stroke(Theme.danger.opacity(0.35), lineWidth: 1)
        )
    }

    // MARK: - 辅助

    private func runAction(_ work: @escaping () async throws -> Void) async {
        lastError = nil
        do { try await work() }
        catch { lastError = "\(error)" }
    }

    private func archIcon(_ item: VMListItem) -> String {
        switch item.config.architecture {
        case .aarch64: return "cpu"
        case .x86_64:  return "cpu.fill"
        case .riscv64: return "bolt.fill"
        }
    }

    private func archBackground(_ item: VMListItem) -> Color {
        switch item.config.architecture {
        case .aarch64: return Theme.accent.opacity(0.25)
        case .x86_64:  return Color.blue.opacity(0.25)
        case .riscv64: return Color.purple.opacity(0.25)
        }
    }
}
