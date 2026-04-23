# Win11 ARM64 启动支持:问题分析与修复全流程

本文档记录把 Windows 11 ARM64 安装在 HellVM 上跑起来的全过程 —— 从一开始完全卡死到最终进入 Windows Setup GUI,期间每一层失败的根因、诊断思路和最终修复。

读完这份文档你会理解:

- **为什么上游 QEMU + kraxel EDK2 跑不了 Win11 ARM64**(而 UTM 能)
- 固件(EDK2)/虚拟机(QEMU)/显示/TPM 每一层的具体冲突
- 最终如何从 UTM 的 QEMU fork 里把关键补丁 port 到我们 upstream v10.2.0 上

---

## 一、背景:我们的栈 vs UTM 的栈

| 组件 | HellVM 初始 | UTM |
|---|---|---|
| QEMU | upstream v10.2.0(kraxel build,我们的 Vendor/qemu-src) | 打过补丁的 v10.1.x-utm fork(utmapp/qemu) |
| EDK2 固件 | kraxel 预编的 `edk2-aarch64-code.fd`(ArmVirtQemu.dsc 默认) | UTM 自编 `edk2-aarch64-secure-code.fd` + UTM 补丁 |
| EDK2 变量模板 | `edk2-arm-vars.fd`(空,无签名密钥) | `edk2-arm-secure-vars.fd`(预置 MS PK/KEK/db/dbx) |
| 显示 | virtio-gpu-pci + ramfb(两个设备) | `virtio-ramfb-gl`(UTM 自己打补丁的组合设备) |
| TPM | `tpm-tis-device`(upstream aarch64 唯一选项) | `tpm-crb-device`(UTM 自己 port 的 CRB sysbus) |
| CD-ROM | virtio-scsi-cd | usb-storage |
| 主磁盘 | virtio-blk | nvme |
| RTC | 默认 UTC | `base=localtime` |

上游 QEMU aarch64 没有 `tpm-crb-device`,没有 Windows 打磨过的内存布局,没有 `virtio-ramfb-gl`。这一堆差异组合起来就是 Win11 在我们栈上跑不动的理由。

---

## 二、故障现象(一开始)

Win11 ARM64 官方 ISO 挂到 aarch64 VM 上,启动后画面卡在 **TianoCore logo + "Start boot option"**,永远不推进。换参数、换 ISO 都一样。同一张 ISO 在 UTM 里能直接装。

现象分三个阶段在诊断中逐步展开:

1. **阶段 A — 屏幕卡死**:看起来 VM hung
2. **阶段 B — dump 出真实屏幕**:实际是 `FvFile Invalid Parameter + BdsDxe: No bootable option`
3. **阶段 C — 开 EDK2 serial log**:真正的错误链 `ConvertPages failed` → `Image ... start failed: Time out`

每一步靠新工具把下一层现象暴露出来,这是整个修复流程能推进的根本。

---

## 三、诊断工具链

### 1. `iosurface-probe`(dump 屏幕到 PPM)

```bash
/Volumes/.../build/iosurface-probe \
    '/Users/.../Win11.hellvm/iosurface.sock' /tmp/screen.ppm
sips -s format png /tmp/screen.ppm --out /tmp/screen.png
```

绕过 GUI 直接从 QEMU 的 iosurface 共享内存抓一帧。有了这个才发现"卡住"的画面其实是 EDK2 BDS 的错误信息,不是 TianoCore logo。

### 2. EDK2 / bootmgr / kernel 串口日志

加了 `VMConfig.boot.serialDebug: Bool` 开关:打开后 `-serial null` 改成 `-serial file:<bundle>/logs/edk2.log`。里面有:

- EDK2 固件 PEI/DXE/BDS 每步 debug 输出
- Windows bootmgr 加载/错误信息
- Linux kernel earlycon

这是整个排查的主线工具 —— 没有它根本看不到 `ConvertPages failed` 这种内部错误。默认关,否则串口 append 模式日志无限增长。约定写在了项目根 `CLAUDE.md`。

### 3. UTM 在跑时抓 QEMU 命令行

```bash
ps -ax -o command= | grep qemu-system-aarch64
```

看 UTM 实际用的完整参数。拿到这个后整个 diff 就清楚了 —— 我们后面一半的修复都是对着 UTM 的命令行反推的。

---

## 四、按层剖析失败原因(为什么 Win11 不能跑)

### 层 1:QEMU virt 机器的物理内存布局

QEMU `virt` 机器的 `base_memmap` 固定:

```
0x00000000 - 0x08000000  VIRT_FLASH         (128MB, pflash)
0x08000000 - 0x10000000  VIRT_CPUPERIPHS等  (GIC / UART / RTC / MMIO)
0x10000000 - 0x3EFF0000  VIRT_PCIE_MMIO     (~755MB, PCIe 32-bit MMIO 窗口)
0x3EFF0000 - 0x3F000000  VIRT_PCIE_PIO
0x3F000000 - 0x40000000  VIRT_PCIE_ECAM
0x40000000 - ...         VIRT_MEM           (系统 RAM 从 1GB 起)
```

**问题**:Windows 11 ARM64 bootmgr 沿用了 x86 UEFI 的硬编码假设 —— 它要对 **0x10000000 附近的低地址**做 `ConvertPages` / `SetMemoryAttributes`。但 QEMU virt 那块是 PCIe MMIO,不是 RAM,也不在 EDK2 的 GCD(Global Coherence Domain)里,转换直接失败。

**证据**(edk2.log):
```
BdsDxe: starting Boot0001 "UEFI QEMU QEMU CD-ROM"
ConvertPages: failed to find range 10000000 - 1012BFFF
ConvertPages: failed to find range 102000 - 102FFF
Error: Image at 0023C2F4000 start failed: Time out
BdsDxe: failed to start Boot0001: Time out
```

bootmgr 在 `ConvertPages` 重试循环里耗尽内部超时,调 `gBS->Exit(EFI_TIMEOUT)` 退出。

### 层 2:EDK2 PEI 的内存发现强绑单 RAM 区

即使我们在 QEMU 里加一块 RAM 在 0x10000000,EDK2 的 `QemuVirtMemInfoPeiLibConstructor` 会去扫 DTB 里的 `/memory@` 节点。原代码逻辑是"取地址最低的节点当主 RAM":

```c
if ((NewBase > CurBase) || (NewBase == 0)) {
    NewBase = CurBase;
    NewSize = CurSize;
}
// 最后
ASSERT (FixedPcdGet64 (PcdSystemMemoryBase) == NewBase);
```

如果我们在 DTB 里声明两个 `/memory@` 节点(主 RAM 在 0x40000000、额外区在 0x10000000),它会把 0x10000000 选成 NewBase,然后 `ASSERT 0x40000000 == 0x10000000` 直接挂固件。

**证据**:
```
ASSERT [MemoryInit] /home/.../QemuVirtMemInfoPeiLibConstructor.c(89): 0x40000000 == NewBase
```

### 层 3:EDK2 MMU 页表只映射 3 个区

`ArmVirtGetMemoryMap` 返回给 `ArmConfigureMmu` 的页表描述符硬编码只映射:

```c
VirtualMemoryTable[0] = System DRAM @ PcdSystemMemoryBase
VirtualMemoryTable[1] = Peripherals @ 0x08000000 (128MB)
VirtualMemoryTable[2] = FV region (flash)
```

就算 PEI 把额外 RAM 加进了 HOB,**MMU 页表里没有这块的映射**。bootmgr 一 access 0x10000000 就 **Synchronous Exception**(data/prefetch abort)。

**证据**:
```
BdsDxe: loading Boot0001 ...
Synchronous Exception at 0x0000000047995598
```

### 层 4:EDK2 GCD 里额外 RAM 未注册为系统内存

`ArmVirtMemoryInitPeiLib.c` 的 `MemoryPeim` 只对主 RAM 调 `BuildResourceDescriptorHob(EFI_RESOURCE_SYSTEM_MEMORY, ...)`。额外 RAM 就算物理存在、MMU 也映射了,**EFI_RESOURCE_SYSTEM_MEMORY 没注册 → 不在 GCD 里 → `ConvertPages` 仍然 fail**(因为 ConvertPages 操作的就是 GCD)。

### 层 5:没有 Secure Boot 能力

Win11 24H2 的 bootmgr 对 SB 有偏好。kraxel 预编的 `edk2-aarch64-code.fd` **没启用 SECURE_BOOT_ENABLE**,也没预置 MS 的 PK/KEK/db 密钥。虽然 SB 不是 bootmgr 启动的硬先决条件,但没它 Win11 后续"系统要求"会卡。

### 层 6:TPM 接口选错

upstream QEMU aarch64 只有 **`tpm-tis-device`**(TIS 接口,Windows 兼容性差)。

UTM 自己打补丁加了 **`tpm-crb-device`**(CRB 接口,Windows 的首选 TPM 接口,Windows Hello/BitLocker 原生支持):

- UTM 新加的文件:`hw/tpm/tpm_crb_sysbus.c`, `hw/tpm/tpm_crb_common.c`, `hw/tpm/tpm-sysbus.c`, `hw/tpm/tpm_crb.h`
- 原 `hw/tpm/tpm_crb.c` 里 x86 ISA 专用部分保留,公共部分抽到 `tpm_crb_common.c`
- 在 `include/system/tpm.h` 定义 `TYPE_TPM_CRB_SYSBUS = "tpm-crb-device"`
- ACPI TPM2 表 / sysbus-fdt binding 都要相应分支

这不是简单开关,是一套横跨 7 个文件的设备类型新增。upstream QEMU 合不进,所以我们必须 port 过来。

### 层 7:CD-ROM / 磁盘接口

- **virtio-scsi-cd**:Linux 爱,Windows 不爱(安装盘需要 virtio driver)
- **usb-storage**:Windows 原生支持,bootmgr 也识别
- **virtio-blk** 主磁盘 → **nvme**:Windows 对 NVMe 原生支持最好

这些属于"对齐 UTM 命令行"的配置改动,不需要补丁。

### 层 8:两个 GOP 设备让 bootmgr 画错帧缓冲(**最隐蔽、最致命的一条**)

我们最初同时挂了:

```
-device virtio-gpu-pci    # 主 GOP
-device ramfb             # 备用 FB
```

EDK2 BDS 把两个都注册成 Graphics Output Protocol。**bootmgr/winload 在 ExitBootServices 前后对 GOP 的 handling**:

- 加载 bootmgfw.efi 时,EDK2 传给它一个 ConOut handle(通常是其中一个 GOP)
- bootmgr 可能 switch 到另一个 GOP(常见是 ramfb,因为它简单)
- winload 再接手后,可能又切回 virtio-gpu
- **最后输出的 framebuffer 和我们从 iosurface 抓的不是同一个**

表现:
- `iosurface-probe` 永远给我们"Display output is not active"(ramfb 默认文字)
- 其实 Win11 Setup 已经在 virtio-gpu 上画出来了,但我们看不见
- 或反过来 —— bootmgr 画在 ramfb 上,iosurface 给的是 virtio-gpu

**最后去掉 `virtio-gpu-pci`,只留 `ramfb`**,bootmgr/winload 没得选,全部输出到 ramfb,iosurface 就能抓到 Win11 Setup 界面。这一条是整个问题最后一把钥匙。

---

## 五、修复时间线

阶段推进用"iosurface 事件数 / serial log 进展 / 屏幕内容"三个指标衡量。

### 起点(全栈 upstream)

```
iosurface: 1280x800 卡死(EDK2 初始化后,bootmgr 没接管)
edk2.log: 未开 serialDebug,看不见
屏幕: TianoCore logo + "Start boot option"
```

### 修复 1:加 ramfb 备用 FB(不动任何底层)

```diff
 -device virtio-gpu-pci
+-device ramfb
```

**进展**:bootmgr 切到 800x600 模式。说明 bootmgfw **真的**跑起来了(不是卡在 BDS),之前看不到只是因为它在找 GOP。

```
iosurface: 640x480 → 1280x800 → 800x600 → 1280x800
屏幕(最终): "No bootable option + FvFile Invalid Parameter"
```

### 修复 2:开 EDK2 serial debug 看到 ConvertPages(诊断)

把 `-serial null` 改成 `-serial file:<edk2.log>`。终于看到:

```
BdsDxe: starting Boot0001 ...
ConvertPages: failed to find range 10000000 - 1012BFFF
...
BdsDxe: failed to start Boot0001: Time out
```

这是整个排查的**转折点**:从此知道 bootmgr 在 0x10000000 附近操作内存失败。

### 修复 3:QEMU virt 加低地址 RAM 孔(`patches/0002-*.patch`)

- `include/hw/arm/virt.h`:加 `VIRT_LOWRAM` 枚举
- `hw/arm/virt.c`:`base_memmap` 把 0x10000000 起 16MB 从 PCIe MMIO 切出来,分给 `VIRT_LOWRAM`;`virt_init` 里用 `memory_region_init_ram` 分配并挂到 sysmem

QEMU 的 PCIe MMIO 窗口本来 755MB,分出 16MB 影响忽略。Ubuntu 测试照常进 GRUB。

**但只改这一步没用 —— EDK2 不知道这块地方是 RAM**。

### 修复 4:QEMU DTB 加第二个 /memory 节点

- `include/hw/arm/boot.h`:`struct arm_boot_info` 加 `extra_ram_base` / `extra_ram_size`
- `hw/arm/boot.c`:`load_dtb` 为非零 extra_ram 添加 `/memory@<base>` 节点
- `hw/arm/virt.c`:`bootinfo.extra_ram_base/size` 指向 `VIRT_LOWRAM`

**结果**:EDK2 读到了第二个 `/memory` 节点,但 **PEI 固件 ASSERT**(层 2 的问题)。

### 修复 5:patch EDK2 PEI 内存发现(`patches/edk2/0001-*.patch`)

- `ArmVirtPkg/Library/QemuVirtMemInfoLib/QemuVirtMemInfoPeiLibConstructor.c`:逻辑从"取地址最低"改成"按 `PcdSystemMemoryBase` 匹配主 RAM",额外节点存入新 `gHellVMArmVirtExtraMemoryGuid` HOB
- `ArmVirtPkg/ArmVirtPkg.dec`:注册新 GUID
- `*.inf` [Guids] 段声明依赖

**结果**:ASSERT 不再触发。bootmgr 运行更久,但现在是 **Synchronous Exception**(层 3)。

### 修复 6:patch EDK2 MMU 映射

`ArmVirtPkg/Library/QemuVirtMemInfoLib/QemuVirtMemInfoLib.c` 的 `ArmVirtGetMemoryMap`:读新 GUID HOB,把额外 RAM 作为第 4 个 descriptor 加进页表,属性 `WRITE_BACK` cacheable。

**结果**:Synchronous Exception 消失。

### 修复 7:patch EDK2 GCD 系统内存注册

`ArmVirtPkg/Library/ArmVirtMemoryInitPeiLib/ArmVirtMemoryInitPeiLib.c` 的 `MemoryPeim`:找到新 GUID HOB 时,额外调一次 `BuildResourceDescriptorHob(EFI_RESOURCE_SYSTEM_MEMORY, ...)`。

**结果**:`ConvertPages failed` 彻底消失,CDROM 文件系统 FS0 也成功挂载。bootmgr 完整执行到 ExitBootServices。

但屏幕还是 "Display output is not active"(层 8 的伏笔)。

### 修复 8:Secure Boot EDK2 + MS keys vars

重编 `ArmVirtQemu.dsc` 带 `-D SECURE_BOOT_ENABLE=TRUE`,用 UTM 的 `edk2-arm-secure-vars.fd`(有预置 MS 签名密钥)作为 vars.fd 模板。

**结果**:行为无明显变化,但满足 Win11 对 SB capability 的要求(后续安装需要)。

### 修复 9:对齐 UTM 命令行的设备配置

- CD-ROM:virtio-scsi-cd → **usb-storage**
- 主磁盘:virtio-blk → **nvme**
- RTC:默认 → `base=localtime`

**结果**:bootmgr 成功 ExitBootServices 后 WinPE 初始化没报错,但屏幕还是黑。

### 修复 10:port UTM 的 TPM CRB sysbus(最大一笔改动)

对着 UTM v10.0.2-utm,在我们 v10.2.0 上新增/修改 18 个文件,+705 -244 行:

**新增文件**(从 UTM 拷贝,修头文件路径 `exec/memory.h` → `system/memory.h`):

- `hw/tpm/tpm_crb_sysbus.c`(161 行,CRB sysbus 设备类型)
- `hw/tpm/tpm_crb_common.c`(264 行,CRB 公共逻辑,包括 Apple Silicon 16KB 页大小修复)
- `hw/tpm/tpm-sysbus.c`(48 行,sysbus TPM 通用 plug hook)
- `hw/tpm/tpm_crb.h`(79 行)

**修改文件**:

- `hw/tpm/tpm_crb.c`:304 → 精简,把公共部分抽到 tpm_crb_common.c
- `hw/tpm/tpm_ppi.[ch]`:加 `tpm_ppi_init_memory()` 函数(CRB sysbus 需要)
- `hw/tpm/Kconfig`:新增 `config TPM_CRB_SYSBUS`
- `hw/tpm/meson.build`:把新文件编进
- `hw/arm/Kconfig`:`imply TPM_CRB_SYSBUS`
- `include/system/tpm.h`:`TYPE_TPM_CRB_SYSBUS = "tpm-crb-device"` + `TPM_IS_CRB_SYSBUS()` 宏
- `include/hw/acpi/tpm.h`:补 `REG32(CRB_CTRL_RSP_LADDR, 0x68)` / `RSP_HADDR`(UTM 把 64-bit ADDR 拆成两个 32-bit)
- `hw/acpi/aml-build.c`:ACPI TPM2 表加 CRB sysbus 分支,从 `x-baseaddr` 算 control area address
- `hw/core/sysbus-fdt.c`:`TYPE_TPM_CRB_SYSBUS` 用 TIS 的 FDT 节点冒充(OVMF 硬编码找 TIS)
- `hw/arm/virt.c`:`machine_class_allow_dynamic_sysbus_dev(mc, TYPE_TPM_CRB_SYSBUS)`,允许 `-device tpm-crb-device` 挂到 virt 的 platform bus
- HVF IPA unknown size fallback

C 调用签名适配(QEMU 10.2 `class_init` 多了 const):`void (*)(ObjectClass *, void *)` → `void (*)(ObjectClass *, const void *)`。

QEMUBackend.swift 里 TPM 设备从 `tpm-tis-device` 改成 `tpm-crb-device`。

**结果**:固件/设备层面全通,但 **仍然屏幕黑**。高 CPU 几秒后回落到 idle,同样的症状。

### 修复 11:去掉 virtio-gpu-pci,只留 ramfb(最后的临门一脚)

```diff
- args += ["-device", "virtio-gpu-pci"]
  args += ["-device", "ramfb"]
```

**结果**:**Windows 11 Setup GUI 出现** — "Select language settings",下拉框、Microsoft logo、Next 按钮全部可见可交互。

这一条背后的原理:bootmgr/winload 看到两个 GOP 时,每一阶段可能选不同的画,最后我们抓的 iosurface 不是 guest 真在写的那个。只留 ramfb,guest 没得选,输出一定在 ramfb。

---

## 六、修复后的完整数据流

```
┌────────────────────────────────────────────────────────────────┐
│ QEMU patched(Vendor/qemu-src + patches/0002-*.patch)           │
├────────────────────────────────────────────────────────────────┤
│ hw/arm/virt.c:                                                 │
│   base_memmap[VIRT_LOWRAM] = {0x10000000, 16MB}                │
│   machine_class_allow_dynamic_sysbus_dev(tpm-crb-device)       │
│ hw/arm/boot.c:                                                 │
│   load_dtb() 加 /memory@10000000 节点                          │
│ hw/tpm/*: port UTM 的 tpm_crb_sysbus(新设备类型)              │
│ hw/acpi/aml-build.c: TPM2 表加 CRB sysbus 分支                 │
└────────────────────────────────────────────────────────────────┘
                           ↓
┌────────────────────────────────────────────────────────────────┐
│ EDK2 patched(Vendor/edk2-src + patches/edk2/0001-*.patch)      │
├────────────────────────────────────────────────────────────────┤
│ PEI: QemuVirtMemInfoPeiLibConstructor                          │
│   - 按 PcdSystemMemoryBase 选主 RAM                            │
│   - 额外节点存入 gHellVMArmVirtExtraMemoryGuid HOB             │
│ PEI: ArmVirtGetMemoryMap                                       │
│   - 额外 RAM 映射进 MMU 页表(WRITE_BACK)                     │
│ PEI: MemoryPeim                                                │
│   - 额外 RAM 注册为 EFI_RESOURCE_SYSTEM_MEMORY                 │
│ 构建:-D SECURE_BOOT_ENABLE=TRUE                               │
└────────────────────────────────────────────────────────────────┘
                           ↓
┌────────────────────────────────────────────────────────────────┐
│ QEMUBackend.swift 生成的命令行                                 │
├────────────────────────────────────────────────────────────────┤
│ -machine virt,accel=hvf                                        │
│ -cpu host                                                      │
│ -drive if=pflash,readonly=on,file=edk2-aarch64-code.fd         │
│ -drive if=pflash,file=<per-VM>/efi/vars.fd                     │
│   (vars.fd 从 edk2-arm-secure-vars.fd 复制,含 MS 密钥)        │
│ -device qemu-xhci,id=usbbus                                    │
│ -drive if=none,id=cdrom0,media=cdrom,file=<iso>,readonly=on    │
│ -device usb-storage,drive=cdrom0,removable=true,bootindex=0    │
│ -drive if=none,id=hd0,file=<disk>,format=qcow2                 │
│ -device nvme,drive=hd0,serial=hellvm-hd0                       │
│ -chardev socket,id=chrtpm,path=<swtpm.sock>                    │
│ -tpmdev emulator,id=tpm0,chardev=chrtpm                        │
│ -device tpm-crb-device,tpmdev=tpm0                             │
│ -rtc base=localtime                                            │
│ -netdev user,id=net0                                           │
│ -device virtio-net-pci,netdev=net0                             │
│ -device ramfb                 ← 仅 ramfb,不要 virtio-gpu-pci  │
│ -device usb-kbd,bus=usbbus.0                                   │
│ -device usb-tablet,bus=usbbus.0                                │
│ -display iosurface,socket=<iosurface.sock>                     │
└────────────────────────────────────────────────────────────────┘
                           ↓
┌────────────────────────────────────────────────────────────────┐
│ Win11 启动链路(成功)                                         │
├────────────────────────────────────────────────────────────────┤
│ 1. EDK2 PEI/DXE 初始化(patched,多内存节点 OK)               │
│ 2. BDS 扫描启动项 → Boot0001 UEFI QEMU USB HARDDRIVE           │
│ 3. 加载 El Torito UEFI boot image (efisys.bin) 里的 bootmgr    │
│ 4. bootmgr.efi:                                                │
│    - ConvertPages @ 0x10000000 ✅(有 RAM + GCD 条目)          │
│    - 读 CD 文件系统 \efi\microsoft\boot\BCD ✅                 │
│    - 加载 \sources\boot.wim 到 ramdisk                         │
│ 5. winload.efi 接手 → ExitBootServices                         │
│ 6. WinPE 内核启动                                              │
│    - 初始化 TPM CRB 设备(tpm-crb-device 存在且 ACPI OK)      │
│    - 加载 Setup.exe                                            │
│ 7. Windows 11 Setup GUI:"Select language settings" ✅         │
└────────────────────────────────────────────────────────────────┘
```

---

## 七、项目里固化下来的产物

| 路径 | 内容 |
|---|---|
| `patches/0001-ui-add-iosurface-display-backend.patch` | iosurface 显示后端(原有,与 Win 无关) |
| `patches/0002-hw-arm-virt-add-low-RAM-hole-for-Win11-bootmgr-compa.patch` | QEMU 端全部 Win 兼容补丁(+705 -244,18 文件) |
| `patches/edk2/0001-ArmVirtPkg-extra-RAM-region-for-Win11-compat.patch` | EDK2 端全部补丁(+118 -17,8 文件) |
| `Vendor/qemu-utm-ref/` | UTM QEMU fork,patch 提取参考(不进 build) |
| `Vendor/edk2-src/` | 打了补丁的 EDK2 源,可 `build -a AARCH64 -t GCC5 -p ArmVirtPkg/ArmVirtQemu.dsc -b RELEASE -D SECURE_BOOT_ENABLE=TRUE` 重编 |
| `Vendor/firmware-archive/` | UTM 原版固件备份,以备参考 |
| `Sources/HVMBackendQEMU/QEMUBackend.swift` | 上述命令行生成逻辑 |
| `Sources/HVMCore/VMConfig.swift` | `boot.tpm` / `boot.serialDebug` 开关 |
| `Sources/HVMBundle/VMBundle.swift` | `tpmStateDirURL` / `tpmSocketURL` / `edk2LogURL` |
| `CLAUDE.md` | 诊断工具章节,记录 `serialDebug` 用法 |

---

## 八、如果要复现整个构建

前提依赖:

```bash
brew install aarch64-elf-gcc nasm acpica swtpm xorriso
```

构建 EDK2(19 秒增量):

```bash
cd Vendor/edk2-src
source edksetup.sh
export GCC5_AARCH64_PREFIX=aarch64-elf-
build -a AARCH64 -t GCC5 -p ArmVirtPkg/ArmVirtQemu.dsc -b RELEASE \
  -D SECURE_BOOT_ENABLE=TRUE -D NETWORK_ENABLE=FALSE
```

装到 Vendor:

```bash
EDK2_FV=Vendor/edk2-src/Build/ArmVirtQemu-AARCH64/RELEASE_GCC5/FV
VENDOR=Vendor/qemu/share/qemu
ARCHIVE=Vendor/firmware-archive
cp "$EDK2_FV/QEMU_EFI.fd" "$VENDOR/edk2-aarch64-code.fd"
cp "$ARCHIVE/edk2-arm-secure-vars.fd.utm" "$VENDOR/edk2-arm-vars.fd"
truncate -s 67108864 "$VENDOR/edk2-aarch64-code.fd"
truncate -s 67108864 "$VENDOR/edk2-arm-vars.fd"
```

构建 QEMU(增量,已 apply 过 patch 的话):

```bash
cd Vendor/qemu-build
ninja qemu-system-aarch64
make install
xattr -cr ../qemu/bin/
codesign --force --sign "-" \
  --entitlements ../../Resources/qemu.entitlements \
  --options runtime ../qemu/bin/qemu-system-aarch64
```

全量重建(包含 patch 应用):

```bash
FORCE=1 bash scripts/build-qemu.sh
```

构建 App:

```bash
make build
make cli
```

跑 Win11:

1. `VMConfig.boot.tpm = true`(swtpm 需要安装)
2. 启动 VM
3. Win11 Setup 直接出现(ramfb 在 800x600)

---

## 九、已知不完美之处

1. **显示只能 ramfb,不能用 virtio-gpu**。代价:无 GPU 加速、分辨率限制 800x600;优点:Win11 boot 稳。要两者兼得需要实现 UTM 的 `virtio-ramfb-gl`(更大改动)。
2. **`iosurface-probe` 必须由 VM 重启后首次连接**。它是单客户端协议,断开后 QEMU 不会重新 accept(已有 ccd_session 评注,不在本次修复范围)。
3. **Win11 安装后需要手动 inject virtio driver** 才能启用网络/显示增强;目前 usb-net/usb-storage/nvme 的原生驱动足够进入桌面。
4. **EDK2 补丁针对 stable202408**。切 EDK2 tag 时可能需要 rebase。我们的 patch 是 surgical 的(只改 3 个 c 文件和 DEC/INF),rebase 成本不大。
5. **对 Linux VM 的副作用**:PCIe MMIO 窗口少了 16MB(755 → 739);virtio-gpu 路径没断,Linux VM 用仍然正常。已在 Ubuntu 24.04 ARM64 live ISO 上回归验证过。

---

## 十、对后续维护者的建议

- 排查任何 Win 启动问题,第一件事:`VMConfig.boot.serialDebug = true`,看 `<bundle>/logs/edk2.log`。
- 换 EDK2 版本(升 stable2025xx)时,注意这些 hooks 是否还在:
  - `ArmVirtGetMemoryMap` 的 MAX_VIRTUAL_MEMORY_MAP_DESCRIPTORS 是否够用(我们占用 [3])
  - `QemuVirtMemInfoPeiLibConstructor` 的选 NewBase 逻辑
  - `MemoryPeim` 里我们加的 `gHellVMArmVirtExtraMemoryGuid` HOB 读取
- 换 QEMU 版本时重点测:
  - TPM CRB sysbus 三联(`tpm_crb_sysbus.c` / `tpm_crb_common.c` / `tpm-sysbus.c`)是否能编
  - `class_init` 签名是否再次变化
  - `exec/memory.h` vs `system/memory.h` 头路径
- 想引入 virtio-gpu 加速 Win11,优先路线:port UTM 的 `virtio-ramfb-gl` 设备(把 virtio-gpu + ramfb 合成单设备)。
