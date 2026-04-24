// FramebufferView —— SwiftUI 包装 MTKView(自定义 FramebufferHostView) + Display/Input 通道
//
// 用法:
//   FramebufferView(displaySocketPath:    bundle.iosurfaceSocketURL.path,
//                   inputSocketPath:      bundle.qmpInputSocketURL.path,
//                   spiceAgentSocketPath: bundle.spiceAgentSocketURL.path)
//
// 生命周期: onAppear 连接三个 socket, onDisappear 关闭; 连接失败周期重试。
// iosurface + qmp-input 是核心渲染/输入通道; spice-vdagent 是可选, 给
// Windows guest(装 spice-guest-tools 后)用来在 host 窗口 resize 时自动切分辨率。
// 若 guest 没装 spice-vdagent, socket 连得上但握手永不完成, 不影响主画面。

import SwiftUI
import MetalKit
import HVMCore
import ObjectiveC

public struct FramebufferView: NSViewRepresentable {
    public let displaySocketPath: String
    public let inputSocketPath: String
    public let spiceAgentSocketPath: String?

    public var retryInterval: TimeInterval = 0.3

    public init(displaySocketPath: String,
                inputSocketPath: String,
                spiceAgentSocketPath: String? = nil,
                retryInterval: TimeInterval = 0.3) {
        self.displaySocketPath    = displaySocketPath
        self.inputSocketPath      = inputSocketPath
        self.spiceAgentSocketPath = spiceAgentSocketPath
        self.retryInterval        = retryInterval
    }

    public func makeNSView(context: Context) -> MTKView {
        guard let device = MTLCreateSystemDefaultDevice() else {
            // 设备不可用, 退回一个空 host view(用户最终会看到黑屏)
            return FramebufferHostView(frame: .zero, device: nil)
        }
        let view = FramebufferHostView(frame: .zero, device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.clearColor = MTLClearColorMake(0, 0, 0, 1)
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.preferredFramesPerSecond = 60
        view.autoResizeDrawable = true

        do {
            let renderer = try FramebufferRenderer(device: device)
            view.delegate = renderer
            context.coordinator.renderer = renderer

            let forwarder = InputForwarder()
            view.inputForwarder = forwarder
            context.coordinator.forwarder = forwarder

            view.onResize = { [weak coordinator = context.coordinator] w, h in
                Task { @MainActor in
                    coordinator?.requestGuestResize(width: w, height: h)
                }
            }

            context.coordinator.start(displayPath: displaySocketPath,
                                      inputPath: inputSocketPath,
                                      spiceAgentPath: spiceAgentSocketPath,
                                      retryInterval: retryInterval)
        } catch {
            log.error(.display, "renderer init failed: \(error)")
        }

        return view
    }

    public func updateNSView(_ nsView: MTKView, context: Context) {
        if context.coordinator.currentDisplayPath != displaySocketPath
            || context.coordinator.currentInputPath != inputSocketPath
            || context.coordinator.currentSpiceAgentPath != spiceAgentSocketPath {
            context.coordinator.stop()
            context.coordinator.start(displayPath: displaySocketPath,
                                      inputPath: inputSocketPath,
                                      spiceAgentPath: spiceAgentSocketPath,
                                      retryInterval: retryInterval)
        }
    }

    public static func dismantleNSView(_ nsView: MTKView, coordinator: Coordinator) {
        coordinator.stop()
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public final class Coordinator {
        var renderer: FramebufferRenderer?
        var forwarder: InputForwarder?
        var displayChannel: DisplayChannel?
        var vdagentChannel: VDAgentChannel?

        var displayTask: Task<Void, Never>?
        var inputTask: Task<Void, Never>?
        var vdagentTask: Task<Void, Never>?
        var currentDisplayPath: String?
        var currentInputPath: String?
        var currentSpiceAgentPath: String?

        func start(displayPath: String, inputPath: String,
                   spiceAgentPath: String?, retryInterval: TimeInterval) {
            log.debug(.display, "Coordinator start \(ObjectIdentifier(self).hashValue)")
            currentDisplayPath    = displayPath
            currentInputPath      = inputPath
            currentSpiceAgentPath = spiceAgentPath

            displayTask = Task { [weak self] in
                await self?.runDisplayLoop(path: displayPath, retry: retryInterval)
            }
            inputTask = Task { [weak self] in
                await self?.runInputLoop(path: inputPath, retry: retryInterval)
            }
            if let vdPath = spiceAgentPath {
                vdagentTask = Task { [weak self] in
                    await self?.runVDAgentLoop(path: vdPath, retry: retryInterval)
                }
            }
        }

        func stop() {
            log.debug(.display, "Coordinator stop \(ObjectIdentifier(self).hashValue)")
            displayTask?.cancel()
            inputTask?.cancel()
            vdagentTask?.cancel()
            displayChannel?.close()
            displayChannel = nil
            vdagentChannel?.close()
            vdagentChannel = nil

            let fwd = forwarder
            Task { await fwd?.close() }

            Task { @MainActor [weak self] in
                self?.renderer?.unbind()
            }
        }

        deinit {
            log.debug(.display, "Coordinator deinit")
        }

        // MARK: - display 循环(连 iosurface socket)

        private func runDisplayLoop(path: String, retry: TimeInterval) async {
            let sleepNanos = UInt64(retry * 1_000_000_000)
            while !Task.isCancelled {
                let ch = DisplayChannel()
                do {
                    try ch.connect(socketPath: path)
                } catch {
                    try? await Task.sleep(nanoseconds: sleepNanos)
                    continue
                }
                self.displayChannel = ch
                await self.consumeEvents(from: ch)
                self.displayChannel = nil
                try? await Task.sleep(nanoseconds: sleepNanos)
            }
        }

        @MainActor
        private func consumeEvents(from ch: DisplayChannel) async {
            for await event in ch.events {
                switch event {
                case .surface(let fb):
                    renderer?.bind(framebuffer: fb)
                case .cursor(let c):
                    renderer?.updateCursor(
                        bgra: c.bgra,
                        width: c.width, height: c.height,
                        hotX: c.hotX, hotY: c.hotY
                    )
                case .mouseSet(let x, let y, let visible):
                    renderer?.updateCursorPosition(x: x, y: y, visible: visible)
                case .ledState(let led):
                    forwarder?.setGuestLED(led)
                case .updateHint:
                    break
                case .disconnected:
                    renderer?.unbind()
                    return
                }
            }
        }

        /// FramebufferHostView 在 layout 变化时调; 200ms debounce 再发 resize,
        /// 避免拖拽过程中每帧都打扰 guest。
        private var resizeDebounce: Task<Void, Never>?
        private var lastRequestedSize: (UInt32, UInt32) = (0, 0)

        @MainActor
        func requestGuestResize(width: UInt32, height: UInt32) {
            guard width >= 64, height >= 64 else {
                log.debug(.display, "requestGuestResize skip: too small \(width)x\(height)")
                return
            }
            if (width, height) == lastRequestedSize {
                log.debug(.display, "requestGuestResize skip: dup \(width)x\(height)")
                return
            }
            resizeDebounce?.cancel()
            resizeDebounce = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 200_000_000)
                if Task.isCancelled { return }
                guard let self else { return }
                self.lastRequestedSize = (width, height)
                log.info(.display, "requestGuestResize send \(width)x\(height)")
                // 两路并发: iosurface 驱动 Linux/EDK2; vdagent 驱动 Windows
                if let ch = self.displayChannel {
                    ch.requestResize(width: width, height: height)
                } else {
                    log.debug(.display, "requestGuestResize: iosurface not ready yet")
                }
                // vdagent 未就绪也会自动缓存 pending, ready 时补发
                self.vdagentChannel?.sendMonitorsConfig(width: width, height: height)
            }
        }

        // MARK: - input 循环(连 qmp-input socket)

        private func runInputLoop(path: String, retry: TimeInterval) async {
            let sleepNanos = UInt64(retry * 1_000_000_000)
            while !Task.isCancelled {
                guard let fwd = forwarder else {
                    try? await Task.sleep(nanoseconds: sleepNanos)
                    continue
                }
                do {
                    try await fwd.connect(socketPath: path)
                    // 连上了就不主动断, 等待 VM 停止 EOF 会 throw 到下一次 send
                    return
                } catch {
                    try? await Task.sleep(nanoseconds: sleepNanos)
                    continue
                }
            }
        }

        // MARK: - vdagent 循环(连 spice-vdagent bridge socket)
        //
        // 和 displayChannel 不同, vdagent 连上就长驻, 不做重连(VM 关机会 EOF)。
        // guest 里 spice-vdagent 服务未启动时 QEMU 侧的 virtio-serial 写入会
        // 被缓冲丢弃, 表现为"没握手", 我们 sendMonitorsConfig 会缓存 pending;
        // 等 guest agent 起来握完手, pending 立刻发出。
        private func runVDAgentLoop(path: String, retry: TimeInterval) async {
            let sleepNanos = UInt64(retry * 1_000_000_000)
            while !Task.isCancelled {
                let ch = VDAgentChannel()
                do {
                    try ch.connect(socketPath: path)
                    self.vdagentChannel = ch
                    return
                } catch {
                    try? await Task.sleep(nanoseconds: sleepNanos)
                    continue
                }
            }
        }
    }
}
