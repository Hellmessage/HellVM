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
        log.info(.backend, "start enter name=\(item.config.name) isRunning=\(item.isRunning)")

        // vmnet 预检: 任一网卡走 vmnet* 但 socket 不存在 → 拒启动并给明确指引,
        // 避免让 QEMU 起来后因为 connect(unix) EACCES 死黑屏
        for net in item.config.networks {
            let status = VMnetSupervisor.status(for: net)
            if status.required && !status.socketExists {
                throw VMError.startFailed("""
                vmnet 后端 socket 不存在: \(status.socketPath ?? "(未知)")
                请到 Settings → 网络 → 点 "安装 vmnet daemon" 一次性初始化 \
                (需管理员密码; 以后重启不用再装).
                """)
            }
        }

        let paths = try QEMUPaths.discover()
        log.debug(.backend, "QEMUPaths.discover OK prefix=\(paths.prefix.path)")
        let backend = try QEMUBackend(config: item.config, bundle: item.bundle, paths: paths)
        log.debug(.backend, "backend init OK")
        try await backend.start()
        log.debug(.backend, "backend.start returned")
        store.retainBackend(backend, for: item.id)
        log.info(.backend, "start exit name=\(item.config.name)")
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
        osType: GuestOSType = .other,
        cpu: Int,
        memoryMB: UInt64,
        diskSizeGB: UInt64,
        isoPath: String?,
        graphical: Bool = true,
        networkMode: NetworkConfig.Mode = .user,
        bridgedInterface: String? = nil
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
        // display/boot/NIC 按 osType 推导默认值: Windows 关闭 virtio-gpu 并启用 TPM/bypass
        // 且 NIC 选 e1000e(开箱自带驱动), Linux/macOS 默认启用 virtio-gpu + virtio-net,
        // other 保持历史行为
        let disk = DiskConfig(relativePath: "disks/main.qcow2", sizeGB: diskSizeGB, format: .qcow2)
        let (display, boot, nic) = VMConfig.defaults(for: osType,
                                                     graphical: graphical,
                                                     isoPath: isoAbs)
        let config = VMConfig(
            name: name,
            architecture: architecture,
            osType: osType,
            cpuCount: cpu,
            memoryMB: memoryMB,
            disks: [disk],
            networks: [NetworkConfig(mode: networkMode,
                                     macAddress: NetworkConfig.generateRandomMAC(),
                                     bridgedInterface: bridgedInterface,
                                     deviceModel: nic)],
            display: display,
            boot: boot
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

    // MARK: - 配置保存(VM 必须停机)

    /// 更新 VM 配置。要求 VM 已停止,写回 config.json 并刷新 store。
    /// 从磁盘读取最新 config 再应用 mutation,避免 VMListItem 快照过期
    @MainActor
    @discardableResult
    static func updateConfig(_ item: VMListItem,
                             store: VMListStore,
                             mutate: (inout VMConfig) throws -> Void) throws -> VMConfig {
        guard !item.bundle.isRunning() else {
            throw VMError.invalidConfig("VM 正在运行,请先停机再修改配置")
        }
        var cfg = try item.bundle.loadConfig()
        try mutate(&cfg)
        try validate(cfg)
        try item.bundle.saveConfig(cfg)
        store.refresh()
        return cfg
    }

    /// 基础配置校验(CPU/内存区间、磁盘非空等)
    private static func validate(_ cfg: VMConfig) throws {
        guard cfg.cpuCount >= 1 && cfg.cpuCount <= 64 else {
            throw VMError.invalidConfig("CPU 核心数需在 1-64 之间: \(cfg.cpuCount)")
        }
        guard cfg.memoryMB >= 128 && cfg.memoryMB <= 262144 else {
            throw VMError.invalidConfig("内存需在 128-262144 MB 之间: \(cfg.memoryMB)")
        }
        guard !cfg.name.isEmpty else {
            throw VMError.invalidConfig("VM 名称不可为空")
        }
    }

    // MARK: - 多磁盘管理(VM 必须停机)

    /// 新增一块磁盘,文件会落在 bundle 的 disks/ 下
    @MainActor
    static func addDisk(_ item: VMListItem,
                        store: VMListStore,
                        sizeGB: UInt64,
                        format: DiskConfig.Format,
                        fileName: String? = nil) async throws {
        guard !item.bundle.isRunning() else {
            throw VMError.invalidConfig("VM 正在运行,请先停机再操作磁盘")
        }
        guard sizeGB >= 1 && sizeGB <= 8192 else {
            throw VMError.invalidConfig("磁盘大小需在 1-8192 GB 之间")
        }
        // 默认文件名 data-<n>.<ext>, 避开和已有 disk 路径冲突
        let ext = format.rawValue
        let used = Set(item.config.disks.map { $0.relativePath })
        var rel = fileName.map { "disks/\($0)" } ?? ""
        if rel.isEmpty {
            var n = item.config.disks.count
            repeat {
                rel = "disks/data-\(n).\(ext)"
                n += 1
            } while used.contains(rel)
        }
        let fullURL = item.bundle.resolve(rel)
        try FileManager.default.createDirectory(
            at: fullURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard !FileManager.default.fileExists(atPath: fullURL.path) else {
            throw VMError.invalidConfig("磁盘文件已存在: \(rel)")
        }

        let qemu = try QEMUPaths.discover()
        try await DiskManager(qemuImgPath: qemu.qemuImg).create(
            at: fullURL, sizeGB: sizeGB, format: format
        )

        try updateConfig(item, store: store) { cfg in
            cfg.disks.append(DiskConfig(relativePath: rel, sizeGB: sizeGB, format: format))
        }
    }

    /// 删除磁盘(同时删文件)。要求至少保留一块磁盘
    @MainActor
    static func removeDisk(_ item: VMListItem,
                           store: VMListStore,
                           at index: Int) throws {
        guard !item.bundle.isRunning() else {
            throw VMError.invalidConfig("VM 正在运行,请先停机再操作磁盘")
        }
        guard index >= 0 && index < item.config.disks.count else {
            throw VMError.invalidConfig("磁盘序号越界: \(index)")
        }
        guard item.config.disks.count > 1 else {
            throw VMError.invalidConfig("至少保留一块磁盘")
        }
        let target = item.config.disks[index]
        let url = item.bundle.resolve(target.relativePath)

        try updateConfig(item, store: store) { cfg in
            cfg.disks.remove(at: index)
        }
        // config 已写回, 再删文件(即使删文件失败, 配置已正确)
        try? FileManager.default.removeItem(at: url)
    }

    /// 扩容磁盘。qemu-img 只支持变大, 缩小不做(数据丢失风险)
    @MainActor
    static func resizeDisk(_ item: VMListItem,
                           store: VMListStore,
                           at index: Int,
                           newSizeGB: UInt64) async throws {
        guard !item.bundle.isRunning() else {
            throw VMError.invalidConfig("VM 正在运行,请先停机再操作磁盘")
        }
        guard index >= 0 && index < item.config.disks.count else {
            throw VMError.invalidConfig("磁盘序号越界: \(index)")
        }
        let disk = item.config.disks[index]
        guard newSizeGB > disk.sizeGB else {
            throw VMError.invalidConfig("只支持扩容(当前 \(disk.sizeGB)G → 目标 \(newSizeGB)G)")
        }

        let qemu = try QEMUPaths.discover()
        try await DiskManager(qemuImgPath: qemu.qemuImg).resize(
            at: item.bundle.resolve(disk.relativePath), newSizeGB: newSizeGB
        )
        try updateConfig(item, store: store) { cfg in
            cfg.disks[index].sizeGB = newSizeGB
        }
    }

    /// 转换磁盘格式(qcow2 ↔ raw)
    @MainActor
    static func convertDisk(_ item: VMListItem,
                            store: VMListStore,
                            at index: Int,
                            to newFormat: DiskConfig.Format) async throws {
        guard !item.bundle.isRunning() else {
            throw VMError.invalidConfig("VM 正在运行,请先停机再操作磁盘")
        }
        guard index >= 0 && index < item.config.disks.count else {
            throw VMError.invalidConfig("磁盘序号越界: \(index)")
        }
        let disk = item.config.disks[index]
        guard disk.format != newFormat else { return }

        let qemu = try QEMUPaths.discover()
        let url = item.bundle.resolve(disk.relativePath)
        try await DiskManager(qemuImgPath: qemu.qemuImg).convert(
            at: url, from: disk.format, to: newFormat
        )
        // 重命名文件扩展名以对齐格式(disks/main.qcow2 → disks/main.raw)
        var newRel = disk.relativePath
        if newRel.lowercased().hasSuffix(".\(disk.format.rawValue)") {
            newRel = String(newRel.dropLast(disk.format.rawValue.count + 1))
                + ".\(newFormat.rawValue)"
            let newURL = item.bundle.resolve(newRel)
            if url.path != newURL.path,
               !FileManager.default.fileExists(atPath: newURL.path) {
                try FileManager.default.moveItem(at: url, to: newURL)
            } else {
                newRel = disk.relativePath   // 目标名冲突, 保留原路径
            }
        }
        try updateConfig(item, store: store) { cfg in
            cfg.disks[index].format = newFormat
            cfg.disks[index].relativePath = newRel
        }
    }

    /// 调整磁盘顺序(第一块约定为启动盘)
    @MainActor
    static func moveDisk(_ item: VMListItem,
                         store: VMListStore,
                         from: Int,
                         to: Int) throws {
        guard !item.bundle.isRunning() else {
            throw VMError.invalidConfig("VM 正在运行,请先停机再操作磁盘")
        }
        try updateConfig(item, store: store) { cfg in
            guard from >= 0 && from < cfg.disks.count,
                  to >= 0 && to < cfg.disks.count else {
                throw VMError.invalidConfig("磁盘序号越界")
            }
            let d = cfg.disks.remove(at: from)
            cfg.disks.insert(d, at: to)
        }
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

