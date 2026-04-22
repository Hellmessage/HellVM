# HellVM 开发路线图

## 当前进度

- ✅ **P0** 项目骨架(Swift Package,`make build`,Hell Dev 自签)
- ✅ **P1** QEMU v10.2.0 自编译 + HVF 加速 + 一键打包(`.app` 223MB,含 22 个 dylib)
- ✅ **P2** QMP 控制通道:start / stop(ACPI 软关机+超时 SIGKILL) / pause / resume / list 状态
- ✅ **P3** SwiftUI GUI:侧栏 + 详情 + 新建向导 + 日志查看
- ✅ **P4** 图形显示 + 键鼠输入 + 独立 Console 窗口(详见下方)

---

## P4 · 图形显示(核心) ✅

目标:把 VM 的 framebuffer 显示到 App 窗口,取代 `-nographic` 串口文本。

- [x] **QEMU 自定义 display backend** (`ui/iosurface.m`, patches/0001)
  - POSIX shm + `SCM_RIGHTS` 传 fd (放弃原 IOSurface+mach port 方案, 见 design doc)
  - DCL 完整实现 + 16B stride 对齐 + 对 USB HID LED 双向同步
  - 协议: HELLO / SURFACE / UPDATE_HINT / CURSOR / MOUSE_SET / LED_STATE / RESIZE_REQ
- [x] **Swift 侧 Metal 渲染** (`HVMDisplay` target)
  - `MTLBuffer(bytesNoCopy:)` + `makeTexture` 零拷贝 + `addCompletedHandler` 生命周期管理
  - 全屏 + cursor 两个 pipeline, alpha-blend 硬件光标合成
  - `SharedFramebuffer` 从 SCM_RIGHTS 收的 shm fd 做 mmap
- [x] **键鼠输入注入** (QMP `input-send-event` 专用 socket 长连接)
  - USB HID (`usb-kbd` / `usb-tablet` / `qemu-xhci`), 兼容 UEFI
  - Caps Lock LED 双向同步 (host 开/关 ↔ guest 开/关 通过 HID output report)
  - `cmd+Q` 退出确认 ("关机所有 VM 再退出"), `cmd+opt+esc` 释放键盘
- [x] **非图形模式 fallback** (`VMConfig.boot.graphical`)
  - 新建向导可选「串口」模式 → `-nographic` + `-serial file:serial.log`
  - 详情页 Console tab 串口模式下显示 serial 日志 tail
- [x] **Guest 动态分辨率** (MSG_RESIZE_REQ → `dpy_set_ui_info`)
  - 窗口拉伸 200ms debounce → QEMU → virtio-gpu EDID 更新 → guest 自适应
- [x] **VM 详情页改版**
  - Console / Settings 标签切换, 切 VM 时自动切换 tab
  - 「打开 Console」独立 `NSWindow` (单画面策略, 打开时内嵌让位)
  - 底部可折叠 Logger tail (`@AppStorage` 持久化)
- [ ] ~~剪贴板同步~~ (延后, 需 SPICE vdagent)

### 过程中的关键踩坑记录

1. **IOSurface 跨进程 lookup 失败** → 改走 POSIX shm + `SCM_RIGHTS` (mach port 要 XPC/launchd, `fileport_makefd` 只认 `IOT_FILEPORT`)
2. **SIGPIPE 杀 App** → VM 关机对端 socket 关闭, `write` 收 SIGPIPE; `signal(SIGPIPE, SIG_IGN)` 全局忽略
3. **macOS Automatic Termination** → `Info.plist` + `ProcessInfo.disableAutomaticTermination` 双保险
4. **Metal stride validation abort** → BIOS 选 2326x1932 等非对齐分辨率时 `bytesPerRow % 16 != 0` 触发 `_mtlValidateStrideTextureParameters` → `SIGABRT`; QEMU 侧对齐 256B + Swift 侧 guard 兜底
5. **双 FramebufferView race** → 打开独立 Console 时内嵌 + 独立同连单客户端 socket 互踢; `detachedIDs.insert` 后 `DispatchQueue.main.async` 延后 buildWindow, 保证 SwiftUI 先 teardown 内嵌
6. **Caps Lock 双轨不同步** → Host Caps LED 状态通过 guest HID LED output report 回传 (MSG_LED_STATE), `syncCapsLockIfNeeded` 不一致时补 toggle 脉冲

---

## P5 · 快照 / 共享 / 外设

- [ ] **快照**
  - qcow2 internal snapshot:`qemu-img snapshot -c/-a/-d`
  - VM 运行中快照:QMP `savevm` / `loadvm`
  - UI:详情页加 "快照" section,列表 + 创建 + 恢复 + 删除
- [ ] **共享文件夹(VirtioFS 替代)**
  - QEMU `virtiofsd` 子进程管理(spawn + 传 socket)
  - UI 里可选 host 目录,挂载到 `/mnt/hellvm-share`(需要 guest 驱动,Linux 5.4+ 原生,Windows 需装驱动)
- [ ] **USB 直通**
  - `qemu-xhci` 控制器 + `usb-host` 设备,libusb 枚举/claim
  - **签名零申请**:不需要 `com.apple.vm.device-access`(那是 VZ 的 entitlement,QEMU 路线用不上)
  - 编译前置:`build-qemu.sh` 确认 `--enable-libusb`,`otool -L` 检查产物链接 libusb
  - 设备兼容性(受 macOS IOKit 抢占策略限制,**非 entitlement 能解决**)
    - ✅ 可直通:U 盘/移动硬盘(需先 eject)、开发板(Arduino/ESP32/ST-Link)、Yubikey、打印机
    - ⚠️ 需卸载驱动:USB 转串口(FTDI/CH340),`libusb_set_auto_detach_kernel_driver` 或 sudo kextunload
    - ❌ 无法直通:HID(键盘/鼠标)、摄像头、USB 音频 —— macOS 硬编码抢占,除非做 DriverKit SysExt(不考虑)
  - 热插拔:QMP `device_add` / `device_del`,VM 运行中动态加卸载
  - 备选方案:`usb-redir` over socket(跨机器 USB 转发,macOS 侧 usbredirect 支持有限)
  - UI:详情页 Devices section
    - 列出主机 USB + 占用状态标识(可直通 / 需释放 / 系统占用)
    - 用户勾选绑定,保存到 VM config,启动时带上 `-device usb-host,vendorid=...`
    - 运行中支持热插拔按钮
- [ ] **网络模式切换**
  - 现有:`-netdev user`(NAT,零依赖,默认保留)
  - 桥接方案:集成 **socket_vmnet** 外挂 helper(决策:先走这个,后续再评估)
    - QEMU 侧:`-netdev stream,id=net0,addr.type=unix,addr.path=/var/run/socket_vmnet`
    - 覆盖三种模式:shared(NAT+DHCP) / host-only / **bridged**(真二层桥接)
    - 用户侧:`brew install socket_vmnet`,首次 sudo 配置一次(launchd daemon)
    - 参考实现:Lima / Colima / Rancher Desktop 均用此方案
  - 决策理由
    - 避开受限 entitlement `com.apple.vm.networking`(Apple 审批 2-6 周,需已发布 App)
    - **自编译版本也能享受完整桥接能力**,不绑死官方签名证书
    - socket_vmnet 社区成熟,vmnet.framework 由 Apple 维护稳定
  - 架构建议:抽象 `NetworkBackend` 接口,后端可插拔
    - 实现顺序:`user` → `socket_vmnet` → (未来)`vmnet-native` / 自研 BPF helper
  - 备选(长期):原生 `-netdev vmnet-bridged` 作为 Release 版锦上添花(见 P6 entitlement 申请)
  - UI:新建向导 + 详情页 network section
- [ ] **多磁盘管理**
  - 详情页 Disks section,增删 / 改大小 / 调顺序
  - qcow2 → raw 转换

预估:**2-3 周**

---

## P6 · 分发 & 质量

- [ ] **README.md 正式版**(项目介绍、截图、安装、CLI 用法、快捷键)
- [ ] **完整 CI**(GitHub Actions / 本地脚本):lint + build + 冒烟启动 VM
- [ ] **测试覆盖**
  - HVMCore 配置编解码(已有骨架,因 CLT 无 Testing framework 未跑)
  - VMBundle 读写 + 运行时文件
  - QMPClient mock 服务端
- [ ] **分发签名(可选)**
  - 注册 Apple Developer Program($99/年),拿 Developer ID Application 证书
  - `bundle.sh` 切换签名身份(已通过 `SIGN_IDENTITY` env 支持)
  - 公证:`xcrun notarytool submit + staple`
- [ ] **申请 `com.apple.vm.networking` entitlement(可选,锦上添花)**
  - 前置条件:项目已发 v1.0 + 有 README/截图 + Bundle ID 稳定 + 账号状态良好
  - 途径:<https://developer.apple.com/contact/> → Entitlements,人工邮件审核
  - 周期:2-6 周,首次被拒可补材料二次申请
  - 参考:VirtualBuddy 已获批,开源项目 + 明确虚拟化用途通过率较高
  - 通过后
    - Release 版启用原生 `-netdev vmnet-bridged`(零外部依赖,体验对齐 VirtualBuddy)
    - 自编译 / 贡献者版本继续走 socket_vmnet 回退路径
    - `NetworkBackend` 运行时自动探测 entitlement 有效性,选择最佳后端
- [ ] **自动更新**(Sparkle 框架,可选)
- [ ] **崩溃上报**(可选)

预估:**1 周**

---

## 已知技术债

### 代码层
- [ ] `QEMUBackend` 的 `NSLock + withStateLock` 改 `actor`(消除 `@unchecked Sendable`)
- [ ] `QMPClient` 读写当前串行化在 actor 内,高并发时需 reader-task + pending response 表
- [ ] `VMController` 里 `killPID` / ISO 绝对路径处理等辅助重复,抽 util
- [ ] 错误类型统一:目前散用 `VMError.startFailed/backendUnavailable/notImplemented`,语义不准确
- [ ] `dbg()` 文件日志只在 debug 时有用,P6 前应改 `OSLog` 或可关
- [ ] `String(format: "%s")` 已知坑已避开,但 `InfoPill` / `keyValue` 等拼接方式不一致

### 构建 / 打包
- [ ] `build-qemu.sh` 目前只编 `aarch64-softmmu`,需要加 `x86_64-softmmu`(未来支持 x86 Windows/Linux guest)
- [ ] `collect-dylibs.sh` 在极端情况下(dylib 嵌套深度 > 10 层)可能死循环,加保护
- [ ] QEMU 上游升级脚本(pin 当前 v10.2.0,需要定期 bump + 重打 patch)
- [ ] `.app` 体积 222MB,edk2-arm-vars.fd 64MB 是稀疏文件可能压缩掉

### GUI / 交互
- [ ] App 关闭时的 VM 处理策略:提示用户 or 强制 SIGKILL 所有 VM(目前 Process ARC 回收时会 SIGTERM 子进程,行为依赖 macOS 版本)
- [ ] 启动按钮点击后无 loading 态指示(~1s 延迟),应加 spinner
- [ ] 删除 VM 时没有校验磁盘残留(qcow2 是否在被其他地方 mount)
- [ ] 错误 banner 只在详情页,新建向导的错误也应统一风格
- [ ] 中文硬编码,缺 i18n
- [ ] 没有键盘快捷键(`cmd+n` 新建 / `cmd+r` 启动 / `cmd+.` 停止)

### CLI
- [ ] `hellvm start` 在 VM 被别的进程 hold 磁盘时只能看到 qemu 原始错误,应预检磁盘锁状态
- [ ] `hellvm info` 输出格式与 `list` 不统一
- [ ] 没有 `hellvm console`(attach 到运行中 VM 的 QMP / serial),需要 P4 之后
- [ ] 没有 `hellvm snapshot` 子命令组

---

## 小 polish 清单(P3 后优化)

- [ ] 侧栏搜索 / 筛选(按架构、状态)
- [ ] VM 重命名(目前只能删+建)
- [ ] VM 克隆 / 导出 `.hellvm` zip
- [ ] VM 图标颜色自定义(用户设定主题色)
- [ ] 启动时间 / 运行时长显示
- [ ] 内存 / CPU 使用率(QMP `query-memory-size-summary` / `query-cpu-usage`)
- [ ] 启动前确认对话框(避免误点)
- [ ] 最近使用的 ISO 历史(新建向导下拉)
- [ ] `hellvm` CLI 放到 `/usr/local/bin/` 的 install 脚本

---

## 不做 / 已评估放弃

- ❌ **Apple Virtualization.framework 后端**:entitlement 需付费 Developer + provisioning profile,已砍(见 git log `feat(qmp)` 前的讨论)
- ❌ **Rosetta-in-Linux**:依赖 VZ,同上放弃
- ❌ **macOS guest**:QEMU+OpenCore 碎片化,VZ 走不通
- ❌ **iOS/iPad 版**:非目标

---

## 里程碑建议顺序

1. **P4 图形显示** —— 没这个就还是个 CLI 工具,GUI 价值有限
2. **P5 快照 + 多磁盘 + 网络模式** —— 让 VM 真正好用
3. **P6 分发 + README + 测试** —— 收尾发布
4. 小 polish 持续迭代
