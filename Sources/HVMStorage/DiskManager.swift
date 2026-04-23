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

    // MARK: - 从外部镜像导入

    /// 把用户提供的磁盘镜像 (OpenWrt .img / cloud image .qcow2 等) 转成 qcow2 放到 dest.
    ///
    /// 识别规则(按后缀, 不依赖文件内容):
    ///   .gz         → 先 gunzip 解压到 tmp, 再当 raw 处理
    ///   .xz         → 先 xz -d 解压到 tmp, 再当 raw 处理(需要 brew install xz)
    ///   .qcow2      → qemu-img convert -f qcow2 -O qcow2
    ///   其它        → 当 raw 处理 (.img / .raw / OpenWrt 的裸 ext4 img 都能用)
    ///
    /// 若 expandToGB 非 nil 且 > 镜像当前虚拟大小, 转换后再 resize。
    ///
    /// - Parameters:
    ///   - source: 用户选择的镜像路径
    ///   - dest: 目标 qcow2 路径 (通常 bundle/disks/main.qcow2)
    ///   - expandToGB: 转换后扩容到的目标 GB; nil → 不扩容
    public func importImage(from source: URL,
                            to dest: URL,
                            expandToGB: UInt64? = nil) async throws {
        // 目标父目录 (bundle/disks/) 必须已存在
        try FileManager.default.createDirectory(
            at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        // 预先清掉目标, 避免旧文件残留影响
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }

        let lower = source.path.lowercased()

        // 解压到 tmp (若是 .gz / .xz)
        var convertSource: URL = source
        var tmpDecompressed: URL?
        defer {
            if let t = tmpDecompressed {
                try? FileManager.default.removeItem(at: t)
            }
        }
        if lower.hasSuffix(".gz") {
            let tmp = try makeTempFile(prefix: "hellvm-import-", suffix: "")
            try await decompress(tool: "/usr/bin/gunzip",
                                 args: ["-c", source.path],
                                 to: tmp)
            convertSource = tmp
            tmpDecompressed = tmp
        } else if lower.hasSuffix(".xz") {
            guard let xzPath = findExecutable("xz") else {
                throw VMError.diskOperationFailed(
                    "镜像是 .xz 压缩, 但未找到 xz 命令. 请执行: brew install xz")
            }
            let tmp = try makeTempFile(prefix: "hellvm-import-", suffix: "")
            try await decompress(tool: xzPath,
                                 args: ["-d", "-c", source.path],
                                 to: tmp)
            convertSource = tmp
            tmpDecompressed = tmp
        }

        // 推断输入格式 (qemu-img 能自动探测, 但显式传 -f 可避免某些 .img 被误识别)
        let srcFormat: String = {
            if convertSource.path.lowercased().hasSuffix(".qcow2") { return "qcow2" }
            return "raw"
        }()

        try await run(arguments: [
            "convert",
            "-f", srcFormat,
            "-O", "qcow2",
            convertSource.path,
            dest.path,
        ])

        // 扩容 (qemu-img resize 幂等, 小于当前大小会报错, 所以只在确实 > 当前时调)
        if let target = expandToGB {
            let info = try await info(at: dest)
            let currentGB = info.virtualSizeBytes / (1024 * 1024 * 1024)
            if target > currentGB {
                try await resize(at: dest, newSizeGB: target)
            }
        }
    }

    /// 调用解压工具, stdout 导入 dest 文件
    private func decompress(tool: String, args: [String], to dest: URL) async throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: tool)
        proc.arguments = args

        FileManager.default.createFile(atPath: dest.path, contents: nil)
        let outHandle = try FileHandle(forWritingTo: dest)
        let errPipe = Pipe()
        proc.standardOutput = outHandle
        proc.standardError = errPipe
        defer { try? outHandle.close() }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            proc.terminationHandler = { p in
                let errData = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
                if p.terminationStatus == 0 {
                    cont.resume()
                } else {
                    let msg = String(data: errData, encoding: .utf8) ?? ""
                    cont.resume(throwing: VMError.diskOperationFailed(
                        "\(tool) 解压失败 (exit=\(p.terminationStatus)): \(msg.trimmingCharacters(in: .whitespacesAndNewlines))"))
                }
            }
            do {
                try proc.run()
            } catch {
                cont.resume(throwing: VMError.diskOperationFailed(
                    "启动 \(tool) 失败: \(error.localizedDescription)"))
            }
        }
    }

    /// 在 $PATH + brew 常见位置找可执行
    private func findExecutable(_ name: String) -> String? {
        let candidates = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)",
        ]
        for p in candidates where FileManager.default.isExecutableFile(atPath: p) {
            return p
        }
        return nil
    }

    /// mktemp(3) 包装, 返回不存在但父目录可写的临时文件路径
    private func makeTempFile(prefix: String, suffix: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
        let name = "\(prefix)\(UUID().uuidString)\(suffix)"
        return dir.appendingPathComponent(name)
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
