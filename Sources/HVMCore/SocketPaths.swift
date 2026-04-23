// socket_vmnet daemon 的标准 socket 路径集中在此
//
// 路径由 Homebrew 的 socket_vmnet plist / scripts/install-vmnet-daemons.sh
// 约定, 运行期由多处消费 (QEMU 后端构造 -netdev, Supervisor 存在性检查,
// NIC 热插拔等)。集中成常量避免散落硬编的字面量漂移。
import Foundation

public enum SocketPaths {
    /// socket_vmnet 默认基路径 (/var/run/socket_vmnet)
    /// Homebrew 的 launchd plist 和 install-vmnet-daemons.sh 保持一致
    public static let vmnetBase = "/var/run/socket_vmnet"

    /// shared 模式 (NAT+DHCP) socket
    public static var vmnetShared: String { vmnetBase }

    /// host-only 模式 socket
    public static var vmnetHost: String { vmnetBase + ".host" }

    /// bridged 模式 socket: 每块宿主 NIC 独立一个 daemon + 独立 socket
    public static func vmnetBridged(interface: String) -> String {
        vmnetBase + ".bridged.\(interface)"
    }
}
