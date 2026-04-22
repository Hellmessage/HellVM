# HellVM 加密设计

本文档讨论 HellVM 虚拟机加密的设计思路、威胁模型与落地方案，不涉及具体代码实现。

---

## 1. 目标

> 没有密码无法查看 VM 的任何内容（磁盘、配置、EFI 变量、日志等）。

当前 bundle 结构（见 [VMBundle.swift](../Sources/HVMBundle/VMBundle.swift)）：

```
<uuid>.hellvm/
├── config.json        # VM 配置（明文）
├── disks/             # 磁盘镜像
├── efi/               # EFI 变量（VZ 后端）
├── logs/              # 运行日志
└── 运行时文件（pid / sockets）
```

任何加密方案必须覆盖以上**全部**内容，否则文件名、硬件配置、固件状态都会泄露。

---

## 2. 威胁模型

不同威胁等级对应不同防御强度，先定义再设计。

| 等级 | 场景 | 典型攻击 |
|---|---|---|
| T1 | 普通丢失/盗窃 | 磁盘直接读取 |
| T2 | 离线取证 | 磁盘镜像、冷启动、固件分析 |
| T3 | 远程入侵 | 0-day、供应链、MDM |
| T4 | 胁迫交出密码 | 法律强制、物理胁迫 |
| T5 | 运行时取证 | 内存快照、DMA、JTAG |
| T6 | 长期侧信道 | TEMPEST、电磁、功耗 |

**普通用户**：T1 即可。
**隐私敏感用户**：T1 + T2。
**国家级对抗**：T1 – T5 全覆盖，T6 在 macOS 平台基本无法做到。

---

## 3. 方案对比

### 方案 A：仅加密磁盘（最小改动）

- 利用 QEMU 原生 LUKS：
  ```
  qemu-img create -f qcow2 -o encrypt.format=luks,encrypt.key-secret=sec0 disk.qcow2 40G
  ```
- 启动时通过 QMP `object-add secret` 注入密码
- 改动点：[DiskManager.swift:14](../Sources/HVMStorage/DiskManager.swift:14) 增加加密参数；QEMU 后端启动时传 `-object secret`

**缺点**：`config.json`、EFI 变量、日志仍是明文，能看到 VM 名称、硬件配置、固件状态。
**适用**：T1。

### 方案 B：整个 bundle 加密容器（推荐）

- 把 `<uuid>.hellvm/` 放进一个 APFS 加密稀疏磁盘映像（`hdiutil create -encryption AES-256 -type SPARSEBUNDLE`）
- 启动 VM 前 `hdiutil attach` 挂载（输入密码），停止后 `detach`
- 改动点：[VMBundle.swift](../Sources/HVMBundle/VMBundle.swift) 增加 `unlock(password:)` / `lock()` 流程；列表逻辑区分"已加密未挂载"状态

**优点**：磁盘 / 配置 / EFI / 日志**全部**加密，未解锁时 bundle 目录不挂载到文件系统。
**适用**：T1 + T2。

### 方案 C：应用层加密（最灵活）

- passphrase → Argon2id → KEK，CryptoKit AES-GCM 加密 config.json + EFI 目录
- 磁盘仍用方案 A 的 LUKS
- 日志另行加密或禁用

**缺点**：每个文件读写路径都要改；密钥管理、失败恢复自行设计。
**适用**：需要细粒度控制（比如只解锁配置不解锁磁盘）的场景。

---

## 4. 国家级对抗的分层设计

若目标是 T1 – T5，需要多层叠加。

### 第 1 层：密钥管理（地基）

- **KDF**：Argon2id，`m=1GB, t=4, p=4`，盐 32 字节。**不要用 PBKDF2**
- **密钥层次**：passphrase → KEK → DEK（数据加密密钥，随机 256 位，KEK 包裹）
- 密钥仅在必要时刻驻留内存，使用后立即 `memset_s` / `mlock` 防止换出
- **不依赖 Keychain / Secure Enclave 作为唯一信任根**——可作为第二因子
- **多因子**：passphrase + YubiKey（FIDO2 hmac-secret）+ 物理 keyfile，任一丢失都不泄密

### 第 2 层：数据加密（对抗 T2）

三选一或叠加：

- **LUKS + detached header**：header 放在 U 盘或另一台设备，主机磁盘看到的是随机数据，**无法证明这是加密卷**
- **VeraCrypt hidden volume**：两个密码，一个解锁诱饵 VM，一个解锁真实 VM（对抗 T4）
- **应用层 AES-256-GCM + 每文件独立 nonce**

### 第 3 层：运行时保护（对抗 T5）

- **禁用 swap / hibernation**：`sudo pmset -a hibernatemode 0 && sudo rm /var/vm/sleepimage`，否则密钥会写入磁盘
- **禁用 coredump**：`ulimit -c 0` + `launchctl limit core 0 0`
- **Spotlight 排除** bundle 目录
- **关闭 Time Machine** 对该目录的快照
- QEMU guest 内存在 host 上是明文，host kernel / root 可读——这是**不可消除的残留风险**
- macOS 无 AMD SEV / Intel TDX 等价特性，无法做 full memory encryption

### 第 4 层：可否认性 / 胁迫防御（对抗 T4）

- **Duress password**：特定密码静默擦除 DEK（覆写 header 的 key slot），卷永久无法解密
- **Hidden volume**：两套数据
- **Dead-man switch**：N 天未启动自动擦除（launchd）
- ⚠️ 某些司法管辖区销毁证据本身是刑事罪名，属法律风险

### 第 5 层：供应链与平台信任（对抗 T3）

- **可重现构建**：`make build` 产物字节一致
- **代码签名 + 公证** 与 **可审计性** 存在 trade-off（公证意味着苹果知晓构建）
- **依赖审计**：QEMU 本身攻击面巨大，考虑最小化 static build
- **不联网**：关闭 `com.apple.quarantine`、崩溃报告、软件更新

### 第 6 层：操作安全

- 物理隔离：运行敏感 VM 的机器不上网，不登录 iCloud
- 启动介质：只读 USB，每次启动前校验 SHA256
- Tamper-evident seals：物理封条防止 covert 开箱植入
- 屏蔽：法拉第袋 / 屏蔽室对抗 T6
- 不拍照、不备份到云、不泄露身份

---

## 5. 方案 B 的解密难度

解密难度**几乎完全取决于密码强度**，与算法无关。

### 技术底牌

macOS `hdiutil -encryption AES-256` 实现：

| 项目 | 规格 |
|---|---|
| 算法 | AES-256-XTS（与 FileVault 同款） |
| KDF | PBKDF2-SHA256，~250,000 轮 |
| 密钥包裹 | 主密钥随机 256 位，KEK 包裹后存 header |
| 算法破解 | 不可行（AES-256 暴力 2^256） |

攻击者唯一实用路径 = 爆破密码。

### 不同密码强度的成本估算

按 **RTX 4090 × 8 卡（~30 万 H/s for PBKDF2-SHA256-250k）** 估算：

| 密码类型 | 示例 | 熵 | 单 GPU | 国家级集群（10 万 GPU） |
|---|---|---|---|---|
| 弱密码 | `password123` | ~30 bit | 秒级 | 瞬间 |
| 一般密码 | `MyDog2024!` | ~45 bit | 几天 | 秒级 |
| 8 随机字符 | `K9#mP2!x` | ~52 bit | 几年 | 几小时 |
| 12 随机字符 | `K9#mP2!xQ@wL` | ~78 bit | ~百万年 | ~10 年 |
| Diceware 6 词 | `correct-horse-battery-staple-moon-rain` | ~77 bit | ~百万年 | ~10 年 |
| Diceware 8 词 | 8 个随机英文词 | ~103 bit | 宇宙年龄级 | 宇宙年龄级 |
| 25 随机字符 | 随机大小写+数字+符号 | ~163 bit | 不可能 | 不可能 |

**国家级对抗结论**：**≥ Diceware 8 词** 或 **≥ 25 随机字符**。

### 方案 B 的固有弱点

1. **PBKDF2 对 GPU 不够友好**，国家级有专用 ASIC，速度可能再快 10–100 倍
2. **迭代轮数固化**（250k）偏弱，Argon2id 更强但 macOS 原生不支持
3. **Header 明显 magic bytes**，取证工具可识别"此处有加密容器"，无法否认
4. **macOS 缓存痕迹**：
   - `Finder` sidebar、`recentitems`、Spotlight 索引
   - QuickLook 缩略图缓存（可能泄露 VM 截图）
   - `com.apple.diskimages.recentitems.plist`（挂载历史）
5. **内存交换**：挂载后密钥在内核内存，若发生 swap / hibernate，密钥落盘

### 方案 B 的强化措施

1. 密码：Diceware **≥ 8 词** 或 **≥ 30 位** 随机字符
2. `sudo pmset -a hibernatemode 0` + 删除 `sleepimage`
3. 挂载参数：`-noverify -noautofsck -nobrowse`
4. 用完立即 `detach`，不让挂载态过夜
5. 清理 `com.apple.diskimages.recentitems.plist`

### 更强的替代

| 方案 | 优势 |
|---|---|
| VeraCrypt | 默认 Argon2id，迭代参数可调至 1GB 内存，GPU 优势大幅缩水 |
| LUKS2 detached header | Argon2id + header 物理分离 |
| 应用层自实现 | CryptoKit AES-GCM + Argon2id（需引入 `swift-crypto` + argon2 C 库） |

---

## 6. 推荐组合

### 场景一：普通隐私保护（T1 + T2）

**方案 B + 强密码**
- `hdiutil` AES-256 稀疏映像
- Diceware 6 词密码
- 禁用 hibernation、清理挂载历史
- 改动范围：仅 `VMBundle` 挂载层

### 场景二：高强度对抗（T1 – T4）

**VeraCrypt + LUKS 双层**
- 外层：VeraCrypt hidden volume（Argon2id，hidden 提供可否认）
- 内层：bundle 里磁盘再套 LUKS2 + detached header（header 放 YubiKey）
- 三因子：passphrase + YubiKey hmac-secret + USB keyfile
- 运行前强制环境检查：swap / hibernate / 网络 / coredump
- 实现 duress password → 覆写 header key slot

### 场景三：国家级（T1 – T5，现实可行的上限）

- 场景二的一切
- 专用离线机器，不登录 iCloud，不联网
- 从只读 USB 启动，SHA256 校验
- 物理封条 + 屏蔽
- 接受残留风险：macOS 内核 / T2 / SEP 闭源无法完全审计

**真正的 T5 对抗不应使用 macOS**，应选 Qubes OS + coreboot + 开源硬件。

---

## 7. 在 HellVM 项目中的落地改动点

以方案 B（场景一）为最小可行版本：

| 位置 | 改动 |
|---|---|
| [VMBundle.swift](../Sources/HVMBundle/VMBundle.swift) | 增加 `isEncrypted`、`isMounted`、`unlock(password:)`、`lock()` 方法 |
| [VMBundle.swift](../Sources/HVMBundle/VMBundle.swift) | `listAll()` 区分"已加密未挂载" bundle，只展示元信息 |
| [VMBundle.swift](../Sources/HVMBundle/VMBundle.swift) | `create` 增加 `encrypted: Bool, password: String?` 参数 |
| 新建模块 | `HVMCrypto`：封装 `hdiutil create / attach / detach`，密码通过 stdin 传入（不走命令行参数避免 `ps` 泄露） |
| CLI | 增加 `hellvm unlock <uuid>` / `hellvm lock <uuid>` 子命令 |
| GUI | 启动 VM 前弹出密码输入框（黑色风格，右上角 X 关闭） |
| 环境检查 | 新建 `hellvm paranoid-check` 子命令：校验 swap / hibernate / coredump / Spotlight 状态 |

---

## 8. 诚实的残留风险声明

以下风险**任何用户层加密方案都无法消除**，使用者需知悉：

- macOS 内核对用户进程内存不透明，苹果 / 国家可通过 kext / DriverKit 读取
- T2 / SEP 固件闭源，硬件级后门无法审计
- QEMU 运行时 guest 内存在 host 上是明文，host root / kernel 可读
- App Store / Gatekeeper 公证链意味着苹果知晓你运行的二进制
- 自动崩溃报告、诊断上传可能泄露进程状态
- 供应链攻击（Xcode、brew、swift package）无法完全防御

> 如果你的威胁模型真的包含国家级对手，**不要使用 macOS**。
