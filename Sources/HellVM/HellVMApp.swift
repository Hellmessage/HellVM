// App 入口 —— SwiftUI @main
import SwiftUI
import AppKit
import Darwin
import HVMCore
import HVMBundle
import HVMBackendQEMU

@main
struct HellVMApp: App {
    @NSApplicationDelegateAdaptor(HellVMAppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            MainView()
                .preferredColorScheme(.dark)
                .frame(minWidth: 960, minHeight: 600)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}

final class HellVMAppDelegate: NSObject, NSApplicationDelegate {
    /// 退出前检查运行中 VM; 三选项:
    /// - 取消:           不退出
    /// - 关机所有 VM 再退出: QMP system_powerdown → 等待 → terminate
    /// - 仍然退出:        直接 terminate(Process ARC 会 SIGTERM 子进程)
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let running = (try? VMBundle.listAll().filter { $0.isRunning() }) ?? []
        guard !running.isEmpty else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = "有 \(running.count) 个虚拟机正在运行"
        if running.count == 1, let cfg = try? running.first?.loadConfig() {
            alert.informativeText =
                "「\(cfg.name)」仍在运行。你可以先关机再退出,或直接强制退出(可能丢数据)。"
        } else {
            alert.informativeText =
                "你可以先逐台关机再退出,或直接强制退出(可能丢数据)。"
        }
        alert.addButton(withTitle: "取消")                 // alertFirstButtonReturn  (default)
        alert.addButton(withTitle: "关机所有 VM 再退出")   // alertSecondButtonReturn
        alert.addButton(withTitle: "仍然退出")             // alertThirdButtonReturn
        let resp = alert.runModal()

        switch resp {
        case .alertFirstButtonReturn:
            return .terminateCancel
        case .alertSecondButtonReturn:
            Task { @MainActor in
                await Self.shutdownAll(running)
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        case .alertThirdButtonReturn:
            return .terminateNow
        default:
            return .terminateCancel
        }
    }

    /// 对所有 bundles 并发 QMP system_powerdown, 每台最多等 20s; 超时则 SIGTERM。
    private static func shutdownAll(_ bundles: [VMBundle]) async {
        log.info(.backend, "shutdown all (\(bundles.count) VMs)")
        await withTaskGroup(of: Void.self) { group in
            for bundle in bundles {
                group.addTask {
                    await shutdownOne(bundle)
                }
            }
        }
    }

    private static func shutdownOne(_ bundle: VMBundle) async {
        let qmp = QMPClient()
        do {
            try await qmp.connect(socketPath: bundle.qmpSocketURL.path)
            _ = try await qmp.execute("system_powerdown")
            await qmp.close()
        } catch {
            log.warn(.backend, "QMP system_powerdown failed for \(bundle.url.lastPathComponent): \(error)")
        }

        // 等退出, 轮询 PID, 上限 20s
        for _ in 0..<40 {
            if !bundle.isRunning() { return }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        // 超时 → SIGTERM
        if let pid = bundle.readPID() {
            log.warn(.backend, "shutdown timeout, sending SIGTERM to \(pid)")
            kill(pid, SIGTERM)
        }
    }
}
