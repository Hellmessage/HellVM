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

## 代码约束

- 代码文件使用中文注释

## GUI约束

- 黑色风格界面
- **弹窗只能通过点击右上角 X 按钮关闭**，禁止通过点击遮罩层关闭

## 开发约束

- 开发完成后,编写`README.md`

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
