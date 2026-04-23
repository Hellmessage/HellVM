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

        do {
            try await QMPClient.withSession(socketPath: item.bundle.qmpSocketURL.path) { qmp in
                _ = try await qmp.execute("system_powerdown")
            }
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

    /// 强制关机 —— 介于"停止"与"断电"之间:
    /// - 不发 ACPI power button(跳过 guest 优雅关机流程, guest 看起来像瞬间断电)
    /// - 但通过 QMP `quit` 让 QEMU 进程**自己清理退出**(刷盘/关 fd/结 socket),
    ///   而不是被 SIGKILL 硬杀, 减少磁盘写入 race 损坏风险
    /// - QMP 命令失败时 fallback 到 SIGTERM, 再不行才 SIGKILL
    @MainActor
    static func forceShutdown(_ item: VMListItem, store: VMListStore, timeout: TimeInterval = 5) async throws {
        defer { store.releaseBackend(for: item.id) }

        do {
            try await QMPClient.withSession(socketPath: item.bundle.qmpSocketURL.path) { qmp in
                _ = try await qmp.execute("quit")
            }
        } catch {
            // QMP socket 已断或不响应, 退而求其次发 SIGTERM
            try? killPID(item.bundle, signal: SIGTERM)
        }

        // 短等 QEMU 自退 —— quit/SIGTERM 都应在秒级生效
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline && item.bundle.isRunning() {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        if item.bundle.isRunning() {
            try killPID(item.bundle, signal: SIGKILL)
        }
    }

    /// 暂停
    static func pause(_ item: VMListItem) async throws {
        try await QMPClient.withSession(socketPath: item.bundle.qmpSocketURL.path) { qmp in
            _ = try await qmp.execute("stop")
        }
    }

    /// 恢复
    static func resume(_ item: VMListItem) async throws {
        try await QMPClient.withSession(socketPath: item.bundle.qmpSocketURL.path) { qmp in
            _ = try await qmp.execute("cont")
        }
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

    /// 从现有磁盘镜像导入创建 VM (OpenWrt / cloud image 等已装好的系统)
    ///
    /// 与 create() 的差异:
    ///   - 不创建空盘, 也不挂 ISO, 直接把 image 转成 qcow2 当启动盘
    ///   - 支持 .img / .raw / .qcow2 以及 .gz / .xz 压缩格式 (见 DiskManager.importImage)
    ///   - 可选 expandToGB 扩容到目标大小
    ///   - boot.bootFromDiskOnly 默认 true (镜像已是装好的系统, 不需要挂 ISO)
    ///
    /// 失败时自动删除已创建的 bundle, 保持原子性 —— 不留半坏 VM。
    static func createFromImage(
        name: String,
        architecture: VMArchitecture,
        osType: GuestOSType = .linux,
        cpu: Int,
        memoryMB: UInt64,
        imagePath: String,
        expandToGB: UInt64?,
        graphical: Bool = true,
        networkMode: NetworkConfig.Mode = .user,
        bridgedInterface: String? = nil
    ) async throws -> VMBundle {
        // 名称校验
        guard !name.isEmpty, !name.contains("/"), !name.contains("\0") else {
            throw VMError.invalidConfig("VM 名称不合法:\(name)")
        }

        // 镜像校验
        let imageURL = URL(fileURLWithPath: imagePath).standardized.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: imageURL.path) else {
            throw VMError.invalidConfig("镜像文件不存在:\(imageURL.path)")
        }

        // bundle 位置
        let libURL = VMBundle.defaultLibraryURL
        try FileManager.default.createDirectory(at: libURL, withIntermediateDirectories: true)
        let bundleURL = libURL.appendingPathComponent("\(name).hellvm")
        if FileManager.default.fileExists(atPath: bundleURL.path) {
            throw VMError.invalidConfig("同名 VM 已存在:\(name)")
        }

        // 构造配置: 使用 OS 默认 (Windows 关 virtio-gpu / 启 TPM, 等),
        // isoPath=nil 且 bootFromDiskOnly=true → QEMU 启动直接走硬盘
        let disk = DiskConfig(relativePath: "disks/main.qcow2",
                              sizeGB: expandToGB ?? 1,  // 临时占位, 导入后用实际大小覆盖
                              format: .qcow2)
        var (display, boot, nic) = VMConfig.defaults(for: osType,
                                                     graphical: graphical,
                                                     isoPath: nil)
        boot.bootFromDiskOnly = true  // 从镜像导入 → 直接从硬盘启动, 不挂 ISO
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

        // 原子性: 转换/扩容失败就把 bundle 整个删掉, 避免残留半坏 VM
        let paths = try QEMUPaths.discover()
        let disks = DiskManager(qemuImgPath: paths.qemuImg)
        do {
            try await disks.importImage(
                from: imageURL,
                to: bundle.resolve(disk.relativePath),
                expandToGB: expandToGB
            )
        } catch {
            try? FileManager.default.removeItem(at: bundleURL)
            throw error
        }

        // 导入成功后, 把实际磁盘容量写回 config.json (从 qemu-img info 拿真值)
        do {
            let info = try await disks.info(at: bundle.resolve(disk.relativePath))
            let actualGB = max(UInt64(1), info.virtualSizeBytes / (1024 * 1024 * 1024))
            var cfg = try bundle.loadConfig()
            if !cfg.disks.isEmpty {
                cfg.disks[0].sizeGB = actualGB
                try bundle.saveConfig(cfg)
            }
        } catch {
            // 拿不到 info 不致命, config 里的 sizeGB 只是显示用
            log.warn(.backend, "读取导入后磁盘大小失败: \(error.localizedDescription)")
        }

        return bundle
    }

    // MARK: - 配置保存(VM 必须停机)

    /// 更新 VM 配置。要求 VM 已停止,写回 config.json 并刷新 store。
    /// 从磁盘读取最新 config 再应用 mutation,避免 VMListItem 快照过期
    @MainActor
    @discardableResult
    static func updateConfig(_ item: VMListItem,
                             store: VMListStore,
                             allowWhenRunning: Bool = false,
                             mutate: (inout VMConfig) throws -> Void) throws -> VMConfig {
        let running = item.bundle.isRunning()
        if running && !allowWhenRunning {
            throw VMError.invalidConfig("VM 正在运行,请先停机再修改配置")
        }
        let original = try item.bundle.loadConfig()
        var cfg = original
        try mutate(&cfg)
        if running {
            // 运行中只允许网络字段改动(走 QMP 热插拔); 其他字段保持不变, 否则拒绝
            var hotSafe = cfg
            hotSafe.networks = original.networks
            if !configsEquivalent(hotSafe, original) {
                throw VMError.invalidConfig("VM 运行中仅允许改网络, 其它字段请先停机")
            }
        }
        try validate(cfg)
        try item.bundle.saveConfig(cfg)
        store.refresh()
        return cfg
    }

    /// 结构等价比较(忽略 updatedAt). Equatable 合成太烦, 手写关键字段对比更直观.
    private static func configsEquivalent(_ a: VMConfig, _ b: VMConfig) -> Bool {
        a.name == b.name &&
        a.architecture == b.architecture &&
        a.osType == b.osType &&
        a.cpuCount == b.cpuCount &&
        a.memoryMB == b.memoryMB &&
        a.display == b.display &&
        a.boot == b.boot &&
        a.disks.count == b.disks.count &&
        zip(a.disks, b.disks).allSatisfy {
            $0.relativePath == $1.relativePath &&
            $0.sizeGB == $1.sizeGB &&
            $0.format == $1.format &&
            $0.readOnly == $1.readOnly
        }
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
        try requireStoppedForDiskOp(item)
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
        try requireStoppedForDiskOp(item)
        try requireValidDiskIndex(index, in: item.config.disks)
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
        try requireStoppedForDiskOp(item)
        try requireValidDiskIndex(index, in: item.config.disks)
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
        try requireStoppedForDiskOp(item)
        try requireValidDiskIndex(index, in: item.config.disks)
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
        try requireStoppedForDiskOp(item)
        try updateConfig(item, store: store) { cfg in
            try requireValidDiskIndex(from, in: cfg.disks)
            try requireValidDiskIndex(to, in: cfg.disks)
            let d = cfg.disks.remove(at: from)
            cfg.disks.insert(d, at: to)
        }
    }

    // MARK: - 磁盘操作共用辅助

    /// 所有磁盘操作共同前提: VM 必须处于停机态(qemu-img 直接读写磁盘, 运行中改会损坏)
    @MainActor
    private static func requireStoppedForDiskOp(_ item: VMListItem) throws {
        if item.bundle.isRunning() {
            throw VMError.invalidConfig("VM 正在运行,请先停机再操作磁盘")
        }
    }

    /// 校验磁盘索引是否在 [0, disks.count) 区间, 否则抛 invalidConfig
    private static func requireValidDiskIndex(_ index: Int, in disks: [DiskConfig]) throws {
        guard index >= 0 && index < disks.count else {
            throw VMError.invalidConfig("磁盘序号越界: \(index)")
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

