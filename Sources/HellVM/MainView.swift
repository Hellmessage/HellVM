// 主窗口 —— 左侧栏(VM 列表)+ 右侧详情,覆盖新建向导与确认弹窗
import SwiftUI

struct MainView: View {
    @State private var store = VMListStore()
    @State private var selectedID: UUID?
    @State private var showingWizard: Bool = false
    @State private var pendingDeleteItem: VMListItem?
    @State private var logViewerItem: VMListItem?
    @State private var errorMessage: String?

    var selectedItem: VMListItem? {
        guard let id = selectedID else { return nil }
        return store.items.first { $0.id == id }
    }

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                SidebarView(
                    store: store,
                    selectedID: $selectedID,
                    onNewVM: { showingWizard = true }
                )
                .frame(width: 260)
                Rectangle().fill(Theme.divider).frame(width: 1)
                VMDetailPane(
                    store: store,
                    item: selectedItem,
                    onDelete: { pendingDeleteItem = $0 },
                    onShowLog: { logViewerItem = $0 }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Theme.background)
            .onAppear { store.startPolling() }
            .onDisappear { store.stopPolling() }

            if showingWizard {
                ModalOverlay {
                    NewVMWizardView(
                        onCancel: { showingWizard = false },
                        onCreated: { name in
                            showingWizard = false
                            store.refresh()
                            // 新创建的 VM 自动选中
                            if let item = store.items.first(where: { $0.config.name == name }) {
                                selectedID = item.id
                            }
                        }
                    )
                    .frame(width: 480, height: 460)
                }
            }

            if let item = logViewerItem {
                ModalOverlay {
                    LogViewerModal(
                        title: "\(item.config.name) 日志",
                        fileURL: item.bundle.hellvmLogURL,
                        onClose: { logViewerItem = nil }
                    )
                    .frame(width: 760, height: 520)
                }
            }

            if let message = errorMessage {
                ModalOverlay {
                    ErrorDialog(
                        title: "操作失败",
                        message: message,
                        onClose: { errorMessage = nil }
                    )
                    .frame(width: 400)
                }
            }

            if let item = pendingDeleteItem {
                ModalOverlay {
                    ConfirmDialog(
                        title: "删除虚拟机",
                        message: "将永久删除 \(item.config.name) 及其所有磁盘。此操作无法撤销。",
                        confirmText: "删除",
                        destructive: true,
                        onCancel: { pendingDeleteItem = nil },
                        onConfirm: {
                            do {
                                try VMController.remove(item)
                                pendingDeleteItem = nil
                                store.refresh()
                                if selectedID == item.id { selectedID = nil }
                            } catch {
                                pendingDeleteItem = nil
                                errorMessage = "删除「\(item.config.name)」失败:\(error.localizedDescription)"
                            }
                        }
                    )
                    .frame(width: 400)
                }
            }
        }
    }
}

/// 遮罩 + 居中内容 —— 遵守 CLAUDE.md:只能通过自身的 X / 取消按钮关闭,遮罩不响应点击
struct ModalOverlay<Content: View>: View {
    let content: () -> Content
    @State private var appeared: Bool = false

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        ZStack {
            // 背景遮罩:深色 + 轻微 blur(macOS 12+)
            Rectangle()
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
                .overlay(Color.black.opacity(0.45))
                .ignoresSafeArea()
                // 故意不加 onTapGesture,点遮罩无效
            content()
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Theme.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.white.opacity(0.06), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.5), radius: 30, y: 10)
                .scaleEffect(appeared ? 1.0 : 0.96)
                .opacity(appeared ? 1 : 0)
                .onAppear {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                        appeared = true
                    }
                }
        }
    }
}
