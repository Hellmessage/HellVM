// FramebufferHostView —— 自定义 MTKView 子类, 拦截键鼠事件并转发给 InputForwarder
//
// - 接管 firstResponder, 拿到键盘焦点
// - 用 NSTrackingArea 监听 mouseMoved(hover 无按键状态也要更新坐标)
// - flagsChanged: 映射 shift/ctrl/cmd/alt/caps 的按放

import AppKit
import MetalKit
import HVMCore

final class FramebufferHostView: MTKView {
    weak var inputForwarder: InputForwarder?
    /// view 布局尺寸变化时调; 目前接到 Coordinator.requestGuestResize
    var onResize: ((UInt32, UInt32) -> Void)?

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
        log.trace(.input,"viewDidMoveToWindow, makeFirstResponder=\(ok) window=\(window != nil)")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = trackingArea {
            removeTrackingArea(area)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved,
                      .mouseEnteredAndExited, .inVisibleRect,
                      .cursorUpdate],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    // MARK: - host 光标隐藏
    //
    // 鼠标 hover 在画面内时隐藏 macOS 光标, 让位给 guest 画的光标(软光标
    // 直接写 framebuffer; 硬件光标通过 MSG_CURSOR 合成到 Metal overlay)。
    // 离开视图或 window 失活时恢复。

    private var cursorHidden = false

    private func hideHostCursor() {
        if !cursorHidden {
            NSCursor.hide()
            cursorHidden = true
        }
    }

    private func showHostCursor() {
        if cursorHidden {
            NSCursor.unhide()
            cursorHidden = false
        }
    }

    override func mouseEntered(with event: NSEvent) {
        hideHostCursor()
    }

    override func mouseExited(with event: NSEvent) {
        showHostCursor()
    }

    override func cursorUpdate(with event: NSEvent) {
        // AppKit 在 hover 区域会重设为标准 arrow; 我们再隐
        hideHostCursor()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        // 切离窗口时必须恢复, 否则全局光标都消失(NSCursor 计数平衡)
        if newWindow == nil { showHostCursor() }
    }

    override func layout() {
        super.layout()
        emitGuestResize()
    }

    // SwiftUI NSViewRepresentable 下发尺寸走 setFrame/setFrameSize, 不一定会
    // 触发 Auto Layout pass 调 layout(), 拖窗口 live resize 期间 layout()
    // 经常一次都不调。这里覆盖 setFrameSize 保证每次尺寸变更都 emit 一次,
    // layout() 保留作 AutoLayout 场景的兜底。
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        emitGuestResize()
    }

    private func emitGuestResize() {
        // abs 坐标归一化用 points 单位, 与 event.locationInWindow 一致,
        // 避免 Retina 下 point/pixel 比例错配导致 guest 光标只能到画面中点。
        let ptWidth  = Int(bounds.width)
        let ptHeight = Int(bounds.height)
        inputForwarder?.updateViewSize(width: ptWidth, height: ptHeight)

        // guest 物理分辨率必须是像素
        let scale = window?.backingScaleFactor ?? 1.0
        let pxWidth  = Int(bounds.width  * scale)
        let pxHeight = Int(bounds.height * scale)
        log.debug(.display,
            "emitGuestResize pt=\(ptWidth)x\(ptHeight) scale=\(scale) px=\(pxWidth)x\(pxHeight)")
        onResize?(UInt32(max(pxWidth, 64)), UInt32(max(pxHeight, 64)))
    }

    // MARK: - 键盘

    override func keyDown(with event: NSEvent) {
        // 本地快捷键: cmd+opt+Esc 释放键盘焦点 + 恢复 host 光标
        if event.modifierFlags.contains([.command, .option]) && event.keyCode == 0x35 {
            releaseKeyboard()
            return
        }
        log.trace(.input, "keyDown \(event.keyCode)")
        syncCapsLockIfNeeded(event)
        inputForwarder?.keyDown(nsKeyCode: event.keyCode)
    }

    override func keyUp(with event: NSEvent) {
        log.trace(.input, "keyUp \(event.keyCode)")
        inputForwarder?.keyUp(nsKeyCode: event.keyCode)
    }

    /// 若 host 的 CapsLock 状态和 guest LED 报告的 CapsLock 不一致, 补发一次
    /// caps_lock 脉冲让 guest 对齐。实现 host/guest Caps Lock 状态双向同步 —
    /// 依赖 iosurface backend 的 MSG_LED_STATE 把 guest HID output report 回传。
    private func syncCapsLockIfNeeded(_ event: NSEvent) {
        guard let fwd = inputForwarder else { return }
        let hostCaps = event.modifierFlags.contains(.capsLock)
        let guestCaps = fwd.guestLED.capsLock
        if hostCaps != guestCaps {
            fwd.modifierKey(nsKeyCode: 0x39, down: true)
            fwd.modifierKey(nsKeyCode: 0x39, down: false)
            // 本地先乐观标记, 避免同一批多个键重复补发; guest 真实状态稍后由
            // MSG_LED_STATE 校正。
            fwd.setGuestLED(GuestLEDState(
                raw: guestCaps
                    ? (fwd.guestLED.raw & ~GuestLEDState.capsLockBit)
                    : (fwd.guestLED.raw |  GuestLEDState.capsLockBit)
            ))
        }
    }

    /// 让 framebuffer 脱离 firstResponder, 恢复 host 光标。
    /// 用户再次点击画面即可重新捕获。
    private func releaseKeyboard() {
        window?.makeFirstResponder(nil)
        showHostCursor()
        log.info(.input, "keyboard released (cmd+opt+esc)")
    }

    override func flagsChanged(with event: NSEvent) {
        // Caps Lock 不再作为独立 modifier 转发 — host CapsLock 状态会在 keyDown/
        // keyUp 里通过 "virtual shift" 映射成 shift+字母, 避免 host 与 guest 的
        // CapsLock LED/状态双轨不同步。
        if event.keyCode == 0x39 { return }

        let bit: NSEvent.ModifierFlags
        switch event.keyCode {
        case 0x37, 0x36: bit = .command
        case 0x38, 0x3C: bit = .shift
        case 0x3A, 0x3D: bit = .option
        case 0x3B, 0x3E: bit = .control
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
