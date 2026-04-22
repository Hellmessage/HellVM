// FramebufferView —— SwiftUI 包装 MTKView(自定义 FramebufferHostView) + Display/Input 通道
//
// 用法:
//   FramebufferView(displaySocketPath: bundle.iosurfaceSocketURL.path,
//                   inputSocketPath:   bundle.qmpInputSocketURL.path)
//
// 生命周期: onAppear 连接两个 socket, onDisappear 关闭; 连接失败周期重试。

import SwiftUI
import MetalKit
import HVMCore

public struct FramebufferView: NSViewRepresentable {
    public let displaySocketPath: String
    public let inputSocketPath: String

    public var retryInterval: TimeInterval = 0.3

    public init(displaySocketPath: String,
                inputSocketPath: String,
                retryInterval: TimeInterval = 0.3) {
        self.displaySocketPath = displaySocketPath
        self.inputSocketPath   = inputSocketPath
        self.retryInterval     = retryInterval
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

            context.coordinator.start(displayPath: displaySocketPath,
                                      inputPath: inputSocketPath,
                                      retryInterval: retryInterval)
        } catch {
            log.error(.display, "renderer init failed: \(error)")
        }

        return view
    }

    public func updateNSView(_ nsView: MTKView, context: Context) {
        if context.coordinator.currentDisplayPath != displaySocketPath
            || context.coordinator.currentInputPath != inputSocketPath {
            context.coordinator.stop()
            context.coordinator.start(displayPath: displaySocketPath,
                                      inputPath: inputSocketPath,
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

        var displayTask: Task<Void, Never>?
        var inputTask: Task<Void, Never>?
        var currentDisplayPath: String?
        var currentInputPath: String?

        func start(displayPath: String, inputPath: String, retryInterval: TimeInterval) {
            currentDisplayPath = displayPath
            currentInputPath   = inputPath

            displayTask = Task { [weak self] in
                await self?.runDisplayLoop(path: displayPath, retry: retryInterval)
            }
            inputTask = Task { [weak self] in
                await self?.runInputLoop(path: inputPath, retry: retryInterval)
            }
        }

        func stop() {
            displayTask?.cancel()
            inputTask?.cancel()
            displayChannel?.close()
            displayChannel = nil

            let fwd = forwarder
            Task { await fwd?.close() }

            Task { @MainActor [weak self] in
                self?.renderer?.unbind()
            }
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
                case .updateHint, .cursor, .mouseSet:
                    break
                case .disconnected:
                    renderer?.unbind()
                    return
                }
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
    }
}
