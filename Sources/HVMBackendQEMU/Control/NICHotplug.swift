// NICHotplug —— 运行时通过 QMP 把 NIC 动态 attach/detach 到 guest
//
// QEMU 对 virt 机器 + virtio-net-pci/e1000e 支持 PCIe hotplug. 两步走:
//   1. netdev_add  创建主机侧后端(user NAT 或 socket_vmnet unix stream)
//   2. device_add  创建 guest 可见的 PCI NIC, 绑到刚才的 netdev
// 卸载反向:
//   1. device_del  通知 guest 卸载 PCI 设备, guest OS 触发 unplug 流程
//   2. netdev_del  删后端
//
// guest 侧要求:
//   - Linux: kernel 自带 pci hotplug + virtio_net/e1000 模块 → 即插即用
//   - Windows: 需要装了 NetKVM/viostor 一套 driver(我们的 virtio-win.iso 装完
//     就有), 热插拔期间可能短暂无网
//
// ID 规则: 两侧都用派生自 MAC 的稳定后缀, 见 NetworkConfig.qemuStableSuffix,
// 这样启动时和后期 hotplug 走同一个 id, 不会串位。

import Foundation
import HVMCore

public enum NICHotplug {

    public enum HotplugError: LocalizedError {
        case noMAC
        case qmpFailed(command: String, underlying: Error)

        public var errorDescription: String? {
            switch self {
            case .noMAC:
                return "NIC 缺 MAC 地址, 无法派生稳定 hotplug id"
            case .qmpFailed(let cmd, let err):
                return "QMP \(cmd) 失败: \(err.localizedDescription)"
            }
        }
    }

    // MARK: - 派生 ID

    public static func netdevID(for net: NetworkConfig) -> String? {
        net.qemuStableSuffix.map { "net_\($0)" }
    }

    public static func deviceID(for net: NetworkConfig) -> String? {
        net.qemuStableSuffix.map { "nic_\($0)" }
    }

    // MARK: - 单 NIC attach / detach

    /// 把指定 NIC hot-plug 进 guest. QMP socket 必须已连接.
    public static func attach(_ net: NetworkConfig, via qmp: QMPClient) async throws {
        guard let netId = netdevID(for: net), let devId = deviceID(for: net) else {
            throw HotplugError.noMAC
        }

        var netdevArgs: [String: Any] = ["id": netId]
        switch net.mode {
        case .user:
            netdevArgs["type"] = "user"
        case .vmnetShared, .vmnetHost, .vmnetBridged:
            netdevArgs["type"] = "stream"
            let sock = net.effectiveSocketPath ?? SocketPaths.vmnetShared
            // netdev-stream 用 SocketAddress(非 Legacy) flat union:
            // discriminator `type` 和 variant 字段(unix 的 `path`)同级平铺。
            // 写成 {"type":"unix","data":{...}} 是 Legacy 格式, QEMU 10.x 的
            // NetdevStreamOptions.addr 不认, 会报 "Parameter 'addr.path' is missing"。
            netdevArgs["addr"] = ["type": "unix", "path": sock]
        case .none:
            return   // 禁用的 NIC 不 attach
        }

        do {
            _ = try await qmp.execute("netdev_add", arguments: netdevArgs)
        } catch {
            throw HotplugError.qmpFailed(command: "netdev_add", underlying: error)
        }

        // ARM virt 的 pcie.0 不支持 hotplug, 必须绑到预留的 pcie-root-port
        let port: String
        do {
            port = try await PCIeSlotAllocator.allocateFreePort(via: qmp)
        } catch {
            _ = try? await qmp.execute("netdev_del", arguments: ["id": netId])
            throw HotplugError.qmpFailed(command: "allocate-pcie-slot", underlying: error)
        }

        var devArgs: [String: Any] = [
            "driver": net.deviceModel.qemuDeviceName,
            "netdev": netId,
            "id": devId,
            "bus": port,
        ]
        if let mac = net.macAddress, !mac.isEmpty {
            devArgs["mac"] = mac
        }
        do {
            _ = try await qmp.execute("device_add", arguments: devArgs)
        } catch {
            // 回滚 netdev, 避免残留
            _ = try? await qmp.execute("netdev_del", arguments: ["id": netId])
            throw HotplugError.qmpFailed(command: "device_add", underlying: error)
        }
    }

    /// 把指定 NIC hot-unplug. 先 device_del 让 guest 走正常卸载流程, 再 netdev_del.
    /// 若 guest 卸载超时(例如 Windows 还没装 driver), device_del 成功但 guest 可能
    /// 暂时没释放, 我们仍进行 netdev_del — 后端释放不影响 guest 真正解绑。
    public static func detach(_ net: NetworkConfig, via qmp: QMPClient) async throws {
        guard let netId = netdevID(for: net), let devId = deviceID(for: net) else {
            throw HotplugError.noMAC
        }
        do {
            _ = try await qmp.execute("device_del", arguments: ["id": devId])
        } catch {
            // 设备本就不在(例如已经被 guest 卸了), 继续删 netdev
            log.warn(.backend, "hotplug: device_del \(devId) failed: \(error) — 继续尝试 netdev_del")
        }
        do {
            _ = try await qmp.execute("netdev_del", arguments: ["id": netId])
        } catch {
            throw HotplugError.qmpFailed(command: "netdev_del", underlying: error)
        }
    }

    // MARK: - 批量 diff

    /// 计算旧 → 新网卡集合的差异, 返回需要 attach 和 detach 的列表.
    ///
    /// 判定口径:
    /// - active(net) = enabled && mode != .none
    /// - 以稳定后缀为身份
    /// - 旧 active && 新 !active  → detach 旧
    /// - 旧 !active && 新 active  → attach 新
    /// - 两边都 active 但 mode/socket/MAC 改了 → detach 旧 + attach 新(完整替换)
    /// - 不变 → 跳过
    public static func diff(old: [NetworkConfig], new: [NetworkConfig]) -> (attach: [NetworkConfig], detach: [NetworkConfig]) {
        func isActive(_ n: NetworkConfig) -> Bool { n.enabled && n.mode != .none }

        // 用稳定后缀建索引
        var oldByKey: [String: NetworkConfig] = [:]
        for n in old {
            if let k = n.qemuStableSuffix { oldByKey[k] = n }
        }
        var newByKey: [String: NetworkConfig] = [:]
        for n in new {
            if let k = n.qemuStableSuffix { newByKey[k] = n }
        }

        var toAttach: [NetworkConfig] = []
        var toDetach: [NetworkConfig] = []

        let allKeys = Set(oldByKey.keys).union(newByKey.keys)
        for key in allKeys {
            let oldN = oldByKey[key]
            let newN = newByKey[key]
            let wasActive = oldN.map(isActive) ?? false
            let willBeActive = newN.map(isActive) ?? false

            if wasActive && !willBeActive {
                toDetach.append(oldN!)
            } else if !wasActive && willBeActive {
                toAttach.append(newN!)
            } else if wasActive && willBeActive {
                // 两边都 active, 检查关键字段是否变化
                let changed = needsReattach(from: oldN!, to: newN!)
                if changed {
                    toDetach.append(oldN!)
                    toAttach.append(newN!)
                }
            }
            // 两边都 !active → 无需操作
        }

        return (toAttach, toDetach)
    }

    /// 判断两个同身份的 NIC 配置是否需要重新 attach(关键字段变化)
    private static func needsReattach(from a: NetworkConfig, to b: NetworkConfig) -> Bool {
        if a.mode != b.mode { return true }
        if a.deviceModel != b.deviceModel { return true }
        if a.effectiveSocketPath != b.effectiveSocketPath { return true }
        // MAC 一般不会变(身份绑定 MAC), 变了走替换安全
        if a.macAddress != b.macAddress { return true }
        return false
    }
}
