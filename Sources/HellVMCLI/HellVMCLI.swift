// hellvm 命令行入口
import ArgumentParser
import Foundation
import HVMCore
import HVMBundle
import HVMStorage
import HVMBackendQEMU

@main
struct HellVM: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hellvm",
        abstract: "HellVM 虚拟机命令行",
        version: "0.1.0",
        subcommands: [List.self, Info.self, Create.self, Start.self, Stop.self, Pause.self, Resume.self, Remove.self]
    )
}

// MARK: - hellvm list

struct List: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "列出所有虚拟机"
    )

    func run() async throws {
        let bundles = try VMBundle.listAll()
        if bundles.isEmpty {
            print("(尚无虚拟机)")
            print("默认库位置:\(VMBundle.defaultLibraryURL.path)")
            return
        }
        print(pad("NAME", 20) + pad("ARCH", 10) + pad("CPU", 6) + pad("MEMORY", 10) + pad("STATE", 8))
        for b in bundles {
            if let cfg = try? b.loadConfig() {
                let state = b.isRunning() ? "RUNNING" : "STOPPED"
                print(
                    pad(cfg.name, 20) +
                    pad(cfg.architecture.rawValue, 10) +
                    pad(String(cfg.cpuCount), 6) +
                    pad("\(cfg.memoryMB) MB", 10) +
                    pad(state, 8)
                )
            } else {
                print("<损坏> \(b.url.lastPathComponent)")
            }
        }
    }

    /// 按字符数左对齐填充(避免 %s 在 Swift String 下的 vararg 崩溃)
    private func pad(_ s: String, _ width: Int) -> String {
        if s.count >= width { return s + " " }
        return s + String(repeating: " ", count: width - s.count)
    }
}

// MARK: - hellvm info <name>

struct Info: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "info",
        abstract: "查看 VM 详情"
    )

    @Argument(help: "VM 名称") var name: String

    func run() async throws {
        let bundle = try findBundle(name: name)
        let cfg = try bundle.loadConfig()
        print("名称:  \(cfg.name)")
        print("架构:  \(cfg.architecture.rawValue)")
        print("CPU:   \(cfg.cpuCount)")
        print("内存:  \(cfg.memoryMB) MB")
        print("Bundle: \(bundle.url.path)")
        if !cfg.disks.isEmpty {
            print("磁盘:")
            for d in cfg.disks {
                print("  - \(d.relativePath) (\(d.sizeGB)G, \(d.format.rawValue))")
            }
        }
        if let iso = cfg.boot.isoPath {
            print("ISO:   \(iso)")
        }
    }
}

// MARK: - hellvm create <name>

struct Create: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "创建一台新 VM"
    )

    @Argument(help: "VM 名称(同时作为 bundle 目录名)")
    var name: String

    @Option(help: "CPU 架构 (aarch64 | x86_64 | riscv64)")
    var arch: String = "aarch64"

    @Option(help: "CPU 核心数")
    var cpu: Int = 2

    @Option(help: "内存(MB)")
    var memory: UInt64 = 2048

    @Option(help: "主磁盘大小(GB)")
    var disk: UInt64 = 20

    @Option(help: "可选:启动 ISO 绝对路径")
    var iso: String?

    func run() async throws {
        // 名称校验
        guard !name.isEmpty, !name.contains("/"), !name.contains("\0") else {
            throw VMError.invalidConfig("VM 名称不合法:\(name)")
        }
        guard let arch = VMArchitecture(rawValue: arch) else {
            throw VMError.invalidConfig("未知架构:\(arch),可选:aarch64 / x86_64 / riscv64")
        }

        // ISO 校验 + 转成绝对路径(start 时 CWD 可能不同)
        var isoAbsolute: String? = nil
        if let iso = iso {
            let url = URL(fileURLWithPath: iso)
            let abs = url.standardized.resolvingSymlinksInPath().path
            guard FileManager.default.fileExists(atPath: abs) else {
                throw VMError.invalidConfig("ISO 文件不存在:\(abs)")
            }
            isoAbsolute = abs
        }

        // 定位 bundle 路径
        let libURL = VMBundle.defaultLibraryURL
        try FileManager.default.createDirectory(at: libURL, withIntermediateDirectories: true)
        let bundleURL = libURL.appendingPathComponent("\(name).hellvm")
        if FileManager.default.fileExists(atPath: bundleURL.path) {
            throw VMError.invalidConfig("同名 VM 已存在:\(bundleURL.path)")
        }

        // 构造配置
        let diskConfig = DiskConfig(
            relativePath: "disks/main.qcow2",
            sizeGB: disk,
            format: .qcow2
        )
        let config = VMConfig(
            name: name,
            architecture: arch,
            cpuCount: cpu,
            memoryMB: memory,
            disks: [diskConfig],
            boot: BootConfig(isoPath: isoAbsolute, efi: true)
        )

        // 创建 bundle
        let bundle = try VMBundle.create(at: bundleURL, config: config)

        // 创建磁盘(需要 qemu-img)
        let qemu = try QEMUPaths.discover()
        let disks = DiskManager(qemuImgPath: qemu.qemuImg)
        let diskURL = bundle.resolve(diskConfig.relativePath)
        try await disks.create(at: diskURL, sizeGB: disk, format: .qcow2)

        print("✓ 创建 VM: \(bundleURL.path)")
        print("  架构: \(arch.rawValue)")
        print("  CPU:  \(cpu)")
        print("  内存: \(memory) MB")
        print("  磁盘: \(disk)G (\(diskConfig.relativePath))")
        if let iso = iso { print("  ISO:  \(iso)") }
    }
}

// MARK: - hellvm start <name>

struct Start: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "start",
        abstract: "启动 VM(串口模式,Ctrl+A X 退出)"
    )

    @Argument(help: "VM 名称") var name: String

    func run() async throws {
        let bundle = try findBundle(name: name)
        let config = try bundle.loadConfig()
        let paths = try QEMUPaths.discover()

        FileHandle.standardError.write(Data(
            "==> 启动 \(config.name) (\(config.architecture.rawValue), HVF)\n    Ctrl+A X 退出\n".utf8
        ))

        let backend = try QEMUBackend(config: config, bundle: bundle, paths: paths)
        // CLI 前台:用 execv 替换当前进程为 qemu,TTY 完整继承
        try backend.execReplacing()
        // 正常情况下不会走到这里
    }
}

// MARK: - hellvm stop <name>

struct Stop: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop",
        abstract: "停止 VM(默认 ACPI 软关机,--force 断电)"
    )

    @Argument(help: "VM 名称") var name: String
    @Flag(name: .shortAndLong, help: "强制停止(SIGKILL,等同拔电源)") var force: Bool = false
    @Option(help: "等待 VM 退出的秒数,超时回退到 --force") var timeout: Int = 30

    func run() async throws {
        let bundle = try findBundle(name: name)
        guard bundle.isRunning() else {
            print("\(name) 未在运行")
            return
        }

        if force {
            try killPID(bundle: bundle, signal: SIGKILL)
            print("✓ 已强制停止 \(name)")
            return
        }

        // 软关机:通过 QMP 发送 system_powerdown
        let qmp = QMPClient()
        do {
            try await qmp.connect(socketPath: bundle.qmpSocketURL.path)
            _ = try await qmp.execute("system_powerdown")
            await qmp.close()
            print("==> 已发送 ACPI 关机信号,等待 VM 响应(最多 \(timeout) 秒)...")
        } catch {
            print("QMP 连接失败,退回 SIGTERM:\(error)")
            try killPID(bundle: bundle, signal: SIGTERM)
        }

        // 等待进程退出
        let deadline = Date().addingTimeInterval(TimeInterval(timeout))
        while Date() < deadline && bundle.isRunning() {
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        if bundle.isRunning() {
            print("⚠️  VM 未响应关机信号,强制 SIGKILL")
            try killPID(bundle: bundle, signal: SIGKILL)
        }
        print("✓ \(name) 已停止")
    }

    private func killPID(bundle: VMBundle, signal: Int32) throws {
        guard let pid = bundle.readPID() else {
            throw VMError.backendUnavailable("找不到 PID 文件")
        }
        if kill(pid, signal) != 0 && errno != ESRCH {
            throw VMError.stopFailed("kill(\(pid), \(signal)) 失败:\(String(cString: strerror(errno)))")
        }
    }
}

// MARK: - hellvm pause <name>

struct Pause: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pause",
        abstract: "暂停 VM(QMP stop)"
    )

    @Argument(help: "VM 名称") var name: String

    func run() async throws {
        let bundle = try findBundle(name: name)
        guard bundle.isRunning() else {
            print("\(name) 未在运行")
            return
        }
        let qmp = QMPClient()
        try await qmp.connect(socketPath: bundle.qmpSocketURL.path)
        _ = try await qmp.execute("stop")
        await qmp.close()
        print("✓ \(name) 已暂停")
    }
}

// MARK: - hellvm resume <name>

struct Resume: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "resume",
        abstract: "恢复 VM(QMP cont)"
    )

    @Argument(help: "VM 名称") var name: String

    func run() async throws {
        let bundle = try findBundle(name: name)
        guard bundle.isRunning() else {
            print("\(name) 未在运行")
            return
        }
        let qmp = QMPClient()
        try await qmp.connect(socketPath: bundle.qmpSocketURL.path)
        _ = try await qmp.execute("cont")
        await qmp.close()
        print("✓ \(name) 已恢复")
    }
}

// MARK: - hellvm remove <name>

struct Remove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "删除 VM(包括磁盘)"
    )

    @Argument(help: "VM 名称") var name: String
    @Flag(name: .shortAndLong, help: "跳过确认") var force: Bool = false

    func run() async throws {
        let bundle = try findBundle(name: name)
        if !force {
            print("将删除: \(bundle.url.path)")
            print("确认吗?(输入 yes 继续):", terminator: "")
            let line = readLine() ?? ""
            guard line.trimmingCharacters(in: .whitespaces).lowercased() == "yes" else {
                print("已取消")
                return
            }
        }
        try FileManager.default.removeItem(at: bundle.url)
        print("✓ 已删除 \(name)")
    }
}

// MARK: - 辅助

/// 按名称查找 bundle
func findBundle(name: String) throws -> VMBundle {
    let bundles = try VMBundle.listAll()
    for b in bundles {
        if (try? b.loadConfig())?.name == name {
            return b
        }
    }
    // 回退:按目录名匹配
    let url = VMBundle.defaultLibraryURL.appendingPathComponent("\(name).hellvm")
    if FileManager.default.fileExists(atPath: url.path) {
        return VMBundle(url: url)
    }
    throw VMError.invalidConfig("找不到 VM: \(name)")
}
