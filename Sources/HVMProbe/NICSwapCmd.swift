// nic-swap —— 程序化重现 "改 NIC model" 的热插拔流程.
//
// 实现: 直接发 QMP device_del → device_add (保留同 netdev, 换 driver).
// 不复用 HVMBackendQEMU.NICHotplug 是因为那边用的是 NetworkConfig 聚合对象,
// 而我们这里用户可能只想换 model, 保留其它字段, 直接用 QMP 原语更薄。
//
// 注意: device_del 是异步的, guest 需要响应 unplug 请求。我们发完后给 1s
// settle 再 add; 实际生产代码会用 DEVICE_DELETED event 通知, 这里调试工具
// 简化处理。

import Foundation
import ArgumentParser
import HVMBundle
import HVMBackendQEMU

struct NICSwapCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "nic-swap",
        abstract: "热拔旧 NIC, 换 driver 热插新 NIC (netdev 保留)"
    )

    @Argument(help: "VM 名字或 bundle 路径")
    var vm: String

    @Argument(help: "要换掉的 NIC device id (QMP 里的 id, 如 nic_525400XXYY)")
    var oldID: String

    @Argument(help: "新 driver, 如 virtio-net-pci / e1000e / rtl8139")
    var newDriver: String

    @Option(name: .long, help: "新 NIC device id, 默认复用旧 id")
    var newID: String?

    @Option(name: .long, help: "关联 netdev id, 默认从旧 NIC 取")
    var netdev: String?

    @Option(name: .long, help: "挂到哪个 pcie-root-port, 默认 rp0")
    var bus: String = "rp0"

    @Option(name: .long, help: "mac 地址 (默认让 QEMU 自选)")
    var mac: String?

    @Option(name: .long, help: "device_del 后等几秒再 add")
    var settle: Double = 1.5

    mutating func run() async throws {
        let bundle = try VMLocator.resolve(vm)

        // 先 del
        _ = try await runQMPRaw(bundle: bundle,
                                command: "device_del",
                                arguments: ["id": oldID])
        print("==> device_del \(oldID)")

        try? await Task.sleep(nanoseconds: UInt64(settle * 1_000_000_000))

        // 再 add
        var args: [String: Any] = [
            "driver": newDriver,
            "id": newID ?? oldID,
            "bus": bus,
        ]
        if let nd = netdev {
            args["netdev"] = nd
        }
        if let mac = mac, !mac.isEmpty {
            args["mac"] = mac
        }
        _ = try await runQMPRaw(bundle: bundle,
                                command: "device_add",
                                arguments: args)
        print("==> device_add driver=\(newDriver) id=\(args["id"]!) bus=\(bus)")
    }
}
