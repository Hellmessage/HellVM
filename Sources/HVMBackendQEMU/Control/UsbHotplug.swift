// UsbHotplug —— 运行时通过 QMP 把 host USB 设备 passthrough 给 guest
//
// 实现: device_add usb-host 指定 vendorid/productid, QEMU 通过 libusb 抢占 host
// 上该设备的控制权, 重定向所有 USB 事务到 guest. 设备从 host 端 "消失", 同时在
// guest 端作为完整 USB 设备出现。
//
// 端口挂载: 绑到启动时预定义的 "usbbus.0" (QEMUArgBuilders.USBControllerBuilder).
// 非图形模式下没有 usbbus.0, 透传不可用 —— 调用方应先确认 graphical=true。
//
// 卸载: device_del 释放设备回 host. guest 端看到的是"设备拔出", host 端看到重新挂上。
//
// 注意事项:
//   - 键鼠 / Apple magic trackpad 不要透传, 会让 host 彻底失去输入(USBDevices 会
//     过滤 HID class, 不会出现在 UI 列表里)
//   - macOS 保留了部分 USB 类的 ownership(HID 子接口), 需要 codesign 带
//     com.apple.security.device.usb entitlement + 运行时 claim 才能完整夺取
//   - 多个同 VID/PID 的设备(例: 两只同款 U 盘)会让 QEMU 随机挑一个, 本模块目前
//     只用 VID/PID 匹配

import Foundation

public enum UsbHotplug {

    public enum HotplugError: LocalizedError {
        case qmpFailed(command: String, underlying: Error)
        public var errorDescription: String? {
            switch self {
            case .qmpFailed(let cmd, let err):
                return "QMP \(cmd) 失败: \(err.localizedDescription)"
            }
        }
    }

    public static func deviceID(vendorID: UInt16, productID: UInt16) -> String {
        String(format: "usbdev_%04x_%04x", vendorID, productID)
    }

    /// 透传一个 host USB 设备给 guest.
    /// - Parameters:
    ///   - vendorID/productID: 从 IOKit 读出来的 USB descriptor
    ///   - hostbus/hostaddr: 可选, 用于同 VID/PID 多设备场景下的二选一
    public static func attach(vendorID: UInt16, productID: UInt16,
                              hostbus: UInt32? = nil, hostaddr: UInt32? = nil,
                              via qmp: QMPClient) async throws {
        // QMP schema 要求 vendorid/productid 是 uint64 (整数), 不是字符串.
        // 之前传 "0x1234" 会被 QMP 拒: "Parameter 'productid' expects uint64".
        var args: [String: Any] = [
            "driver": "usb-host",
            "id": deviceID(vendorID: vendorID, productID: productID),
            "vendorid": Int(vendorID),
            "productid": Int(productID),
            "bus": "usbbus.0",
        ]
        if let b = hostbus { args["hostbus"] = Int(b) }
        if let a = hostaddr { args["hostaddr"] = Int(a) }

        do {
            _ = try await qmp.execute("device_add", arguments: args)
        } catch {
            throw HotplugError.qmpFailed(command: "device_add", underlying: error)
        }
    }

    /// 取消透传, 把 USB 设备还给 host.
    public static func detach(vendorID: UInt16, productID: UInt16,
                              via qmp: QMPClient) async throws {
        let id = deviceID(vendorID: vendorID, productID: productID)
        do {
            _ = try await qmp.execute("device_del", arguments: ["id": id])
        } catch {
            throw HotplugError.qmpFailed(command: "device_del", underlying: error)
        }
    }
}
