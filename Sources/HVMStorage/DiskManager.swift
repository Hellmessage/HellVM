// 磁盘管理 —— 封装 qemu-img
import Foundation
import HVMCore

/// 封装 qemu-img 的磁盘操作
public struct DiskManager: Sendable {
    public let qemuImgPath: URL

    public init(qemuImgPath: URL) {
        self.qemuImgPath = qemuImgPath
    }

    /// 创建磁盘镜像 —— 调用 `qemu-img create -f <format> <path> <size>G`
    public func create(at url: URL, sizeGB: UInt64, format: DiskConfig.Format) async throws {
        try await run(arguments: [
            "create",
            "-f", format.rawValue,
            url.path,
            "\(sizeGB)G",
        ])
    }

    /// 查询磁盘信息 —— `qemu-img info --output=json <path>`
    public func info(at url: URL) async throws -> DiskInfo {
        let json = try await runCapturingOutput(arguments: [
            "info", "--output=json", url.path,
        ])
        struct Raw: Decodable {
            let format: String
            let virtualSize: UInt64
            let actualSize: UInt64
            enum CodingKeys: String, CodingKey {
                case format
                case virtualSize = "virtual-size"
                case actualSize  = "actual-size"
            }
        }
        let raw = try JSONDecoder().decode(Raw.self, from: Data(json.utf8))
        guard let fmt = DiskConfig.Format(rawValue: raw.format) else {
            throw VMError.diskOperationFailed("未知磁盘格式:\(raw.format)")
        }
        return DiskInfo(
            format: fmt,
            virtualSizeBytes: raw.virtualSize,
            actualSizeBytes: raw.actualSize
        )
    }

    /// 改变磁盘大小 —— `qemu-img resize <path> <size>G`
    public func resize(at url: URL, newSizeGB: UInt64) async throws {
        try await run(arguments: [
            "resize", url.path, "\(newSizeGB)G",
        ])
    }

    /// 转换磁盘格式 —— `qemu-img convert -f <src> -O <dst> <in> <out>`
    /// - Note: 写入临时文件成功后原子替换原路径,失败不影响原文件
    public func convert(at url: URL,
                        from srcFormat: DiskConfig.Format,
                        to dstFormat: DiskConfig.Format) async throws {
        guard srcFormat != dstFormat else { return }
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).convert.tmp")
        // 先确保没有残留
        try? FileManager.default.removeItem(at: tmp)
        try await run(arguments: [
            "convert",
            "-f", srcFormat.rawValue,
            "-O", dstFormat.rawValue,
            url.path,
            tmp.path,
        ])
        // 原子替换(跨进程安全; 目标不存在时 replaceItemAt 也能处理)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }

    /// 删除磁盘文件(不可恢复)
    public func remove(at url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - 内部

    private func run(arguments: [String]) async throws {
        _ = try await runCapturingOutput(arguments: arguments)
    }

    /// 运行 qemu-img 并返回 stdout;失败时抛 VMError.diskOperationFailed
    private func runCapturingOutput(arguments: [String]) async throws -> String {
        let process = Process()
        process.executableURL = qemuImgPath
        process.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { proc in
                let out = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
                let err = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
                if proc.terminationStatus == 0 {
                    continuation.resume(returning: String(data: out, encoding: .utf8) ?? "")
                } else {
                    let msg = String(data: err, encoding: .utf8) ?? "未知错误"
                    continuation.resume(throwing: VMError.diskOperationFailed(
                        "qemu-img \(arguments.first ?? "") 失败 (exit=\(proc.terminationStatus)):\(msg.trimmingCharacters(in: .whitespacesAndNewlines))"
                    ))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: VMError.diskOperationFailed("启动 qemu-img 失败:\(error.localizedDescription)"))
            }
        }
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
