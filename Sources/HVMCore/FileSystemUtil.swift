// 文件系统小工具 —— 跨模块共用, 避免每个模块各自实现
import Foundation

public extension FileManager {
    /// 幂等删除路径(文件或目录). 不存在跳过; 存在但删除失败写 warn 日志, 不抛异常.
    ///
    /// 使用场景: 清理"陈旧 socket / 旧 ISO / stage 目录"这类副作用, best-effort 语义 —
    /// 即使清不掉也不该阻塞主流程.
    ///
    /// - Parameters:
    ///   - url: 要删除的路径
    ///   - label: 日志里识别清理对象的人类可读描述
    ///   - category: log 分类, 默认 .general
    func removeIfExists(_ url: URL, label: String, category: LogCategory = .general) {
        guard fileExists(atPath: url.path) else { return }
        do {
            try removeItem(at: url)
        } catch {
            log.warn(category, "清理 \(label) 失败 (\(url.path)): \(error.localizedDescription)")
        }
    }
}
