// VM 后端协议 —— VZ / QEMU 各自实现
import Foundation

/// 虚拟机运行时后端抽象
public protocol VMBackend: AnyObject {
    /// 当前状态
    var state: VMState { get }

    /// 状态变化事件流
    var stateStream: AsyncStream<VMState> { get }

    /// 启动 VM
    func start() async throws

    /// 停止 VM(force=true 等同强制断电)
    func stop(force: Bool) async throws

    /// 暂停
    func pause() async throws

    /// 恢复
    func resume() async throws
}

/// VM 相关错误
///
/// 同时实现 `LocalizedError`, 让 Swift NSError 桥接时 `localizedDescription` 返回
/// 中文描述而不是 "The operation couldn't be completed. (HVMCore.VMError error N.)".
public enum VMError: Error, CustomStringConvertible, LocalizedError {
    case invalidConfig(String)
    case backendUnavailable(String)
    case startFailed(String)
    case stopFailed(String)
    case bundleCorrupted(String)
    case diskOperationFailed(String)
    case notImplemented(String)

    public var description: String {
        switch self {
        case .invalidConfig(let m):      return "配置无效:\(m)"
        case .backendUnavailable(let m): return "后端不可用:\(m)"
        case .startFailed(let m):        return "启动失败:\(m)"
        case .stopFailed(let m):         return "停止失败:\(m)"
        case .bundleCorrupted(let m):    return "Bundle 损坏:\(m)"
        case .diskOperationFailed(let m): return "磁盘操作失败:\(m)"
        case .notImplemented(let m):     return "尚未实现:\(m)"
        }
    }

    public var errorDescription: String? { description }
}
