// PCIeSlotAllocator —— 查询当前占用的 pcie-root-port, 返回第一个空闲的 rpN
//
// 启动时 PCIeRootPortsArgsBuilder 预定义 4 个 root port (rp0..rp3). 每个能挂一块
// hot-pluggable 设备. 要 hot-plug 新设备时, 先调用 allocateFreePort 查当前哪些 rp
// 没被占用, 返回 "rp\(N)" 作为 bus 参数.
//
// 实现: QMP `query-pci` 返回 pci 树 (bus → devices[] 嵌套). 我们扫所有 bus, 如果
// bus.devices 里某个设备 id == rpN 且它自己的 .pci_bridge.devices 为空, 就算空闲.

import Foundation

public enum PCIeSlotAllocator {

    public enum AllocError: LocalizedError {
        case noFreeSlot
        case qmpFailed(underlying: Error)
        public var errorDescription: String? {
            switch self {
            case .noFreeSlot:
                return "PCIe hot-plug 槽位已满 (预留了 4 个, 全部被占用). 停机重启 VM 释放."
            case .qmpFailed(let err):
                return "QMP query-pci 失败: \(err.localizedDescription)"
            }
        }
    }

    /// 返回第一个空闲 pcie-root-port 的 id (如 "rp0"), 没有空闲则抛异常.
    /// 每个 root port 只能挂一个设备, 所以 pci_bridge.devices 为空 = 空闲.
    public static func allocateFreePort(via qmp: QMPClient) async throws -> String {
        // query-pci 返回 {return: [{bus: 0, devices: [...]}]}
        // 注意: HVMBackendQEMU 的 QMPClient.execute 返回值是 [String: Any] 字典 —
        // 但 query-pci 的 return 是数组, 会变成 {"": [...]} 或类似包装? 我们直接
        // 用一次 raw 发送的迂回方案: 手写读取原始 JSON.
        //
        // 简化: 使用 query-pci 并自行解析. QMPClient.execute 把 {"return": X} 的 X
        // 当 [String: Any] 读, 但 X 是数组时会失败. 需要另一个 API. 这里我们用
        // executeExpectingArray (见下).
        let root = try await queryPCIRaw(via: qmp)
        let occupied = findOccupiedRootPorts(in: root)
        for i in 0..<4 {
            let id = "rp\(i)"
            if !occupied.contains(id) {
                return id
            }
        }
        throw AllocError.noFreeSlot
    }

    /// 递归遍历 pci 树, 找占用了设备的 rp0..rp3 的 id.
    /// 一个 rp 算占用 = 它自己是 type=bridge (pcie-root-port) 且 pci_bridge.devices 非空.
    private static func findOccupiedRootPorts(in root: [[String: Any]]) -> Set<String> {
        var occupied = Set<String>()
        func walk(_ devices: [[String: Any]]) {
            for dev in devices {
                let qdev = dev["qdev_id"] as? String ?? ""
                if qdev.hasPrefix("rp") {
                    // 检查 pci_bridge.devices
                    if let bridge = dev["pci_bridge"] as? [String: Any],
                       let sub = bridge["devices"] as? [[String: Any]],
                       !sub.isEmpty {
                        occupied.insert(qdev)
                    }
                }
                // 向下递归
                if let bridge = dev["pci_bridge"] as? [String: Any],
                   let sub = bridge["devices"] as? [[String: Any]] {
                    walk(sub)
                }
            }
        }
        for bus in root {
            if let devs = bus["devices"] as? [[String: Any]] {
                walk(devs)
            }
        }
        return occupied
    }

    /// 绕过 QMPClient.execute 的 dict 限制, 直接用内部 transport 发 query-pci 取
    /// 数组返回. 因为现有 QMPClient 签名返回 [String: Any], 这里用 reflection 技巧不好做,
    /// 改为发一个包装命令 — 不行, QMP 没有内置包装.
    /// 实际做法: 用 QMPClient.executeRaw (见本文件补丁), 返回顶层 return 字段的 Any.
    private static func queryPCIRaw(via qmp: QMPClient) async throws -> [[String: Any]] {
        let any = try await qmp.executeRaw("query-pci")
        guard let array = any as? [[String: Any]] else {
            throw AllocError.qmpFailed(underlying: NSError(
                domain: "HVM", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "query-pci 返回不是数组"]))
        }
        return array
    }
}
