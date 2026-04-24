// SpiceToolsManager —— 全局 spice-guest-tools.exe 缓存的下载与状态管理
//
// spice-guest-tools 是 spice-space.org 官方 Windows 安装包(NSIS), 含:
// - spice-vdagent 服务 (Windows service, 响应 host 的 MONITORS_CONFIG 切分辨率)
// - 可选的 virtio-serial / USBDK 驱动(若未单独装 virtio-win)
// 体积 ~30MB, 所有 Windows guest VM 共用一份, 通过 AutoUnattend ISO 打进新装 VM,
// FirstLogonCommands 里 `/S` 静默安装。
//
// 缓存策略:
// - 唯一存放位置: VMBundle.spiceToolsCacheURL
//   (~/Library/Application Support/HellVM/cache/spice-guest-tools.exe)
// - 首次下载: 用户创建 Windows VM 时在 Wizard 或 Settings 触发
// - 后续 VM 共用, 不再重复下载
//
// 源:
// - spice-space.org 官方 latest 直链 (可通过 SPICE_GUEST_TOOLS_URL env 覆盖)
//
// 失败策略: 下载失败允许用户跳过, VM 仍能启动(只是拖窗口 resize 在 Windows 上
// 不自动生效; Linux guest 不受影响)。

import Foundation
import HVMCore
import HVMBundle

public struct SpiceToolsStatus: Sendable {
    public var exists: Bool           // 缓存文件存在
    public var path: String           // 缓存路径(总是返回, 便于 UI 展示)
    public var sizeBytes: Int64?      // 存在时文件大小
}

@MainActor
public final class SpiceToolsManager: ObservableObject {
    public static let shared = SpiceToolsManager()

    /// 官方 latest 直链. 环境变量 SPICE_GUEST_TOOLS_URL 可覆盖(离线镜像 / 内部镜像).
    public static var downloadURL: URL {
        if let env = ProcessInfo.processInfo.environment["SPICE_GUEST_TOOLS_URL"],
           let u = URL(string: env) {
            return u
        }
        return URL(string:
            "https://www.spice-space.org/download/binaries/spice-guest-tools/spice-guest-tools-latest.exe"
        )!
    }

    /// 当前下载进度 (0..1), 不在下载时为 nil. SwiftUI 绑定用.
    @Published public private(set) var downloadProgress: Double?
    /// 最近一次下载错误消息(UI 展示).
    @Published public private(set) var lastError: String?
    private var currentTask: URLSessionDownloadTask?

    private init() {}

    // MARK: - 状态查询

    public static func status() -> SpiceToolsStatus {
        let url = VMBundle.spiceToolsCacheURL
        let fm = FileManager.default
        if let attr = try? fm.attributesOfItem(atPath: url.path),
           let size = attr[.size] as? Int64, size > 0 {
            return SpiceToolsStatus(exists: true, path: url.path, sizeBytes: size)
        }
        return SpiceToolsStatus(exists: false, path: url.path, sizeBytes: nil)
    }

    public var isDownloading: Bool { currentTask != nil }

    // MARK: - 下载

    /// 下载 spice-guest-tools.exe 到全局缓存. 已存在则直接返回.
    public func downloadIfNeeded() async throws {
        if Self.status().exists { return }

        lastError = nil
        downloadProgress = 0

        let cacheDir = VMBundle.cacheDirURL
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        log.info(.ui, "spice-guest-tools: 开始下载 \(Self.downloadURL.absoluteString)")
        let dest = VMBundle.spiceToolsCacheURL
        let tmp = dest.appendingPathExtension("part")
        let fm = FileManager.default
        fm.removeIfExists(tmp, label: "陈旧 spice-guest-tools .part", category: .ui)

        do {
            try await runDownload(to: tmp)
            fm.removeIfExists(dest, label: "旧 spice-guest-tools.exe", category: .ui)
            try fm.moveItem(at: tmp, to: dest)
            downloadProgress = nil
            log.info(.ui, "spice-guest-tools: 下载完成 \(dest.path)")
        } catch {
            downloadProgress = nil
            lastError = "下载失败: \(error.localizedDescription)"
            fm.removeIfExists(tmp, label: "下载失败后的 .part", category: .ui)
            log.warn(.ui, "spice-guest-tools: 下载失败 \(error)")
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
            let delegate = SpiceDownloadDelegate(
                onProgress: { [weak self] p in
                    Task { @MainActor in self?.downloadProgress = p }
                },
                onFinish: { [weak self] result in
                    Task { @MainActor in self?.currentTask = nil }
                    switch result {
                    case .success(let srcURL):
                        do {
                            FileManager.default.removeIfExists(tmp, label: "残留 .part 中间文件", category: .ui)
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

/// URLSession downloadTask 代理: 桥接进度和完成回调到 closure.
/// 另起一个类, 和 VirtioWinManager 内那份解耦, 避免 cross-module visibility。
private final class SpiceDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let onProgress: @Sendable (Double) -> Void
    let onFinish: @Sendable (Result<URL, Error>) -> Void
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
        lock.lock(); defer { lock.unlock() }
        guard !delivered else { return }
        delivered = true

        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("spice-guest-tools-\(UUID().uuidString).exe")
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
    }
}
