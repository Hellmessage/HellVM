// 主窗口 —— 左侧栏(VM 列表)+ 右侧详情
import SwiftUI

struct MainView: View {
    var body: some View {
        HStack(spacing: 0) {
            SidebarView()
                .frame(width: 240)
            Rectangle()
                .fill(Theme.divider)
                .frame(width: 1)
            DetailView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.background)
    }
}

/// 左侧栏 —— VM 列表(P0 占位)
struct SidebarView: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("HellVM")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Button {
                    // TODO P3:打开新建向导
                } label: {
                    Image(systemName: "plus")
                        .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Rectangle()
                .fill(Theme.divider)
                .frame(height: 1)

            VStack {
                Spacer()
                Text("暂无虚拟机")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textDisabled)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
        .background(Theme.surface)
    }
}

/// 右侧详情 —— P0 仅显示占位
struct DetailView: View {
    var body: some View {
        ZStack {
            Theme.background
            VStack(spacing: 8) {
                Text("HellVM")
                    .font(.system(size: 48, weight: .thin))
                    .foregroundStyle(Theme.textPrimary.opacity(0.25))
                Text("选择左侧虚拟机,或点击 + 新建")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textDisabled)
            }
        }
    }
}
