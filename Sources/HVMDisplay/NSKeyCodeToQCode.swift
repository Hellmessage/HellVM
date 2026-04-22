// macOS NSEvent.keyCode (Carbon HIToolbox kVK_*) → QEMU QKeyCode 字符串映射
//
// QKeyCode 枚举值定义: Vendor/qemu-src/qapi/ui.json 里 enum QKeyCode
// Carbon kVK_* 定义:  <HIToolbox/Events.h> (Apple SDK, 不可直接 import 到 Swift)
//
// 只做常用键; 未覆盖的返回 nil, InputForwarder 静默丢弃。

import Foundation

enum NSKeyCodeToQCode {
    /// NSEvent.keyCode (UInt16) → QKeyCode 字符串
    static func map(_ code: UInt16) -> String? {
        switch code {
        // 字母区
        case 0x00: return "a"
        case 0x0B: return "b"
        case 0x08: return "c"
        case 0x02: return "d"
        case 0x0E: return "e"
        case 0x03: return "f"
        case 0x05: return "g"
        case 0x04: return "h"
        case 0x22: return "i"
        case 0x26: return "j"
        case 0x28: return "k"
        case 0x25: return "l"
        case 0x2E: return "m"
        case 0x2D: return "n"
        case 0x1F: return "o"
        case 0x23: return "p"
        case 0x0C: return "q"
        case 0x0F: return "r"
        case 0x01: return "s"
        case 0x11: return "t"
        case 0x20: return "u"
        case 0x09: return "v"
        case 0x0D: return "w"
        case 0x07: return "x"
        case 0x10: return "y"
        case 0x06: return "z"

        // 数字行
        case 0x12: return "1"
        case 0x13: return "2"
        case 0x14: return "3"
        case 0x15: return "4"
        case 0x17: return "5"
        case 0x16: return "6"
        case 0x1A: return "7"
        case 0x1C: return "8"
        case 0x19: return "9"
        case 0x1D: return "0"

        // 符号
        case 0x1B: return "minus"             // -
        case 0x18: return "equal"             // =
        case 0x21: return "bracket_left"      // [
        case 0x1E: return "bracket_right"     // ]
        case 0x2A: return "backslash"         // \
        case 0x29: return "semicolon"         // ;
        case 0x27: return "apostrophe"        // '
        case 0x32: return "grave_accent"      // `
        case 0x2B: return "comma"             // ,
        case 0x2F: return "dot"               // .
        case 0x2C: return "slash"             // /

        // 编辑/导航
        case 0x24: return "ret"               // Return
        case 0x30: return "tab"
        case 0x31: return "spc"
        case 0x33: return "backspace"         // macOS Delete
        case 0x35: return "esc"
        case 0x75: return "delete"            // macOS Forward Delete
        case 0x72: return "insert"            // macOS Help 键(部分键盘)
        case 0x73: return "home"
        case 0x77: return "end"
        case 0x74: return "pgup"
        case 0x79: return "pgdn"
        case 0x7B: return "left"
        case 0x7C: return "right"
        case 0x7D: return "down"
        case 0x7E: return "up"

        // 修饰键(flagsChanged 路径, 非 keyDown)
        case 0x37: return "meta_l"            // Left Cmd
        case 0x36: return "meta_r"            // Right Cmd
        case 0x38: return "shift"             // Left Shift
        case 0x3C: return "shift_r"
        case 0x39: return "caps_lock"
        case 0x3A: return "alt"               // Left Option
        case 0x3D: return "alt_r"
        case 0x3B: return "ctrl"              // Left Control
        case 0x3E: return "ctrl_r"

        // 功能键
        case 0x7A: return "f1"
        case 0x78: return "f2"
        case 0x63: return "f3"
        case 0x76: return "f4"
        case 0x60: return "f5"
        case 0x61: return "f6"
        case 0x62: return "f7"
        case 0x64: return "f8"
        case 0x65: return "f9"
        case 0x6D: return "f10"
        case 0x67: return "f11"
        case 0x6F: return "f12"

        // 小键盘
        case 0x52: return "kp_0"
        case 0x53: return "kp_1"
        case 0x54: return "kp_2"
        case 0x55: return "kp_3"
        case 0x56: return "kp_4"
        case 0x57: return "kp_5"
        case 0x58: return "kp_6"
        case 0x59: return "kp_7"
        case 0x5B: return "kp_8"
        case 0x5C: return "kp_9"
        case 0x41: return "kp_decimal"
        case 0x43: return "kp_multiply"
        case 0x45: return "kp_add"
        case 0x4E: return "kp_subtract"
        case 0x4B: return "kp_divide"
        case 0x4C: return "kp_enter"
        case 0x51: return "kp_equals"

        default:
            return nil
        }
    }
}
