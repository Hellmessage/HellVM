// VirtioWinManager —— 全局 virtio-win.iso 缓存的下载与状态管理
//
// virtio-win.iso 是 Red Hat 打包的 Windows 驱动合集 (NetKVM / viostor / viogpudo / qemu-ga 等),
// 约 700MB, 所有 Windows guest VM 共享同一份只读挂载。
//
// 缓存策略:
// - 唯一存放位置: VMBundle.virtioWinCacheURL  (~/Library/Application Support/HellVM/cache/virtio-win.iso)
// - 首次下载: 用户创建 Windows VM 时在 Wizard 弹进度条触发
// - 后续所有 VM 共用这个路径, 不再重复下载
//
// 源:
// - Red Hat 官方 stable 频道直链 (可通过 VIRTIO_WIN_URL env 覆盖)
//
// 失败策略: 下载失败时允许用户跳过, VM 仍能创建(只是 autoInstallVirtioWin 生效不了,
// e1000e 仍可用)。

import Foundation
import HVMCore
import HVMBundle

public struct VirtioWinStatus: Sendable {
    public var exists: Bool           // 缓存文件存在
    public var path: String           // 缓存路径(总是返回, 便于 UI 展示)
    public var sizeBytes: Int64?      // 存在时文件大小
}

@MainActor
public final class VirtioWinManager: ObservableObject {
    public static let shared = VirtioWinManager()

    /// 官方 stable 直链. 环境变量 VIRTIO_WIN_URL 可覆盖(离线镜像 / 国内镜像用).
    public static var downloadURL: URL {
        if let env = ProcessInfo.processInfo.environment["VIRTIO_WIN_URL"],
           let u = URL(string: env) {
            return u
        }
        return URL(string:
            "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso"
        )!
    }

    /// 当前下载进度 (0..1), 不在下载时为 nil. 供 SwiftUI 绑定.
    @Published public private(set) var downloadProgress: Double?
    /// 最近一次下载错误消息(UI 展示).
    @Published public private(set) var lastError: String?
    /// 下载任务句柄, 取消时用
    private var currentTask: URLSessionDownloadTask?

    private init() {}

    // MARK: - 状态查询

    public static func status() -> VirtioWinStatus {
        let url = VMBundle.virtioWinCacheURL
        let fm = FileManager.default
        if let attr = try? fm.attributesOfItem(atPath: url.path),
           let size = attr[.size] as? Int64, size > 0 {
            return VirtioWinStatus(exists: true, path: url.path, sizeBytes: size)
        }
        return VirtioWinStatus(exists: false, path: url.path, sizeBytes: nil)
    }

    public var isDownloading: Bool { currentTask != nil }

    // MARK: - 下载

    /// 下载 virtio-win.iso 到全局缓存.  已存在则直接返回.
    /// 进度通过 @Published downloadProgress 推送, UI 层观察即可.
    public func downloadIfNeeded() async throws {
        if Self.status().exists { return }

        lastError = nil
        downloadProgress = 0

        let cacheDir = VMBundle.cacheDirURL
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        log.info(.ui, "virtio-win: 开始下载 \(Self.downloadURL.absoluteString)")
        let dest = VMBundle.virtioWinCacheURL
        let tmp = dest.appendingPathExtension("part")
        // 旧 .part 残留清一下, 避免 URLSession resume 歧义
        try? FileManager.default.removeItem(at: tmp)

        do {
            try await runDownload(to: tmp)
            // 原子替换
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmp, to: dest)
            downloadProgress = nil
            log.info(.ui, "virtio-win: 下载完成 \(dest.path)")
        } catch {
            downloadProgress = nil
            lastError = "下载失败: \(error.localizedDescription)"
            try? FileManager.default.removeItem(at: tmp)
            log.warn(.ui, "virtio-win: 下载失败 \(error)")
            throw error
        }
    }

    public func cancelDownload() {
        currentTask?.cancel()
        currentTask = nil
        downloadProgress = nil
    }

    private func runDownload(to tmp: URL) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let delegate = DownloadDelegate(
                onProgress: { [weak self] p in
                    Task { @MainActor in self?.downloadProgress = p }
                },
                onFinish: { [weak self] result in
                    Task { @MainActor in self?.currentTask = nil }
                    switch result {
                    case .success(let srcURL):
                        do {
                            // URLSession 把文件下到临时路径, 我们 move 到 .part
                            try? FileManager.default.removeItem(at: tmp)
                            try FileManager.default.moveItem(at: srcURL, to: tmp)
                            cont.resume()
                        } catch {
                            cont.resume(throwing: error)
                        }
                    case .failure(let err):
                        cont.resume(throwing: err)
                    }
                }
            )
            let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
            let task = session.downloadTask(with: Self.downloadURL)
            currentTask = task
            task.resume()
        }
    }
}

/// URLSession downloadTask 代理: 桥接进度和完成回调到 closure
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let onProgress: @Sendable (Double) -> Void
    let onFinish: @Sendable (Result<URL, Error>) -> Void
    /// 避免 willSwitch / didFinishDownloadingTo 都调 onFinish
    private var delivered = false
    private let lock = NSLock()

    init(onProgress: @escaping @Sendable (Double) -> Void,
         onFinish: @escaping @Sendable (Result<URL, Error>) -> Void) {
        self.onProgress = onProgress
        self.onFinish = onFinish
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let p = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        onProgress(p)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // didFinishDownloadingTo 之后 URLSession 会立刻清理 location,
        // 必须同步把文件 move 走. 这里先拷到 delegate 临时路径, 再交出去.
        lock.lock(); defer { lock.unlock() }
        guard !delivered else { return }
        delivered = true

        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("virtio-win-\(UUID().uuidString).iso")
        do {
            try FileManager.default.moveItem(at: location, to: tmp)
            onFinish(.success(tmp))
        } catch {
            onFinish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        lock.lock(); defer { lock.unlock() }
        guard !delivered else { return }
        if let err = error {
            delivered = true
            onFinish(.failure(err))
        }
        // 无 error 时 didFinishDownloadingTo 已经处理过了
    }
}
