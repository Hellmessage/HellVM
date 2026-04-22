// FramebufferHostView —— 自定义 MTKView 子类, 拦截键鼠事件并转发给 InputForwarder
//
// - 接管 firstResponder, 拿到键盘焦点
// - 用 NSTrackingArea 监听 mouseMoved(hover 无按键状态也要更新坐标)
// - flagsChanged: 映射 shift/ctrl/cmd/alt/caps 的按放

import AppKit
import MetalKit

fileprivate func dbgHost(_ msg: @autoclosure () -> String) {
    let line = "[\(Date())] HOST \(msg())\n"
    guard let data = line.data(using: .utf8) else { return }
    if let fh = try? FileHandle(forWritingTo: URL(fileURLWithPath: "/tmp/hellvm-input.log")) {
        fh.seekToEndOfFile()
        fh.write(data)
        try? fh.close()
    } else {
        try? data.write(to: URL(fileURLWithPath: "/tmp/hellvm-input.log"))
    }
}

final class FramebufferHostView: MTKView {
    weak var inputForwarder: InputForwarder?

    private var trackingArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect, device: MTLDevice?) {
        super.init(frame: frameRect, device: device)
        wantsLayer = true
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // 获得焦点才能收键盘事件
        let ok = window?.makeFirstResponder(self) ?? false
        dbgHost("viewDidMoveToWindow, makeFirstResponder=\(ok) window=\(window != nil)")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = trackingArea {
            removeTrackingArea(area)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved,
                      .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func layout() {
        super.layout()
        inputForwarder?.updateViewSize(
            width: Int(bounds.width),
            height: Int(bounds.height)
        )
    }

    // MARK: - 键盘

    override func keyDown(with event: NSEvent) {
        dbgHost("keyDown \(event.keyCode)")
        inputForwarder?.keyDown(nsKeyCode: event.keyCode)
    }

    override func keyUp(with event: NSEvent) {
        dbgHost("keyUp \(event.keyCode)")
        inputForwarder?.keyUp(nsKeyCode: event.keyCode)
    }

    override func flagsChanged(with event: NSEvent) {
        let bit: NSEvent.ModifierFlags
        switch event.keyCode {
        case 0x37, 0x36: bit = .command
        case 0x38, 0x3C: bit = .shift
        case 0x3A, 0x3D: bit = .option
        case 0x3B, 0x3E: bit = .control
        case 0x39:       bit = .capsLock
        default:
            return
        }
        let isDown = event.modifierFlags.contains(bit)
        inputForwarder?.modifierKey(nsKeyCode: event.keyCode, down: isDown)
    }

    // MARK: - 鼠标

    override func mouseMoved(with event: NSEvent)   { forwardMove(event) }
    override func mouseDragged(with event: NSEvent) { forwardMove(event) }
    override func rightMouseDragged(with event: NSEvent) { forwardMove(event) }
    override func otherMouseDragged(with event: NSEvent) { forwardMove(event) }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        forwardButton(event, button: .left, down: true)
    }
    override func mouseUp(with event: NSEvent) {
        forwardButton(event, button: .left, down: false)
    }
    override func rightMouseDown(with event: NSEvent) {
        forwardButton(event, button: .right, down: true)
    }
    override func rightMouseUp(with event: NSEvent) {
        forwardButton(event, button: .right, down: false)
    }
    override func otherMouseDown(with event: NSEvent) {
        forwardButton(event, button: .middle, down: true)
    }
    override func otherMouseUp(with event: NSEvent) {
        forwardButton(event, button: .middle, down: false)
    }

    override func scrollWheel(with event: NSEvent) {
        inputForwarder?.scrollWheel(dy: Double(event.scrollingDeltaY))
    }

    // MARK: - 辅助

    private func forwardMove(_ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        inputForwarder?.mouseMove(x: Double(p.x), y: Double(p.y))
    }

    private func forwardButton(_ event: NSEvent,
                               button: InputForwarder.MouseButton,
                               down: Bool) {
        let p = convert(event.locationInWindow, from: nil)
        inputForwarder?.mouseButton(
            button: button, down: down,
            x: Double(p.x), y: Double(p.y)
        )
    }
}
