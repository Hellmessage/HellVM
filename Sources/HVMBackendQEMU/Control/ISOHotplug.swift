// ISOHotplug —— 运行时通过 QMP 挂/卸 ISO 光驱
//
// 两步走:
//   attach:  blockdev-add (raw file node) → device_add (usb-storage/scsi-cd)
//   detach:  device_del → blockdev-del
//
// ID 约定(和 BootMediaArgsBuilder 一致, 重启后能继续被识别):
//   - driveID  = "cdrom0"  (blockdev node-name)
//   - deviceID = "usbcd0"  (guest 可见设备 id)
//
// guest 侧要求:
//   - Linux: 内核自带 usb-storage 驱动, 即插即用
//   - Windows: usb-storage 是通用 class driver, 不依赖 virtio-win, 直接识别
//
// 场景:
//   - 安装完成后 bootFromDiskOnly=true → 挂载时跳过 ISO, 运行中再手动插 ISO 装软件
//   - 换 ISO(比如切不同驱动盘): detach 旧 + attach 新

import Foundation
import HVMCore

public enum ISOHotplug {

    public static let driveID  = "cdrom0"
    public static let deviceID = "usbcd0"

    public enum HotplugError: LocalizedError {
        case qmpFailed(command: String, underlying: Error)
        public var errorDescription: String? {
            switch self {
            case .qmpFailed(let cmd, let err):
                return "QMP \(cmd) 失败: \(err.localizedDescription)"
            }
        }
    }

    /// 挂载 ISO. graphical=true 用 usb-storage(和 Win11 首选一致), false 用 scsi-cd.
    /// 调用前应先确认 guest 里没有同名 device, 否则 QMP 会报 duplicate ID.
    public static func attach(isoPath: String, graphical: Bool, via qmp: QMPClient) async throws {
        // 先加 block 后端 (raw driver + 嵌套 file driver 指向真实文件)
        let blockdevArgs: [String: Any] = [
            "driver": "raw",
            "node-name": driveID,
            "read-only": true,
            "file": ["driver": "file", "filename": isoPath] as [String: Any],
        ]
        do {
            _ = try await qmp.execute("blockdev-add", arguments: blockdevArgs)
        } catch {
            throw HotplugError.qmpFailed(command: "blockdev-add", underlying: error)
        }

        // 再加 guest 可见设备, 绑到上面的 block node
        let deviceArgs: [String: Any]
        if graphical {
            deviceArgs = [
                "driver": "usb-storage",
                "id": deviceID,
                "drive": driveID,
                "removable": true,
                "bus": "usbbus.0",
            ]
        } else {
            // 非图形模式假设已有 virtio-scsi-pci id=scsi0 (由 BootMediaArgsBuilder 生成)
            deviceArgs = [
                "driver": "scsi-cd",
                "id": deviceID,
                "drive": driveID,
            ]
        }
        do {
            _ = try await qmp.execute("device_add", arguments: deviceArgs)
        } catch {
            // 回滚 blockdev, 避免 stale node
            _ = try? await qmp.execute("blockdev-del", arguments: ["node-name": driveID])
            throw HotplugError.qmpFailed(command: "device_add", underlying: error)
        }
    }

    /// 卸载 ISO. device_del 异步(guest OS 要响应 eject), 我们尽最大努力;
    /// 之后 blockdev-del 主机侧立即释放 node, 即便 guest 没卸干净也不影响下次 attach.
    public static func detach(via qmp: QMPClient) async throws {
        do {
            _ = try await qmp.execute("device_del", arguments: ["id": deviceID])
        } catch {
            log.warn(.backend, "hotplug: device_del \(deviceID) 失败: \(error) — 继续 blockdev-del")
        }
        // guest 卸载是异步, 等几百毫秒让 device 真走完 eject
        try? await Task.sleep(nanoseconds: 500_000_000)
        do {
            _ = try await qmp.execute("blockdev-del", arguments: ["node-name": driveID])
        } catch {
            // blockdev 可能还被设备占用, 无害忽略 — 下次 attach 会先 detach 再来
            log.warn(.backend, "hotplug: blockdev-del \(driveID) 失败: \(error)")
        }
    }

    // MARK: - diff

    /// 判断一个 BootConfig 是否意味着"ISO 应挂载":isoPath 非空且未开 bootFromDiskOnly
    public static func isoActive(_ boot: BootConfig) -> Bool {
        guard let p = boot.isoPath, !p.isEmpty else { return false }
        return !boot.bootFromDiskOnly
    }

    /// 计算 ISO 挂载状态的 diff 动作
    public enum Action {
        case noop
        case attach(path: String, graphical: Bool)
        case detach
        case replace(path: String, graphical: Bool)   // 先 detach 再 attach(路径变了)
    }

    public static func diff(old: BootConfig, new: BootConfig) -> Action {
        let oldActive = isoActive(old)
        let newActive = isoActive(new)
        switch (oldActive, newActive) {
        case (false, false): return .noop
        case (false, true):  return .attach(path: new.isoPath!, graphical: new.graphical)
        case (true, false):  return .detach
        case (true, true):
            if old.isoPath == new.isoPath && old.graphical == new.graphical {
                return .noop
            }
            return .replace(path: new.isoPath!, graphical: new.graphical)
        }
    }
}
