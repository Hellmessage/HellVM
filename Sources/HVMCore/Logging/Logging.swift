// 全局日志管理器
//
// 设计:
// - 单例 Logger.shared, 公开 `log` 全局快捷变量
// - 等级 off/error/warn/info/debug/trace; autoclosure 实现关闭等级时零开销
// - 分类(LogCategory): general/ui/backend/qmp/display/input, 可扩展
// - 双 sink:
//     globalSink  = ~/Library/Logs/HellVM/hellvm.log  (App 级)
//     activeVMSink = <bundle>/logs/hellvm.log         (详情页选中的 VM)
// - 每个 sink 独立 10MB 滚动(超过时 .log -> .log.1, 覆盖旧 .1)
// - 配置持久化到 UserDefaults(level / enabled / fileEnabled / categoryOverrides)
import Foundation

// MARK: - 等级 & 分类

public enum LogLevel: Int, Sendable, Comparable, CaseIterable {
    case off   = 0
    case error = 1
    case warn  = 2
    case info  = 3
    case debug = 4
    case trace = 5

    public var label: String {
        switch self {
        case .off:   return "OFF"
        case .error: return "ERROR"
        case .warn:  return "WARN"
        case .info:  return "INFO"
        case .debug: return "DEBUG"
        case .trace: return "TRACE"
        }
    }

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

public struct LogCategory: Sendable, Hashable {
    public let name: String
    public init(_ name: String) { self.name = name }

    public static let general = LogCategory("general")
    public static let ui      = LogCategory("ui")
    public static let backend = LogCategory("backend")
    public static let qmp     = LogCategory("qmp")
    public static let display = LogCategory("display")
    public static let input   = LogCategory("input")
    /// QEMU 子进程原始 stdout/stderr(逐行)
    public static let qemu    = LogCategory("qemu")

    /// 所有预定义分类(用于 UI 设置面板); 自定义 category 不会出现在此列表
    public static let known: [LogCategory] = [
        .general, .ui, .backend, .qmp, .display, .input, .qemu
    ]
}

// MARK: - 滚动文件 Sink

final class RotatingFileSink: @unchecked Sendable {
    let fileURL: URL
    let maxBytes: Int
    private var handle: FileHandle?
    private let lock = NSLock()

    init(fileURL: URL, maxBytes: Int) {
        self.fileURL = fileURL
        self.maxBytes = maxBytes
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        openOrCreate()
    }

    private func openOrCreate() {
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: fileURL)
        _ = try? handle?.seekToEnd()
    }

    func write(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        lock.lock()
        defer { lock.unlock() }
        guard let h = handle else { return }
        do {
            try h.write(contentsOf: data)
        } catch {
            return
        }
        // 检查大小
        if let size = try? h.offset(), size >= UInt64(maxBytes) {
            rotateLocked()
        }
    }

    private func rotateLocked() {
        // 关 handle → rename .log -> .log.1 → 新建 → reopen
        try? handle?.close()
        handle = nil
        let rotated = fileURL.deletingPathExtension().appendingPathExtension("log.1")
        try? FileManager.default.removeItem(at: rotated)
        try? FileManager.default.moveItem(at: fileURL, to: rotated)
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        handle = try? FileHandle(forWritingTo: fileURL)
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        try? handle?.close()
        handle = nil
    }

    deinit { close() }
}

// MARK: - Logger

public final class Logger: @unchecked Sendable {
    public static let shared = Logger()

    // --- 配置(带锁) ---
    private let lock = NSLock()
    private var _enabled = true
    private var _globalLevel: LogLevel = .info
    private var _categoryOverrides: [String: LogLevel] = [:]
    private var _stderrEnabled = false
    private var _fileEnabled = true

    // --- sinks ---
    // 所有 sink 访问(write / rotate / 切换) 都被调度到 flushQueue 串行执行,
    // 把 IO 从调用线程抽走。好处:
    //   - QEMU 高频 stdout/stderr (每秒几十行) 不再阻塞主/worker 线程
    //   - 日志滚动 (rename + mkdir) 也在后台, 不卡 UI
    // 代价: 进程崩溃时尾部 pending 日志会丢 (等价于 stdio line-buffered, 可接受)
    private let flushQueue = DispatchQueue(label: "hellvm.logger.flush", qos: .utility)
    // 以下 sink 字段只在 flushQueue 上下文访问, 不需要额外 lock.
    private var globalSink: RotatingFileSink?
    private var activeVMSink: RotatingFileSink?
    public private(set) var activeVMBundleURL: URL?

    public let globalLogURL: URL = {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Logs/HellVM/hellvm.log")
    }()

    public var activeVMLogURL: URL? {
        // 从 activeVMBundleURL 推算, 避免跨 queue 访问 activeVMSink
        lock.lock(); defer { lock.unlock() }
        return activeVMBundleURL?.appendingPathComponent("logs/hellvm.log")
    }

    public static let maxBytes = 10 * 1024 * 1024

    private init() {
        loadFromDefaults()
        if _fileEnabled {
            globalSink = RotatingFileSink(fileURL: globalLogURL, maxBytes: Self.maxBytes)
        }
    }

    // MARK: - 配置接口

    public var isEnabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _enabled }
        set { lock.lock(); _enabled = newValue; lock.unlock(); saveToDefaults() }
    }

    public var globalLevel: LogLevel {
        get { lock.lock(); defer { lock.unlock() }; return _globalLevel }
        set { lock.lock(); _globalLevel = newValue; lock.unlock(); saveToDefaults() }
    }

    public var stderrEnabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _stderrEnabled }
        set { lock.lock(); _stderrEnabled = newValue; lock.unlock(); saveToDefaults() }
    }

    public var fileEnabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _fileEnabled }
        set {
            lock.lock()
            _fileEnabled = newValue
            let activeBundle = activeVMBundleURL
            lock.unlock()
            // sink 切换异步跑在 flushQueue, 确保与 write 串行
            flushQueue.async { [self] in
                if newValue {
                    if globalSink == nil {
                        globalSink = RotatingFileSink(fileURL: globalLogURL, maxBytes: Self.maxBytes)
                    }
                    if activeVMSink == nil, let url = activeBundle {
                        let logURL = url.appendingPathComponent("logs/hellvm.log")
                        activeVMSink = RotatingFileSink(fileURL: logURL, maxBytes: Self.maxBytes)
                    }
                } else {
                    globalSink?.close();   globalSink = nil
                    activeVMSink?.close(); activeVMSink = nil
                }
            }
            saveToDefaults()
        }
    }

    public func level(for category: LogCategory) -> LogLevel {
        lock.lock(); defer { lock.unlock() }
        return _categoryOverrides[category.name] ?? _globalLevel
    }

    public func setLevel(_ level: LogLevel?, for category: LogCategory) {
        lock.lock()
        if let level {
            _categoryOverrides[category.name] = level
        } else {
            _categoryOverrides.removeValue(forKey: category.name)
        }
        lock.unlock()
        saveToDefaults()
    }

    public var allCategoryOverrides: [String: LogLevel] {
        lock.lock(); defer { lock.unlock() }
        return _categoryOverrides
    }

    // MARK: - active VM sink

    /// 设置当前详情页选中的 VM;  nil = 无 VM 上下文
    public func setActiveVM(bundleURL: URL?) {
        lock.lock()
        if activeVMBundleURL == bundleURL {
            lock.unlock(); return
        }
        activeVMBundleURL = bundleURL
        let fileEn = _fileEnabled
        lock.unlock()
        // sink 切换异步: 排在 pending writes 之后, 不会写到半关闭 handle
        flushQueue.async { [self] in
            activeVMSink?.close()
            activeVMSink = nil
            if let url = bundleURL, fileEn {
                let logURL = url.appendingPathComponent("logs/hellvm.log")
                activeVMSink = RotatingFileSink(fileURL: logURL, maxBytes: Self.maxBytes)
            }
        }
    }

    // MARK: - 日志入口

    public func log(_ level: LogLevel,
                    _ category: LogCategory = .general,
                    _ message: @autoclosure () -> String,
                    file: String = #fileID,
                    line: Int = #line) {
        guard shouldLog(level: level, category: category) else { return }
        let rendered = format(level: level, category: category,
                              message: message(), file: file, line: line)
        emit(rendered)
    }

    private func shouldLog(level: LogLevel, category: LogCategory) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard _enabled else { return false }
        let threshold = _categoryOverrides[category.name] ?? _globalLevel
        return level.rawValue <= threshold.rawValue && level != .off
    }

    private func format(level: LogLevel, category: LogCategory,
                        message: String, file: String, line: Int) -> String {
        // 时间 [LEVEL] [category] (file:line) message
        let ts = Self.tsFormatter.string(from: Date())
        let shortFile = file.split(separator: "/").last.map(String.init) ?? file
        return "\(ts) [\(level.label)] [\(category.name)] (\(shortFile):\(line)) \(message)\n"
    }

    private static let tsFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private func emit(_ line: String) {
        // stderr 同步输出 (调试用, 低频且需立即可见)
        if stderrEnabled {
            FileHandle.standardError.write(Data(line.utf8))
        }
        // file sinks 异步写 —— 调用者只付入队开销, 真实 IO 在 flushQueue
        flushQueue.async { [self] in
            globalSink?.write(line)
            activeVMSink?.write(line)
        }
    }

    /// 等待当前排队的日志写完 (测试 / 优雅关机用)
    public func flush() {
        flushQueue.sync { /* barrier */ }
    }

    // MARK: - 便利方法

    public func error(_ cat: LogCategory = .general,
                      _ msg: @autoclosure () -> String,
                      file: String = #fileID, line: Int = #line) {
        log(.error, cat, msg(), file: file, line: line)
    }
    public func warn(_ cat: LogCategory = .general,
                     _ msg: @autoclosure () -> String,
                     file: String = #fileID, line: Int = #line) {
        log(.warn, cat, msg(), file: file, line: line)
    }
    public func info(_ cat: LogCategory = .general,
                     _ msg: @autoclosure () -> String,
                     file: String = #fileID, line: Int = #line) {
        log(.info, cat, msg(), file: file, line: line)
    }
    public func debug(_ cat: LogCategory = .general,
                      _ msg: @autoclosure () -> String,
                      file: String = #fileID, line: Int = #line) {
        log(.debug, cat, msg(), file: file, line: line)
    }
    public func trace(_ cat: LogCategory = .general,
                      _ msg: @autoclosure () -> String,
                      file: String = #fileID, line: Int = #line) {
        log(.trace, cat, msg(), file: file, line: line)
    }

    // MARK: - UserDefaults 持久化

    private static let dKeyEnabled   = "hellvm.logger.enabled"
    private static let dKeyLevel     = "hellvm.logger.level"
    private static let dKeyFile      = "hellvm.logger.fileEnabled"
    private static let dKeyStderr    = "hellvm.logger.stderrEnabled"
    private static let dKeyOverrides = "hellvm.logger.categoryOverrides"

    private func loadFromDefaults() {
        let d = UserDefaults.standard
        if d.object(forKey: Self.dKeyEnabled) != nil {
            _enabled = d.bool(forKey: Self.dKeyEnabled)
        }
        if let raw = d.object(forKey: Self.dKeyLevel) as? Int,
           let lv = LogLevel(rawValue: raw) {
            _globalLevel = lv
        }
        if d.object(forKey: Self.dKeyFile) != nil {
            _fileEnabled = d.bool(forKey: Self.dKeyFile)
        }
        if d.object(forKey: Self.dKeyStderr) != nil {
            _stderrEnabled = d.bool(forKey: Self.dKeyStderr)
        }
        if let dict = d.dictionary(forKey: Self.dKeyOverrides) as? [String: Int] {
            for (k, v) in dict {
                if let lv = LogLevel(rawValue: v) {
                    _categoryOverrides[k] = lv
                }
            }
        }
    }

    private func saveToDefaults() {
        lock.lock()
        let enabled = _enabled
        let level = _globalLevel.rawValue
        let fileEn = _fileEnabled
        let stderrEn = _stderrEnabled
        let overrides = _categoryOverrides.mapValues { $0.rawValue }
        lock.unlock()
        let d = UserDefaults.standard
        d.set(enabled,  forKey: Self.dKeyEnabled)
        d.set(level,    forKey: Self.dKeyLevel)
        d.set(fileEn,   forKey: Self.dKeyFile)
        d.set(stderrEn, forKey: Self.dKeyStderr)
        d.set(overrides, forKey: Self.dKeyOverrides)
    }
}

/// 全局快捷变量: `log.info(.input, "foo")`
public let log = Logger.shared
