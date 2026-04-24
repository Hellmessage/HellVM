// vdagent-resize —— 通过 spice-vdagent 让 Windows guest 改分辨率.
//
// 直接复用 HVMDisplay.VDAgentChannel, 连 vdagent.sock → 发
// VD_AGENT_MONITORS_CONFIG. 需要 Windows 里装了 spice-guest-tools。
// guest 没装 agent 时这条消息会被 cache, 装了之后才生效; 调用方能看到
// 的实际效果: Windows resize 到目标分辨率。

import Foundation
import ArgumentParser
import HVMBundle
import HVMDisplay

struct VDAgentResizeCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "vdagent-resize",
        abstract: "通过 spice-vdagent 触发 Windows guest 改分辨率"
    )

    @Argument(help: "VM 名字或 bundle 路径")
    var vm: String

    @Argument(help: "目标分辨率, 如 1920x1080")
    var resolution: String

    @Option(name: .long, help: "发完等几秒再退出, 给 agent 时间处理")
    var settle: Double = 1.5

    mutating func run() async throws {
        let parts = resolution.lowercased().split(separator: "x").map(String.init)
        guard parts.count == 2, let w = UInt32(parts[0]), let h = UInt32(parts[1]) else {
            throw ProbeError.protocolError("resolution 格式: <W>x<H>, 如 1920x1080")
        }
        let bundle = try VMLocator.resolve(vm)

        let ch = VDAgentChannel()
        do {
            try ch.connect(socketPath: bundle.spiceAgentSocketURL.path)
        } catch {
            throw ProbeError.socketConnectFailed("vdagent: \(error.localizedDescription)")
        }
        ch.sendMonitorsConfig(width: w, height: h)
        // 等 agent 处理(握手 + ChangeDisplaySettingsEx)
        try? await Task.sleep(nanoseconds: UInt64(settle * 1_000_000_000))
        ch.close()
        print("==> 已发 MONITORS_CONFIG \(w)x\(h)")
    }
}
