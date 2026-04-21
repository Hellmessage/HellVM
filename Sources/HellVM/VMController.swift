// VM 控制器 —— 封装 GUI 对 VM 的操作(start/stop/pause/resume/remove/create)
import Foundation
import HVMCore
import HVMBundle
import HVMBackendQEMU
import HVMStorage

/// VM 操作集合(无状态,所有方法 async)
struct VMController {
    /// 启动 VM —— Process spawn,store 保活 backend 防 ARC 回收
    @MainActor
    static func start(_ item: VMListItem, store: VMListStore) async throws {
        dbg("start enter name=\(item.config.name) isRunning=\(item.isRunning)")
        let paths = try QEMUPaths.discover()
        dbg("QEMUPaths.discover OK prefix=\(paths.prefix.path)")
        let backend = try QEMUBackend(config: item.config, bundle: item.bundle, paths: paths)
        dbg("backend init OK")
        try await backend.start()
        dbg("backend.start returned")
        store.retainBackend(backend, for: item.id)
        dbg("start exit")
    }

    /// 停止 VM —— QMP system_powerdown → 超时 SIGKILL
    @MainActor
    static func stop(_ item: VMListItem, store: VMListStore, force: Bool = false, timeout: TimeInterval = 30) async throws {
        defer { store.releaseBackend(for: item.id) }

        if force {
            try killPID(item.bundle, signal: SIGKILL)
            return
        }

        let qmp = QMPClient()
        do {
            try await qmp.connect(socketPath: item.bundle.qmpSocketURL.path)
            _ = try await qmp.execute("system_powerdown")
            await qmp.close()
        } catch {
            try killPID(item.bundle, signal: SIGTERM)
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline && item.bundle.isRunning() {
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        if item.bundle.isRunning() {
            try killPID(item.bundle, signal: SIGKILL)
        }
    }

    /// 暂停
    static func pause(_ item: VMListItem) async throws {
        let qmp = QMPClient()
        try await qmp.connect(socketPath: item.bundle.qmpSocketURL.path)
        _ = try await qmp.execute("stop")
        await qmp.close()
    }

    /// 恢复
    static func resume(_ item: VMListItem) async throws {
        let qmp = QMPClient()
        try await qmp.connect(socketPath: item.bundle.qmpSocketURL.path)
        _ = try await qmp.execute("cont")
        await qmp.close()
    }

    /// 删除 bundle(要求 VM 已停止)
    @MainActor
    static func remove(_ item: VMListItem) throws {
        if item.bundle.isRunning() {
            throw VMError.startFailed("VM 正在运行,请先停止")
        }
        try FileManager.default.removeItem(at: item.bundle.url)
    }

    /// 新建 VM
    static func create(
        name: String,
        architecture: VMArchitecture,
        cpu: Int,
        memoryMB: UInt64,
        diskSizeGB: UInt64,
        isoPath: String?
    ) async throws -> VMBundle {
        // 名称校验
        guard !name.isEmpty, !name.contains("/"), !name.contains("\0") else {
            throw VMError.invalidConfig("VM 名称不合法:\(name)")
        }

        // ISO 转绝对路径 + 校验
        var isoAbs: String? = nil
        if let iso = isoPath, !iso.isEmpty {
            let url = URL(fileURLWithPath: iso)
            let abs = url.standardized.resolvingSymlinksInPath().path
            guard FileManager.default.fileExists(atPath: abs) else {
                throw VMError.invalidConfig("ISO 文件不存在:\(abs)")
            }
            isoAbs = abs
        }

        // bundle 位置
        let libURL = VMBundle.defaultLibraryURL
        try FileManager.default.createDirectory(at: libURL, withIntermediateDirectories: true)
        let bundleURL = libURL.appendingPathComponent("\(name).hellvm")
        if FileManager.default.fileExists(atPath: bundleURL.path) {
            throw VMError.invalidConfig("同名 VM 已存在:\(name)")
        }

        // 构造配置 + 创建 bundle
        let disk = DiskConfig(relativePath: "disks/main.qcow2", sizeGB: diskSizeGB, format: .qcow2)
        let config = VMConfig(
            name: name,
            architecture: architecture,
            cpuCount: cpu,
            memoryMB: memoryMB,
            disks: [disk],
            boot: BootConfig(isoPath: isoAbs, efi: true)
        )
        let bundle = try VMBundle.create(at: bundleURL, config: config)

        // 创建磁盘
        let paths = try QEMUPaths.discover()
        let disks = DiskManager(qemuImgPath: paths.qemuImg)
        try await disks.create(
            at: bundle.resolve(disk.relativePath),
            sizeGB: diskSizeGB,
            format: .qcow2
        )
        return bundle
    }

    // MARK: - 内部

    private static func killPID(_ bundle: VMBundle, signal: Int32) throws {
        guard let pid = bundle.readPID() else {
            throw VMError.backendUnavailable("找不到 PID 文件")
        }
        if kill(pid, signal) != 0 && errno != ESRCH {
            throw VMError.stopFailed("kill(\(pid), \(signal)) 失败:\(String(cString: strerror(errno)))")
        }
    }
}

/// 简易文件日志(附加到 /tmp/hellvm.log),方便 GUI 调试
func dbg(_ msg: String, file: String = #file, line: Int = #line) {
    let ts = ISO8601DateFormatter().string(from: Date())
    let f = (file as NSString).lastPathComponent
    let line = "\(ts) [\(f):\(line)] \(msg)\n"
    let url = URL(fileURLWithPath: "/tmp/hellvm.log")
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    } else {
        try? line.write(to: url, atomically: true, encoding: .utf8)
    }
}
