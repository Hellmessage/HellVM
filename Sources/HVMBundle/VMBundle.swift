// .hellvm bundle 读写 —— 每台 VM 是磁盘上的一个目录
// 结构:
//   <uuid>.hellvm/
//     ├── config.json       VM 配置
//     ├── disks/            磁盘镜像
//     └── efi/              EFI 变量存储(VZ 后端)
import Foundation
import HVMCore

/// .hellvm bundle —— 磁盘上的 VM 目录
public struct VMBundle: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    // MARK: - 路径

    public var configURL: URL { url.appendingPathComponent("config.json") }
    public var disksDirURL: URL { url.appendingPathComponent("disks") }
    public var efiDirURL: URL { url.appendingPathComponent("efi") }
    public var logsDirURL: URL { url.appendingPathComponent("logs") }

    /// Logger 统一写入的 per-VM 日志文件 (10MB 滚动)
    public var hellvmLogURL: URL { logsDirURL.appendingPathComponent("hellvm.log") }

    /// 非图形模式(-nographic)的 guest 串口输出文件
    public var serialLogURL: URL { logsDirURL.appendingPathComponent("serial.log") }

    /// 运行时 QEMU PID 文件
    public var pidFileURL: URL { url.appendingPathComponent("qemu.pid") }

    /// 运行时 QMP unix socket(控制通道: start/stop/pause/resume)
    public var qmpSocketURL: URL { url.appendingPathComponent("qmp.sock") }

    /// 运行时 QMP 输入专用 socket(键鼠注入独立通道, 避免与控制通道争抢)
    public var qmpInputSocketURL: URL { url.appendingPathComponent("qmp-input.sock") }

    /// 运行时 iosurface display backend 的 unix socket(Swift 侧作为客户端连入)
    public var iosurfaceSocketURL: URL { url.appendingPathComponent("iosurface.sock") }

    /// QEMU 子进程的 stdout/stderr 日志(GUI 模式下捕获崩溃信息)
    public var qemuLogURL: URL { url.appendingPathComponent("qemu.log") }

    /// 读取 PID 文件,返回 qemu 进程 PID(若存在且能解析)
    public func readPID() -> Int32? {
        guard let data = try? Data(contentsOf: pidFileURL),
              let str = String(data: data, encoding: .utf8),
              let pid = Int32(str.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            return nil
        }
        return pid
    }

    /// 检查 VM 是否正在运行(PID 文件存在 + 进程存活)
    public func isRunning() -> Bool {
        guard let pid = readPID() else { return false }
        // signal 0 检查进程是否存在,不实际发信号
        return kill(pid, 0) == 0
    }

    /// 清理陈旧的运行时文件(PID + socket),确保下次启动干净
    public func cleanupRuntimeFiles() {
        let fm = FileManager.default
        try? fm.removeItem(at: pidFileURL)
        try? fm.removeItem(at: qmpSocketURL)
        try? fm.removeItem(at: qmpInputSocketURL)
        try? fm.removeItem(at: iosurfaceSocketURL)
    }

    /// bundle 内相对路径 → 绝对 URL
    public func resolve(_ relativePath: String) -> URL {
        url.appendingPathComponent(relativePath)
    }

    // MARK: - 默认库位置

    /// ~/Library/Application Support/HellVM/VMs
    public static var defaultLibraryURL: URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("HellVM/VMs", isDirectory: true)
    }

    // MARK: - 创建 / 读取 / 写入

    /// 在指定位置创建一个新 bundle(目录 + 空 disks/)
    public static func create(at url: URL, config: VMConfig) throws -> VMBundle {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            throw VMError.bundleCorrupted("目标已存在:\(url.path)")
        }
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        let bundle = VMBundle(url: url)
        try fm.createDirectory(at: bundle.disksDirURL, withIntermediateDirectories: true)
        try fm.createDirectory(at: bundle.efiDirURL, withIntermediateDirectories: true)
        try bundle.saveConfig(config)
        return bundle
    }

    /// 读取配置
    public func loadConfig() throws -> VMConfig {
        let data = try Data(contentsOf: configURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(VMConfig.self, from: data)
    }

    /// 写入配置(会刷新 updatedAt)
    public func saveConfig(_ config: VMConfig) throws {
        var mutable = config
        mutable.updatedAt = Date()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(mutable)
        try data.write(to: configURL, options: .atomic)
    }

    // MARK: - 列表

    /// 列出默认库里所有 bundle
    public static func listAll() throws -> [VMBundle] {
        let fm = FileManager.default
        let libURL = defaultLibraryURL
        guard fm.fileExists(atPath: libURL.path) else { return [] }
        let entries = try fm.contentsOfDirectory(
            at: libURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        return entries
            .filter { $0.pathExtension == "hellvm" }
            .map { VMBundle(url: $0) }
    }
}
