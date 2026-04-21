// QEMU 后端 —— 通过子进程 + QMP(QEMU Machine Protocol)控制 VM
// 显示方案:QEMU patched display backend 写入 IOSurface,Swift 侧 Metal 渲染
// P4 阶段实现
import Foundation
import HVMCore
import HVMBundle

/// 基于 QEMU 子进程的 VM 后端
public final class QEMUBackend: VMBackend {
    public let config: VMConfig
    public let bundle: VMBundle
    public let qemuBinaryURL: URL

    private let stateContinuation: AsyncStream<VMState>.Continuation
    public let stateStream: AsyncStream<VMState>

    private var _state: VMState = .stopped
    public var state: VMState { _state }

    /// - Parameters:
    ///   - qemuBinaryURL: 指向 Vendor/qemu/bin/qemu-system-<arch>
    public init(config: VMConfig, bundle: VMBundle, qemuBinaryURL: URL) throws {
        self.config = config
        self.bundle = bundle
        self.qemuBinaryURL = qemuBinaryURL
        var cont: AsyncStream<VMState>.Continuation!
        self.stateStream = AsyncStream { cont = $0 }
        self.stateContinuation = cont
    }

    public func start() async throws {
        throw VMError.notImplemented("QEMUBackend.start —— 待 P4")
    }

    public func stop(force: Bool) async throws {
        throw VMError.notImplemented("QEMUBackend.stop —— 待 P4")
    }

    public func pause() async throws {
        throw VMError.notImplemented("QEMUBackend.pause —— 待 P4")
    }

    public func resume() async throws {
        throw VMError.notImplemented("QEMUBackend.resume —— 待 P4")
    }

    deinit {
        stateContinuation.finish()
    }
}
