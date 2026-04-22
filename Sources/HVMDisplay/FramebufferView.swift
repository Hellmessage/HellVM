// FramebufferView —— SwiftUI 包装 MTKView + DisplayChannel 生命周期
//
// 用法:
//   FramebufferView(socketPath: bundle.iosurfaceSocketURL.path)
//
// 生命周期: onAppear 连接 socket, onDisappear 关闭。连接失败会周期性重试,
//          直到成功或 View 销毁。

import SwiftUI
import MetalKit

public struct FramebufferView: NSViewRepresentable {
    public let socketPath: String

    /// 连接重试间隔(秒); VM 启动后会先 delay 一小段, socket 才会被 QEMU 建出
    public var retryInterval: TimeInterval = 0.3

    public init(socketPath: String, retryInterval: TimeInterval = 0.3) {
        self.socketPath = socketPath
        self.retryInterval = retryInterval
    }

    public func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        guard let device = MTLCreateSystemDefaultDevice() else {
            return view
        }
        view.device = device
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
            context.coordinator.start(socketPath: socketPath,
                                      retryInterval: retryInterval)
        } catch {
            NSLog("FramebufferView: renderer init failed: \(error)")
        }

        return view
    }

    public func updateNSView(_ nsView: MTKView, context: Context) {
        // socketPath 若变了, 重启连接
        if context.coordinator.currentPath != socketPath {
            context.coordinator.stop()
            context.coordinator.start(socketPath: socketPath,
                                      retryInterval: retryInterval)
        }
    }

    public static func dismantleNSView(_ nsView: MTKView, coordinator: Coordinator) {
        coordinator.stop()
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public final class Coordinator {
        var renderer: FramebufferRenderer?
        var channel: DisplayChannel?
        var eventTask: Task<Void, Never>?
        var reconnectTask: Task<Void, Never>?
        var currentPath: String?

        func start(socketPath: String, retryInterval: TimeInterval) {
            currentPath = socketPath
            reconnectTask = Task { [weak self] in
                guard let self else { return }
                while !Task.isCancelled {
                    let ch = DisplayChannel()
                    do {
                        try ch.connect(socketPath: socketPath)
                    } catch {
                        try? await Task.sleep(nanoseconds: UInt64(retryInterval * 1_000_000_000))
                        continue
                    }
                    self.channel = ch
                    await self.consumeEvents(from: ch)
                    // 断开后重试
                    self.channel = nil
                    try? await Task.sleep(nanoseconds: UInt64(retryInterval * 1_000_000_000))
                }
            }
        }

        func stop() {
            reconnectTask?.cancel()
            eventTask?.cancel()
            channel?.close()
            channel = nil
            Task { @MainActor [weak self] in
                self?.renderer?.unbind()
            }
        }

        @MainActor
        private func consumeEvents(from ch: DisplayChannel) async {
            for await event in ch.events {
                switch event {
                case .surface(let fb):
                    renderer?.bind(framebuffer: fb)
                case .updateHint:
                    // MTKView 60Hz 自刷, 暂不用 hint
                    break
                case .cursor, .mouseSet:
                    // Sprint 5 处理
                    break
                case .disconnected:
                    renderer?.unbind()
                    return
                }
            }
        }
    }
}
