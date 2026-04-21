// hellvm 命令行入口
import ArgumentParser
import Foundation
import HVMCore
import HVMBundle

@main
struct HellVM: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hellvm",
        abstract: "HellVM 虚拟机命令行",
        version: "0.1.0",
        subcommands: [List.self, Info.self, Start.self, Stop.self]
    )
}

// MARK: - hellvm list

struct List: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "列出所有虚拟机"
    )

    func run() async throws {
        let bundles = try VMBundle.listAll()
        if bundles.isEmpty {
            print("(尚无虚拟机)")
            print("默认库位置:\(VMBundle.defaultLibraryURL.path)")
            return
        }
        for b in bundles {
            if let cfg = try? b.loadConfig() {
                print("\(cfg.name)\t\(cfg.architecture.rawValue)\t\(cfg.cpuCount) CPU\t\(cfg.memoryMB) MB")
            } else {
                print("<损坏> \(b.url.lastPathComponent)")
            }
        }
    }
}

// MARK: - hellvm info <name>

struct Info: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "info",
        abstract: "查看 VM 详情"
    )

    @Argument(help: "VM 名称") var name: String

    func run() async throws {
        throw VMError.notImplemented("info —— 待 P1")
    }
}

// MARK: - hellvm start <name>

struct Start: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "start",
        abstract: "启动 VM"
    )

    @Argument(help: "VM 名称") var name: String

    func run() async throws {
        throw VMError.notImplemented("start —— 待 P1")
    }
}

// MARK: - hellvm stop <name>

struct Stop: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop",
        abstract: "停止 VM"
    )

    @Argument(help: "VM 名称") var name: String
    @Flag(name: .shortAndLong, help: "强制停止(等同断电)") var force: Bool = false

    func run() async throws {
        throw VMError.notImplemented("stop —— 待 P1")
    }
}
