// VM 运行时状态机
import Foundation

/// 虚拟机运行状态
public enum VMState: String, Sendable, Codable {
    case stopped    // 已停止
    case starting   // 启动中
    case running    // 运行中
    case paused     // 已暂停
    case stopping   // 停止中
    case error      // 异常

    /// 是否为稳定状态(非过渡态)
    public var isStable: Bool {
        switch self {
        case .stopped, .running, .paused, .error: return true
        case .starting, .stopping: return false
        }
    }
}
