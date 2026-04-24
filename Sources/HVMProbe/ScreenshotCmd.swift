// screenshot —— 连 iosurface socket 拿一帧 framebuffer 导出 PNG.
//
// 复用 HVMDisplay.DisplayChannel:
//   1. connect(socketPath) 会发 HELLO
//   2. QEMU 回 SURFACE 消息, 带 shmfd 被 mmap 成 SharedFramebuffer
//   3. 我们只要等第一个 .surface 事件, 就有 (w, h, stride, BGRA 裸指针)
//
// 把裸指针包成 CGImage → CGImageDestination 写 PNG, 零拷贝到文件。

import Foundation
import ArgumentParser
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import HVMBundle
import HVMDisplay

struct ScreenshotCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "screenshot",
        abstract: "抓 guest framebuffer 到 PNG"
    )

    @Argument(help: "VM 名字或 bundle 路径")
    var vm: String

    @Option(name: [.short, .long], help: "输出路径 (默认 ./<vm>-<timestamp>.png)")
    var output: String?

    @Option(name: .long, help: "等 surface 事件的超时秒数")
    var timeout: Double = 3.0

    mutating func run() async throws {
        let bundle = try VMLocator.resolve(vm)
        let sockPath = bundle.iosurfaceSocketURL.path
        let ch = DisplayChannel()
        do {
            try ch.connect(socketPath: sockPath)
        } catch {
            throw ProbeError.socketConnectFailed(
                "iosurface @\(sockPath): \(error.localizedDescription). VM 可能没在跑, 或没开图形模式。")
        }
        defer { ch.close() }

        // 等第一个 .surface, 超时兜底
        let fb = try await withSurface(ch: ch, timeout: timeout)

        let destPath = output ?? defaultOutputPath(for: vm)
        let url = URL(fileURLWithPath: (destPath as NSString).expandingTildeInPath)
        try writePNG(framebuffer: fb, to: url)
        print("==> \(url.path) (\(fb.width)x\(fb.height), stride=\(fb.stride))")
    }

    private func defaultOutputPath(for vm: String) -> String {
        let ts = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        // 清理 vm 里的路径分隔符, 只取最后一段
        let leaf = (vm as NSString).lastPathComponent
            .replacingOccurrences(of: ".hellvm", with: "")
        return "\(leaf)-\(ts).png"
    }

    /// 等一个 .surface 事件, 超时就抛
    private func withSurface(ch: DisplayChannel, timeout: Double) async throws -> SharedFramebuffer {
        try await withThrowingTaskGroup(of: SharedFramebuffer.self) { group in
            group.addTask {
                for await event in ch.events {
                    if case .surface(let fb) = event {
                        return fb
                    }
                }
                throw ProbeError.protocolError("iosurface 断开前没收到 surface 事件")
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw ProbeError.protocolError("等 surface 超时(\(timeout)s)")
            }
            let fb = try await group.next()!
            group.cancelAll()
            return fb
        }
    }

    private func writePNG(framebuffer fb: SharedFramebuffer, to url: URL) throws {
        // format 常量 0x42475241 ('BGRA'). CGImage 用 Little Endian 32 + AlphaPremultipliedFirst
        // 解 BGRA in-memory 到 BGRA 32bpp. 裸指针 → CGDataProvider(不拷贝, 只持引用).
        let bytesPerRow = fb.stride
        let totalBytes = fb.byteCount

        guard let provider = CGDataProvider(
            dataInfo: nil,
            data: fb.rawPointer,
            size: totalBytes,
            releaseData: { _, _, _ in /* 不释放, SharedFramebuffer 管理 */ }
        ) else {
            throw ProbeError.pngEncodeFailed("CGDataProvider 构造失败")
        }

        let bitmapInfo = CGBitmapInfo(rawValue:
            CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw ProbeError.pngEncodeFailed("sRGB ColorSpace 构造失败")
        }
        guard let image = CGImage(
            width: fb.width, height: fb.height,
            bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: cs, bitmapInfo: bitmapInfo,
            provider: provider, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent
        ) else {
            throw ProbeError.pngEncodeFailed("CGImage 构造失败")
        }

        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else {
            throw ProbeError.pngEncodeFailed("CGImageDestination 构造失败")
        }
        CGImageDestinationAddImage(dest, image, nil)
        if !CGImageDestinationFinalize(dest) {
            throw ProbeError.pngEncodeFailed("finalize 失败")
        }
    }
}
