# CLAUDE.md

## 文档约束

- `CLAUDE.md` 只存放约束,不放其他东西.
- `README.md` 存放项目说明

## 交付约束 **必须遵守**

- 代码变更后,必须使用`make build` 进行验证
- 必须`make build`验证通过,否则视为任务未完成

## 构建约束

- 所有构建产物输出到根目录 `build/`
- 编译和测试必须通过 `make build` 执行
- **零环境可构建**: 空白 Mac 上 `make build` 必须一条命令跑通,脚本自动处理
  Xcode Command Line Tools / Xcode license / Homebrew / brew formulas / QEMU 源码编译。
  新增外部依赖时,必须同步更新 `scripts/install-deps.sh`(和/或 `scripts/build-qemu.sh`),
  不能要求用户手动 `brew install xxx` 才能 build。

## 代码约束

- 代码文件使用中文注释

## GUI约束

- 黑色风格界面
- **弹窗只能通过点击右上角 X 按钮关闭**，禁止通过点击遮罩层关闭

## 开发约束

- 开发完成后,编写`README.md`

## 补丁约束 **必须遵守**

- 所有对外部 vendored 源码(`Vendor/qemu-src/`、`Vendor/edk2-src/` 等)的修改,
  **必须**导出为 `patches/` 下的 `.patch` 文件,不能只留在 vendored tree 里。
- 原因: `scripts/build-qemu.sh` 在每次构建开头会 `git fetch + git reset --hard FETCH_HEAD`,
  vendored tree 里的脏改动会被**无声清除**,只有 `patches/*.patch` 会被 `git am` 重新应用。
- 制作流程:
  1. 在 `Vendor/qemu-src/` 里 `git commit` 改动
  2. `git format-patch -1 -o ../../patches/` 导出
  3. 确认文件名有序号前缀(`0003-...`),保证 apply 顺序稳定
  4. 重跑 `make build` 验证 patch 能干净 apply 且编译通过

## 调试/诊断工作方式约束 **必须遵守**

- **禁止使用 osascript / AppleScript UI scripting 模拟 GUI 点击**(如点主 App 按钮、
  选 VM、切 tab 等)。这种做法脆弱、依赖屏幕坐标和辅助功能权限,不可复现。
- 需要**启动/停止 VM** 时: 走 `hellvm` 命令行或 `hvmdbg`,不要靠 HellVM GUI。
- 需要**在 guest 里做任何操作**(看桌面、点按钮、键入命令、查设备管理器等):
  走 `hvmdbg` 子命令(`screenshot` / `click` / `key` / `type` / `qmp` 等)。
- 若 `hvmdbg` 没有所需子命令或能力,**立即扩展 `hvmdbg` 补齐**,不要退回用
  osascript 或手动 GUI。补完后必须 `make build` 验证。
- `hvmdbg` 扩展原则: **零新协议实现**,复用 `HVMDisplay` / `HVMBackendQEMU` 已暴露
  的公开类型(`DisplayChannel` / `InputForwarder` / `QMPClient` / `VDAgentChannel`)。

## 诊断工具

### EDK2 / bootmgr / kernel 串口日志(排查启动失败用)

VMConfig 里 `boot.serialDebug: Bool` 开关控制是否把 guest 串口重定向到 `<bundle>/logs/edk2.log`。默认 false。

使用流程:

1. 编辑目标 VM 的 `config.json`, 在 `boot` 里加 `"serialDebug": true`
2. 启动 VM, 复现启动失败场景
3. 读 `<bundle>/logs/edk2.log`, 里面有:
   - EDK2 固件 PEI/DXE/BDS 每步 debug 输出
   - Windows bootmgr 加载/错误信息
   - Linux kernel earlycon 输出
   - UEFI Shell 输出
4. 排查完记得改回 `false`, 串口 append 模式长时间跑会一直增长

典型诊断价值: bootmgr 失败时能看到 `ConvertPages: failed to find range X`, `Error: Image at ... start failed: <reason>` 这类关键错误, 直接定位固件/bootloader bug。

### Per-VM 常规日志

- `<bundle>/logs/hellvm.log` —— Swift 侧 Logger 统一日志(10MB 滚动)
- `<bundle>/logs/swtpm.log` —— swtpm 调试日志(启用 TPM 时)
- `<bundle>/logs/serial.log` —— 非图形模式(`-nographic`)的 guest 串口
