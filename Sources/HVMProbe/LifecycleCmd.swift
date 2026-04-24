// start / stop —— VM 生命周期控制.
//
// start: 复用 QEMUBackend.start(), 和 HellVM.app 内部用的一样的 SpawnedProcess 路径.
//   子进程独立 process group, 父进程 (hvmdbg) 退出后 VM 继续跑。
//   完成后父进程立刻 exit, 不等 VM 退出。
//
// stop:  force=false → QMP system_powerdown; force=true → killpg(pgid, SIGKILL).
//   stop 直接从 pid 文件读 QEMU pid → getpgid → killpg, 走 hellvm CLI 同套机制.

import Foundation
import ArgumentParser
import HVMCore
import HVMBundle
import HVMBackendQEMU

// MARK: - start

struct StartCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "start",
        abstract: "后台启动 VM (独立 process group, hvmdbg 退出后 VM 继续跑)"
    )

    @Argument(help: "VM 名字或 bundle 路径")
    var vm: String

    mutating func run() async throws {
        let bundle = try VMLocator.resolve(vm)
        if bundle.isRunning() {
            FileHandle.standardError.write("==> \(vm) 已在运行 (pid=\(bundle.readPID() ?? -1))\n".data(using: .utf8)!)
            return
        }
        let config = try bundle.loadConfig()
        let paths = try QEMUPaths.discover()
        let backend = try QEMUBackend(config: config, bundle: bundle, paths: paths)
        try await backend.start()

        // 关键: 让 backend 的 SpawnedProcess 脱离 ARC.
        // backend 作为局部变量, 退出函数时会 deinit. SpawnedProcess 设计为即使
        // 父 ARC 释放, 已 spawn 的子进程因为独立 pg 会继续存活。
        let pid = bundle.readPID() ?? -1
        print("==> \(vm) 已启动 (pid=\(pid))")
    }
}

// MARK: - stop

struct StopCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop",
        abstract: "停止 VM (默认 ACPI 软关机, --force SIGKILL 整 pg)"
    )

    @Argument(help: "VM 名字或 bundle 路径")
    var vm: String

    @Flag(name: .long, help: "强制断电 (killpg(SIGKILL))")
    var force: Bool = false

    @Option(name: .long, help: "等进程退出的秒数")
    var timeout: Double = 15.0

    mutating func run() async throws {
        let bundle = try VMLocator.resolve(vm)
        guard bundle.isRunning() else {
            FileHandle.standardError.write("==> \(vm) 未在运行\n".data(using: .utf8)!)
            return
        }

        if force {
            try killProcessGroup(bundle: bundle, signal: SIGKILL)
        } else {
            // 先 QMP system_powerdown, 失败退 pg-level SIGTERM
            do {
                _ = try await QMPClient.withSession(socketPath: bundle.qmpSocketURL.path) { qmp in
                    try await qmp.execute("system_powerdown")
                }
            } catch {
                try killProcessGroup(bundle: bundle, signal: SIGTERM)
            }
        }

        // 等进程真正退
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline && bundle.isRunning() {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        if bundle.isRunning() {
            // 超时兜底 SIGKILL
            try killProcessGroup(bundle: bundle, signal: SIGKILL)
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        // 清 pid 文件, 避免 pid 复用误判
        try? FileManager.default.removeItem(at: bundle.pidFileURL)
        print("==> \(vm) 已停止")
    }

    private func killProcessGroup(bundle: VMBundle, signal: Int32) throws {
        guard let pid = bundle.readPID() else {
            throw ProbeError.vmNotRunning("找不到 pid 文件: \(bundle.pidFileURL.path)")
        }
        let pgid = getpgid(pid)
        let target: pid_t = pgid > 0 ? pgid : pid
        if killpg(target, signal) != 0 && errno != ESRCH {
            throw ProbeError.protocolError(
                "killpg(\(target), \(signal)) 失败: \(String(cString: strerror(errno)))")
        }
    }
}
