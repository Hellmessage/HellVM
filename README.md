# HellVM

基于 QEMU + HVF 的 macOS 虚拟机管理器，SwiftUI 暗色界面。

面向 Apple Silicon 优先优化：aarch64 主打，x86_64 / riscv64 实验支持。内置 swtpm 2.0、EDK2 UEFI 固件、socket_vmnet 网络、iosurface 共享内存显示后端，Windows ARM64 / Linux / OpenWrt 开箱可用。

## 特性

- **零环境构建** — 空白 Mac 上 `make build` 一条命令跑通。脚本自动处理 Xcode CLT、Homebrew、brew formulas、QEMU 源码编译、EDK2 固件构建。
- **Windows ARM64 开箱** — 自动生成 AutoUnattend ISO 绕过 Win11 硬件检查（TPM/SecureBoot/RAM/CPU/存储），可选 FirstLogon 静默装 virtio-win 驱动。
- **swtpm 集成** — TPM 2.0 通过独立 process group 原子管理，不留孤儿进程。
- **iosurface 显示后端** — 自定义 QEMU patch，Metal 零拷贝渲染 guest framebuffer，支持 virtio-gpu + ramfb 融合（解决 Win11 安装盘 bootmgr 挂死问题）。
- **socket_vmnet 网络** — shared / host-only / bridged 三模式，osascript 一次授权装齐 launchd daemon。
- **多 NIC 热插拔** — 同一 VM 同时挂多块网卡（例：shared 上网 + bridged 暴露服务），运行时改网络走 QMP device_add/device_del，无需重启 VM。
- **磁盘导入** — 支持 `.img / .raw / .qcow2` 及 `.gz / .xz` 压缩镜像直接转为启动盘，适配 OpenWrt / cloud-init 场景。
- **CLI + GUI** — SwiftUI 主 App 交互式操作，`hellvm` 命令行做脚本化管理。

## 系统要求

- macOS 14 (Sonoma) 或更新
- Apple Silicon 或 Intel Mac
- 首次构建会从 Homebrew 拉一些依赖 + 编译 QEMU（约 10-15 分钟），后续增量构建秒级

## 快速开始

```bash
git clone <repo> hell-vm
cd hell-vm
make build           # 编译 App bundle 到 build/HellVM.app
make run             # 启动 App
# 或:
make cli             # 编译命令行工具到 build/hellvm
./build/hellvm list
```

### 命令行

```bash
hellvm list                          # 列出所有 VM
hellvm create <name> --cpu 4 --mem 4096 --disk 40
hellvm start <name>                  # 前台启动(execv 替换进程, 继承终端)
hellvm stop <name>                   # QMP system_powerdown, 超时 SIGTERM
hellvm config <name>                 # 打印 config.json
```

## 项目结构

```
Sources/
├── HellVM/                 SwiftUI 主 App
│   ├── App/                入口 + 主窗口 + 设计 Token
│   ├── Components/         通用 UI 组件 (Pills/Buttons/FormFields/Hoverable)
│   ├── Dialogs/            弹窗 (Confirm/Error/LogViewer/Console)
│   ├── Services/           vmnet / virtio-win 跨 VM 服务
│   ├── Settings/           VM 设置页 (boot/disks/network 子区块)
│   ├── State/              VMListStore / VMConfigDraft / VMController
│   └── Wizard/             新建 VM 向导 (两步:OS 类型 → 详细配置)
├── HVMCore/                核心抽象
│   ├── Config/             VMConfig / VMState / VMArchitecture / VMBackend
│   ├── Logging/            统一 Logger (滚动 + 分类)
│   └── Util/               FileSystem / ProjectRootFinder / SocketPaths / NetworkInterfaces
├── HVMBundle/              .hellvm bundle 读写(配置 + 磁盘目录)
├── HVMStorage/             qemu-img 封装(创建/扩容/转换/导入)
├── HVMBackendQEMU/         QEMU 后端
│   ├── Core/               QEMUBackend / QEMUPaths / QEMUArgBuilders
│   ├── Process/            SpawnedProcess (posix_spawn + pg) / SwtpmSupervisor
│   └── Control/            QMPClient / NICHotplug / WindowsUnattend
├── HVMDisplay/             iosurface 显示后端客户端
│   ├── C/                  recvmsg + SCM_RIGHTS 的 C 辅助
│   ├── Protocol/           DisplayChannel / DisplayProtocol
│   └── View/               Metal 渲染 + 键鼠转发
├── HVMDisplayC/            (逻辑 target, 物理位于 HVMDisplay/C)
└── HellVMCLI/              ArgumentParser 命令行

scripts/                    构建脚本 (install-deps / build-qemu / build-edk2 / bundle ...)
patches/                    QEMU + EDK2 补丁(构建时 git am 应用)
Vendor/                     首次 make build 自动拉的 qemu / edk2 源码
```

## 外部补丁

`patches/` 下都是项目自有补丁，构建时 `scripts/build-qemu.sh` 会 `git reset --hard` vendored tree 再 `git am` 回来，所以修改 QEMU / EDK2 源码**必须导出成 patch**，不能只留在 Vendor/ 里（脏改动会被无声清除）。

当前补丁：

- `0001-ui-add-iosurface-display-backend.patch` — iosurface 共享内存显示后端
- `0002-hw-arm-virt-Win11-compat.patch` — Windows ARM64 machine 兼容
- `0003-virtio-ramfb-skip-ramfb-update-when-driver-bound.patch` — ramfb 驱动已接管时跳过 host 更新
- `0004-hw-arm-virt-make-VIRT_LOWRAM-opt-in-via-hellvm-lowra.patch` — Win11 bootmgr 低 RAM 模式兼容
- `0005-iosurface-fix-multi-console-active_con-thrash.patch` — 多 console 场景下 active_con 切换修复
- `edk2/0001-ArmVirtPkg-extra-RAM-region-for-Win11-compat.patch` — EDK2 额外 RAM region

## Windows guest 动态分辨率(spice-vdagent)

拖动 HellVM 窗口时,HellVM 会同时通过两条通道请求 guest 改分辨率:

- **iosurface `MSG_RESIZE_REQ` → `dpy_set_ui_info`** —— Linux guest 的 virtio-gpu
  驱动收到后自动重建 scanout, 立即生效。
- **virtio-serial `com.redhat.spice.0` + spice-vdagent 协议** —— Windows guest
  的 `viogpudo.sys` 运行时不响应 `dpy_set_ui_info`, 需要 `spice-vdagent` 服务
  收到 `VD_AGENT_MONITORS_CONFIG` 后主动调 `ChangeDisplaySettingsEx` 切分辨率。

### 新建 Windows VM:自动安装(默认开)

新建 Win11 VM 向导里会自动提示下载 `spice-guest-tools.exe`(约 30MB),缓存到全局:

```
~/Library/Application Support/HellVM/cache/spice-guest-tools.exe
```

下载源是 spice-space.org 官方 latest 直链,可用 `SPICE_GUEST_TOOLS_URL` env 覆盖(离线/国内镜像)。

VM 设置里的 "**自动装 Spice 工具**" 开关默认开:

- 启动 VM 时 HellVM 把 `spice-guest-tools.exe` 打进 `autounattend.iso` 根目录
- Windows 装完进 OOBE,FirstLogonCommands 扫 C..Z 盘找这个 exe,跑 `/S` 静默装
- 装完 spice-vdagent 服务自启,无需重启,下次拖窗口立即自动 resize

ARM64 Windows 注意:`spice-guest-tools-latest.exe` 是 x86 NSIS installer,ARM64 Windows 通过 x86 emulation 能跑 user-mode 服务;驱动部分(virtio-serial)走 `virtio-win.iso` 里的 ARM64 包,**建议同时开启 `autoInstallVirtioWin`**。

### 已装好的 Windows VM:手动安装

FirstLogonCommands 只在首次 OOBE 跑一次,对已装好的 Windows 不生效。手动装一次:

1. HellVM 里 Settings → 启动 → 打开 "自动装 Spice 工具" 触发下载
2. 复制缓存里的 `~/Library/Application Support/HellVM/cache/spice-guest-tools.exe` 到 guest(共享目录、拖拽、或任意方式)
3. 在 Windows 里管理员双击运行,或 PowerShell 里 `.\spice-guest-tools-latest.exe /S` 静默装
4. 服务名 "Spice Agent" 自启,拖 HellVM 窗口即自动 resize

Linux guest 若装了 `spice-vdagent` 包也会走这条路。未装时 virtio-serial 握手不会完成,不影响主画面和键鼠。

## 诊断

### 运行日志
每个 VM bundle 自带 `logs/` 目录：
- `hellvm.log` — Swift 侧统一日志（10MB 滚动）
- `swtpm.log` — swtpm 调试日志（启用 TPM 时）
- `serial.log` — 非图形模式（`-nographic`）下的 guest 串口

### 固件 / bootloader 级调试
VMConfig `boot.serialDebug: true` 打开时，guest 串口重定向到 `<bundle>/logs/edk2.log`，包含：
- EDK2 PEI/DXE/BDS 每步 debug 输出
- Windows bootmgr 加载 / 错误信息
- Linux kernel earlycon 输出
- UEFI Shell 输出

排查启动失败场景（如 `ConvertPages: failed to find range`、`Image at ... start failed`）很关键，完成后记得关掉 —— 串口 append 模式长时间跑会一直增长。

## 构建命令

```bash
make build        # 编译 .app (含 QEMU 首次编译)
make cli          # 编译命令行 hellvm
make run          # build + open
make clean        # 清理 .app / hellvm / .build
make distclean    # 深度清理（含 Vendor/qemu，下次重编 QEMU）
```

## 开发约束

见 [CLAUDE.md](./CLAUDE.md) —— 代码中文注释、黑色风格 UI、弹窗只能通过 X 按钮关闭、vendored 改动必须导出为 patch 等等。
