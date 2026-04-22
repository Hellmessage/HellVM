// VM 列表数据源 —— 扫描 bundles、定时轮询运行状态、保活 Process 引用
import Foundation
import Observation
import HVMCore
import HVMBundle
import HVMBackendQEMU
import HVMStorage

/// 列表里每一项
public struct VMListItem: Identifiable, Sendable {
    public let bundle: VMBundle
    public let config: VMConfig
    public let isRunning: Bool
    public var id: UUID { config.id }
}

@Observable @MainActor
final class VMListStore {
    private(set) var items: [VMListItem] = []
    private(set) var lastRefresh: Date = .distantPast
    private(set) var error: String?

    private var timer: Timer?
    /// 保持 Backend 对象引用,避免 ARC 回收 → Process 被回收 → qemu 子进程被 SIGTERM
    private var liveBackends: [UUID: QEMUBackend] = [:]

    init() {}

    // MARK: - 刷新 / 轮询

    func refresh() {
        // 保留上一轮的运行状态, diff 出 running → stopped 的 VM, 关掉它们的
        // 独立 Console 窗口(guest poweroff 后自动关窗)。
        let previouslyRunning = Set(items.filter { $0.isRunning }.map { $0.id })

        do {
            let bundles = try VMBundle.listAll()
            var out: [VMListItem] = []
            for b in bundles {
                guard let cfg = try? b.loadConfig() else { continue }
                out.append(VMListItem(bundle: b, config: cfg, isRunning: b.isRunning()))
            }
            items = out.sorted { $0.config.name < $1.config.name }
            error = nil
        } catch {
            self.error = "\(error)"
        }
        lastRefresh = Date()

        let currentlyRunning = Set(items.filter { $0.isRunning }.map { $0.id })
        let stopped = previouslyRunning.subtracting(currentlyRunning)
        for id in stopped {
            ConsoleWindowManager.shared.close(for: id)
        }
    }

    func startPolling(interval: TimeInterval = 2.0) {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Backend 保活

    func retainBackend(_ backend: QEMUBackend, for id: UUID) {
        liveBackends[id] = backend
    }

    func releaseBackend(for id: UUID) {
        liveBackends.removeValue(forKey: id)
    }
}
