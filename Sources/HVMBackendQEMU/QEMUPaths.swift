// QEMU 二进制与固件路径发现
// 只使用自编译产物:<项目根>/Vendor/qemu/
// 开发调试时可用 HVM_QEMU_PREFIX 覆盖(例如临时指向 brew 的 qemu 做对比测试)
import Foundation
import HVMCore

/// QEMU 可执行文件 + 固件路径发现
public struct QEMUPaths: Sendable {
    /// QEMU 安装前缀(含 bin/ share/qemu/)
    public let prefix: URL

    public func qemuSystem(_ arch: VMArchitecture) -> URL {
        let name: String
        switch arch {
        case .aarch64:  name = "qemu-system-aarch64"
        case .x86_64:   name = "qemu-system-x86_64"
        case .riscv64:  name = "qemu-system-riscv64"
        }
        return prefix.appendingPathComponent("bin").appendingPathComponent(name)
    }

    public var qemuImg: URL {
        prefix.appendingPathComponent("bin/qemu-img")
    }

    /// EDK2 ARM64 UEFI 固件(只读代码段)
    public var edk2AArch64Code: URL {
        prefix.appendingPathComponent("share/qemu/edk2-aarch64-code.fd")
    }

    /// EDK2 ARM64 UEFI 变量段模板(每 VM 应复制一份到 bundle 内部)
    public var edk2ArmVars: URL {
        prefix.appendingPathComponent("share/qemu/edk2-arm-vars.fd")
    }

    /// 查找顺序:HVM_QEMU_PREFIX → .app 内部 (Contents/Resources/qemu) → 项目 Vendor/qemu
    public static func discover() throws -> QEMUPaths {
        let fm = FileManager.default

        // 1. 环境变量覆盖
        if let override = ProcessInfo.processInfo.environment["HVM_QEMU_PREFIX"] {
            let url = URL(fileURLWithPath: override)
            guard fm.isExecutableFile(atPath: url.appendingPathComponent("bin/qemu-img").path) else {
                throw VMError.backendUnavailable("HVM_QEMU_PREFIX 指向的路径无效:\(override)")
            }
            return QEMUPaths(prefix: url)
        }

        // 2. App Bundle 内部(生产模式:打包后的 .app)
        if let res = Bundle.main.resourcePath {
            let prefix = URL(fileURLWithPath: res).appendingPathComponent("qemu")
            if fm.isExecutableFile(atPath: prefix.appendingPathComponent("bin/qemu-img").path) {
                return QEMUPaths(prefix: prefix)
            }
        }

        // 3. 项目 Vendor/qemu(开发模式)
        if let vendor = vendorPrefix() {
            return QEMUPaths(prefix: vendor)
        }

        throw VMError.backendUnavailable(
            """
            未找到 QEMU 安装。可以:
              - 在项目根执行 scripts/build-qemu.sh(开发)
              - 使用已打包的 HellVM.app(生产)
              - 设置 HVM_QEMU_PREFIX 指向已有 QEMU 前缀
            """
        )
    }

    /// 从可执行文件位置回溯项目根下的 Vendor/qemu
    private static func vendorPrefix() -> URL? {
        var root = URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
        for _ in 0..<6 {
            let probe = root.appendingPathComponent("Vendor/qemu/bin/qemu-img")
            if FileManager.default.isExecutableFile(atPath: probe.path) {
                return root.appendingPathComponent("Vendor/qemu")
            }
            root = root.deletingLastPathComponent()
        }
        return nil
    }
}
