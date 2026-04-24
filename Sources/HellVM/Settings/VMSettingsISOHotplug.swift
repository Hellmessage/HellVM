// VMSettings 的 ISO 热挂载保存后钩子
//
// 与网络 hot-plug 对称: save 后调用, diff 旧/新 BootConfig, 走 QMP 应用挂/卸。
// 单一错误即返回 localized 字符串给 UI 显示, 不抛。

import Foundation
import HVMCore
import HVMBackendQEMU

@MainActor
func vmSettingsApplyISOHotplug(
    item: VMListItem,
    old: BootConfig,
    new: BootConfig
) async -> String? {
    let action = ISOHotplug.diff(old: old, new: new)
    switch action {
    case .noop:
        return nil

    case .attach(let path, let graphical):
        return await withQMP(item) { qmp in
            try await ISOHotplug.attach(isoPath: path, graphical: graphical, via: qmp)
            log.info(.backend, "hotplug: attached ISO \(path)")
        }

    case .detach:
        return await withQMP(item) { qmp in
            try await ISOHotplug.detach(via: qmp)
            log.info(.backend, "hotplug: detached ISO")
        }

    case .replace(let path, let graphical):
        return await withQMP(item) { qmp in
            try await ISOHotplug.detach(via: qmp)
            // detach 后 guest 需要一点时间释放设备, ISOHotplug.detach 内部已 sleep 500ms
            try await ISOHotplug.attach(isoPath: path, graphical: graphical, via: qmp)
            log.info(.backend, "hotplug: replaced ISO -> \(path)")
        }
    }
}

/// QMP 会话封装: 连接 → 执行 work → 断开。失败时返回错误字符串。
@MainActor
private func withQMP(_ item: VMListItem,
                     _ work: (QMPClient) async throws -> Void) async -> String? {
    let qmp = QMPClient()
    do {
        try await qmp.connect(socketPath: item.bundle.qmpSocketURL.path)
    } catch {
        return "QMP 连接失败, ISO 热插拔未生效: \(error.localizedDescription)"
    }
    defer { Task { await qmp.close() } }
    do {
        try await work(qmp)
        return nil
    } catch {
        return "ISO 热插拔失败: \(error.localizedDescription)"
    }
}
