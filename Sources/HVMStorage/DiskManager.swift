// 磁盘管理 —— 封装 qemu-img(创建 / 查询 / 改大小)
// P0 为占位实现,等待 P4 接入 Vendor/qemu 的 qemu-img
import Foundation
import HVMCore

/// 封装 qemu-img 的磁盘操作
public struct DiskManager: Sendable {
    /// qemu-img 可执行文件路径(由 App 注入,通常指向 Vendor/qemu/bin/qemu-img)
    public let qemuImgPath: URL

    public init(qemuImgPath: URL) {
        self.qemuImgPath = qemuImgPath
    }

    /// 创建磁盘镜像
    public func create(at url: URL, sizeGB: UInt64, format: DiskConfig.Format) async throws {
        throw VMError.notImplemented("DiskManager.create —— 待 P4 接入 qemu-img")
    }

    /// 查询磁盘信息
    public func info(at url: URL) async throws -> DiskInfo {
        throw VMError.notImplemented("DiskManager.info —— 待 P4 接入 qemu-img")
    }

    /// 改变磁盘大小
    public func resize(at url: URL, newSizeGB: UInt64) async throws {
        throw VMError.notImplemented("DiskManager.resize —— 待 P4 接入 qemu-img")
    }
}

/// 磁盘镜像元信息
public struct DiskInfo: Sendable {
    public let format: DiskConfig.Format
    public let virtualSizeBytes: UInt64
    public let actualSizeBytes: UInt64

    public init(format: DiskConfig.Format, virtualSizeBytes: UInt64, actualSizeBytes: UInt64) {
        self.format = format
        self.virtualSizeBytes = virtualSizeBytes
        self.actualSizeBytes = actualSizeBytes
    }
}
