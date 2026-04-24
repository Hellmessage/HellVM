// VDAgentProtocol —— spice-vdagent 线协议常量/结构体
//
// 参考: https://gitlab.freedesktop.org/spice/spice-protocol/-/blob/master/spice/vd_agent.h
//
// 通道是 virtio-serial port "com.redhat.spice.0", QEMU 把它桥到一条 unix socket,
// HellVM (host) 作为客户端连入, Windows 里的 spice-vdagent 作为 guest 端。
//
// Wire format:
//   [VDIChunkHeader(port=1, size=N)]          ← chunk 层, 一条消息可跨多 chunk
//   [VDAgentMessage(protocol=1,type,size=M)]  ← message 层
//   [payload M bytes]
//
// 典型的 resize 场景只走一条 chunk: N = sizeof(VDAgentMessage) + M。
//
// 握手: 连接建立后双方各发一次 ANNOUNCE_CAPABILITIES:
//   - guest 发 (request=1, caps bitmap) 询问 host
//   - host 回 (request=0, caps bitmap) 告知自己支持的
// host 声明 VD_AGENT_CAP_MONITORS_CONFIG 后即可发 MONITORS_CONFIG 触发 resize。

import Foundation

/// VDI chunk header 里的 port, 普通消息固定 VDP_CLIENT_PORT=1
let vdiClientPort: UInt32 = 1

/// VDAgent 协议版本
let vdAgentProtocol: UInt32 = 1

/// 消息类型子集 —— HellVM 只关心 resize 相关 + 握手
enum VDAgentMessageType: UInt32 {
    case mouseState           = 1
    case monitorsConfig       = 2   // host → guest: 告诉 guest 切换显示模式
    case reply                = 3
    case clipboard            = 4
    case displayConfig        = 5
    case announceCapabilities = 6   // host ↔ guest: 握手
    case clipboardGrab        = 7
    case clipboardRequest     = 8
    case clipboardRelease     = 9
    case fileXferStart        = 10
    case fileXferStatus       = 11
    case fileXferData         = 12
    case clientDisconnected   = 13
    case maxClipboard         = 14
    case audioVolumeSync      = 15
    case graphicsDeviceInfo   = 16
}

/// ANNOUNCE_CAPABILITIES 里的 cap bits (从 0 起)
enum VDAgentCap: UInt32 {
    case mouseState            = 0
    case monitorsConfig        = 1
    case reply                 = 2
    case clipboard             = 3
    case displayConfig         = 4
    case clipboardByDemand     = 5
    case clipboardSelection    = 6
    case sparseMonitorsConfig  = 7
    case guestLineEndLF        = 8
    case guestLineEndCRLF      = 9
    case maxClipboard          = 10
    case audioVolumeSync       = 11
    case monitorsConfigPosition = 13
    case fileXferDisabled      = 14
    case fileXferDetailedErrors = 15
    case graphicsCardInfo      = 16
    case clipboardNoReleaseOnRegrab = 17
    case clipboardGrabSerial   = 18
}

/// VDIChunkHeader 紧接在 socket 流开头
struct VDIChunkHeader {
    var port: UInt32
    var size: UInt32
}

/// VDAgentMessage —— 每条消息的头
struct VDAgentMessageHeader {
    var `protocol`: UInt32
    var type: UInt32
    var opaque: UInt64
    var size: UInt32
}

/// VD_AGENT_MONITORS_CONFIG payload (单显示器)
struct VDAgentMonitorsConfigHeader {
    var numOfMonitors: UInt32
    var flags: UInt32
}

struct VDAgentMonConfig {
    var height: UInt32
    var width: UInt32
    var depth: UInt32
    var x: Int32
    var y: Int32
}

/// VD_AGENT_ANNOUNCE_CAPABILITIES payload (单一 32-bit caps word)
struct VDAgentAnnounceCapabilitiesHeader {
    /// 1 = 对方在询问, 需要回复; 0 = 对方在告知自己的能力, 不需回复
    var request: UInt32
}
