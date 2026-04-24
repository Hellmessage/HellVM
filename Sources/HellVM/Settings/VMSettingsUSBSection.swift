// VMSettings 的 USB 透传子区块
//
// 运行中才可用: 列出 host 上的 USB 设备, 用户点 "透传" 把设备控制权交给 guest,
// 点 "释放" 还回来。只追踪本 session 内挂过的 device id (Set<String>), 不持久化
// 到 config.json —— USB passthrough 本质是临时操作, 关机重启默认不恢复。

import SwiftUI
import HVMCore
import HVMBackendQEMU

struct VMSettingsUSBSection: View {
    let item: VMListItem

    @State private var hostDevices: [HostUSBDevice] = []
    @State private var attached: Set<String> = []    // 用 HostUSBDevice.id 作 key
    @State private var busy: Bool = false
    @State private var errorText: String?

    var body: some View {
        VMSection(title: "USB 透传") {
            if !item.config.boot.graphical {
                VMSectionKV(label: "—", value: "非图形模式不挂 USB 控制器, 透传不可用")
            } else if !item.bundle.isRunning() {
                VMSectionKV(label: "—", value: "VM 未运行. 启动 VM 后在此透传 host USB 设备")
            } else {
                deviceListView
            }
        }
    }

    @ViewBuilder
    private var deviceListView: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                SecondaryButton(title: "扫描 host USB", systemImage: "arrow.clockwise",
                                disabled: busy) {
                    hostDevices = HostUSBDevices.list()
                }
                if let err = errorText {
                    Text(err).font(.system(size: 10)).foregroundStyle(Theme.danger)
                }
                Spacer()
            }
            if hostDevices.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                    Text("未扫描或扫不到可透传设备. HID(键鼠)被过滤, 透传这些会导致 host 失去输入.")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)
                    Spacer()
                }
            } else {
                ForEach(hostDevices, id: \.id) { dev in
                    deviceRow(dev)
                }
            }
        }
        .onAppear {
            hostDevices = HostUSBDevices.list()
        }
    }

    private func deviceRow(_ dev: HostUSBDevice) -> some View {
        let isAttached = attached.contains(dev.id)
        return HStack(spacing: 10) {
            Image(systemName: isAttached ? "dot.radiowaves.left.and.right" : "cable.connector")
                .font(.system(size: 12))
                .foregroundStyle(isAttached ? Theme.accent : Theme.textSecondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(dev.displayLabel)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1).truncationMode(.middle)
                HStack(spacing: 8) {
                    if let loc = dev.location {
                        Text("bus.addr = \(loc)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    if dev.isMassStorage && !isAttached {
                        Text("· 存储设备, 透传会自动 unmount")
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.warning)
                    }
                }
            }
            Spacer()
            if isAttached {
                SecondaryButton(title: "释放", systemImage: "arrow.uturn.left",
                                tint: Theme.warning, disabled: busy) {
                    Task { await toggle(dev, attach: false) }
                }
            } else {
                SecondaryButton(title: "透传", systemImage: "arrow.right.circle",
                                disabled: busy) {
                    Task { await toggle(dev, attach: true) }
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.surfaceElevated))
    }

    @MainActor
    private func toggle(_ dev: HostUSBDevice, attach: Bool) async {
        busy = true
        errorText = nil
        defer { busy = false }

        // attach 路径: 如果是 USB mass storage, 先 diskutil unmountDisk 把 IOUSBMassStorage
        // 驱动和它挂的卷释放掉, libusb 才能抢占 USB 设备
        if attach && dev.isMassStorage && !dev.bsdDisks.isEmpty {
            for bsd in dev.bsdDisks {
                let ok = await unmountDisk(bsd)
                if !ok {
                    errorText = "无法 unmount \(bsd), 请在 Finder 里手动推出后再试"
                    return
                }
                log.info(.backend, "hotplug: USB storage pre-unmount \(bsd) OK")
            }
        }

        let qmp = QMPClient()
        do {
            try await qmp.connect(socketPath: item.bundle.qmpSocketURL.path)
        } catch {
            errorText = "QMP 连接失败: \(error.localizedDescription)"
            return
        }
        defer { Task { await qmp.close() } }

        do {
            if attach {
                try await UsbHotplug.attach(
                    vendorID: dev.vendorID, productID: dev.productID,
                    via: qmp
                )
                attached.insert(dev.id)
                log.info(.backend, "hotplug: USB attached \(dev.displayLabel)")
            } else {
                try await UsbHotplug.detach(
                    vendorID: dev.vendorID, productID: dev.productID,
                    via: qmp
                )
                attached.remove(dev.id)
                log.info(.backend, "hotplug: USB detached \(dev.displayLabel)")
            }
        } catch {
            errorText = "\(error.localizedDescription)"
        }
    }

    /// 对 /dev/diskN 调 `diskutil unmountDisk`, 级联卸载所有分区. 不需要 sudo.
    /// 用户数据盘已经 mount 时才会 unmount, 不占资源时直接返回成功。
    @MainActor
    private func unmountDisk(_ bsdName: String) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            let proc = Process()
            proc.launchPath = "/usr/sbin/diskutil"
            proc.arguments = ["unmountDisk", "/dev/\(bsdName)"]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe
            do {
                try proc.run()
                proc.waitUntilExit()
                return proc.terminationStatus == 0
            } catch {
                return false
            }
        }.value
    }
}
