# HellVM 反虚拟机检测设计

本文档讨论如何让 HellVM 的 guest 难以被识别为虚拟机(anti-VM-detection / stealth),梳理检测向量、分层方案与取舍,不涉及具体代码实现。

---

## 1. 目标

> guest 内部的软件在常规手段下无法判断自己正运行于虚拟机。

"常规手段"的含义随威胁模型而变化,见下一节。项目当前架构为 QEMU + HVF(见 [Package.swift](../Package.swift)),因此所有伪装都要围绕这套组合实现。

---

## 2. 威胁模型

| 等级 | 检测方 | 典型手段 |
|---|---|---|
| D1 | 普通商业软件 / 游戏 demo | 读 SMBIOS、MAC 前缀、磁盘型号 |
| D2 | 带反调试的闭源软件 | CPUID hypervisor 位、hypervisor vendor 串、ACPI OEM ID |
| D3 | 恶意样本 / APT 沙箱逃逸 | PCI 子厂商 ID、virtio 设备、fw_cfg、SeaBIOS 字符串 |
| D4 | 商业反作弊(EAC / BattlEye / Vanguard) | 时序侧信道(RDTSC + CPUID)、TSC 频率、MSR 行为、VM-exit 特征 |
| D5 | 定制化取证 / 内核级检测 | 硬件行为差异、缓存时序、中断抖动、指令微架构特征 |

**默认目标**:D1 + D2(方案 A 可达)。
**进阶目标**:D3(方案 A + B)。
**D4/D5 不在本项目 MVP 范围内**,作为长期课题。

---

## 3. 检测向量清单

### 3.1 CPUID

| Leaf | 位/字段 | 泄露点 |
|---|---|---|
| `0x00000001:ECX[31]` | hypervisor 位 | 1 → 明确在 VM 内 |
| `0x40000000` | hypervisor vendor | `KVMKVMKVM` / `TCGTCGTCGTCG` / `Microsoft Hv` |
| `0x40000001–0x400000FF` | hypervisor 接口 | KVM / Hyper-V paravirt 接口 |
| `0x00000001:EBX[31:24]` | initial APIC ID | 拓扑异常 |
| `0x80000002–0x80000004` | 处理器品牌串 | 可能含 "QEMU Virtual CPU" |

HVF 本身会暴露 host CPUID,但 QEMU 仍然可能覆盖品牌串和注入 hypervisor 位,需要逐项确认。

### 3.2 SMBIOS / DMI

| 表 | 字段 | 默认值(典型) |
|---|---|---|
| Type 0(BIOS) | Vendor | `SeaBIOS` |
| Type 0 | Version | `rel-1.16.x-0-...` |
| Type 1(System) | Manufacturer | `QEMU` |
| Type 1 | Product | `Standard PC (i440FX + PIIX, 1996)` / `Q35 + ICH9` |
| Type 1 | Serial | 空 / 固定值 |
| Type 2(Baseboard) | Manufacturer | `QEMU` |
| Type 3(Chassis) | Manufacturer | `QEMU` |
| Type 4(CPU) | Socket | `CPU 0` |

Guest 侧读取路径:Linux `/sys/class/dmi/id/*`、Windows `WMI Win32_ComputerSystem` / `Win32_BIOS`。

### 3.3 ACPI

- OEM ID: `BOCHS` / `QEMU`(RSDT、FACP、DSDT 等所有表头)
- OEM Table ID: `BXPC` / `BXDSDT`
- Creator ID: `BXPC`
- `_SB.PCI0` 下的设备树含 `PNP0A03`(常规)但 DSDT 字节完全一致容易指纹化

### 3.4 PCI 设备指纹

| Device | Vendor/Device ID | 特征 |
|---|---|---|
| virtio-net | `1AF4:1000` / `1041` | virtio 本身就是 VM 强信号 |
| virtio-blk | `1AF4:1001` / `1042` | 同上 |
| virtio-gpu | `1AF4:1050` | 同上 |
| QXL VGA | `1B36:0100` | SPICE / QEMU 专属 |
| Cirrus VGA | `1013:00B8` | QEMU 默认仿真 |
| Intel HDA | `8086:2668` | 不算强指纹 |
| i440FX | `8086:1237` | 古董芯片组,99% 是 VM |

子厂商 ID(Subsystem Vendor)常为 `1AF4`(Red Hat),独立成条指纹。

### 3.5 存储 / 网络

- 磁盘 `INQUIRY`: `QEMU HARDDISK` / `QEMU DVD-ROM`
- 磁盘序列号:全 0 或 `QM00001`
- 网卡 MAC 前缀:
  - `52:54:00` → QEMU
  - `08:00:27` → VirtualBox
  - `00:50:56` / `00:0C:29` → VMware
  - `00:15:5D` → Hyper-V

### 3.6 固件 / fw_cfg

- QEMU `fw_cfg` 接口(io 端口 `0x510/0x511`)guest 可直接枚举,暴露 `etc/qemu-...` 字符串
- OVMF/EDK II 的 `DXE_SMM` 字符串中含 `QEMU`、`EDK II`
- SeaBIOS 的 e820 / CBFS 特征

### 3.7 时序侧信道(D4 级)

- `RDTSC` + `CPUID`:`CPUID` 在 VM 里必然触发 VM-exit,延迟比物理机高 1~2 个数量级
- `RDTSC` + `RDTSC`:背靠背测量,host/guest 的 TSC 频率不一致会露馅
- APIC timer、HPET 的抖动特征
- 特定内存访问(如跨页)的缓存 miss 模式

---

## 4. 分层方案

### 方案 A:QEMU 命令行定制

**代价**:低。只改 `HVMBackendQEMU` 组装参数,不动 QEMU 源码。
**覆盖**:D1 + D2 基本够用。

核心改动点:

| 项 | QEMU 参数 |
|---|---|
| 关 hypervisor 位 | `-cpu host,-hypervisor`(HVF 下需验证是否生效) |
| 伪造品牌串 | `-cpu host,model-name="Intel(R) Core(TM) i7-..."` |
| 覆盖 SMBIOS | `-smbios type=0,...` / `type=1,manufacturer=...,product=...,serial=...,uuid=...` |
| 机器类型 | `-machine q35`(比 i440FX 更现代,不那么像 VM) |
| 磁盘伪装 | `-device ahci` + `-drive ...,model="Samsung SSD 980",serial=...` 替代 virtio-blk |
| 网卡伪装 | `-device e1000e,mac=<非 52:54:00 MAC>` 替代 virtio-net |
| 显卡伪装 | `-vga std` 或 `-device virtio-vga-gl`,避开 QXL / Cirrus |
| 禁用调试信息 | `-no-fd-bootchk` 等减少特征 |

**配置层**:`VMBundle.config.json` 增加 `stealth` section:
```json
"stealth": {
  "enabled": true,
  "level": "basic"   // basic | advanced
}
```

### 方案 B:定制 QEMU 源码补丁

**代价**:中高。需要维护补丁,跟进 QEMU 上游(每 4 个月一个大版本)。
**覆盖**:D1–D3。
**落地位置**:现有 `patches/` 目录(项目已为 P4 做过 QEMU patch)。

要打的补丁:

| 位置 | 改什么 |
|---|---|
| `hw/acpi/aml-build.c` | OEM ID 从 `BOCHS` 改为可配置(或运行时传参) |
| `include/hw/acpi/acpi-defs.h` | 默认 OEM Table ID / Creator ID |
| `hw/smbios/smbios.c` | 默认 vendor 从 `QEMU` 改可配 |
| `hw/nvram/fw_cfg.c` | 关闭 `etc/qemu-*` 字符串暴露或重命名签名 |
| `roms/seabios/src/config.h` | `CONFIG_APPNAME` 从 `SeaBIOS` 改掉 |
| `hw/ide/core.c` | 默认 model `QEMU HARDDISK` 改可配 |
| `hw/pci/pci.c` | 默认子厂商 ID 可覆盖 |

**打包**:`build-qemu.sh` 在 apply P4 iosurface 补丁之后再 apply `qemu-stealth.patch`,输出放 `Vendor/qemu-stealth/`。可以通过 Makefile 开关决定是否启用(正常 build 用干净 QEMU,stealth build 用打补丁的)。

### 方案 C:Guest 内部伪装(兜底)

**代价**:高,与 guest OS 强耦合。
**覆盖**:填补 A/B 覆盖不到的 guest 侧接口。
**不建议作为主路径**,只在特定镜像预装时附带。

- Linux:bind-mount 替换 `/sys/class/dmi/id/*`、`/proc/cpuinfo` 内容
- Windows:注册表改 `HKLM\HARDWARE\DESCRIPTION\System\BIOS`、装过滤驱动 hook `Win32_*` WMI 查询
- 维护负担极重,且容易被 guest 用户空间软件绕过

### 方案 D:时序侧信道对抗(D4,长期研究)

**代价**:极高,涉及 QEMU + HVF 底层。
**覆盖**:D4。
**技术路径**:

- TSC offset / scaling:通过 HVF API 调整 guest 可见的 TSC,让 `CPUID` 等指令的可感知延迟接近物理机
- 引入随机噪声:主动在 RDTSC 结果上加抖动,但不能破坏 guest 正常计时
- MSR 行为模拟:`IA32_VMX_*` 等 MSR 的读写结果需要与物理机一致

**现实**:此方向研究成本非常高,且商业反作弊厂商会持续更新检测方法,属于军备竞赛。MVP 不做,仅作为未来可选路线保留。

---

## 5. 实施优先级建议

| 阶段 | 范围 | 交付物 |
|---|---|---|
| S1 | 方案 A 完整落地 + 配置开关 | `stealth: basic` 可用,对抗 D1/D2 |
| S2 | 方案 B 最小集(ACPI OEM + SMBIOS + SeaBIOS 字符串) | `stealth: advanced`,对抗 D3 |
| S3 | 方案 B 完整 + 磁盘/网卡型号随机化 | 每个 VM 指纹不同 |
| S4 | (研究)TSC 对抗、MSR 模拟 | 对抗 D4 的探索性 PoC |

---

## 6. 风险与取舍

- **兼容性**:部分伪装参数(如换 AHCI + e1000e)会显著影响性能;virtio-* 才是高性能路径。stealth 模式下性能可能下降 20~40%,需要在 UI 上提示用户。
- **维护负担**:QEMU 补丁需要跟上游,每次大版本升级都要重新 rebase,与 P4 iosurface 补丁叠加后复杂度上升。
- **指纹稳定性**:如果每个 VM 都用同一套伪装值,反而形成 "HellVM 专属指纹"。必须在新建 VM 时**随机化**关键字段(SMBIOS serial、MAC、磁盘序列号、ACPI OEM ID 部分位)。
- **法律/道德边界**:反检测技术本身中立,但可能被用于规避反作弊或分析环境识别。建议在 UI / 文档里明确定位为**兼容性工具**(帮助跑拒绝在 VM 里运行的合法软件 / 做兼容性测试 / 安全研究),不作为对抗反作弊的卖点。
- **与加密方案的关系**:stealth 是运行时伪装,加密(见 [encrypt.md](encrypt.md))是存储态保护,两者正交,可同时启用。

---

## 7. 开放问题

- HVF 下 `-cpu host,-hypervisor` 是否真能关掉 CPUID hypervisor 位?需要实验验证(macOS 14 / 15 行为可能不同)
- QEMU q35 + OVMF 组合下 ACPI 表的最小可控粒度,是否能完全运行时参数化而不必 patch
- 磁盘/网卡换成非 virtio 后,P4 图形显示(virtio-gpu + IOSurface)是否需要同步考虑 GPU 伪装
- 是否提供 "一键从物理机 dump 一套 SMBIOS/ACPI 作为模板" 的工具(tools/ 下)

---

## 8. 参考

- Intel SDM Vol. 3,CPUID 定义
- SMBIOS Reference Specification 3.x
- ACPI Specification 6.x
- QEMU `docs/system/`(命令行参数)
- Pafish / al-khaser(反 VM 检测样本,用于自测)
