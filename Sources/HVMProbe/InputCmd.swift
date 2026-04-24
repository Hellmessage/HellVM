// move / click / scroll / key / type —— 输入类命令.
//
// 鼠标:
//   复用 HVMDisplay.InputForwarder (usb-tablet absolute 坐标),
//   坐标系由 updateViewSize() 设定, 我们先连 iosurface 拿 framebuffer 尺寸,
//   再把该尺寸注入 InputForwarder, 这样 click/move 的 x/y 就是 guest 像素坐标,
//   和 screenshot 的 PNG 尺寸对齐。
//
// 键盘:
//   不走 InputForwarder, 直接 QMP `send-key` —— 接受 qcode 字符串数组, 天然支持
//   组合键(ctrl+alt+delete 一次发 3 个 qcode)。比 NSKeyCode → QCode 转一层更直接。

import Foundation
import ArgumentParser
import HVMBundle
import HVMBackendQEMU
import HVMDisplay

// MARK: - 共用: 连 iosurface 拿 fb size + 连 qmp-input 配 InputForwarder

/// 返回 (forwarder, fbWidth, fbHeight). 用完记得 close().
/// 连两条 socket 各自失败时给明确原因。
func prepareInput(bundle: VMBundle, timeout: Double = 3.0) async throws
    -> (forwarder: InputForwarder, width: Int, height: Int)
{
    // 先拿 framebuffer 尺寸
    let ch = DisplayChannel()
    do {
        try ch.connect(socketPath: bundle.iosurfaceSocketURL.path)
    } catch {
        throw ProbeError.socketConnectFailed("iosurface: \(error.localizedDescription)")
    }
    let (w, h) = try await withThrowingTaskGroup(of: (Int, Int).self) { group in
        group.addTask {
            for await event in ch.events {
                if case .surface(let fb) = event {
                    return (fb.width, fb.height)
                }
            }
            throw ProbeError.protocolError("iosurface 断开前没收到 surface")
        }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            throw ProbeError.protocolError("等 surface 超时(\(timeout)s)")
        }
        let r = try await group.next()!
        group.cancelAll()
        return r
    }
    ch.close()

    // 连 qmp-input
    let fwd = InputForwarder()
    do {
        try await fwd.connect(socketPath: bundle.qmpInputSocketURL.path)
    } catch {
        throw ProbeError.socketConnectFailed("qmp-input: \(error.localizedDescription)")
    }
    // 让 InputForwarder 把 (x, y) 按这个尺寸归一化. 我们传 guest pixels, 它内部 /width
    // 后再 *0x7fff 写给 usb-tablet, guest 看到的 absolute 坐标和 screenshot 对齐。
    fwd.updateViewSize(width: w, height: h)
    return (fwd, w, h)
}

/// InputForwarder 的 flush 是 async, 但类型无 flush API public. 简单 sleep 让
/// 后台 Task 把事件 drain 到 socket, 再 close。
func closeInput(_ fwd: InputForwarder, settleMs: UInt64 = 200) async {
    try? await Task.sleep(nanoseconds: settleMs * 1_000_000)
    await fwd.close()
}

// MARK: - move

struct MoveCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "move",
        abstract: "鼠标 absolute move (guest 像素坐标系, 和 screenshot 对齐)"
    )

    @Argument(help: "VM 名字或 bundle 路径")
    var vm: String

    @Argument var x: Int
    @Argument var y: Int

    mutating func run() async throws {
        let bundle = try VMLocator.resolve(vm)
        let (fwd, _, _) = try await prepareInput(bundle: bundle)
        fwd.mouseMove(x: Double(x), y: Double(y))
        await closeInput(fwd)
    }
}

// MARK: - click

struct ClickCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "click",
        abstract: "鼠标点击 (先 move 再 down/up)"
    )

    @Argument(help: "VM 名字或 bundle 路径")
    var vm: String

    @Argument var x: Int
    @Argument var y: Int

    @Option(name: .long, help: "left / right / middle")
    var button: String = "left"

    @Flag(name: .long, help: "双击")
    var double: Bool = false

    mutating func run() async throws {
        let btn: InputForwarder.MouseButton
        switch button.lowercased() {
        case "left":   btn = .left
        case "right":  btn = .right
        case "middle": btn = .middle
        default:
            throw ProbeError.protocolError("button 必须是 left/right/middle")
        }
        let bundle = try VMLocator.resolve(vm)
        let (fwd, _, _) = try await prepareInput(bundle: bundle)
        let clicks = double ? 2 : 1
        for _ in 0..<clicks {
            fwd.mouseButton(button: btn, down: true, x: Double(x), y: Double(y))
            try? await Task.sleep(nanoseconds: 40_000_000)
            fwd.mouseButton(button: btn, down: false, x: Double(x), y: Double(y))
            if clicks == 2 {
                try? await Task.sleep(nanoseconds: 80_000_000)
            }
        }
        await closeInput(fwd)
    }
}

// MARK: - scroll

struct ScrollCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scroll",
        abstract: "滚轮. 正=向上, 负=向下"
    )

    @Argument(help: "VM 名字或 bundle 路径")
    var vm: String

    @Argument(help: "滚动量, 例如 120 或 -120")
    var delta: Double

    mutating func run() async throws {
        let bundle = try VMLocator.resolve(vm)
        let (fwd, _, _) = try await prepareInput(bundle: bundle)
        fwd.scrollWheel(dy: delta)
        await closeInput(fwd)
    }
}

// MARK: - key / type: 走 QMP send-key

/// 从易读名字 → QKeyCode 字符串. QKeyCode 定义见 Vendor/qemu-src/qapi/ui.json.
/// 覆盖常用键 + a-z/0-9/常见标点. 未覆盖的大写字母由 type 命令用 shift 组合触发。
enum KeyName {
    static func qcode(for name: String) -> String? {
        let n = name.lowercased()
        // alias
        switch n {
        case "enter", "return", "ret": return "ret"
        case "esc", "escape":          return "esc"
        case "space", "spc", " ":      return "spc"
        case "tab":                    return "tab"
        case "backspace", "bksp":      return "backspace"
        case "delete", "del":          return "delete"
        case "up":                     return "up"
        case "down":                   return "down"
        case "left":                   return "left"
        case "right":                  return "right"
        case "home":                   return "home"
        case "end":                    return "end"
        case "pgup", "pageup":         return "pgup"
        case "pgdn", "pagedown":       return "pgdn"
        case "insert", "ins":          return "insert"
        case "ctrl", "control":        return "ctrl"
        case "alt", "option":          return "alt"
        case "shift":                  return "shift"
        case "meta", "cmd", "win", "super": return "meta_l"
        case "caps_lock", "capslock":  return "caps_lock"
        case "-", "minus":             return "minus"
        case "=", "equal":             return "equal"
        case "[", "bracket_left":      return "bracket_left"
        case "]", "bracket_right":     return "bracket_right"
        case "\\", "backslash":        return "backslash"
        case ";", "semicolon":         return "semicolon"
        case "'", "apostrophe":        return "apostrophe"
        case "`", "grave_accent":      return "grave_accent"
        case ",", "comma":             return "comma"
        case ".", "dot":               return "dot"
        case "/", "slash":             return "slash"
        default: break
        }
        // f1..f12
        if n.hasPrefix("f"), let num = Int(n.dropFirst()), num >= 1, num <= 12 {
            return "f\(num)"
        }
        // 单字符字母/数字
        if n.count == 1 {
            let c = n.first!
            if c.isLetter, c.isASCII { return String(c) }
            if c.isNumber, c.isASCII { return String(c) }
        }
        // 原样透传 (qcode 名)
        if !n.isEmpty { return n }
        return nil
    }
}

struct KeyCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "key",
        abstract: "按一次键, 支持组合 (例 'ctrl+alt+del')"
    )

    @Argument(help: "VM 名字或 bundle 路径")
    var vm: String

    @Argument(help: "键名, 例 'a' / 'Enter' / 'ctrl+alt+del'")
    var key: String

    mutating func run() async throws {
        let parts = key.split(separator: "+").map(String.init)
        var qcodes: [String] = []
        for p in parts {
            guard let q = KeyName.qcode(for: p) else {
                throw ProbeError.unknownKey(p)
            }
            qcodes.append(q)
        }
        let bundle = try VMLocator.resolve(vm)
        try await sendKey(bundle: bundle, qcodes: qcodes)
    }
}

struct TypeCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "type",
        abstract: "键入字符串 (ASCII, 自动处理大小写/简单标点)"
    )

    @Argument(help: "VM 名字或 bundle 路径")
    var vm: String

    @Argument(help: "要打的字符串")
    var text: String

    mutating func run() async throws {
        let bundle = try VMLocator.resolve(vm)
        for ch in text {
            guard let (qcodes, _) = qcodeSequence(for: ch) else {
                FileHandle.standardError.write(
                    "warn: 跳过无法输入的字符 '\(ch)'\n".data(using: .utf8)!)
                continue
            }
            try await sendKey(bundle: bundle, qcodes: qcodes)
            // 小间隔让 guest 逐字收到 (QMP send-key 默认无 hold_time, 够快了)
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
    }

    /// 字符 → (qcodes, 显示用描述). qcodes 会作为一次组合键发送(含 shift 等修饰)。
    private func qcodeSequence(for ch: Character) -> ([String], String)? {
        if ch == " "    { return (["spc"], "space") }
        if ch == "\t"   { return (["tab"], "tab") }
        if ch == "\n"   { return (["ret"], "enter") }

        let s = String(ch)
        if ch.isLetter, ch.isASCII {
            let lower = s.lowercased()
            if ch.isUppercase { return (["shift", lower], s) }
            return ([lower], s)
        }
        if ch.isNumber, ch.isASCII { return ([s], s) }

        // 常见 US 键盘标点: shift + 对应键
        switch ch {
        case "-": return (["minus"], "-")
        case "_": return (["shift", "minus"], "_")
        case "=": return (["equal"], "=")
        case "+": return (["shift", "equal"], "+")
        case "[": return (["bracket_left"], "[")
        case "{": return (["shift", "bracket_left"], "{")
        case "]": return (["bracket_right"], "]")
        case "}": return (["shift", "bracket_right"], "}")
        case "\\": return (["backslash"], "\\")
        case "|": return (["shift", "backslash"], "|")
        case ";": return (["semicolon"], ";")
        case ":": return (["shift", "semicolon"], ":")
        case "'": return (["apostrophe"], "'")
        case "\"": return (["shift", "apostrophe"], "\"")
        case "`": return (["grave_accent"], "`")
        case "~": return (["shift", "grave_accent"], "~")
        case ",": return (["comma"], ",")
        case "<": return (["shift", "comma"], "<")
        case ".": return (["dot"], ".")
        case ">": return (["shift", "dot"], ">")
        case "/": return (["slash"], "/")
        case "?": return (["shift", "slash"], "?")
        case "!": return (["shift", "1"], "!")
        case "@": return (["shift", "2"], "@")
        case "#": return (["shift", "3"], "#")
        case "$": return (["shift", "4"], "$")
        case "%": return (["shift", "5"], "%")
        case "^": return (["shift", "6"], "^")
        case "&": return (["shift", "7"], "&")
        case "*": return (["shift", "8"], "*")
        case "(": return (["shift", "9"], "(")
        case ")": return (["shift", "0"], ")")
        default:  return nil
        }
    }
}

// MARK: - QMP send-key 底层封装

/// QMP `send-key` 需要 keys=[{type:"qcode", data:<qcode>}, ...]
func sendKey(bundle: VMBundle, qcodes: [String]) async throws {
    let keys: [[String: Any]] = qcodes.map { ["type": "qcode", "data": $0] }
    _ = try await runQMPRaw(bundle: bundle,
                            command: "send-key",
                            arguments: ["keys": keys])
}
