// HostNetworkInterface —— 枚举宿主机可用于桥接的以太网/Wi-Fi 接口
//
// 用途:
// - New VM Wizard / Settings 的 "桥接接口" picker 数据源
// - VMnetSupervisor 判断用户选的 iface 当前是否 link up
//
// 过滤策略(不把虚拟/内部接口暴露给用户):
// - 跳过 lo0(回环)、utun*(VPN tunnel)、awdl*(AirDrop)、llw*(low-latency Wi-Fi)
// - 跳过 bridge*(系统桥)、ap*(AP 模式)、anpi*(Apple Network Private Interface)
// - 保留 en*(Ethernet/Wi-Fi)、以及 pktap*(抓包接口, 极少见但有人用)

import Foundation
import Darwin

/// 宿主机一个可桥接的网络接口快照
public struct HostNetworkInterface: Sendable, Hashable, Identifiable {
    public var id: String { name }
    /// BSD 名, 如 `en0`
    public var name: String
    /// 接口是否 UP 且有 IPv4 地址(一般代表"当前能用")
    public var isActive: Bool
    /// 第一个 IPv4 地址(UP 时才有), 仅用于 UI 展示
    public var ipv4: String?

    public init(name: String, isActive: Bool, ipv4: String?) {
        self.name = name
        self.isActive = isActive
        self.ipv4 = ipv4
    }

    /// UI 展示名, 形如 "en0 — 192.168.1.101" / "en1 — (未连接)"
    public var displayLabel: String {
        if let ip = ipv4, !ip.isEmpty {
            return "\(name) — \(ip)"
        }
        return isActive ? "\(name) — (无 IPv4)" : "\(name) — (未连接)"
    }
}

public enum HostNetworkInterfaces {
    /// 扫描当前宿主机, 返回适合用于 vmnet bridged 桥接的接口列表.
    /// 排序: 活跃优先 + en0/en1 前置 + 字母序兜底.
    public static func list() -> [HostNetworkInterface] {
        var raw: [String: (ipv4: String?, isUp: Bool)] = [:]

        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let start = head else { return [] }
        defer { freeifaddrs(head) }

        var p: UnsafeMutablePointer<ifaddrs>? = start
        while let cur = p {
            defer { p = cur.pointee.ifa_next }
            let name = String(cString: cur.pointee.ifa_name)
            guard isBridgeCandidate(name: name) else { continue }

            let flags = cur.pointee.ifa_flags
            let isUp = (flags & UInt32(IFF_UP)) != 0 && (flags & UInt32(IFF_RUNNING)) != 0

            var entry = raw[name] ?? (ipv4: nil, isUp: false)
            if isUp { entry.isUp = true }

            // IPv4 地址提取(可能要遍历多条 ifaddrs 才碰到 AF_INET 的那一条)
            if let sa = cur.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) {
                var storage = sockaddr_storage()
                memcpy(&storage, sa, Int(sa.pointee.sa_len))
                let ip = withUnsafePointer(to: &storage) { sp -> String? in
                    sp.withMemoryRebound(to: sockaddr.self, capacity: 1) { sap -> String? in
                        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        let rc = getnameinfo(sap, socklen_t(sap.pointee.sa_len),
                                             &host, socklen_t(host.count),
                                             nil, 0, NI_NUMERICHOST)
                        return rc == 0 ? String(cString: host) : nil
                    }
                }
                if entry.ipv4 == nil { entry.ipv4 = ip }
            }

            raw[name] = entry
        }

        let items = raw.map { (name, v) in
            HostNetworkInterface(name: name,
                                 isActive: v.isUp && v.ipv4 != nil,
                                 ipv4: v.ipv4)
        }
        return items.sorted { lhs, rhs in
            if lhs.isActive != rhs.isActive { return lhs.isActive }
            return lhs.name < rhs.name
        }
    }

    /// 默认要桥接的接口. 优先选活跃的 en0, 其次任意活跃 en*, 再其次第一个活跃接口, 最后 en0 兜底.
    public static func recommendedDefault() -> String {
        let all = list()
        if let en0 = all.first(where: { $0.name == "en0" && $0.isActive }) { return en0.name }
        if let enX = all.first(where: { $0.name.hasPrefix("en") && $0.isActive }) { return enX.name }
        if let any = all.first(where: { $0.isActive }) { return any.name }
        return "en0"
    }

    private static func isBridgeCandidate(name: String) -> Bool {
        // 白名单式过滤: 只认 en* 和 pktap*
        if name.hasPrefix("en") { return true }
        if name.hasPrefix("pktap") { return true }
        return false
    }
}
