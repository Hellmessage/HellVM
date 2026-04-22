// DisplayProtocol —— iosurface display backend 线协议常量/结构体
// 必须与 Vendor/qemu-src/ui/iosurface.m 保持一致, 见 docs/p4-design.md §2.5
import Foundation
import HVMCore

enum MessageType: UInt32 {
    case hello      = 0x01
    case surface    = 0x02
    case updateHint = 0x03
    case cursor     = 0x04
    case mouseSet   = 0x05
    case ledState   = 0x06
    case resizeReq  = 0x07   // Swift → QEMU: 请求 guest 改分辨率
}

/// QEMU 键盘 LED 位 (QEMU_*_LED 宏)
public struct GuestLEDState: Sendable, Equatable {
    public static let scrollLockBit: UInt32 = 1 << 0
    public static let numLockBit:    UInt32 = 1 << 1
    public static let capsLockBit:   UInt32 = 1 << 2

    public let raw: UInt32
    public var scrollLock: Bool { raw & Self.scrollLockBit != 0 }
    public var numLock:    Bool { raw & Self.numLockBit    != 0 }
    public var capsLock:   Bool { raw & Self.capsLockBit   != 0 }

    public init(raw: UInt32) { self.raw = raw }
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

struct LedStatePayload {
    var ledstate: UInt32
}

struct ResizeReqPayload {
    var width: UInt32
    var height: UInt32
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
        log.debug(.display, "SharedFramebuffer dispose fd=\(shmFD) size=\(size)")
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
    case ledState(GuestLEDState)
    case disconnected(String?)
}
