// InputForwarder —— 把 Cocoa 键鼠事件转成 QMP input-send-event 发给 guest

/// 诊断日志 - 写 /tmp/hellvm-input.log; 生产时可移除
fileprivate func dbgInput(_ msg: @autoclosure () -> String) {
    let line = "[\(Date())] \(msg())\n"
    if let data = line.data(using: .utf8),
       let fh = try? FileHandle(forWritingTo: URL(fileURLWithPath: "/tmp/hellvm-input.log")) {
        fh.seekToEndOfFile()
        fh.write(data)
        try? fh.close()
    } else if let data = line.data(using: .utf8) {
        try? data.write(to: URL(fileURLWithPath: "/tmp/hellvm-input.log"))
    }
}
//
// 通道: 专用 QMP socket(VMBundle.qmpInputSocketURL), 持久连接,
//      与 VMController 的控制通道(qmp.sock)隔离, 避免 accept 争抢。
//
// 批处理: 调用方(主线程)调用 keyDown/keyUp/mouseAbs 等只是往 batch 里塞
//        event, 实际 QMP 调用在后台 Task 里串行化。鼠标 abs 位置做去重,
//        连续同一坐标只发一次。

import Foundation
import Darwin
import HVMBundle
import HVMBackendQEMU

/// 单次 `input-send-event` 的原子事件 JSON 片段(最终直接放进 events 数组)
private typealias QMPInputEvent = [String: Any]

public final class InputForwarder: @unchecked Sendable {
    private let qmp = QMPClient()

    /// VM 画面像素尺寸, 供 abs 坐标归一化; updateViewSize() 更新
    private var viewWidth: Int = 1
    private var viewHeight: Int = 1

    /// 当前鼠标坐标(归一化到 0..32767), 去重用
    private var lastAbsX: Int32 = -1
    private var lastAbsY: Int32 = -1

    /// 事件队列
    private let queueLock = NSLock()
    private var pending: [QMPInputEvent] = []

    private var flushTask: Task<Void, Never>?
    private var connected = false

    public init() {}

    // MARK: - 生命周期

    /// 连 QMP 输入 socket; 失败抛出, 调用方负责重试
    public func connect(socketPath: String) async throws {
        dbgInput("connect attempt \(socketPath)")
        do {
            try await qmp.connect(socketPath: socketPath)
        } catch {
            dbgInput("connect FAIL: \(error)")
            throw error
        }
        connected = true
        dbgInput("connect OK")
    }

    public func close() async {
        flushTask?.cancel()
        flushTask = nil
        await qmp.close()
        connected = false
    }

    /// MTKView 尺寸变化时调, 用于坐标归一化
    public func updateViewSize(width: Int, height: Int) {
        viewWidth = max(width, 1)
        viewHeight = max(height, 1)
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
            dbgInput("enqueue DROP (not connected) count=\(events.count)")
            return
        }
        dbgInput("enqueue count=\(events.count)")
        queueLock.lock()
        pending.append(contentsOf: events)
        queueLock.unlock()
        scheduleFlush()
    }

    private func scheduleFlush() {
        if flushTask != nil { return }
        dbgInput("scheduleFlush spawn")
        flushTask = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.flushLoop()
        }
    }

    private func flushLoop() async {
        dbgInput("flushLoop enter")
        while !Task.isCancelled {
            let events = drainPending()
            if events.isEmpty {
                dbgInput("flushLoop drain empty, exit")
                flushTask = nil
                return
            }

            dbgInput("flush -> QMP execute count=\(events.count)")
            do {
                try await qmp.execute("input-send-event",
                                      arguments: ["events": events])
                dbgInput("flush OK")
            } catch {
                dbgInput("flush FAIL: \(error)")
                flushTask = nil
                return
            }
        }
        dbgInput("flushLoop exit (cancelled)")
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
        let nx = Int32(clamp((x / Double(viewWidth)) * 32767.0, 0, 32767))
        let ny = Int32(clamp(((Double(viewHeight) - y) / Double(viewHeight)) * 32767.0, 0, 32767))
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
