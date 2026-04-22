// swift-tools-version: 5.9
// HellVM —— macOS 虚拟机软件
// 架构:QEMU + HVF(所有架构走统一后端)

import PackageDescription

let package = Package(
    name: "HellVM",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        // 主 App
        .executable(name: "HellVM", targets: ["HellVM"]),
        // 命令行工具
        .executable(name: "hellvm", targets: ["HellVMCLI"]),
        // 核心库
        .library(name: "HVMCore", targets: ["HVMCore"]),
        .library(name: "HVMBundle", targets: ["HVMBundle"]),
        .library(name: "HVMStorage", targets: ["HVMStorage"]),
        .library(name: "HVMBackendQEMU", targets: ["HVMBackendQEMU"]),
        .library(name: "HVMDisplay", targets: ["HVMDisplay"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        // 核心抽象:VM 配置、状态、后端协议
        .target(name: "HVMCore"),

        // .hellvm bundle 读写(配置 + 磁盘目录)
        .target(name: "HVMBundle", dependencies: ["HVMCore"]),

        // 磁盘管理(封装 qemu-img)
        .target(name: "HVMStorage", dependencies: ["HVMCore"]),

        // QEMU 进程后端(QMP 控制 + 共享内存 framebuffer + HVF 加速)
        .target(name: "HVMBackendQEMU", dependencies: ["HVMCore", "HVMBundle"]),

        // P4: iosurface display backend 协议对端 C 辅助(recvmsg + SCM_RIGHTS)
        .target(
            name: "HVMDisplayC",
            publicHeadersPath: "include"
        ),

        // P4: iosurface display backend 客户端(socket 协议 + Metal 渲染)
        //     输入通道复用 HVMBackendQEMU 的 QMPClient
        .target(
            name: "HVMDisplay",
            dependencies: ["HVMCore", "HVMBundle", "HVMDisplayC", "HVMBackendQEMU"]
        ),

        // 主 App(SwiftUI)
        .executableTarget(
            name: "HellVM",
            dependencies: [
                "HVMCore", "HVMBundle", "HVMStorage", "HVMBackendQEMU",
                "HVMDisplay",
            ]
        ),

        // 命令行
        .executableTarget(
            name: "HellVMCLI",
            dependencies: [
                "HVMCore", "HVMBundle", "HVMStorage", "HVMBackendQEMU",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),

        // 测试
        .testTarget(name: "HVMCoreTests", dependencies: ["HVMCore"]),
    ]
)
