// 黑色主题色板 —— 集中维护 UI 颜色
import SwiftUI

/// 全局颜色 Token
public enum Theme {
    /// 窗口主背景(纯黑)
    public static let background = Color.black
    /// 侧栏/面板背景(带一点点亮度,区分层次)
    public static let surface = Color(white: 0.08)
    /// 次级面板
    public static let surfaceElevated = Color(white: 0.12)
    /// 分隔线
    public static let divider = Color(white: 0.18)
    /// 主文本
    public static let textPrimary = Color.white
    /// 次文本
    public static let textSecondary = Color(white: 0.65)
    /// 禁用文本
    public static let textDisabled = Color(white: 0.40)
    /// 强调色(按钮 / 焦点边框)
    public static let accent = Color(red: 0.95, green: 0.30, blue: 0.25)
}
