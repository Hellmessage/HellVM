// InputForwarder —— 把 Cocoa 键鼠事件转成 QMP input-send-event 发给 guest
//
// 通道: 专用 QMP socket(VMBundle.qmpInputSocketURL), 持久连接,
//      与 VMController 的控制通道(qmp.sock)隔离, 避免 accept 争抢。
//
// 批处理: 调用方(主线程)调用 keyDown/keyUp/mouseAbs 等只是往 batch 里塞
//        event, 实际 QMP 调用在后台 Task 里串行化。鼠标 abs 位置做去重,
//        连续同一坐标只发一次。

import Foundation
import Darwin
import HVMCore
import HVMBundle
import HVMBackendQEMU

/// 单次 `input-send-event` 的原子事件 JSON 片段(最终直接放进 events 数组)
private typealias QMPInputEvent = [String: Any]

public final class InputForwarder: @unchecked Sendable {
    private let qmp = QMPClient()

    /// VM 画面像素尺寸, 供 abs 坐标归一化; updateViewSize() 更新.
    /// 锁保护: 主线程在 MTKView resize 时写, 后台 flushLoop/absEvents 读,
    /// 无锁直读会在窗口缩放的同时出现"拿到不匹配的 w/h"导致鼠标跳一下。
    private let viewSizeLock = NSLock()
    private var viewWidth: Int = 1
    private var viewHeight: Int = 1

    /// 当前鼠标坐标(归一化到 0..32767), 去重用
    private var lastAbsX: Int32 = -1
    private var lastAbsY: Int32 = -1

    /// Guest 键盘 LED 状态(由 DisplayChannel 的 LED_STATE 消息回传刷新).
    /// FramebufferHostView 在 keyDown 前对比 host CapsLock 与此值,
    /// 不一致时先补发 caps_lock toggle, 再 forward 按键。
    private let ledLock = NSLock()
    private var _guestLED: GuestLEDState = GuestLEDState(raw: 0)

    public var guestLED: GuestLEDState {
        ledLock.lock(); defer { ledLock.unlock() }
        return _guestLED
    }
    public func setGuestLED(_ state: GuestLEDState) {
        ledLock.lock(); _guestLED = state; ledLock.unlock()
    }

    /// 事件队列
    private let queueLock = NSLock()
    private var pending: [QMPInputEvent] = []

    private var flushTask: Task<Void, Never>?
    private var connected = false

    public init() {}

    // MARK: - 生命周期

    /// 连 QMP 输入 socket; 失败抛出, 调用方负责重试
    public func connect(socketPath: String) async throws {
        log.debug(.input, "connect attempt \(socketPath)")
        do {
            try await qmp.connect(socketPath: socketPath)
        } catch {
            log.warn(.input, "connect FAIL: \(error)")
            throw error
        }
        connected = true
        log.info(.input, "QMP input channel connected")
    }

    public func close() async {
        flushTask?.cancel()
        flushTask = nil
        await qmp.close()
        connected = false
    }

    /// MTKView 尺寸变化时调, 用于坐标归一化
    public func updateViewSize(width: Int, height: Int) {
        viewSizeLock.lock()
        viewWidth = max(width, 1)
        viewHeight = max(height, 1)
        viewSizeLock.unlock()
    }

    // MARK: - 键盘

    public func keyDown(nsKeyCode: UInt16) {
        guard let qcode = NSKeyCodeToQCode.map(nsKeyCode) else { return }
        enqueue(Self.keyEvent(qcode: qcode, down: true))
    }

    public func keyUp(nsKeyCode: UInt16) {
        guard let qcode = NSKeyCodeToQCode.map(nsKeyCode) else { return }
        enqueue(Self.keyEvent(qcode: qcode, down: false))
    }

    /// 修饰键(flagsChanged)状态变化; caller 应比较 modifierFlags 差异自行决定 down/up
    public func modifierKey(nsKeyCode: UInt16, down: Bool) {
        guard let qcode = NSKeyCodeToQCode.map(nsKeyCode) else { return }
        enqueue(Self.keyEvent(qcode: qcode, down: down))
    }

    // MARK: - 鼠标

    /// 点击; x,y 为 NSView 坐标(左下原点)
    public func mouseButton(button: MouseButton, down: Bool,
                            x: Double, y: Double) {
        var batch: [QMPInputEvent] = []
        if let abs = absEvents(x: x, y: y) {
            batch.append(contentsOf: abs)
        }
        batch.append(Self.btnEvent(button: button, down: down))
        enqueueBatch(batch)
    }

    /// 鼠标移动/拖动; 自动做归一化和去重
    public func mouseMove(x: Double, y: Double) {
        if let abs = absEvents(x: x, y: y) {
            enqueueBatch(abs)
        }
    }

    /// 滚轮; dy > 0 向上滚
    public func scrollWheel(dy: Double) {
        // 一次 scroll 发 button down + up, QEMU 认 "wheel-up" / "wheel-down"
        guard abs(dy) >= 0.5 else { return }
        let btn: MouseButton = dy > 0 ? .wheelUp : .wheelDown
        enqueueBatch([
            Self.btnEvent(button: btn, down: true),
            Self.btnEvent(button: btn, down: false),
        ])
    }

    public enum MouseButton: String {
        case left, middle, right
        case wheelUp   = "wheel-up"
        case wheelDown = "wheel-down"
    }

    // MARK: - 入队 / flush

    private func enqueue(_ event: QMPInputEvent) {
        enqueueBatch([event])
    }

    private func enqueueBatch(_ events: [QMPInputEvent]) {
        guard !events.isEmpty else { return }
        guard connected else {
            log.warn(.input, "enqueue DROP (not connected) count=\(events.count)")
            return
        }
        log.trace(.input, "enqueue count=\(events.count)")
        queueLock.lock()
        pending.append(contentsOf: events)
        queueLock.unlock()
        scheduleFlush()
    }

    private func scheduleFlush() {
        if flushTask != nil { return }
        flushTask = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.flushLoop()
        }
    }

    /// 长期活着, pending 空时短暂 sleep 再 drain。
    /// 只在: 连接失败 / Task 被 cancel 时退出。
    ///
    /// 关键: drain 后再等 2ms 合并窗口, 把 flagsChanged(shift) + keyDown(a)
    /// 这类紧挨的事件压到同一个 QMP input-send-event 里; 否则 usb-kbd 会发
    /// 两次 HID report, guest 可能按 shift 没到的小写解析 a。
    private func flushLoop() async {
        while !Task.isCancelled {
            var events = drainPending()
            if events.isEmpty {
                try? await Task.sleep(nanoseconds: 3_000_000)
                continue
            }
            // 合并窗口: 2ms 内紧邻的事件合并
            try? await Task.sleep(nanoseconds: 2_000_000)
            events.append(contentsOf: drainPending())

            log.debug(.input, "flush \(Self.describe(events))")
            do {
                try await qmp.execute("input-send-event",
                                      arguments: ["events": events])
            } catch {
                log.warn(.input, "flush FAIL: \(error)")
                flushTask = nil
                return
            }
        }
    }

    /// 把 QMP event 列表格式化成人类可读的短字符串, 用于日志
    private static func describe(_ events: [QMPInputEvent]) -> String {
        var parts: [String] = []
        for e in events {
            guard let type = e["type"] as? String,
                  let data = e["data"] as? [String: Any] else { continue }
            switch type {
            case "key":
                let down = (data["down"] as? Bool) ?? false
                let qcode = (data["key"] as? [String: Any])?["data"] as? String ?? "?"
                parts.append("\(qcode)\(down ? "↓" : "↑")")
            case "btn":
                let down = (data["down"] as? Bool) ?? false
                let btn = (data["button"] as? String) ?? "?"
                parts.append("\(btn)\(down ? "↓" : "↑")")
            case "abs":
                let axis = (data["axis"] as? String) ?? "?"
                let v = (data["value"] as? Int) ?? 0
                parts.append("\(axis)=\(v)")
            default:
                parts.append(type)
            }
        }
        return "[\(parts.joined(separator: " "))]"
    }

    private func drainPending() -> [QMPInputEvent] {
        queueLock.lock()
        defer { queueLock.unlock() }
        let events = pending
        pending.removeAll(keepingCapacity: true)
        return events
    }

    // MARK: - abs 坐标归一化

    /// view 坐标(左下原点)  →  QEMU abs(0..32767, 左上原点)
    private func absEvents(x: Double, y: Double) -> [QMPInputEvent]? {
        // snapshot w/h 后再计算, 避免和 updateViewSize 交错拿到半新半旧值
        viewSizeLock.lock()
        let w = Double(viewWidth)
        let h = Double(viewHeight)
        viewSizeLock.unlock()
        let nx = Int32(clamp((x / w) * 32767.0, 0, 32767))
        let ny = Int32(clamp(((h - y) / h) * 32767.0, 0, 32767))
        if nx == lastAbsX && ny == lastAbsY { return nil }
        lastAbsX = nx
        lastAbsY = ny
        return [
            Self.absEvent(axis: "x", value: nx),
            Self.absEvent(axis: "y", value: ny),
        ]
    }

    private func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        min(max(v, lo), hi)
    }

    // MARK: - 事件 JSON 构造

    private static func keyEvent(qcode: String, down: Bool) -> QMPInputEvent {
        [
            "type": "key",
            "data": [
                "down": down,
                "key": ["type": "qcode", "data": qcode],
            ],
        ]
    }

    private static func btnEvent(button: MouseButton, down: Bool) -> QMPInputEvent {
        [
            "type": "btn",
            "data": [
                "down": down,
                "button": button.rawValue,
            ],
        ]
    }

    private static func absEvent(axis: String, value: Int32) -> QMPInputEvent {
        [
            "type": "abs",
            "data": [
                "axis": axis,
                "value": Int(value),
            ],
        ]
    }
}
