# HellVM 自研 GPU 驱动设计(替代 viogpudo)

本文是 [stealth.md](stealth.md) §3.4 (PCI ID) + §7 开放问题的专题展开,专门讨论**自研
Windows 显示驱动** 替代 Red Hat `viogpudo` 的设计与取舍。不涉及具体代码实现,作为后续
立项时的起始参考。

---

## 1. 背景与动机

### 1.1 当前状态

- QEMU 侧:用 `virtio-ramfb` 融合设备(patch 0002 port 自 UTM + patch 0003 修复
  driver 接管后回刷问题)。 bootmgr 阶段走 ramfb facet,Windows 装 `viogpudo` 后
  走 virtio-gpu facet,支持 `dpy_set_ui_info` 动态分辨率。
- Guest 侧:依赖 Red Hat `virtio-win.iso` 里的 `viogpudo` 驱动(ARM64 版本较新
  才有,版本依赖强)。

### 1.2 `viogpudo` 带来的检测暴露面

| 信号 | 暴露位置 | 检测难度 |
|---|---|---|
| PCI Vendor ID `1AF4` (Red Hat/Qumranet) | 设备管理器、`dxdiag`、WMI | D1(用户态一行代码) |
| PCI Device ID `1050` (virtio-gpu) | 同上 | D1 |
| 驱动 INF 字符串 "Red Hat VirtIO GPU" | 设备管理器 → 驱动名 | D1 |
| 驱动文件名 `viogpudo.sys` | `%WINDIR%\System32\drivers\` | D1 |
| 驱动签名者 "Red Hat, Inc." | 驱动属性 → 数字签名 | D1 |
| 设备实例路径 `PCI\VEN_1AF4&DEV_1050` | 注册表 `HKLM\SYSTEM\...\Enum\PCI` | D1 |

任何一条被商业软件捕获就直接判"VM"。自研驱动的核心价值就是**消除这些字符串/ID
线索**,同时保留 virtio-gpu 协议带来的动态分辨率能力。

### 1.3 为什么不能"只改驱动,QEMU 照旧"

viogpudo 的 PCI 匹配项写死 `VEN_1AF4&DEV_1050`。即使把驱动名字改了,设备管理器
里那条 VEN_1AF4 依然赤裸写着"Red Hat"——供应商数据库是 Windows 内置的。必须
**QEMU 改 VEN/DEV + 驱动 INF 匹配新 ID** 成对推进。

---

## 2. 目标与不目标

### 2.1 目标(能达成)

- [D1] 设备管理器、`dxdiag`、WMI `Win32_VideoController` 查询不再出现 "Red Hat" /
  "VirtIO" / "QEMU" 字样
- [D1] PCI VEN/DEV ID 换成预设的"看起来像真显卡"的值
- 保留 `virtio-gpu` 协议 → 保留动态分辨率 / 光标 / 多显示器能力
- ARM64 / x86_64 都能 build(优先 ARM64,因为 HellVM 主力)

### 2.2 不目标(不解决)

- D4 级 anti-cheat(EAC/BattlEye/Vanguard):时序侧信道、VM-exit 特征由硬件虚拟化
  本身决定,换驱动无效
- GPU 真实硬件伪装(假装 NVIDIA/AMD):需要完整 WDDM 驱动 + 模拟 D3D 命令,工作量
  超过本项目 10 倍
- Windows 启动早期(PE/bootmgr)阶段的伪装:那时驱动还没加载,只能靠 QEMU 侧的
  ACPI/SMBIOS 伪装

---

## 3. 技术路线对比

| 路线 | 工作量 | 隐蔽度 | 风险 |
|---|---|---|---|
| A. Fork `kvm-guest-drivers-windows`,改 INF/字符串/VEN-DEV | 2-3 天 | ★★★ | 低 |
| B. 从 MS Display-Only Driver 样例重写 | 1-2 周 | ★★★★ | 中 |
| C. 完整 WDDM 全功能驱动(假装真显卡) | 1-2 月 | ★★★★★ | 高 |
| D. 放弃 virtio,用纯 framebuffer + IOMMU passthrough 模拟 | 不可行 | - | Apple Silicon 无 GPU passthrough |

**推荐路线 A**:最小改动达到 D1-D2 级伪装,保留升级到 B 的路径。

---

## 4. 路线 A 详细方案

### 4.1 QEMU 侧改动(预计 1-2 天)

#### 4.1.1 新增 patch `0004-virtio-ramfb-custom-vendor-id.patch`

- 给 `virtio-ramfb` 增加 property:
  ```c
  DEFINE_PROP_UINT16("vendor-id", VirtIORAMFBBase, custom_vendor_id, 0),
  DEFINE_PROP_UINT16("device-id", VirtIORAMFBBase, custom_device_id, 0),
  ```
- `virtio_ramfb_realize` 里如果 property 非 0,覆盖 PCI 配置空间的 VEN/DEV
- 可选同时改 subsystem-vendor-id / subsystem-id、revision

#### 4.1.2 ID 选型

选择一个**不冲突且不像 VM** 的 VEN/DEV 组合:

| 方案 | VEN | DEV | 说明 |
|---|---|---|---|
| 假装 Intel 集显 | `8086` | 随机分配(避开已知) | 看着像真显卡,但 Windows 可能试图加载真实 Intel 驱动 → 冲突 |
| 自建厂商 | `1B36` (QEMU)? | - | 仍有 QEMU 标识 ✗ |
| **未分配 VEN + 自定义 DEV** | `xxxx` | `xxxx` | 取一个 [PCI ID 数据库](https://pci-ids.ucw.cz/) 里**未分配**的 VEN(避免冲突) |

**推荐**: 取一个未分配 VEN(需上网查 pci-ids 列表挑),或者注册一个私有 ID(成本
$500/年,非必需)。初期可用未分配 VEN 走 D1 级别。

#### 4.1.3 Swift 侧暴露开关

- `VMConfig` 新增 `stealth: StealthConfig` 子结构
- 字段:`gpuVendorId: UInt16?`、`gpuDeviceId: UInt16?`、`hideHypervisor: Bool`等
- `QEMUBackend` 产出 `-device virtio-ramfb,vendor-id=0xXXXX,device-id=0xYYYY` 参数
- Settings UI 加 "隐身模式" 分组(默认关闭,开启时提醒:"需配套的 HellVM GPU 驱动")

### 4.2 Windows 驱动侧改动(预计 2-3 天)

#### 4.2.1 源码 fork

```
git clone https://github.com/virtio-win/kvm-guest-drivers-windows
cd kvm-guest-drivers-windows/viogpudo
```

BSD license,完全可以 fork 改名商用(只需保留原版权声明到 NOTICES)。

#### 4.2.2 重命名与字符串清洗

目标:去掉所有 "Red Hat" / "VirtIO" / "QEMU" 标识,替换成 HellVM 品牌(或"通用
PCI 显示适配器"之类中性名)。

核心文件:
- `viogpudo.inx` (INF 模板,build 后生成 .inf):
  - `Provider`、`ClassName`、`[Strings]` 段、驱动名描述
  - PCI 匹配项:`PCI\VEN_1AF4&DEV_1050` → `PCI\VEN_YOUR&DEV_YOUR`
- `viogpudo.vcxproj` 里的 `TargetName`:`viogpudo` → `hvmdisp`(或其他)
- 源码字符串:grep `VirtIO|Red Hat|Virtio|Qumranet` 全部替换
- 资源文件 `viogpudo.rc`:`FileDescription`、`CompanyName`、`ProductName`、
  `OriginalFilename` 字段

#### 4.2.3 WHQL / 签名策略

Windows 加载 kernel-mode 驱动必须签名。三档选择:

| 档位 | 要求 | 适用场景 |
|---|---|---|
| Test Mode | guest 里 `bcdedit /set testsigning on` | 开发测试,用户要手动开 Test Mode |
| 开发者证书签名 | 购买 Code Signing Cert ($100-$500/年),**非 EV** | 用户需手动"允许驱动"一次 |
| EV + Attestation | EV 证书 ($300-$700/年) + 提交 MS 门户 | 无需任何 guest 侧开关,开箱即用 |

**推荐**:初期用 Test Mode(文档化开机步骤),后期有预算再升级 EV。

#### 4.2.4 ARM64 build

viogpudo 源码本来支持 ARM64 编译,只是 Red Hat 的 release ISO 不一定每次都放
ARM64 binary。 自己 build 没问题:

```
msbuild /p:Configuration=Release /p:Platform=ARM64 viogpudo.vcxproj
```

需要 Windows host(x86 或 ARM)+ Visual Studio 2022 + WDK 最新版。

### 4.3 配套产物与分发

- HellVM.app 里内置一个"HellVM GPU 驱动安装盘"(ISO 或 ZIP)
- 启动 Windows VM 时,自动挂载这个 ISO 到 USB 存储
- guest 里跑一个 `install.bat`:开 Test Mode → 安装驱动 → 提示重启
- 或者集成到现有 "Win11 AutoUnattend" 流程里自动化

---

## 5. 路线 B 概要(留作后续)

从 Microsoft 的 [Display-Only Sample](https://github.com/microsoft/Windows-driver-samples/tree/main/video/KMDOD)
重写,不依赖 virtio-win 源码:

- 优点:无任何 "VirtIO" / "Red Hat" 血缘,字符串完全可控
- 优点:可以实现非 virtio-gpu 协议(比如 HellVM 自定义 MMIO 协议)
- 缺点:工作量大,要自己实现 DMA/IOMMU/scanout/cursor 逻辑
- 缺点:要重做对应的 QEMU 设备模拟(新 `-device hvm-gpu`)

路线 B 是"彻底自主"的方案,但只有在 A 被检测到、或需要高度定制协议时才值得
投入。

---

## 6. 风险与取舍

### 6.1 短期风险

- **Windows Update 可能覆盖/卸载未 WHQL 驱动**:需要 SetupDiUnregister 持久化或
  每次启动时重装。
- **未分配 VEN 数据库冲突**:pci-ids 数据库会更新,选的"未分配 ID"以后可能被
  分配给真厂商。需要定期检查或直接注册私有 ID。
- **签名过期**:Code Signing Cert 每年到期,到期后旧驱动还能用但不能签新 build。

### 6.2 长期风险

- anti-cheat 的 heuristic 检测可能通过 GPU capability 指纹(显存大小、DirectX
  feature level、GPU 名字的熵、PCI header 字节模式)识别出异常,需要持续对抗
- Microsoft 未来可能收紧 kernel driver 签名策略(比如强制全体 EV + 附加 MS 审核),
  影响分发难度

### 6.3 法律与合规

- BSD fork:完全合法,保留原始 copyright 即可
- 假装 Intel/NVIDIA VEN ID:可能违反 PCI-SIG 规则(VEN ID 归分配厂商专有),不
  建议用真厂商 ID,优先选未分配 ID
- 自研 VEN ID(自掏腰包注册): 合规上最干净

---

## 7. 实施步骤建议

若将来立项,推荐分三个 Sprint:

**Sprint 1** (2 天) —— QEMU patch 0004
- [ ] virtio-ramfb 增加 vendor-id/device-id property
- [ ] `make build` + 手测 Win11 guest 里设备管理器 VEN/DEV 变化
- [ ] Swift Config 增加 stealth 字段

**Sprint 2** (3 天) —— Windows 驱动 fork
- [ ] fork kvm-guest-drivers-windows,重命名 viogpudo → hvmdisp
- [ ] INF/字符串清洗
- [ ] ARM64 build 通过
- [ ] Test Mode 下 guest 能加载并驱动画面

**Sprint 3** (1 天) —— 集成与分发
- [ ] 把驱动 ISO 打进 HellVM.app 或 bundle
- [ ] AutoUnattend 流程里自动安装
- [ ] 文档化"隐身模式"开启流程

合计 ~6 天,可达 D1-D2 级 GPU 伪装。

---

## 8. 参考

- [kvm-guest-drivers-windows](https://github.com/virtio-win/kvm-guest-drivers-windows) —
  Red Hat viogpudo 源码(BSD),fork 起点
- [Windows KMDOD sample](https://github.com/microsoft/Windows-driver-samples/tree/main/video/KMDOD) —
  路线 B 起点
- [virtio-gpu spec](https://docs.oasis-open.org/virtio/virtio/v1.2/cs01/virtio-v1.2-cs01.html#x1-3430007) —
  virtio-gpu 协议(驱动实现参考)
- [Windows Driver Signing](https://learn.microsoft.com/en-us/windows-hardware/drivers/install/driver-signing) —
  签名策略官方文档
- [stealth.md](stealth.md) —— 整体 anti-detection 框架
