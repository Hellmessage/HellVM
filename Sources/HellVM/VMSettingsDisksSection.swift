// VMSettings 的磁盘子区块
//
// 设计要点:
// - 磁盘增删改查立即生效 (涉及 qemu-img 子进程), 不走 draft, 直接调 VMController
// - VM 运行时 readOnly=true, 隐藏所有操作按钮
// - 扩容/删除用内联确认条, 避免弹窗(符合主题)
import SwiftUI
import HVMCore

struct VMSettingsDisksSection: View {
    let item: VMListItem
    let store: VMListStore
    let readOnly: Bool
    @Binding var busy: Bool
    @Binding var errorText: String?

    // 磁盘局部 UI 状态
    @State private var addingDisk: Bool = false
    @State private var newDiskSizeGB: Int = 20
    @State private var newDiskFormat: DiskConfig.Format = .qcow2
    @State private var resizingIndex: Int?
    @State private var resizeSizeGB: Int = 0
    @State private var removingIndex: Int?

    var body: some View {
        VMSection(title: "磁盘") {
            if item.config.disks.isEmpty {
                VMSectionKV(label: "—", value: "无磁盘")
            } else {
                VStack(spacing: 8) {
                    ForEach(Array(item.config.disks.enumerated()), id: \.element.id) { idx, disk in
                        diskRow(index: idx, disk: disk)
                    }
                }
            }

            if !readOnly {
                if addingDisk {
                    addDiskForm
                        .padding(.top, 6)
                } else {
                    HStack {
                        SecondaryButton(title: "添加磁盘", systemImage: "plus", disabled: busy) {
                            addingDisk = true
                            newDiskSizeGB = 20
                            newDiskFormat = .qcow2
                        }
                        Spacer()
                    }
                    .padding(.top, 4)
                }
            }
        }
    }

    // MARK: - 单块磁盘行

    private func diskRow(index: Int, disk: DiskConfig) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                Text(index == 0 ? "#0 BOOT" : "#\(index)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(index == 0 ? Theme.accent : Theme.textTertiary)
                    .frame(width: 66, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(disk.relativePath)
                        .font(Font2.mono)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1).truncationMode(.middle)
                    Text("\(disk.sizeGB) GB · \(disk.format.rawValue)\(disk.readOnly ? " · 只读" : "")")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer(minLength: 8)

                if !readOnly {
                    diskActions(index: index, disk: disk)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.surfaceElevated))

            if resizingIndex == index {
                resizeInline(index: index, disk: disk)
                    .padding(.horizontal, 10).padding(.top, 6)
            }
            if removingIndex == index {
                removeInline(index: index, disk: disk)
                    .padding(.horizontal, 10).padding(.top, 6)
            }
        }
    }

    @ViewBuilder
    private func diskActions(index: Int, disk: DiskConfig) -> some View {
        HStack(spacing: 4) {
            VMIconButton(systemImage: "arrow.up", disabled: busy || index == 0) {
                runTask { try VMController.moveDisk(item, store: store, from: index, to: index - 1) }
            }
            VMIconButton(systemImage: "arrow.down",
                         disabled: busy || index == item.config.disks.count - 1) {
                runTask { try VMController.moveDisk(item, store: store, from: index, to: index + 1) }
            }
            VMIconButton(systemImage: "arrow.up.and.down.and.arrow.left.and.right", disabled: busy) {
                resizingIndex = (resizingIndex == index) ? nil : index
                resizeSizeGB = Int(disk.sizeGB) + 10
                removingIndex = nil
            }
            Menu {
                ForEach([DiskConfig.Format.qcow2, .raw], id: \.self) { fmt in
                    Button {
                        runTaskAsync {
                            try await VMController.convertDisk(item, store: store, at: index, to: fmt)
                        }
                    } label: {
                        HStack {
                            Text("转为 \(fmt.rawValue)")
                            if fmt == disk.format {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    .disabled(fmt == disk.format)
                }
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(busy ? Theme.textDisabled : Theme.textSecondary)
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.surface))
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .disabled(busy)
            .frame(width: 26, height: 26)
            VMIconButton(systemImage: "trash", tint: Theme.danger,
                         disabled: busy || item.config.disks.count <= 1) {
                removingIndex = (removingIndex == index) ? nil : index
                resizingIndex = nil
            }
        }
    }

    private func resizeInline(index: Int, disk: DiskConfig) -> some View {
        HStack(spacing: 10) {
            FieldLabel("扩容至")
            StepperCard(value: $resizeSizeGB, unit: "GB",
                        range: max(Int(disk.sizeGB) + 1, 1)...8192, step: 5)
                .frame(width: 160)
            Spacer()
            SecondaryButton(title: "取消", systemImage: nil, disabled: busy) {
                resizingIndex = nil
            }
            PrimaryButton(title: "确认", systemImage: "checkmark", disabled: busy) {
                let target = UInt64(resizeSizeGB)
                runTaskAsync {
                    try await VMController.resizeDisk(item, store: store, at: index, newSizeGB: target)
                }
                resizingIndex = nil
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.surface))
    }

    private func removeInline(index: Int, disk: DiskConfig) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.danger)
            Text("将永久删除文件 \(disk.relativePath),此操作无法撤销")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textPrimary.opacity(0.85))
            Spacer()
            SecondaryButton(title: "取消", systemImage: nil, disabled: busy) {
                removingIndex = nil
            }
            Button {
                runTask { try VMController.removeDisk(item, store: store, at: index) }
                removingIndex = nil
            } label: {
                Text("删除")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Theme.danger))
            }
            .buttonStyle(.plain)
            .disabled(busy)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.danger.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.danger.opacity(0.35), lineWidth: 1))
    }

    private var addDiskForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel("大小")
                    StepperCard(value: $newDiskSizeGB, unit: "GB", range: 1...8192, step: 5)
                        .frame(width: 160)
                }
                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel("格式")
                    formatSegment($newDiskFormat)
                }
                Spacer()
            }
            HStack {
                Spacer()
                SecondaryButton(title: "取消", systemImage: nil, disabled: busy) {
                    addingDisk = false
                }
                PrimaryButton(title: busy ? "创建中…" : "创建", systemImage: "plus", disabled: busy) {
                    let size = UInt64(newDiskSizeGB)
                    let fmt = newDiskFormat
                    runTaskAsync {
                        try await VMController.addDisk(item, store: store, sizeGB: size, format: fmt)
                    }
                    addingDisk = false
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surface))
    }

    private func formatSegment(_ binding: Binding<DiskConfig.Format>) -> some View {
        HStack(spacing: 6) {
            ForEach([DiskConfig.Format.qcow2, .raw], id: \.self) { fmt in
                let selected = binding.wrappedValue == fmt
                Button(action: { binding.wrappedValue = fmt }) {
                    Text(fmt.rawValue)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 6)
                            .fill(selected ? Theme.accent.opacity(0.2) : Theme.surfaceElevated))
                        .overlay(RoundedRectangle(cornerRadius: 6)
                            .stroke(selected ? Theme.accent : Color.clear, lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - 异步包装 (共享父的 busy / errorText)

    private func runTask(_ work: @escaping () throws -> Void) {
        errorText = nil
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do { try work() } catch { errorText = "\(error)" }
        }
    }

    private func runTaskAsync(_ work: @escaping () async throws -> Void) {
        errorText = nil
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do { try await work() } catch { errorText = "\(error)" }
        }
    }
}
