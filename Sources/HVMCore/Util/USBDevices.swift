// USBDevices —— 宿主机 USB 设备枚举 (IOKit)
//
// 用于 "USB 透传" UI: 列出 host 上所有挂着的 USB 设备, 用户选一个
// 让 QEMU 通过 usb-host 透传到 guest.
//
// 实现: IOKit IOServiceGetMatchingServices kIOUSBDeviceClassName, 读每个
// 设备的 idVendor/idProduct/Product Name/Vendor Name. 过滤掉系统 root hub 和
// HID 键鼠(透传键鼠会让 host 失去输入, 体验灾难)。

import Foundation
import IOKit
import IOKit.usb

public struct HostUSBDevice: Sendable, Hashable, Identifiable {
    public var id: String    // "v<VID>p<PID>b<bus>a<addr>" 形式, 唯一稳定
    public var vendorID: UInt16
    public var productID: UInt16
    public var productName: String
    public var vendorName: String
    /// "bus.address" — 给 QMP hostbus/hostport 参数用, 可选
    public var location: String?
    /// 是否是 USB Mass Storage (class 0x08). macOS 对这类设备会让 IOUSBMassStorage
    /// 驱动占着卷, libusb 抢不过来 —— 透传前必须先 unmount.
    public var isMassStorage: Bool
    /// 如果是 mass storage, 这里列出它挂载的 BSD disk node (例 "disk4") 数组,
    /// 用于 `diskutil unmountDisk` 释放给 libusb.
    public var bsdDisks: [String]

    public var displayLabel: String {
        let hexVID = String(format: "%04x", vendorID)
        let hexPID = String(format: "%04x", productID)
        var name = productName
        if name.isEmpty { name = vendorName.isEmpty ? "(未知设备)" : vendorName }
        return "\(name) · \(hexVID):\(hexPID)"
    }
}

public enum HostUSBDevices {

    /// 扫描 host 上当前挂着的 USB 设备.
    public static func list() -> [HostUSBDevice] {
        var out: [HostUSBDevice] = []
        guard let matching = IOServiceMatching(kIOUSBDeviceClassName) else { return out }
        var iter: io_iterator_t = 0
        let rc = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter)
        guard rc == KERN_SUCCESS else { return out }
        defer { IOObjectRelease(iter) }

        while case let service = IOIteratorNext(iter), service != 0 {
            defer { IOObjectRelease(service) }

            let vid = readU16(service, "idVendor")
            let pid = readU16(service, "idProduct")
            guard let vid, let pid else { continue }

            // 过滤 root hub (Apple root hub VID 通常 0x05ac + 特定 PID;
            // 但可靠做法是看 bDeviceClass = 0x09 = Hub)
            let devClass = readU16(service, "bDeviceClass") ?? 0
            if devClass == 0x09 { continue }

            // 跳过 HID 键盘/鼠标 (class 3, 透传会让 host 失去输入)
            // bDeviceClass=0 表示交给 interface descriptor 分类, 此时放行(常见 composite 设备)
            // 只拦 bDeviceClass=3 的显式 HID
            if devClass == 0x03 { continue }

            let productName = readString(service, "USB Product Name") ?? ""
            let vendorName  = readString(service, "USB Vendor Name") ?? ""
            let busNumber   = readU32(service, "USBBusNumber")
            let addr        = readU32(service, "USB Address") ?? readU32(service, "USBDeviceAddress")

            let locationStr: String?
            if let b = busNumber, let a = addr {
                locationStr = "\(b).\(a)"
            } else {
                locationStr = nil
            }

            // USB mass storage 检测: bDeviceClass=0x08 (通用 mass storage) 或
            // composite 设备 (bDeviceClass=0) 下找 interface class=0x08. 简化起见
            // 只看 device class, composite 设备的 interface class 读取比较繁琐.
            let isMassStorage = (devClass == 0x08)
            let disks = isMassStorage ? findBSDDisks(forUSBDevice: service) : []

            let id = "v\(String(format: "%04x", vid))p\(String(format: "%04x", pid))b\(busNumber ?? 0)a\(addr ?? 0)"
            out.append(HostUSBDevice(
                id: id,
                vendorID: vid,
                productID: pid,
                productName: productName,
                vendorName: vendorName,
                location: locationStr,
                isMassStorage: isMassStorage,
                bsdDisks: disks
            ))
        }
        return out.sorted { $0.displayLabel < $1.displayLabel }
    }

    /// 从 USB device service 向下递归到其挂的 storage volume, 收集 BSD Name (如 "disk4").
    /// macOS 的 IOKit 注册树: IOUSBDevice → IOUSBInterface → IOUSBMassStorageDriver
    /// → IOSCSIPeripheralDeviceNub → ... → IOMedia (含 BSD Name). 全路径递归取 BSD Name.
    private static func findBSDDisks(forUSBDevice usb: io_service_t) -> [String] {
        var disks: [String] = []
        var childIter: io_iterator_t = 0
        let rc = IORegistryEntryCreateIterator(
            usb, kIOServicePlane,
            IOOptionBits(kIORegistryIterateRecursively),
            &childIter
        )
        guard rc == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(childIter) }

        while case let child = IOIteratorNext(childIter), child != 0 {
            defer { IOObjectRelease(child) }
            if let bsd = readString(child, "BSD Name"),
               bsd.hasPrefix("disk"),
               !disks.contains(bsd) {
                // 只要 /dev/diskN (whole disk), 不要 /dev/diskNsM (partition),
                // 因为 diskutil unmountDisk diskN 会级联卸所有分区
                let parts = bsd.split(separator: "s")
                if parts.count == 1 {
                    disks.append(bsd)
                }
            }
        }
        return disks
    }

    // MARK: - IORegistry 读属性辅助

    private static func readU16(_ service: io_service_t, _ key: String) -> UInt16? {
        guard let v = IORegistryEntryCreateCFProperty(service, key as CFString,
                                                      kCFAllocatorDefault, 0)?.takeRetainedValue()
                as? NSNumber else { return nil }
        return v.uint16Value
    }

    private static func readU32(_ service: io_service_t, _ key: String) -> UInt32? {
        guard let v = IORegistryEntryCreateCFProperty(service, key as CFString,
                                                      kCFAllocatorDefault, 0)?.takeRetainedValue()
                as? NSNumber else { return nil }
        return v.uint32Value
    }

    private static func readString(_ service: io_service_t, _ key: String) -> String? {
        guard let v = IORegistryEntryCreateCFProperty(service, key as CFString,
                                                      kCFAllocatorDefault, 0)?.takeRetainedValue()
                as? String else { return nil }
        return v
    }
}
