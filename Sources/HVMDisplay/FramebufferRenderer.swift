// FramebufferRenderer —— 把跨进程 shm framebuffer 渲染到 MTKView
//
// 零拷贝链路(Apple Silicon unified memory):
//   shm_open(QEMU)
//     → mmap(Swift)
//     → device.makeBuffer(bytesNoCopy:)      (storageModeShared)
//     → MTLBuffer.makeTexture(bytesPerRow:)  (BGRA texture 直接读 mmap)
//     → 全屏 triangle strip + fragment sampler → drawable

import Foundation
import Metal
import MetalKit
import QuartzCore

public final class FramebufferRenderer: NSObject, MTKViewDelegate {
    public let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState

    // 当前绑定的 framebuffer (主线程读写)
    private var currentFB: SharedFramebuffer?
    private var currentBuffer: MTLBuffer?
    private var currentTexture: MTLTexture?

    public init(device: MTLDevice) throws {
        self.device = device
        guard let q = device.makeCommandQueue() else {
            throw NSError(domain: "HVMDisplay", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "makeCommandQueue 失败"
            ])
        }
        self.queue = q

        let source = """
        #include <metal_stdlib>
        using namespace metal;

        struct VertexOut {
            float4 position [[position]];
            float2 uv;
        };

        vertex VertexOut fullscreen_vs(uint vid [[vertex_id]]) {
            // triangle strip: 4 顶点覆盖整个 clip space
            float2 positions[4] = {
                float2(-1, -1), float2( 1, -1),
                float2(-1,  1), float2( 1,  1)
            };
            // UV 轴与 Metal NDC Y 相反, 翻 Y
            float2 uvs[4] = {
                float2(0, 1), float2(1, 1),
                float2(0, 0), float2(1, 0)
            };
            VertexOut out;
            out.position = float4(positions[vid], 0.0, 1.0);
            out.uv = uvs[vid];
            return out;
        }

        fragment float4 fullscreen_fs(VertexOut in [[stage_in]],
                                      texture2d<float> tex [[texture(0)]]) {
            constexpr sampler s(mag_filter::linear, min_filter::linear);
            return tex.sample(s, in.uv);
        }
        """
        let library = try device.makeLibrary(source: source, options: nil)
        guard let vs = library.makeFunction(name: "fullscreen_vs"),
              let fs = library.makeFunction(name: "fullscreen_fs") else {
            throw NSError(domain: "HVMDisplay", code: -2, userInfo: [
                NSLocalizedDescriptionKey: "makeFunction 失败"
            ])
        }

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vs
        desc.fragmentFunction = fs
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm

        self.pipeline = try device.makeRenderPipelineState(descriptor: desc)

        super.init()
    }

    /// 绑定新的 framebuffer (分辨率变化时调用)
    public func bind(framebuffer: SharedFramebuffer) {
        let buf = device.makeBuffer(
            bytesNoCopy: framebuffer.pointer,
            length: framebuffer.byteCount,
            options: [.storageModeShared],
            deallocator: nil
        )
        guard let buf else {
            currentFB = nil
            currentBuffer = nil
            currentTexture = nil
            return
        }

        let texDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: framebuffer.width,
            height: framebuffer.height,
            mipmapped: false
        )
        texDesc.storageMode = .shared
        texDesc.usage = .shaderRead

        let tex = buf.makeTexture(
            descriptor: texDesc,
            offset: 0,
            bytesPerRow: framebuffer.stride
        )

        currentFB = framebuffer
        currentBuffer = buf
        currentTexture = tex
    }

    public func unbind() {
        currentFB = nil
        currentBuffer = nil
        currentTexture = nil
    }

    // MARK: - MTKViewDelegate

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    public func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let passDesc = view.currentRenderPassDescriptor else {
            return
        }

        let cmd = queue.makeCommandBuffer()
        let enc = cmd?.makeRenderCommandEncoder(descriptor: passDesc)

        if let tex = currentTexture {
            enc?.setRenderPipelineState(pipeline)
            enc?.setFragmentTexture(tex, index: 0)
            enc?.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        // 没绑 texture 时 pass 只做 clear (黑屏)

        enc?.endEncoding()
        cmd?.present(drawable)
        cmd?.commit()
    }
}
