// hvmdbg clipboard —— 把 guest 剪贴板文本抓到 host
//
// 走 HVMDisplay.VDAgentChannel 公开 API, 零新协议实现。原理:
//   1. connect vdagent.sock, 完成 ANNOUNCE_CAPABILITIES 握手
//   2. 监听 guest 侧 spice-vdagent 发来的 CLIPBOARD_GRAB
//   3. 自动回 CLIPBOARD_REQUEST (UTF8_TEXT), 收到 CLIPBOARD 后 onClipboardText 回调
//   4. 回调里把文本写 stdout, 可选 --copy 写入 host NSPasteboard
//
// 前置: guest 装了 spice-guest-tools (Windows) 或 spice-vdagent (Linux).
// 限制: 只响应 guest 主动复制, 不能"主动 pull 当前剪贴板"(协议限制)。

import Foundation
import ArgumentParser
import AppKit
import HVMBundle
import HVMDisplay

struct ClipboardCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clipboard",
        abstract: "抓 guest 剪贴板文本(需 spice-guest-tools)",
        subcommands: [ClipboardGetCmd.self, ClipboardWatchCmd.self]
    )
}

// MARK: - get —— 阻塞等一次 GRAB, 拿到就退出

struct ClipboardGetCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "等待 guest 下一次复制, 把文本打印到 stdout"
    )

    @Argument(help: "VM 名字或 bundle 路径")
    var vm: String

    @Option(name: .long, help: "最多等几秒, 超时退出码 2")
    var timeout: Double = 60

    @Flag(name: .long, help: "除了 stdout, 同时写入 host 剪贴板 (NSPasteboard)")
    var copy: Bool = false

    mutating func run() async throws {
        let bundle = try VMLocator.resolve(vm)
        let ch = VDAgentChannel()
        do {
            try ch.connect(socketPath: bundle.spiceAgentSocketURL.path)
        } catch {
            throw ProbeError.socketConnectFailed("vdagent: \(error.localizedDescription)")
        }
        defer { ch.close() }

        let receivedText = AsyncValue<String>()
        ch.onClipboardText = { text in
            receivedText.setIfEmpty(text)
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let text = receivedText.get() {
                // stdout 直接写, 不加换行避免污染二进制粘贴
                FileHandle.standardOutput.write(Data(text.utf8))
                if copy {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(text, forType: .string)
                    FileHandle.standardError.write(Data("==> 已写入 host 剪贴板 (\(text.utf8.count) 字节)\n".utf8))
                }
                return
            }
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }
        throw ProbeError.protocolError("等 guest 复制超时 (\(timeout)s). 检查 guest 是否装了 spice-guest-tools 并且有在复制。")
    }
}

// MARK: - watch —— 长连接, 每次 guest 复制都打印一行

struct ClipboardWatchCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "watch",
        abstract: "持续监听 guest 剪贴板, 每次复制打印一行到 stdout (Ctrl+C 退出)"
    )

    @Argument(help: "VM 名字或 bundle 路径")
    var vm: String

    @Flag(name: .long, help: "每次都同步到 host 剪贴板 (NSPasteboard)")
    var copy: Bool = false

    mutating func run() async throws {
        let bundle = try VMLocator.resolve(vm)
        let ch = VDAgentChannel()
        do {
            try ch.connect(socketPath: bundle.spiceAgentSocketURL.path)
        } catch {
            throw ProbeError.socketConnectFailed("vdagent: \(error.localizedDescription)")
        }
        defer { ch.close() }

        let shouldCopy = copy
        ch.onClipboardText = { text in
            // 每段前加 header, 带字节数和时间戳, 方便 tail 看
            let now = ISO8601DateFormatter().string(from: Date())
            let header = "---- [\(now)] \(text.utf8.count) bytes ----\n"
            FileHandle.standardOutput.write(Data(header.utf8))
            FileHandle.standardOutput.write(Data(text.utf8))
            FileHandle.standardOutput.write(Data("\n".utf8))
            if shouldCopy {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(text, forType: .string)
            }
        }

        FileHandle.standardError.write(Data("==> 监听中, Ctrl+C 退出\n".utf8))
        // 挂住不返回, 让读循环在后台持续工作
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }
}

// MARK: - 辅助

/// 线程安全的"一次写入"容器, 用于把读循环 callback 的文本传给主 Task。
/// VDAgentChannel 的 onClipboardText 在独立线程上被同步调用, 不能直接 await。
private final class AsyncValue<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T?

    func setIfEmpty(_ v: T) {
        lock.lock(); defer { lock.unlock() }
        if value == nil { value = v }
    }

    func get() -> T? {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}
