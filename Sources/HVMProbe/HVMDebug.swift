// hvmdbg —— HellVM 调试探针 CLI
//
// 目标: 通过 HellVM 既有的 socket 协议(iosurface / qmp / qmp-input / spice-vdagent)
// 做端到端诊断 + 远程操作, 让脚本 (甚至 AI) 能不依赖 GUI 控制/观察 guest。
//
// 子命令索引:
//   screenshot     —— 抓 guest framebuffer 成 PNG
//   qmp            —— 发任意 QMP 命令, 打印 JSON
//   pci-tree       —— query-pci 语法糖, 格式化 bus 树
//   move           —— 鼠标 absolute move (guest framebuffer 坐标系)
//   click          —— 鼠标点击
//   scroll         —— 滚轮
//   key            —— 按一次键(支持组合 "ctrl+alt+del")
//   type           —— 键入字符串
//   vdagent-resize —— 通过 spice-vdagent 让 Windows guest 改分辨率
//   nic-swap       —— 程序化重现 "切 NIC model" 热插拔
//
// 所有命令参数 <vm> 接受:
//   - bundle 名字(自动 resolve 到 ~/Library/Application Support/HellVM/VMs/<name>.hellvm)
//   - 绝对路径(含 .hellvm 后缀的 bundle 目录)
//
// 设计原则: 零新协议实现, 所有 socket 客户端复用 HVMDisplay / HVMBackendQEMU 公开类型。

import Foundation
import ArgumentParser

@main
struct HVMDebug: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hvmdbg",
        abstract: "HellVM 调试探针 —— 走项目既有 socket 协议做观察/操作",
        subcommands: [
            StartCmd.self,
            StopCmd.self,
            ScreenshotCmd.self,
            QMPCmd.self,
            PciTreeCmd.self,
            MoveCmd.self,
            ClickCmd.self,
            ScrollCmd.self,
            KeyCmd.self,
            TypeCmd.self,
            VDAgentResizeCmd.self,
            NICSwapCmd.self,
        ]
    )
}
