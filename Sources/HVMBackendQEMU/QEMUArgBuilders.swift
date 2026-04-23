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
        return [
            "-machine", opts,
            "-cpu", "host",
            "-smp", String(config.cpuCount),
            "-m", "\(config.memoryMB)M",
        ]
    }
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

// MARK: - ④ 主磁盘 (NVMe)

/// 所有 VMConfig.disks 挂成 NVMe (Windows 内建支持 + UTM 验证过能跑 Win11; Linux 也支持)
struct MainDiskArgsBuilder {
    let config: VMConfig
    let bundle: VMBundle

    func build() -> [String] {
        var out: [String] = []
        for (idx, disk) in config.disks.enumerated() {
            let path = bundle.resolve(disk.relativePath).path
            let driveId = "hd\(idx)"
            var driveOpts = "if=none,id=\(driveId),file=\(path),format=\(disk.format.rawValue)"
            if disk.readOnly { driveOpts += ",readonly=on" }
            out += ["-drive", driveOpts]
            out += ["-device", "nvme,drive=\(driveId),serial=hellvm-\(driveId)"]
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
        if config.boot.graphical {
            return [
                "-drive", "if=none,id=cdrom0,media=cdrom,file=\(isoPath),readonly=on",
                "-device", "usb-storage,drive=cdrom0,removable=true,bootindex=0,bus=usbbus.0",
            ]
        } else {
            return [
                "-drive", "if=none,id=cdrom0,media=cdrom,file=\(isoPath),readonly=on",
                "-device", "virtio-scsi-pci,id=scsi0",
                "-device", "scsi-cd,drive=cdrom0,bootindex=1",
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
                // Linux/Asahi 等: virtio-gpu-pci + ramfb 双 console, 能走 virtio-gpu 加速
                out += ["-device", "virtio-gpu-pci"]
                out += ["-device", "ramfb"]
            } else {
                // Windows: virtio-ramfb 融合设备(HellVM patch 0002+0003 port 自 UTM)
                // 单 PCI 设备单 console, bootmgr 走 ramfb facet 不挂死, 装完 viogpudo
                // 驱动后 scanout->resource_id != 0 自动切 virtio-gpu facet, 支持
                // dpy_set_ui_info 动态分辨率。
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

        var out: [String] = []
        for (idx, net) in active {
            let suffix = net.qemuStableSuffix ?? String(idx)
            let netdevID = "net_\(suffix)"
            let deviceID = "nic_\(suffix)"
            var deviceOpts = "\(net.deviceModel.qemuDeviceName),netdev=\(netdevID),id=\(deviceID)"
            if let mac = net.macAddress, !mac.isEmpty {
                deviceOpts += ",mac=\(mac)"
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
