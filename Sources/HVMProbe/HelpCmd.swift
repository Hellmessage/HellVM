// help —— hvmdbg 的帮助子命令
//
// 行为:
//   hvmdbg help                        打印按类别分组的概览 + 典型示例
//   hvmdbg help <sub>                  等价于 `hvmdbg <sub> --help`, 并追加静态示例
//   hvmdbg help <sub1> <sub2> ...      逐级下钻到嵌套子命令 (例: help qga exec)
//
// 实现说明:
//   - ArgumentParser 自带 `--help`, 但没有"分类概览 + 示例"的能力.
//   - 这里通过 `HVMDebug.configuration.subcommands` 走 subcommand 树, 拿到对应的
//     `ParsableCommand.Type` 再调用其 `.helpMessage()`, 输出和 `--help` 完全一致.
//   - 类别/示例用静态表 `categories` 维护. **新增子命令时必须同步在表里加一行**,
//     否则 `hvmdbg help` 概览里会漏掉.

import Foundation
import ArgumentParser

struct HelpCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "help",
        abstract: "查看 hvmdbg 子命令帮助 (不带参数=概览, 带参数=详细)",
        discussion: """
        示例:
          hvmdbg help                概览 + 示例
          hvmdbg help screenshot     screenshot 的详细参数
          hvmdbg help qga exec       嵌套子命令的详细参数
        """
    )

    @Argument(parsing: .remaining,
              help: "子命令路径, 省略则打印概览 (例: 'screenshot' 或 'qga exec')")
    var path: [String] = []

    func run() async throws {
        if path.isEmpty {
            printOverview()
            return
        }
        try printSubcommandHelp(path: path)
    }

    // MARK: - 概览数据

    private struct Entry {
        let name: String     // 顶层子命令名 (和 CommandConfiguration.commandName 对齐)
        let abstract: String // 一句话说明
        let example: String  // 典型调用示例
    }

    private struct Category {
        let title: String
        let entries: [Entry]
    }

    /// 顶层子命令的分类表. 新增顶层子命令必须同步更新这里, 否则概览会漏.
    /// abstract/示例以项目里真实的 CommandConfiguration / 参数为准.
    private static let categories: [Category] = [
        .init(title: "生命周期", entries: [
            .init(name: "start",
                  abstract: "后台启动 VM (独立 process group, hvmdbg 退出后 VM 继续跑)",
                  example: "hvmdbg start Windows11"),
            .init(name: "stop",
                  abstract: "停止 VM (默认 ACPI 软关机, --force SIGKILL 整 pg)",
                  example: "hvmdbg stop Windows11 --force"),
        ]),
        .init(title: "观察 guest", entries: [
            .init(name: "screenshot",
                  abstract: "抓 guest framebuffer 到 PNG",
                  example: "hvmdbg screenshot Windows11 -o /tmp/shot.png"),
            .init(name: "qmp",
                  abstract: "发任意 QMP 命令, 打印 JSON",
                  example: "hvmdbg qmp Windows11 query-status"),
            .init(name: "pci-tree",
                  abstract: "query-pci 的格式化版本, 按 bus 树展示",
                  example: "hvmdbg pci-tree Windows11"),
            .init(name: "clipboard",
                  abstract: "抓 guest 剪贴板文本 (被动等 guest 复制, 需 spice-guest-tools)",
                  example: "hvmdbg clipboard get Windows11"),
        ]),
        .init(title: "输入控制", entries: [
            .init(name: "move",
                  abstract: "鼠标 absolute move (guest 像素坐标系, 和 screenshot 对齐)",
                  example: "hvmdbg move Windows11 400 300"),
            .init(name: "click",
                  abstract: "鼠标点击 (先 move 再 down/up)",
                  example: "hvmdbg click Windows11 400 300 --button left"),
            .init(name: "scroll",
                  abstract: "滚轮. 正=向上, 负=向下",
                  example: "hvmdbg scroll Windows11 -120"),
            .init(name: "key",
                  abstract: "按一次键, 支持组合 (例 'ctrl+alt+del')",
                  example: "hvmdbg key Windows11 ctrl+alt+del"),
            .init(name: "type",
                  abstract: "键入字符串 (ASCII, 自动处理大小写/简单标点)",
                  example: "hvmdbg type Windows11 \"hello world\""),
        ]),
        .init(title: "Guest 交互", entries: [
            .init(name: "vdagent-resize",
                  abstract: "通过 spice-vdagent 触发 Windows guest 改分辨率",
                  example: "hvmdbg vdagent-resize Windows11 1920 1080"),
            .init(name: "qga",
                  abstract: "QEMU Guest Agent 通道 (ping/exec/read/clipboard)",
                  example: "hvmdbg qga exec Windows11 -- whoami"),
        ]),
        .init(title: "设备热插", entries: [
            .init(name: "nic-swap",
                  abstract: "热拔旧 NIC, 换 driver 热插新 NIC (netdev 保留)",
                  example: "hvmdbg nic-swap Windows11 --model e1000e"),
        ]),
        .init(title: "帮助", entries: [
            .init(name: "help",
                  abstract: "查看本帮助 (不带参数=概览, 带参数=详细)",
                  example: "hvmdbg help qga exec"),
        ]),
    ]

    /// 嵌套子命令的静态示例表, key 是完整路径 (用空格 join).
    /// 只覆盖二级及以下 —— 顶层示例已在 `categories` 里.
    private static let nestedExamples: [String: String] = [
        "clipboard get":   "hvmdbg clipboard get Windows11",
        "clipboard watch": "hvmdbg clipboard watch Windows11",
        "qga ping":        "hvmdbg qga ping Windows11",
        "qga exec":        "hvmdbg qga exec Windows11 -- whoami",
        "qga read":        "hvmdbg qga read Windows11 C:/Windows/System32/drivers/etc/hosts",
        "qga clipboard":   "hvmdbg qga clipboard Windows11",
    ]

    // MARK: - 概览输出

    private func printOverview() {
        print("hvmdbg —— HellVM 调试探针 (走项目既有 socket 协议做观察/操作)")
        print("")
        print("用法:")
        print("  hvmdbg <subcommand> [options] [args]")
        print("  hvmdbg help                   打印本概览")
        print("  hvmdbg help <subcommand>...   打印指定 (嵌套) 子命令的详细参数")
        print("")

        let nameWidth = 18
        for cat in Self.categories {
            print("【\(cat.title)】")
            for e in cat.entries {
                print("  " + pad(e.name, nameWidth) + e.abstract)
                print("  " + pad("", nameWidth) + "例: " + e.example)
            }
            print("")
        }

        print("所有命令的 <vm> 参数都接受:")
        print("  - bundle 名字 (~/Library/Application Support/HellVM/VMs/<name>.hellvm)")
        print("  - 绝对路径 (含 .hellvm 后缀的 bundle 目录)")
    }

    private func pad(_ s: String, _ width: Int) -> String {
        let count = s.count
        if count >= width { return s + " " }
        return s + String(repeating: " ", count: width - count)
    }

    // MARK: - 单个/嵌套子命令详细帮助

    private func printSubcommandHelp(path: [String]) throws {
        // 沿 subcommand 链路下钻
        var current: ParsableCommand.Type = HVMDebug.self
        var walked: [String] = []
        for name in path {
            guard let next = current.configuration.subcommands.first(where: {
                $0.configuration.commandName == name
            }) else {
                let avail = current.configuration.subcommands
                    .compactMap { $0.configuration.commandName }
                    .joined(separator: ", ")
                let prefix = walked.isEmpty ? "hvmdbg" : "hvmdbg " + walked.joined(separator: " ")
                let msg = """
                未知子命令: '\(name)' (在 `\(prefix)` 下)
                可用子命令: \(avail.isEmpty ? "(无)" : avail)
                """
                FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
                throw ExitCode.failure
            }
            current = next
            walked.append(name)
        }

        // ArgumentParser 内置帮助渲染, 和 `--help` 完全一致
        print(current.helpMessage())

        // 追加静态示例
        let fullKey = path.joined(separator: " ")
        let topLevel = path.first ?? ""
        let example: String? = {
            if let nested = Self.nestedExamples[fullKey] { return nested }
            if path.count == 1,
               let e = Self.categories
                   .flatMap({ $0.entries })
                   .first(where: { $0.name == topLevel }) {
                return e.example
            }
            return nil
        }()
        if let ex = example {
            print("示例:")
            print("  " + ex)
        }
    }
}
