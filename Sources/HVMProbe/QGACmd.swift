// hvmdbg qga —— QEMU Guest Agent 通道的调试子命令
//
// 走 HVMBackendQEMU.QGAClient, 通过 <bundle>/qga.sock 向 guest 内的
// qemu-guest-agent 发 JSON-RPC。前置条件: guest 装了 qemu-guest-agent:
//   Linux   apt/yum install qemu-guest-agent, 启动 systemd 服务
//   Windows 来自 virtio-win.iso 里的 qemu-ga 包(HellVM 自动挂载)
//
// 子命令:
//   ping      —— 探活 guest agent
//   exec      —— 跑一条命令, 捕获 stdout/stderr
//   read      —— 读 guest 里的任意文件
//   clipboard —— 抓 guest 当前剪贴板文本(走 powershell Get-Clipboard 或 xclip/wl-paste)
//
// clipboard 子命令相对 hvmdbg clipboard(走 vdagent)的区别:
//   - vdagent 版: 被动, 只响应 guest 主动复制, 需要 spice-guest-tools
//   - qga 版:   主动 pull 当前剪贴板, 需要 qemu-guest-agent, 任何时候都能拉

import Foundation
import ArgumentParser
import AppKit
import HVMBundle
import HVMBackendQEMU

struct QGACmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "qga",
        abstract: "QEMU Guest Agent 通道 (ping/exec/read/clipboard)",
        subcommands: [
            QGAPingCmd.self,
            QGAExecCmd.self,
            QGAReadCmd.self,
            QGAClipboardCmd.self,
        ]
    )
}

// MARK: - ping

struct QGAPingCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ping",
        abstract: "探活 guest-agent. 存活返回 0, 无响应返回非零"
    )

    @Argument(help: "VM 名字或 bundle 路径")
    var vm: String

    mutating func run() async throws {
        let bundle = try VMLocator.resolve(vm)
        try await QGAClient.withSession(socketPath: bundle.qgaSocketURL.path) { qga in
            if await qga.ping() {
                print("==> qga ping OK")
            } else {
                throw ProbeError.protocolError("qga 无响应 (guest 侧 qemu-guest-agent 未运行?)")
            }
        }
    }
}

// MARK: - exec

struct QGAExecCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "exec",
        abstract: "在 guest 里跑一条命令, 打印 stdout / stderr / exit-code"
    )

    @Argument(help: "VM 名字或 bundle 路径")
    var vm: String

    @Argument(help: "可执行文件绝对路径 (Linux: /usr/bin/cat / Windows: powershell.exe)")
    var path: String

    @Argument(parsing: .captureForPassthrough, help: "传给命令的参数, 原样透传")
    var args: [String] = []

    @Option(name: .long, help: "总超时(秒)")
    var timeout: Double = 60

    @Flag(name: .long, help: "只打印 stdout, 隐藏 stderr 和 exit-code 行(脚本友好)")
    var quiet: Bool = false

    mutating func run() async throws {
        let bundle = try VMLocator.resolve(vm)
        try await QGAClient.withSession(socketPath: bundle.qgaSocketURL.path) { qga in
            let (code, out, err) = try await qga.execAndWait(
                path: path, args: args, timeoutSeconds: timeout
            )
            FileHandle.standardOutput.write(out)
            if !quiet {
                if !err.isEmpty {
                    FileHandle.standardError.write(Data("---- stderr ----\n".utf8))
                    FileHandle.standardError.write(err)
                    if err.last != 0x0a {
                        FileHandle.standardError.write(Data("\n".utf8))
                    }
                }
                FileHandle.standardError.write(Data("---- exit=\(code) ----\n".utf8))
            }
            if code != 0 {
                throw ExitCode(Int32(truncatingIfNeeded: code))
            }
        }
    }
}

// MARK: - read

struct QGAReadCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "read",
        abstract: "读 guest 里的任意文件, 二进制直接写 stdout"
    )

    @Argument(help: "VM 名字或 bundle 路径")
    var vm: String

    @Argument(help: "guest 里的文件绝对路径")
    var path: String

    mutating func run() async throws {
        let bundle = try VMLocator.resolve(vm)
        try await QGAClient.withSession(socketPath: bundle.qgaSocketURL.path) { qga in
            let data = try await qga.readFile(path: path)
            FileHandle.standardOutput.write(data)
        }
    }
}

// MARK: - clipboard

enum QGAOSKind: String, ExpressibleByArgument {
    case windows, linux
}

struct QGAClipboardCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clipboard",
        abstract: "主动抓 guest 当前剪贴板文本 (走 powershell / xclip / wl-paste)"
    )

    @Argument(help: "VM 名字或 bundle 路径")
    var vm: String

    @Option(name: .long, help: "guest OS. windows=powershell Get-Clipboard, linux=xclip/wl-paste")
    var os: QGAOSKind = .windows

    @Option(name: .long, help: "Linux 下读哪个剪贴板工具. auto → 先 wl-paste, 失败 xclip")
    var tool: String = "auto"

    @Flag(name: .long, help: "同时写入 host 剪贴板 (NSPasteboard)")
    var copy: Bool = false

    mutating func run() async throws {
        let bundle = try VMLocator.resolve(vm)
        let text = try await QGAClient.withSession(socketPath: bundle.qgaSocketURL.path) { qga in
            switch os {
            case .windows:
                return try await pullWindowsClipboard(qga: qga)
            case .linux:
                return try await pullLinuxClipboard(qga: qga, tool: tool)
            }
        }
        FileHandle.standardOutput.write(Data(text.utf8))
        if copy {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
            FileHandle.standardError.write(
                Data("==> 已写入 host 剪贴板 (\(text.utf8.count) 字节)\n".utf8))
        }
    }

    private func pullWindowsClipboard(qga: QGAClient) async throws -> String {
        // -NoProfile 加快启动; [Console]::OutputEncoding 确保 UTF-8 输出。
        // Get-Clipboard -Raw 保持原始换行和字符不做处理。
        let script = """
        [Console]::OutputEncoding=[System.Text.Encoding]::UTF8;Get-Clipboard -Raw
        """
        let (code, out, err) = try await qga.execAndWait(
            path: "powershell.exe",
            args: ["-NoProfile", "-NonInteractive", "-Command", script],
            timeoutSeconds: 15
        )
        guard code == 0 else {
            let errMsg = String(data: err, encoding: .utf8) ?? ""
            throw ProbeError.protocolError("powershell Get-Clipboard exit=\(code): \(errMsg)")
        }
        var text = String(data: out, encoding: .utf8) ?? ""
        // Get-Clipboard -Raw 有时追加一个 trailing \r\n, 保留还是剥掉有争议;
        // 保守策略: 仅去掉最末尾 1 个换行, 中间原样保留
        if text.hasSuffix("\r\n") {
            text.removeLast(2)
        } else if text.hasSuffix("\n") {
            text.removeLast()
        }
        return text
    }

    private func pullLinuxClipboard(qga: QGAClient, tool: String) async throws -> String {
        // tool=auto: 优先 wl-paste (Wayland), 失败再 xclip (X11). 两个都没就抛错。
        let attempts: [(String, [String])]
        switch tool {
        case "auto":
            attempts = [
                ("/usr/bin/wl-paste", []),
                ("/usr/bin/xclip",    ["-o", "-selection", "clipboard"]),
            ]
        case "wl-paste":
            attempts = [("/usr/bin/wl-paste", [])]
        case "xclip":
            attempts = [("/usr/bin/xclip", ["-o", "-selection", "clipboard"])]
        default:
            throw ProbeError.protocolError("未知 --tool: \(tool) (可选: auto/wl-paste/xclip)")
        }

        var lastErr = ""
        for (path, args) in attempts {
            do {
                let (code, out, err) = try await qga.execAndWait(
                    path: path, args: args, timeoutSeconds: 10)
                if code == 0 {
                    return String(data: out, encoding: .utf8) ?? ""
                }
                lastErr = "\(path) exit=\(code): \(String(data: err, encoding: .utf8) ?? "")"
            } catch {
                lastErr = "\(path): \(error.localizedDescription)"
            }
        }
        throw ProbeError.protocolError("Linux 剪贴板读取失败: \(lastErr)")
    }
}
