// DiskHotplug —— 运行时通过 QMP 挂/卸 数据盘 (virtio-blk-pci)
//
// 两步走:
//   attach: blockdev-add (qcow2/raw file node) → device_add virtio-blk-pci
//   detach: device_del → blockdev-del
//
// ID 约定(和 MainDiskArgsBuilder 的数据盘分支一致):
//   - driveID  = "disk_<uuid8>"  (blockdev node-name)
//   - deviceID = "data_<uuid8>"  (guest 可见设备 id)
//
// guest 侧要求:
//   - Linux: 自带 virtio_blk 模块 + pci hotplug, 即插即用
//   - Windows: 需 virtio-win 里的 viostor 驱动才能认. 不然设备管理器显示"未知设备"
//
// 注意: 主盘(disks[0]) 不走热插拔, 启动时 NVMe 挂死, 重启时才能换。
// 本模块只处理 disks[1+] 的数据盘。

import Foundation
import HVMCore

public enum DiskHotplug {

    public enum HotplugError: LocalizedError {
        case qmpFailed(command: String, underlying: Error)
        public var errorDescription: String? {
            switch self {
            case .qmpFailed(let cmd, let err):
                return "QMP \(cmd) 失败: \(err.localizedDescription)"
            }
        }
    }

    public static func driveID(for disk: DiskConfig)  -> String { "disk_\(disk.qemuStableSuffix)" }
    public static func deviceID(for disk: DiskConfig) -> String { "data_\(disk.qemuStableSuffix)" }

    /// 挂载一块数据盘 (virtio-blk-pci). 调用前需确认 ID 不和现有设备冲突。
    /// - Parameters:
    ///   - disk: 磁盘配置
    ///   - absolutePath: qcow2/raw 在 host 上的绝对路径
    public static func attach(_ disk: DiskConfig, absolutePath: String, via qmp: QMPClient) async throws {
        // qcow2/raw 走 QEMU 推荐的 nested driver 表达: 外层 driver = 文件格式,
        // 内层 file driver 指向实际宿主机文件
        let fileDriver: [String: Any] = ["driver": "file", "filename": absolutePath]
        let blockdevArgs: [String: Any] = [
            "driver": disk.format.rawValue,         // "qcow2" / "raw"
            "node-name": driveID(for: disk),
            "read-only": disk.readOnly,
            "file": fileDriver,
        ]
        do {
            _ = try await qmp.execute("blockdev-add", arguments: blockdevArgs)
        } catch {
            throw HotplugError.qmpFailed(command: "blockdev-add", underlying: error)
        }

        // ARM virt 的 pcie.0 不支持 hotplug, 必须绑到预留的 pcie-root-port
        let port: String
        do {
            port = try await PCIeSlotAllocator.allocateFreePort(via: qmp)
        } catch {
            _ = try? await qmp.execute("blockdev-del", arguments: ["node-name": driveID(for: disk)])
            throw HotplugError.qmpFailed(command: "allocate-pcie-slot", underlying: error)
        }

        var devArgs: [String: Any] = [
            "driver": "virtio-blk-pci",
            "id": deviceID(for: disk),
            "drive": driveID(for: disk),
            "serial": "hellvm-\(disk.qemuStableSuffix)",
            "bus": port,
        ]
        if disk.readOnly {
            devArgs["read-only"] = true
        }
        do {
            _ = try await qmp.execute("device_add", arguments: devArgs)
        } catch {
            _ = try? await qmp.execute("blockdev-del", arguments: ["node-name": driveID(for: disk)])
            throw HotplugError.qmpFailed(command: "device_add", underlying: error)
        }
    }

    /// 卸载一块数据盘. guest 端卸载是异步的 (需要 flush), 用重试循环等 block node 释放.
    public static func detach(_ disk: DiskConfig, via qmp: QMPClient) async throws {
        do {
            _ = try await qmp.execute("device_del", arguments: ["id": deviceID(for: disk)])
        } catch {
            log.warn(.backend, "hotplug: device_del \(deviceID(for: disk)) 失败: \(error) — 继续 blockdev-del")
        }
        // blockdev-del 等 device 完全 unref. guest 没 ACK (例: UEFI Shell / 挂死)
        // 时最多等 ~5 秒, 之后放弃 (节点留着不影响下次使用, QEMU 退出自清).
        for attempt in 1...10 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            do {
                _ = try await qmp.execute("blockdev-del",
                                          arguments: ["node-name": driveID(for: disk)])
                return
            } catch {
                if attempt == 10 {
                    log.warn(.backend, "hotplug: blockdev-del \(driveID(for: disk)) 放弃(\(attempt) 次): \(error)")
                }
                // 继续重试
            }
        }
    }

    // diff 策略直接由上层 (VMController.setDiskEnabled/addDisk/removeDisk) 基于用户操作
    // 发起对应 attach/detach 调用, 无需在 backend 层二次 diff。保持本模块纯 QMP 封装。
}
