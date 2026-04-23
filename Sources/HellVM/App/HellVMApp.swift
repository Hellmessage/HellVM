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
                .frame(minWidth: 1060, minHeight: 600)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}

final class HellVMAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // 忽略 SIGPIPE: VM 关机时 qmp / iosurface socket 对端会关, 我们仍可能
        // write/sendmsg, 内核默认发 SIGPIPE kill 整个进程。显式 SIG_IGN 让
        // write 改返回 EPIPE, 调用方 try? 吞掉即可, App 不再被炸。
        signal(SIGPIPE, SIG_IGN)

        // 捕获 ObjC 层 uncaught 异常(Metal / AppKit / KVO 等触发), Swift 没法 try-catch。
        NSSetUncaughtExceptionHandler { exc in
            let stack = exc.callStackSymbols.joined(separator: "\n")
            log.error(.general,
                "UNCAUGHT ObjC \(exc.name.rawValue): \(exc.reason ?? "")\nstack:\n\(stack)")
        }
        // POSIX signal (SIGABRT / SIGSEGV / SIGBUS) 记录后原样 abort
        for sig: Int32 in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE] {
            signal(sig) { sig in
                let msg = "HellVM SIGNAL \(sig)\n"
                msg.withCString { p in _ = write(STDERR_FILENO, p, strlen(p)) }
                signal(sig, SIG_DFL)
                raise(sig)
            }
        }
    }

    /// SwiftUI App 在 macOS 下默认"最后一个窗口关闭即退出 App"。
    /// 我们不希望这种隐式退出(用户关 VM 时可能意外触发), 强制返回 false,
    /// 只允许通过 cmd+Q / 菜单 Quit 退出, 走 applicationShouldTerminate 确认流程。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        log.info(.ui, "HellVM terminating")
    }

    /// 退出前检查运行中 VM; 三选项:
    /// - 取消:           不退出
    /// - 关机所有 VM 再退出: QMP system_powerdown → 等待 → terminate
    /// - 仍然退出:        直接 terminate(Process ARC 会 SIGTERM 子进程)
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        log.info(.ui, "applicationShouldTerminate called")
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
        do {
            try await QMPClient.withSession(socketPath: bundle.qmpSocketURL.path) { qmp in
                _ = try await qmp.execute("system_powerdown")
            }
        } catch {
            log.warn(.backend, "QMP system_powerdown failed for \(bundle.url.lastPathComponent): \(error)")
        }

        // 等 VM 自己关机, 轮询 PID 是否消失
        let shutdownTimeoutSec = 20
        let pollIntervalMs: UInt64 = 500
        let iterations = shutdownTimeoutSec * 1_000 / Int(pollIntervalMs)
        for _ in 0..<iterations {
            if !bundle.isRunning() { return }
            try? await Task.sleep(nanoseconds: pollIntervalMs * 1_000_000)
        }
        // 超时 → SIGTERM
        if let pid = bundle.readPID() {
            log.warn(.backend, "shutdown timeout (\(shutdownTimeoutSec)s), sending SIGTERM to \(pid)")
            kill(pid, SIGTERM)
        }
    }
}
