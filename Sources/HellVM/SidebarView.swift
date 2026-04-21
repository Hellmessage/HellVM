// 左侧栏 —— VM 列表 + 运行状态 pill + 选中指示条 + hover
import SwiftUI

struct SidebarView: View {
    let store: VMListStore
    @Binding var selectedID: UUID?
    let onNewVM: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.divider).frame(height: 1)
            if store.items.isEmpty {
                emptyState
            } else {
                listContent
            }
            Spacer(minLength: 0)
            footer
        }
        .background(Theme.surface)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "cube.transparent")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Theme.accent)
            Text("HellVM")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            IconButton(systemImage: "plus", action: onNewVM)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: - Empty

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 40)
            ZStack {
                Circle()
                    .fill(Theme.surfaceElevated)
                    .frame(width: 72, height: 72)
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(Theme.textTertiary)
            }
            VStack(spacing: 4) {
                Text("暂无虚拟机")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                Text("点击下方按钮创建第一台")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
            }
            PrimaryButton(title: "新建虚拟机", systemImage: "plus", action: onNewVM)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - List

    private var listContent: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 2) {
                Text("虚拟机")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.top, 14)
                    .padding(.bottom, 6)
                ForEach(store.items) { item in
                    VMRow(item: item, isSelected: selectedID == item.id)
                        .contentShape(Rectangle())
                        .onTapGesture { selectedID = item.id }
                }
            }
            .padding(.horizontal, 8)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Text("\(store.items.count) 台")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textTertiary)
            Spacer()
            if store.items.count > 0 {
                Text(store.items.filter { $0.isRunning }.count > 0
                     ? "\(store.items.filter { $0.isRunning }.count) 运行中"
                     : "全部停止")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Theme.surface.opacity(0.5))
    }
}

/// 侧栏单项 —— 左侧 accent 竖条(选中态)+ icon + 名称 + pill
private struct VMRow: View {
    let item: VMListItem
    let isSelected: Bool

    @State private var hovering: Bool = false

    var body: some View {
        HStack(spacing: 0) {
            // 选中指示条
            Rectangle()
                .fill(isSelected ? Theme.accent : Color.clear)
                .frame(width: 3)
                .padding(.vertical, 6)

            HStack(spacing: 10) {
                // 架构图标
                ZStack {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(archBackground)
                        .frame(width: 30, height: 30)
                    Image(systemName: archIcon)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.config.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(item.config.architecture.rawValue)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Theme.textTertiary)
                        Text("·")
                            .foregroundStyle(Theme.textTertiary)
                        Text("\(item.config.memoryMB) MB")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                Spacer(minLength: 0)
                if item.isRunning {
                    Circle()
                        .fill(Theme.success)
                        .frame(width: 7, height: 7)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Theme.surfaceElevated : (hovering ? Theme.surfaceHover.opacity(0.5) : Color.clear))
        )
        .onHover { hovering = $0 }
    }

    private var archIcon: String {
        switch item.config.architecture {
        case .aarch64: return "cpu"
        case .x86_64:  return "cpu.fill"
        case .riscv64: return "bolt.fill"
        }
    }

    private var archBackground: Color {
        switch item.config.architecture {
        case .aarch64: return Theme.accent.opacity(0.20)
        case .x86_64:  return Color.blue.opacity(0.20)
        case .riscv64: return Color.purple.opacity(0.20)
        }
    }
}
