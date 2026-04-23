// 全局设计 Token —— 颜色 / 字号
// 通用 UI 组件住在 Sources/HellVM/Components/ 下, 本文件只放设计系统常量.
import SwiftUI

/// 颜色 Token
public enum Theme {
    // 背景层级(从深到浅)
    public static let background      = Color(red: 0.040, green: 0.042, blue: 0.048)   // #0A0B0C
    public static let surface         = Color(red: 0.075, green: 0.080, blue: 0.094)   // #131520
    public static let surfaceElevated = Color(red: 0.115, green: 0.120, blue: 0.138)   // #1D1F24
    public static let surfaceHover    = Color(red: 0.155, green: 0.162, blue: 0.188)   // #282934
    public static let divider         = Color(white: 1.0).opacity(0.06)

    // 文字层级
    public static let textPrimary     = Color(white: 0.96)
    public static let textSecondary   = Color(white: 0.66)
    public static let textTertiary    = Color(white: 0.46)
    public static let textDisabled    = Color(white: 0.32)

    // 强调 / 状态
    public static let accent          = Color(red: 1.00, green: 0.35, blue: 0.30)      // warm coral
    public static let accentHover     = Color(red: 1.00, green: 0.45, blue: 0.40)
    public static let success         = Color(red: 0.20, green: 0.78, blue: 0.35)      // #33C759
    public static let warning         = Color(red: 1.00, green: 0.62, blue: 0.04)      // #FF9F0A
    public static let danger          = Color(red: 1.00, green: 0.27, blue: 0.23)      // #FF453A
}

/// 字号 Token
public enum Font2 {
    public static let titleXL: Font = .system(size: 26, weight: .semibold, design: .default)
    public static let titleL:  Font = .system(size: 20, weight: .semibold)
    public static let titleM:  Font = .system(size: 15, weight: .semibold)
    public static let body:    Font = .system(size: 13)
    public static let caption: Font = .system(size: 11)
    public static let tiny:    Font = .system(size: 10, weight: .medium)
    public static let mono:    Font = .system(size: 11, design: .monospaced)
}
