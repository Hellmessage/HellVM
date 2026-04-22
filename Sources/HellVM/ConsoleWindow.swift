// 独立 Console 窗口 —— 把 FramebufferView 拉出到单独 NSWindow
//
// 单画面策略: iosurface backend 是单客户端协议(新连接踢旧的), 不允许详情页内嵌
// Console 和独立窗口同时显示画面。独立窗口存在时, 详情页 Console tab 自动显示
// "已分离" 占位; 关闭独立窗口后自动恢复。
import AppKit
import SwiftUI
import HVMCore
import HVMBundle
import HVMDisplay

@MainActor
final class ConsoleWindowManager: NSObject, NSWindowDelegate, ObservableObject {
    static let shared = ConsoleWindowManager()

    @Published private(set) var detachedIDs: Set<UUID> = []
    private var windowsByVM: [UUID: NSWindow] = [:]

    func isDetached(_ id: UUID) -> Bool {
        detachedIDs.contains(id)
    }

    /// 打开(或前置)指定 VM 的 Console 独立窗口
    func open(for item: VMListItem) {
        if let existing = windowsByVM[item.id] {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let content = FramebufferView(
            displaySocketPath: item.bundle.iosurfaceSocketURL.path,
            inputSocketPath: item.bundle.qmpInputSocketURL.path
        )
        .background(Color.black)
        .frame(minWidth: 640, minHeight: 480)

        let hosting = NSHostingController(rootView: content)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "\(item.config.name) · Console"
        window.contentViewController = hosting
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.tabbingMode = .disallowed
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.identifier = NSUserInterfaceItemIdentifier("hellvm.console.\(item.id.uuidString)")

        windowsByVM[item.id] = window
        detachedIDs.insert(item.id)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        log.info(.ui, "console window opened for \(item.config.name)")
    }

    /// 关闭独立 Console 窗口, 让详情页内嵌 Console 恢复
    func close(for id: UUID) {
        if let w = windowsByVM[id] {
            w.close()  // 触发 windowWillClose → 清理 state
        }
    }

    // MARK: - NSWindowDelegate

    nonisolated func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let ident = window.identifier?.rawValue,
              ident.hasPrefix("hellvm.console."),
              let uuid = UUID(uuidString: String(ident.dropFirst("hellvm.console.".count)))
        else { return }
        Task { @MainActor in
            self.windowsByVM.removeValue(forKey: uuid)
            self.detachedIDs.remove(uuid)
        }
    }
}
