// DisplayProtocol —— iosurface display backend 线协议常量/结构体
// 必须与 Vendor/qemu-src/ui/iosurface.m 保持一致, 见 docs/p4-design.md §2.5
import Foundation

enum MessageType: UInt32 {
    case hello      = 0x01
    case surface    = 0x02
    case updateHint = 0x03
    case cursor     = 0x04
    case mouseSet   = 0x05
}

let protocolVersion: UInt32 = 1

// 所有结构体都 packed, 网络字节序其实是小端(与 QEMU 进程本地一致)

struct MsgHeader {
    var type: UInt32
    var payloadLen: UInt32
}

struct HelloPayload {
    var protocolVersion: UInt32
}

struct SurfacePayload {
    var width: UInt32
    var height: UInt32
    var stride: UInt32
    var format: UInt32   // 'BGRA' = 0x42475241
}

struct UpdateHintPayload {
    var x: UInt32
    var y: UInt32
    var w: UInt32
    var h: UInt32
    var seq: UInt64
}

struct MouseSetPayload {
    var x: Int32
    var y: Int32
    var visible: UInt8
}

// ---------- Swift 侧事件 ----------

/// 跨进程 framebuffer 共享内存(shm fd + mmap 结果)
public final class SharedFramebuffer: @unchecked Sendable {
    public let width: Int
    public let height: Int
    public let stride: Int
    public let format: UInt32
    let shmFD: Int32
    let pointer: UnsafeMutableRawPointer
    let size: Int

    init(width: Int, height: Int, stride: Int, format: UInt32,
         shmFD: Int32, pointer: UnsafeMutableRawPointer, size: Int) {
        self.width = width
        self.height = height
        self.stride = stride
        self.format = format
        self.shmFD = shmFD
        self.pointer = pointer
        self.size = size
    }

    public var byteCount: Int { size }

    public func dispose() {
        munmap(pointer, size)
        close(shmFD)
    }

    deinit { dispose() }
}

public struct CursorFrame: Sendable {
    public let hotX: Int32
    public let hotY: Int32
    public let width: Int
    public let height: Int
    public let bgra: Data
}

public enum DisplayEvent: Sendable {
    case surface(SharedFramebuffer)
    case updateHint(x: Int, y: Int, w: Int, h: Int, seq: UInt64)
    case cursor(CursorFrame)
    case mouseSet(x: Int32, y: Int32, visible: Bool)
    case disconnected(String?)
}
