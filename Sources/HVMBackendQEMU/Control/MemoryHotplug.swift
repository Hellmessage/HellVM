// MemoryHotplug —— 运行时通过 QMP 给 guest 加内存 (pc-dimm)
//
// 前提条件: 启动时必须已用 `-m <init>M,slots=N,maxmem=<max>M` 预留热插槽位.
// slots 决定最多能插多少块 DIMM; maxmem 决定总上限.
//
// 两步走:
//   1. object-add memory-backend-ram  创建 host 侧 anonymous memory region
//   2. device_add pc-dimm              把 region 挂到 guest 的 ACPI DIMM slot
// 卸载一般不做 (guest 必须 offline 那块 RAM, 复杂且不稳定), 热插只加不减。
//
// guest 侧要求:
//   - Linux: CONFIG_MEMORY_HOTPLUG + CONFIG_ACPI_MEMORY_HOTPLUG_MANUAL 默认都开
//     需要 `udev` 规则 auto-online, 否则要手动 `echo online > /sys/...`. Ubuntu
//     >=20.04 的 kernel 支持 SRAT 的 memory hotplug 提议 online.
//   - Windows: ARM64 对内存热插支持差, 实测不稳定, 有可能需重启才生效。

import Foundation

public enum MemoryHotplug {

    public enum HotplugError: LocalizedError {
        case qmpFailed(command: String, underlying: Error)
        case sizeInvalid(String)
        public var errorDescription: String? {
            switch self {
            case .qmpFailed(let cmd, let err):
                return "QMP \(cmd) 失败: \(err.localizedDescription)"
            case .sizeInvalid(let msg):
                return "内存大小不合法: \(msg)"
            }
        }
    }

    /// DIMM slot 指纹: 用当前 Unix 时间 (毫秒) 的短哈希生成, 保证每次 attach
    /// 的 object/device id 不重复. QEMU 不允许同名 object 存在。
    public static func nextDIMMID() -> String {
        let ms = UInt64(Date().timeIntervalSince1970 * 1000)
        return "dimm_\(String(ms, radix: 16))"
    }

    /// 往 guest 里加一块指定大小的 DIMM (MB 级对齐), 调用前应确保
    /// 当前已用插槽数 + 1 <= slots 上限, 否则 QMP 报错.
    ///
    /// - Parameters:
    ///   - sizeMB: 要加的内存块大小, 必须 >= 1024 (QEMU ACPI memory 最小颗粒 1GB,
    ///     小于 1GB 的 DIMM 有的 guest kernel 不认)
    public static func attachDIMM(sizeMB: UInt64, via qmp: QMPClient) async throws -> String {
        guard sizeMB >= 1 else {
            throw HotplugError.sizeInvalid("sizeMB 需 >= 1")
        }
        let dimmID = nextDIMMID()
        let objectID = "mem_\(dimmID)"

        // object-add 的 qom-type 参数在新 QMP schema (QEMU 6+) 平铺在 arguments 根,
        // 旧版需要 "qom-type" + "id" + props. 我们用新格式 (QEMU 10.2 支持).
        let objArgs: [String: Any] = [
            "qom-type": "memory-backend-ram",
            "id": objectID,
            "size": Int(sizeMB) * 1024 * 1024,   // 字节
        ]
        do {
            _ = try await qmp.execute("object-add", arguments: objArgs)
        } catch {
            throw HotplugError.qmpFailed(command: "object-add", underlying: error)
        }

        let devArgs: [String: Any] = [
            "driver": "pc-dimm",
            "id": dimmID,
            "memdev": objectID,
        ]
        do {
            _ = try await qmp.execute("device_add", arguments: devArgs)
        } catch {
            // 回滚 backend 对象, 避免 stale object
            _ = try? await qmp.execute("object-del", arguments: ["id": objectID])
            throw HotplugError.qmpFailed(command: "device_add", underlying: error)
        }
        return dimmID
    }

    /// 查询当前 guest 内存总量 (MB). 用于 UI 展示 "当前已分配". QMP `query-memory-size-summary`.
    public static func queryTotalMB(via qmp: QMPClient) async -> UInt64? {
        guard let ret = try? await qmp.execute("query-memory-size-summary") else {
            return nil
        }
        if let baseMem = ret["base-memory"] as? Int {
            let pluggedMem = (ret["plugged-memory"] as? Int) ?? 0
            return UInt64(baseMem + pluggedMem) / 1024 / 1024
        }
        return nil
    }
}
