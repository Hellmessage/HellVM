// qmp / pci-tree —— 基于 QMPClient 的观察类命令
//
// qmp:      发任意 QMP 命令, 打印返回的 JSON (整个 "return" 对象)
// pci-tree: query-pci 的语法糖, 把嵌套的 bus/devices 数组扁平化成人类可读

import Foundation
import ArgumentParser
import HVMBundle
import HVMBackendQEMU

// MARK: - qmp

struct QMPCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "qmp",
        abstract: "发任意 QMP 命令 (万能瑞士军刀)",
        discussion: """
        示例:
          hvmdbg qmp Windows11 query-status
          hvmdbg qmp Windows11 query-pci
          hvmdbg qmp Windows11 human-monitor-command '{"command-line":"info network"}'
        """
    )

    @Argument(help: "VM 名字或 bundle 路径")
    var vm: String

    @Argument(help: "QMP 命令名")
    var command: String

    @Argument(help: "arguments 的 JSON 对象 (如 '{\"id\":\"nic0\"}')")
    var argsJSON: String?

    mutating func run() async throws {
        let bundle = try VMLocator.resolve(vm)
        let args: [String: Any]
        if let s = argsJSON, !s.isEmpty {
            guard let data = s.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                throw ProbeError.protocolError("arguments 必须是合法 JSON object: \(s)")
            }
            args = obj
        } else {
            args = [:]
        }

        let result = try await runQMPRaw(bundle: bundle, command: command, arguments: args)
        // pretty print. JSONSerialization 要求顶层是 array/dict, 把其它类型包一层。
        let obj: Any
        if JSONSerialization.isValidJSONObject(result) {
            obj = result
        } else {
            obj = ["return": result]
        }
        let data = try JSONSerialization.data(
            withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]
        )
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0a]))
    }
}

// MARK: - pci-tree

struct PciTreeCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pci-tree",
        abstract: "query-pci 的格式化版本, 按 bus 树展示"
    )

    @Argument(help: "VM 名字或 bundle 路径")
    var vm: String

    mutating func run() async throws {
        let bundle = try VMLocator.resolve(vm)
        let raw = try await runQMPRaw(bundle: bundle, command: "query-pci", arguments: [:])
        guard let arr = raw as? [[String: Any]] else {
            throw ProbeError.protocolError("query-pci 返回不是数组: \(raw)")
        }
        renderPciRoot(arr)
    }

    private func renderPciRoot(_ arr: [[String: Any]]) {
        for entry in arr {
            if let bus = entry["bus"] as? Int {
                print("== Bus \(bus) ==")
            }
            if let devices = entry["devices"] as? [[String: Any]] {
                renderDevices(devices, indent: "")
            }
        }
    }

    private func renderDevices(_ devices: [[String: Any]], indent: String) {
        for dev in devices {
            let slot = dev["slot"] as? Int ?? -1
            let fn   = dev["function"] as? Int ?? 0
            let qdevID = dev["qdev_id"] as? String ?? ""
            let classInfo = dev["class_info"] as? [String: Any]
            let className = classInfo?["desc"] as? String ?? ""
            let devClass  = (dev["id"] as? [String: Any])?["device"].flatMap { "\($0)" } ?? ""
            let idLabel = qdevID.isEmpty ? devClass : qdevID
            print("\(indent)\(String(format: "%02x:%02x.%d", 0, slot, fn))  \(className)  [\(idLabel)]")
            // 某些 device 带 pci_bridge (root port 等), 递归
            if let bridge = dev["pci_bridge"] as? [String: Any],
               let subs = bridge["devices"] as? [[String: Any]] {
                renderDevices(subs, indent: indent + "    └─ ")
            }
        }
    }
}

// MARK: - 内部辅助

/// 在 QMPClient.withSession 里发一次命令. QMPClient.execute 已把返回扒掉 "return" 外壳,
/// 所以返回的 dict 就是 result 本身(某些命令如 query-pci 其实是数组,但 execute 会归一成 dict wrap)。
func runQMP(bundle: VMBundle, command: String, arguments: [String: Any]) async throws -> [String: Any] {
    let sockPath = bundle.qmpSocketURL.path
    do {
        return try await QMPClient.withSession(socketPath: sockPath) { qmp in
            try await qmp.execute(command, arguments: arguments)
        }
    } catch {
        throw ProbeError.socketConnectFailed(
            "qmp @\(sockPath): \(error.localizedDescription). VM 可能没在跑。")
    }
}

/// 返回值是数组时走 executeRaw, 自己解 "return" 壳。给 pci-tree 这种用。
func runQMPRaw(bundle: VMBundle, command: String, arguments: [String: Any]) async throws -> Any {
    let sockPath = bundle.qmpSocketURL.path
    do {
        return try await QMPClient.withSession(socketPath: sockPath) { qmp in
            try await qmp.executeRaw(command, arguments: arguments)
        }
    } catch {
        throw ProbeError.socketConnectFailed(
            "qmp @\(sockPath): \(error.localizedDescription). VM 可能没在跑。")
    }
}
