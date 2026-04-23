// VMnetSupervisor —— socket_vmnet daemon 的生命周期代理
//
// 职责:
// - 判断某个 NetworkConfig 的 socket 当前是否就绪(可直接启动 VM)
// - 缺失时通过 osascript 触发 sudo 权限弹窗, 跑 install-vmnet-daemons.sh 批量装
//   shared/host/bridged(按当前所有 VM 用到的 interfaces) 三种 daemon
//
// 为什么不用 SMJobBless: 那需要独立的 helper bundle 签名 + Info.plist 约束, 重得离谱.
// 对于用户一次性安装 launchd daemon 这种"偶尔执行 + 需要 root"的操作, osascript
// administrator privileges 弹 Touch ID / 密码框是 macOS 上公认轻量的方案.

import Foundation
import HVMCore
import HVMBundle

public struct VMnetStatus: Sendable {
    public var required: Bool          // 当前 config 是否需要 vmnet(.vmnet* 模式)
    public var socketPath: String?     // 需要的 socket 路径
    public var socketExists: Bool      // 路径是否存在(daemon 起了就有)
    public var healthy: Bool { !required || socketExists }
}

@MainActor
public enum VMnetSupervisor {

    // MARK: - 状态查询

    /// 不触发副作用的状态探测. 供 Settings UI / 启动前 preflight 共用.
    public static func status(for net: NetworkConfig) -> VMnetStatus {
        let requiresVmnet: Bool
        switch net.mode {
        case .vmnetShared, .vmnetHost, .vmnetBridged: requiresVmnet = true
        case .user, .none: requiresVmnet = false
        }
        let path = net.effectiveSocketPath
        let exists = path.map { FileManager.default.fileExists(atPath: $0) } ?? false
        return VMnetStatus(required: requiresVmnet,
                           socketPath: path,
                           socketExists: exists)
    }

    /// 列出当前系统上已就绪的 vmnet socket, 给 "网络诊断" 面板展示.
    public static func presentSockets() -> (shared: Bool, host: Bool, bridged: [String]) {
        let fm = FileManager.default
        let shared = fm.fileExists(atPath: SocketPaths.vmnetShared)
        let host   = fm.fileExists(atPath: SocketPaths.vmnetHost)
        // bridged.<iface> 扫一遍 /var/run
        var bridged: [String] = []
        let runURL = URL(fileURLWithPath: "/var/run")
        if let items = try? fm.contentsOfDirectory(atPath: runURL.path) {
            for name in items {
                let prefix = (SocketPaths.vmnetBase as NSString).lastPathComponent + ".bridged."
                if name.hasPrefix(prefix) {
                    bridged.append(String(name.dropFirst(prefix.count)))
                }
            }
        }
        return (shared, host, bridged.sorted())
    }

    // MARK: - 安装 daemon

    /// 收集"当前所有 VM 用到的 bridged interfaces", 加上必要的 shared/host 一起
    /// 装进 launchd. 一次 sudo 弹窗, 一次到位.
    ///
    /// 会走 osascript administrator privileges 弹授权框. 用户拒绝时 throw.
    public static func installAllDaemons(extraBridgedInterfaces: [String] = []) async throws {
        var bridgedSet = Set<String>()
        if let items = try? VMBundle.listAll() {
            for b in items {
                guard let cfg = try? b.loadConfig() else { continue }
                for net in cfg.networks where net.mode == .vmnetBridged {
                    if let iface = net.bridgedInterface, !iface.isEmpty {
                        bridgedSet.insert(iface)
                    }
                }
            }
        }
        for iface in extraBridgedInterfaces where !iface.isEmpty {
            bridgedSet.insert(iface)
        }

        let script = try scriptPath()
        var args = [script]
        args.append(contentsOf: bridgedSet.sorted())
        try await runWithAdminPrivileges(args: args)
    }

    /// 卸载全部 HellVM 管理的 vmnet daemon.
    public static func uninstallAllDaemons() async throws {
        let script = try scriptPath()
        try await runWithAdminPrivileges(args: [script, "--uninstall"])
    }

    // MARK: - 内部: 脚本定位 + 提权执行

    private enum VMnetError: LocalizedError {
        case scriptNotFound
        case userCancelled
        case osaFailed(String)

        var errorDescription: String? {
            switch self {
            case .scriptNotFound:
                return "找不到 install-vmnet-daemons.sh(开发环境在 scripts/, 打包后在 .app/Contents/Resources/scripts/)"
            case .userCancelled:
                return "用户取消了授权"
            case .osaFailed(let msg):
                return "osascript 执行失败: \(msg)"
            }
        }
    }

    /// 查脚本路径: 先 .app 内嵌, 再项目根 scripts/(开发模式)
    private static func scriptPath() throws -> String {
        if let res = Bundle.main.resourcePath {
            let embedded = URL(fileURLWithPath: res)
                .appendingPathComponent("scripts/install-vmnet-daemons.sh")
            if FileManager.default.isExecutableFile(atPath: embedded.path) {
                return embedded.path
            }
        }
        // 开发模式: 从可执行文件回溯找项目根
        let marker = "scripts/install-vmnet-daemons.sh"
        if let root = ProjectRootFinder.ancestor(containing: marker) {
            return root.appendingPathComponent(marker).path
        }
        throw VMnetError.scriptNotFound
    }

    /// 用 osascript 触发 Touch ID / 密码授权框执行 `sudo bash <script> <args>`.
    /// 注意: 参数需要做 AppleScript 字符串转义(双引号和反斜杠).
    private static func runWithAdminPrivileges(args: [String]) async throws {
        let shellLine = args.map { shellEscape($0) }.joined(separator: " ")
        let appleScriptBody = "do shell script \"/bin/bash \(escapeForAppleScript(shellLine))\" with administrator privileges"

        log.info(.backend, "vmnet: installing daemons via osascript")

        try await Task.detached(priority: .userInitiated) {
            let proc = Process()
            proc.launchPath = "/usr/bin/osascript"
            proc.arguments = ["-e", appleScriptBody]

            let errPipe = Pipe()
            let outPipe = Pipe()
            proc.standardError = errPipe
            proc.standardOutput = outPipe
            try proc.run()
            proc.waitUntilExit()

            if proc.terminationStatus != 0 {
                let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                                 encoding: .utf8) ?? ""
                // 用户点取消 osascript 会返回 errno -128
                if err.contains("-128") || err.lowercased().contains("user canceled") {
                    throw VMnetError.userCancelled
                }
                throw VMnetError.osaFailed(err.isEmpty ? "exit \(proc.terminationStatus)" : err)
            }
        }.value
    }

    /// 给 shell 层转义(外层包双引号, 内部的 " 和 \\ 要加反斜杠)
    private static func shellEscape(_ s: String) -> String {
        var out = s
        out = out.replacingOccurrences(of: "\\", with: "\\\\")
        out = out.replacingOccurrences(of: "\"", with: "\\\"")
        return "\"" + out + "\""
    }

    /// 给 AppleScript 层转义(外层已是 do shell script "...", 内部 " 要变 \")
    private static func escapeForAppleScript(_ s: String) -> String {
        var out = s
        out = out.replacingOccurrences(of: "\\", with: "\\\\")
        out = out.replacingOccurrences(of: "\"", with: "\\\"")
        return out
    }
}
