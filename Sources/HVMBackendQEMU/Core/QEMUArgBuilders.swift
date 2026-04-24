// QEMU 命令行参数分段 Builder
//
// 把原先 500+ 行的 buildArguments() 拆成按语义内聚的 struct, 每个 struct 产出
// 自己负责的 [String] 片段。主 QEMUBackend.buildArguments 只做顺序组装。
//
// 设计准则:
//   - 各 Builder 只负责 **组装字符串**, 有副作用的操作(ISO 生成、日志清理、
//     目录创建)留在主函数里或通过 closure 注入, 保持 Builder 本身可单测.
//   - 不跨 Builder 共享可变状态, 依赖只通过 config / bundle / paths 属性注入.
//   - Builder 顺序 = QEMU argv 顺序, 不能随意调换 (USB bus 要在 usb-storage 前定义).
import Foundation
import HVMCore
import HVMBundle

// MARK: - ① 运行时控制通道

/// PID 文件 + 两个 QMP socket:
/// - qmp.sock       控制 (start/stop/pause/resume)
/// - qmp-input.sock 键鼠注入 (InputForwarder 长连接, 与控制互不干扰)
struct ControlChannelArgsBuilder {
    let bundle: VMBundle

    func build() -> [String] {
        [
            "-pidfile", bundle.pidFileURL.path,
            "-qmp", "unix:\(bundle.qmpSocketURL.path),server=on,wait=off",
            "-qmp", "unix:\(bundle.qmpInputSocketURL.path),server=on,wait=off",
        ]
    }
}

// MARK: - ② machine / cpu / smp / 内存

/// virt + hvf + cpu host + smp + memory
///
/// hellvm-lowram=on: 仅 Windows 11 ARM64 guest 开, 在 0x10000000 挂一小块 RAM
/// 骗 bootmgr 的硬编码内存假设. 要求配套打过 patch 的 EDK2.
struct MachineArgsBuilder {
    let config: VMConfig

    func build() -> [String] {
        var opts = "virt,accel=hvf"
        if config.osType == .windows {
            opts += ",hellvm-lowram=on"
        }
        // 内存参数: 基础是 "-m <init>M". 当 maxMemoryMB 设定且大于 memoryMB,
        // 追加 slots + maxmem 预留 DIMM 插槽, 给运行时 MemoryHotplug 热插用.
        // slots 数量给 4 (够用; guest 侧 ACPI SRAT 对 ARM 支持稳定).
        let memArg: String
        if let maxMB = config.maxMemoryMB, maxMB > config.memoryMB {
            memArg = "\(config.memoryMB)M,slots=4,maxmem=\(maxMB)M"
        } else {
            memArg = "\(config.memoryMB)M"
        }
        return [
            "-machine", opts,
            "-cpu", "host",
            "-smp", String(config.cpuCount),
            "-m", memArg,
        ]
    }
}

// MARK: - ②b PCIe Root Ports (预留热插槽位)

/// ARM virt 机器的默认 PCIe root bus (`pcie.0`) 不支持 hot-plug.
/// 启动时预定义 N 个 pcie-root-port, 每个能挂一块 hot-pluggable 设备 (virtio-net-pci,
/// virtio-blk-pci 等). 运行时 QMP `device_add` 指定 `bus=rp_N` 来占用空闲的 root port.
///
/// root port 自带 PCIe native hotplug 能力, guest 内核收到 ACPI/PCIe hotplug 事件后
/// 自动触发 probe 流程。 4 个槽位对日常"加一张 NIC / 加一块数据盘"够用, 多了用户可以
/// 重启扩容。
struct PCIeRootPortsArgsBuilder {
    static let count = 4

    func build() -> [String] {
        var out: [String] = []
        for i in 0..<Self.count {
            // chassis 必须 >= 1 (chassis 0 保留); 每个 port 独占一个 chassis
            out += ["-device", "pcie-root-port,id=rp\(i),chassis=\(i + 1)"]
        }
        return out
    }

    /// 派生第 i 个 root port 的 bus id, 供 DiskHotplug/NICHotplug 透传给 QMP device_add
    public static func busID(index: Int) -> String { "rp\(index)" }
}

// MARK: - ③ EFI 固件

/// 代码只读 pflash + 每 VM 独立变量 pflash
struct EFIArgsBuilder {
    let config: VMConfig
    let paths: QEMUPaths
    let efiVars: URL

    func build() -> [String] {
        guard config.boot.efi else { return [] }
        return [
            "-drive", "if=pflash,format=raw,readonly=on,file=\(paths.edk2AArch64Code.path)",
            "-drive", "if=pflash,format=raw,file=\(efiVars.path)",
        ]
    }
}

// MARK: - ④ 主磁盘 (NVMe) + 数据盘 (virtio-blk-pci, 可热插拔)

/// disks[0] 挂成 NVMe 作为主启动盘 (Windows 内建支持 + UTM 验证过能跑 Win11).
/// disks[1+] 挂成 virtio-blk-pci, ID 基于 UUID 稳定(DiskHotplug 用同样 ID).
/// 非 enabled 的数据盘跳过; 主盘无视 enabled 始终挂载。
struct MainDiskArgsBuilder {
    let config: VMConfig
    let bundle: VMBundle

    func build() -> [String] {
        var out: [String] = []
        for (idx, disk) in config.disks.enumerated() {
            let path = bundle.resolve(disk.relativePath).path
            let isBoot = (idx == 0)
            // 非主盘且被禁用, 跳过 (运行时可通过 QMP 热插拔上来)
            if !isBoot && !disk.enabled { continue }

            if isBoot {
                let driveId = "hd0"
                var driveOpts = "if=none,id=\(driveId),file=\(path),format=\(disk.format.rawValue)"
                if disk.readOnly { driveOpts += ",readonly=on" }
                out += ["-drive", driveOpts]
                out += ["-device", "nvme,drive=\(driveId),serial=hellvm-\(driveId)"]
            } else {
                // 数据盘: ID 和 DiskHotplug 的常量一致, 方便运行时 detach/attach
                let driveId  = "disk_\(disk.qemuStableSuffix)"
                let deviceId = "data_\(disk.qemuStableSuffix)"
                var driveOpts = "if=none,id=\(driveId),file=\(path),format=\(disk.format.rawValue)"
                if disk.readOnly { driveOpts += ",readonly=on" }
                out += ["-drive", driveOpts]
                var devOpts = "virtio-blk-pci,drive=\(driveId),id=\(deviceId),serial=hellvm-\(disk.qemuStableSuffix)"
                if disk.readOnly { devOpts += ",readonly=on" }
                out += ["-device", devOpts]
            }
        }
        return out
    }
}

// MARK: - ⑤ USB 控制器 (图形模式前置)

/// 必须在 usb-storage / usb-kbd / usb-tablet 前定义 usbbus.0
struct USBControllerArgsBuilder {
    let config: VMConfig

    func build() -> [String] {
        guard config.boot.graphical else { return [] }
        return ["-device", "qemu-xhci,id=usbbus"]
    }
}

// MARK: - ⑥ 启动介质 (ISO)

/// 图形模式走 usb-storage (Win11 首选, 对齐 UTM 经验证配置);
/// 非图形模式保留 virtio-scsi-cd.
/// bootFromDiskOnly=true 时跳过 ISO 挂载 —— 安装完成后的切换开关。
struct BootMediaArgsBuilder {
    let config: VMConfig

    func build() -> [String] {
        guard let isoPath = config.boot.isoPath, !config.boot.bootFromDiskOnly else {
            return []
        }
        // drive/device ID 与 ISOHotplug 的常量对齐, 便于运行时 QMP 热插拔定位
        if config.boot.graphical {
            return [
                "-drive", "if=none,id=\(ISOHotplug.driveID),media=cdrom,file=\(isoPath),readonly=on",
                "-device", "usb-storage,drive=\(ISOHotplug.driveID),id=\(ISOHotplug.deviceID),removable=true,bootindex=0,bus=usbbus.0",
            ]
        } else {
            return [
                "-drive", "if=none,id=\(ISOHotplug.driveID),media=cdrom,file=\(isoPath),readonly=on",
                "-device", "virtio-scsi-pci,id=scsi0",
                "-device", "scsi-cd,drive=\(ISOHotplug.driveID),id=\(ISOHotplug.deviceID),bootindex=1",
            ]
        }
    }
}

// MARK: - ⑦ Unattend ISO (Win11 Bypass 检查)

/// ISO 必须已由 prepareUnattendISO() 生成(副作用在主函数里做)。
/// 仅图形模式 + bypassWin11Checks 时挂载。
struct UnattendISOArgsBuilder {
    let bundle: VMBundle

    func build() -> [String] {
        [
            "-drive", "if=none,id=cdrom_unattend,media=cdrom,file=\(bundle.unattendIsoURL.path),readonly=on",
            "-device", "usb-storage,drive=cdrom_unattend,removable=true,bus=usbbus.0",
        ]
    }
}

// MARK: - ⑧ virtio-win 驱动盘

/// 第三个 CD-ROM, 装完 Windows 后 AutoUnattend 的 FirstLogonCommands 会从中
/// 静默装 virtio-win-gt-arm64.msi。ISO 来自全局缓存, 多台 Win VM 共享。
struct VirtioWinArgsBuilder {
    let config: VMConfig

    func build() -> [String] {
        let vwPath = VMBundle.virtioWinCacheURL.path
        guard config.boot.autoInstallVirtioWin, config.boot.graphical else { return [] }
        guard FileManager.default.fileExists(atPath: vwPath) else {
            log.warn(.qemu, "[autoInstallVirtioWin] 开关已开但缓存不存在, 跳过: \(vwPath)")
            return []
        }
        log.info(.qemu, "[autoInstallVirtioWin] 已挂 virtio-win.iso \(vwPath)")
        return [
            "-drive", "if=none,id=cdrom_vwin,media=cdrom,file=\(vwPath),readonly=on",
            "-device", "usb-storage,drive=cdrom_vwin,removable=true,bus=usbbus.0",
        ]
    }
}

// MARK: - ⑨ TPM (swtpm + tpm-crb-device)

/// Windows 首选 CRB 接口。aarch64 也支持 tpm-crb-device (UTM patch 已 port 进我们 QEMU)
struct TPMArgsBuilder {
    let socketPath: String?

    func build() -> [String] {
        guard let sock = socketPath else { return [] }
        return [
            "-chardev", "socket,id=chrtpm,path=\(sock)",
            "-tpmdev", "emulator,id=tpm0,chardev=chrtpm",
            "-device", "tpm-crb-device,tpmdev=tpm0",
        ]
    }
}

// MARK: - ⑩ 显示 / 键鼠 / 串口

/// 图形模式: virtio-gpu-pci+ramfb 或 virtio-ramfb 融合设备, USB HID 键鼠, IOSurface 显示
/// 非图形模式: -nographic + serial 写 serial.log
///
/// serialDebug 开时: guest 串口写 edk2.log(抓 EDK2/bootmgr/kernel early debug),
/// 每次启动前清旧内容(QEMU -serial file: 是 append, 不清就无限增长).
/// logRemover 注入: 清理旧 edk2.log 的 side effect, 由主 QEMUBackend 的
/// removeIfExists 提供(保留"删除失败写 warn 日志"语义)。
struct DisplayArgsBuilder {
    let config: VMConfig
    let bundle: VMBundle
    /// 删除文件的副作用 (url, 人类可读 label)
    let logRemover: (URL, String) -> Void

    func build() throws -> [String] {
        var out: [String] = []
        if config.boot.graphical {
            if config.display.virtioGpu {
                // 主路径: virtio-gpu-pci + ramfb 双 console, 能走 virtio-gpu 加速。
                // Linux/Asahi 原生支持; Win11 24H2 ARM64 实测在新 EDK2 下也稳定。
                out += ["-device", "virtio-gpu-pci"]
                out += ["-device", "ramfb"]
            } else {
                // Fallback: virtio-ramfb 融合设备 (HellVM patch 0002+0003, port 自 UTM).
                // 单 PCI 设备单 console, 最初是为早期 Win11 ISO 下 bootmgr 和双 console
                // 不兼容而写的 workaround. 当前 Win11 24H2 ARM64 不再需要, 且实测
                // 新 ISO 在此模式 PE 阶段会卡安装。代码保留作兼容老 ISO / 其它 fallback。
                out += ["-device", "virtio-ramfb"]
            }
            out += ["-device", "usb-kbd,bus=usbbus.0"]
            out += ["-device", "usb-tablet,bus=usbbus.0"]
            if config.boot.serialDebug {
                logRemover(bundle.edk2LogURL, "旧 edk2.log")
                try FileManager.default.createDirectory(
                    at: bundle.logsDirURL, withIntermediateDirectories: true)
                out += ["-serial", "file:\(bundle.edk2LogURL.path)"]
            } else {
                out += ["-serial", "null"]
            }
            out += ["-vga", "none"]
            out += ["-display", "iosurface,socket=\(bundle.iosurfaceSocketURL.path)"]

            // spice-vdagent 桥接 —— 目的: Windows guest (装 spice-guest-tools 后)
            // 运行时动态 resize。纯 dpy_set_ui_info 路径在 Linux guest 上能走通,
            // 但 Windows virtio-gpu 驱动只在首次 boot 读 EDID 时 pick 分辨率,运行时
            // 不响应后续 ui_info 变更。HellVM 在 iosurface 路径之外, 额外开一条
            // virtio-serial chardev, Swift 侧按 spice-vdagent 协议发 MONITORS_CONFIG,
            // Windows 里的 spice-vdagent 服务再调 ChangeDisplaySettingsEx 切分辨率。
            //
            // port name 必须是 "com.redhat.spice.0", spice-vdagent-win 只认这个名。
            // chardev server=on,wait=off: QEMU 先起 listener, Swift 侧随时连入;
            // VM 关机前一直保持。
            out += ["-device", "virtio-serial-pci,id=virtioserial0"]
            out += ["-chardev",
                    "socket,id=vdagent,path=\(bundle.spiceAgentSocketURL.path),server=on,wait=off"]
            out += ["-device",
                    "virtserialport,bus=virtioserial0.0,chardev=vdagent,name=com.redhat.spice.0"]
        } else {
            // 非图形模式(-nographic): 适合无桌面服务器镜像/云 init
            // guest 串口直接写入 serial.log, 详情页 Console tab tail 显示
            out += ["-serial", "file:\(bundle.serialLogURL.path)"]
            out += ["-nographic"]
        }
        return out
    }
}

// MARK: - ⑪ 网络 (多 NIC + 热插拔友好)

/// 每个启用的 NetworkConfig 生成独立的 netdev/device.
/// ID 派生自 MAC(qemuStableSuffix), 保证 boot-time 和 QMP 运行时热插拔用同一个句柄.
///
/// 过滤: 跳过 enabled=false 或 mode==.none; 全部空 → -nic none.
struct NetworkArgsBuilder {
    let networks: [NetworkConfig]

    func build() -> [String] {
        let active = networks.enumerated().filter { (_, n) in
            n.enabled && n.mode != .none
        }
        guard !active.isEmpty else { return ["-nic", "none"] }

        // ARM virt 的根 bus (pcie.0) 不支持热插拔, 挂在上面的设备 device_del 会失败
        // "Bus 'pcie.0' does not support hotplugging". 为了让启动时加载的 NIC 也能
        // 后续被运行时 detach / 改 model / 改 mode, 把每张网卡按 index 绑到一个
        // PCIeRootPortsArgsBuilder 预留的 rp_N 上, 和 NICHotplug.attach 路径一致。
        //
        // 超过 rp 槽位总数(PCIeRootPortsArgsBuilder.count=4)的部分 fallback 到 pcie.0,
        // 功能上还是能 work, 只是这几张无法热拔 / 运行时改参数。
        let rpCount = PCIeRootPortsArgsBuilder.count

        var out: [String] = []
        for (slotIdx, pair) in active.enumerated() {
            let (_, net) = pair
            let suffix = net.qemuStableSuffix ?? String(slotIdx)
            let netdevID = "net_\(suffix)"
            let deviceID = "nic_\(suffix)"
            var deviceOpts = "\(net.deviceModel.qemuDeviceName),netdev=\(netdevID),id=\(deviceID)"
            if let mac = net.macAddress, !mac.isEmpty {
                deviceOpts += ",mac=\(mac)"
            }
            // 前 rpCount 张绑到 rp_N; 第 rpCount+1 张起无槽位, 落回 pcie.0
            if slotIdx < rpCount {
                deviceOpts += ",bus=\(PCIeRootPortsArgsBuilder.busID(index: slotIdx))"
            } else {
                log.warn(.qemu,
                    "[network] NIC #\(slotIdx) 超过 pcie-root-port 槽位上限(\(rpCount)), 落到 pcie.0, 这张网卡无法热拔/运行时改参数")
            }
            switch net.mode {
            case .user:
                out += ["-netdev", "user,id=\(netdevID)"]
                out += ["-device", deviceOpts]
            case .vmnetShared, .vmnetHost, .vmnetBridged:
                // socket_vmnet 约定: QEMU 以 unix stream 连 helper socket, helper 把
                // 以太网帧转进 vmnet.framework。
                let sock = net.effectiveSocketPath ?? SocketPaths.vmnetShared
                out += ["-netdev", "stream,id=\(netdevID),addr.type=unix,addr.path=\(sock)"]
                out += ["-device", deviceOpts]
            case .none:
                continue
            }
        }
        return out
    }
}
