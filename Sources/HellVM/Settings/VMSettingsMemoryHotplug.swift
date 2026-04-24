// VMSettings 保存后的内存热扩钩子
//
// 策略: 把 draft.memoryMB - original.memoryMB 的差额一次性加进去 (多数情况只加
// 一块 DIMM). 超过 1024MB 的大块分成几块 2GB 挂, 避免单次 allocate 过大失败.
// QEMU/guest 端的 slots 上限(启动参数给的 4)足够应对日常扩容。

import Foundation
import HVMCore
import HVMBackendQEMU

@MainActor
func vmSettingsApplyMemoryHotplug(
    item: VMListItem,
    additionalMB: UInt64
) async -> String? {
    guard additionalMB > 0 else { return nil }

    let qmp = QMPClient()
    do {
        try await qmp.connect(socketPath: item.bundle.qmpSocketURL.path)
    } catch {
        return "QMP 连接失败, 内存热扩未生效: \(error.localizedDescription)"
    }
    defer { Task { await qmp.close() } }

    // 拆分成 <= 2048MB 的 DIMM, 适配不同 guest kernel 的 memory block size 限制
    let dimmSize: UInt64 = 2048
    var remaining = additionalMB
    while remaining > 0 {
        let thisChunk = min(remaining, dimmSize)
        do {
            let id = try await MemoryHotplug.attachDIMM(sizeMB: thisChunk, via: qmp)
            log.info(.backend, "hotplug: attached DIMM \(id) size=\(thisChunk)MB")
        } catch {
            return "内存热扩失败 (\(thisChunk)MB): \(error.localizedDescription)"
        }
        remaining -= thisChunk
    }
    return nil
}
