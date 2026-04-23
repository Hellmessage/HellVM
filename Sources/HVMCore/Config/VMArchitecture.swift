// VM 架构枚举 —— 决定启动时走 Virtualization 还是 QEMU 后端
import Foundation

/// 虚拟机 CPU 架构
public enum VMArchitecture: String, Codable, Sendable, CaseIterable {
    case aarch64
    case x86_64
    case riscv64

    /// 宿主机架构,用于判断是否可用 Virtualization.framework
    public static var host: VMArchitecture {
        #if arch(arm64)
        return .aarch64
        #elseif arch(x86_64)
        return .x86_64
        #else
        fatalError("不支持的宿主机架构")
        #endif
    }

    /// 是否与宿主机同架构(可用 VZ 后端)
    public var isHostNative: Bool {
        self == .host
    }
}
