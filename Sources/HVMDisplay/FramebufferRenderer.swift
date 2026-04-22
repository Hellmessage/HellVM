// FramebufferRenderer —— 把跨进程 shm framebuffer 渲染到 MTKView
//
// 两个 pipeline:
// - fullscreen: 覆盖整张 drawable, 采样 framebuffer texture
// - cursor:     alpha-blend 的 quad, 覆盖在 framebuffer 上画硬件光标
//
// 零拷贝链路(Apple Silicon unified memory):
//   shm_open(QEMU) → mmap(Swift) → MTLBuffer(bytesNoCopy:) →
//   MTLBuffer.makeTexture(bytesPerRow:) → fullscreen pipeline → drawable

import Foundation
import Metal
import MetalKit
import QuartzCore
import HVMCore

public final class FramebufferRenderer: NSObject, MTKViewDelegate {
    public let device: MTLDevice
    private let queue: MTLCommandQueue
    private let fullscreenPipeline: MTLRenderPipelineState
    private let cursorPipeline: MTLRenderPipelineState

    // 当前绑定的 framebuffer
    private var currentFB: SharedFramebuffer?
    private var currentBuffer: MTLBuffer?
    private var currentTexture: MTLTexture?

    // 当前光标 state(主线程读写)
    private var cursorTexture: MTLTexture?
    private var cursorHotX: Int32 = 0
    private var cursorHotY: Int32 = 0
    private var cursorWidth: Int = 0
    private var cursorHeight: Int = 0
    private var cursorPosX: Int32 = 0
    private var cursorPosY: Int32 = 0
    private var cursorVisible: Bool = false

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

        // ---- fullscreen: 4 顶点 triangle strip ----
        vertex VertexOut fullscreen_vs(uint vid [[vertex_id]]) {
            float2 positions[4] = {
                float2(-1, -1), float2( 1, -1),
                float2(-1,  1), float2( 1,  1)
            };
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

        // ---- cursor: NDC 矩形, 使用 uniform 传递 ----
        struct CursorUniforms {
            float4 rectNDC;   // (x_left, y_top, x_right, y_bottom) in NDC
        };

        vertex VertexOut cursor_vs(uint vid [[vertex_id]],
                                   constant CursorUniforms &u [[buffer(0)]]) {
            float2 corners[4] = {
                float2(0, 1), float2(1, 1),
                float2(0, 0), float2(1, 0)
            };
            float2 c = corners[vid];
            float x = mix(u.rectNDC.x, u.rectNDC.z, c.x);
            float y = mix(u.rectNDC.y, u.rectNDC.w, c.y);
            VertexOut out;
            out.position = float4(x, y, 0.0, 1.0);
            // cursor 的 BGRA 数据 Y 方向与 Metal NDC 反, uv.y 翻转
            out.uv = float2(c.x, 1.0 - c.y);
            return out;
        }

        fragment float4 cursor_fs(VertexOut in [[stage_in]],
                                  texture2d<float> tex [[texture(0)]]) {
            constexpr sampler s(mag_filter::nearest, min_filter::nearest);
            float4 c = tex.sample(s, in.uv);
            return c;
        }
        """
        let library = try device.makeLibrary(source: source, options: nil)
        guard let fsVS = library.makeFunction(name: "fullscreen_vs"),
              let fsFS = library.makeFunction(name: "fullscreen_fs"),
              let curVS = library.makeFunction(name: "cursor_vs"),
              let curFS = library.makeFunction(name: "cursor_fs") else {
            throw NSError(domain: "HVMDisplay", code: -2, userInfo: [
                NSLocalizedDescriptionKey: "makeFunction 失败"
            ])
        }

        let fsDesc = MTLRenderPipelineDescriptor()
        fsDesc.vertexFunction = fsVS
        fsDesc.fragmentFunction = fsFS
        fsDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        self.fullscreenPipeline = try device.makeRenderPipelineState(descriptor: fsDesc)

        // cursor: alpha blending
        let curDesc = MTLRenderPipelineDescriptor()
        curDesc.vertexFunction = curVS
        curDesc.fragmentFunction = curFS
        let att = curDesc.colorAttachments[0]!
        att.pixelFormat = .bgra8Unorm
        att.isBlendingEnabled = true
        att.rgbBlendOperation = .add
        att.alphaBlendOperation = .add
        att.sourceRGBBlendFactor = .sourceAlpha
        att.destinationRGBBlendFactor = .oneMinusSourceAlpha
        att.sourceAlphaBlendFactor = .one
        att.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        self.cursorPipeline = try device.makeRenderPipelineState(descriptor: curDesc)

        super.init()
    }

    deinit {
        log.info(.display, "FramebufferRenderer deinit")
    }

    // MARK: - framebuffer 绑定

    public func bind(framebuffer: SharedFramebuffer) {
        log.info(.display, "bind fb \(framebuffer.width)x\(framebuffer.height) size=\(framebuffer.byteCount)")
        // 把 SharedFramebuffer 强引用捕获到 MTLBuffer.deallocator: Metal 保证
        // GPU 处理完所有 in-flight command buffer 后才调用 deallocator, 那时释放
        // SharedFramebuffer(munmap) 才安全。否则 VM 关机 → unbind() 立即释放会
        // 让 GPU 访问已 munmap 的地址 → Metal crash → App 异常退出。
        let keep = framebuffer
        let buf = device.makeBuffer(
            bytesNoCopy: framebuffer.pointer,
            length: framebuffer.byteCount,
            options: [.storageModeShared],
            deallocator: { _, _ in
                // closure 捕获 keep; 调用时 capture 释放 → SharedFramebuffer deinit
                _ = keep
            }
        )
        guard let buf else {
            currentFB = nil; currentBuffer = nil; currentTexture = nil
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

        currentTexture = buf.makeTexture(
            descriptor: texDesc, offset: 0,
            bytesPerRow: framebuffer.stride
        )
        currentFB = framebuffer
        currentBuffer = buf
    }

    public func unbind() {
        log.info(.display, "unbind")
        // 此处只断 renderer 的引用, SharedFramebuffer 实际 munmap 由 MTLBuffer
        // deallocator 在 GPU 完成后触发。
        currentFB = nil
        currentBuffer = nil
        currentTexture = nil
        cursorTexture = nil
        cursorVisible = false
    }

    // MARK: - 光标

    /// 更新硬件光标贴图(BGRA8 像素)
    public func updateCursor(bgra: Data, width: Int, height: Int,
                             hotX: Int32, hotY: Int32) {
        guard width > 0, height > 0, bgra.count >= width * height * 4 else {
            return
        }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width, height: height, mipmapped: false
        )
        desc.storageMode = .shared
        desc.usage = .shaderRead
        guard let tex = device.makeTexture(descriptor: desc) else { return }
        bgra.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            tex.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: base,
                bytesPerRow: width * 4
            )
        }
        cursorTexture = tex
        cursorWidth = width
        cursorHeight = height
        cursorHotX = hotX
        cursorHotY = hotY
        cursorVisible = true
    }

    /// 更新光标位置(guest framebuffer 坐标系, 左上原点)
    public func updateCursorPosition(x: Int32, y: Int32, visible: Bool) {
        cursorPosX = x
        cursorPosY = y
        cursorVisible = visible && cursorTexture != nil
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

        // pass 1: fullscreen framebuffer
        if let tex = currentTexture {
            enc?.setRenderPipelineState(fullscreenPipeline)
            enc?.setFragmentTexture(tex, index: 0)
            enc?.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }

        // pass 2: cursor overlay
        if cursorVisible, let curTex = cursorTexture, let fb = currentFB,
           fb.width > 0, fb.height > 0 {
            let fx = Float(cursorPosX - cursorHotX) / Float(fb.width)
            let fy = Float(cursorPosY - cursorHotY) / Float(fb.height)
            let fw = Float(cursorWidth)  / Float(fb.width)
            let fh = Float(cursorHeight) / Float(fb.height)
            // NDC: x ∈ [-1,1] 映射 [0, fb.width]; y 轴翻转
            let xl = fx * 2 - 1
            let xr = (fx + fw) * 2 - 1
            let yt = 1 - fy * 2
            let yb = 1 - (fy + fh) * 2
            var uniforms = SIMD4<Float>(xl, yt, xr, yb)

            enc?.setRenderPipelineState(cursorPipeline)
            enc?.setVertexBytes(&uniforms,
                                length: MemoryLayout<SIMD4<Float>>.size,
                                index: 0)
            enc?.setFragmentTexture(curTex, index: 0)
            enc?.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }

        enc?.endEncoding()
        cmd?.present(drawable)
        cmd?.commit()
    }
}
