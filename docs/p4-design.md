# P4 图形显示 · 设计文档

> 路线:**方案 C** —— patch QEMU 源码,新增 IOSurface display backend,Swift 侧用 Metal 零拷贝渲染。

## 关键决策(已拍板)

| 项 | 选定 | 理由 |
|---|---|---|
| 1. 补丁管理 | `patches/*.patch` + `git am` | 文件可读可 review,QEMU 升版时 rebase 友好,不需要独立 fork |
| 2. 编译开关 | macOS 平台无条件编入 | 这是 macOS-only 项目,不需要 meson option 开关 |
| 3. Swift 模块 | 新 target `HVMDisplay` | 解耦 App 与渲染,便于单测 IOSurface/Metal 逻辑 |
| 4. 输入通道 | QMP `input-send-event` | 零额外 patch,协议稳定,延迟可接受;后续有瓶颈再换 B |

---

## 1. 架构总览

```
┌─────────────────────────────────────────────────────────────┐
│                     HellVM.app (Swift)                      │
│  ┌──────────────────┐    ┌────────────────────────────┐     │
│  │ VMDetailPane     │    │ HVMDisplay target          │     │
│  │ ├ Settings tab   │    │ ┌────────────────────────┐ │     │
│  │ └ Console tab ───┼──► │ │ FramebufferView        │ │     │
│  │                  │    │ │  (MTKView + CAMetal)   │ │     │
│  └──────────────────┘    │ │  ← MTLTexture          │ │     │
│                          │ │    from IOSurface      │ │     │
│  ┌──────────────────┐    │ └────────────────────────┘ │     │
│  │ QMPClient        │    │ ┌────────────────────────┐ │     │
│  │ input-send-event │◄───┤ │ DisplayChannel         │ │     │
│  └────────┬─────────┘    │ │  (AF_UNIX client)      │ │     │
│           │              │ └────────────┬───────────┘ │     │
│           │              └──────────────┼─────────────┘     │
└───────────┼─────────────────────────────┼───────────────────┘
            │ QMP socket                  │ iosurface socket
            │ (已有)                      │ (新增)
            ▼                             ▼
┌─────────────────────────────────────────────────────────────┐
│                    qemu-system-aarch64                      │
│   ┌──────────┐    ┌─────────────────────────────────────┐   │
│   │ QMP      │    │ ui/iosurface.m  ← patch 新增        │   │
│   │ monitor  │    │ ┌─────────────────────────────────┐ │   │
│   └──────────┘    │ │ DisplayChangeListenerOps        │ │   │
│                   │ │  dpy_gfx_switch / _update /     │ │   │
│                   │ │  _refresh / _cursor_define      │ │   │
│                   │ │                                 │ │   │
│                   │ │ AF_UNIX listener                │ │   │
│                   │ │  → 握手: 发送 IOSurface mach    │ │   │
│                   │ │    port + 尺寸/格式             │ │   │
│                   │ └─────────────────────────────────┘ │   │
│                   │   IOSurface (零拷贝 BGRA8)          │   │
│                   └─────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

**数据流:**
- Guest 写 framebuffer → QEMU 设备模型 → pixman DisplaySurface → `dpy_gfx_update(x,y,w,h)` → iosurface backend 把 dirty region memcpy 到 IOSurface → Swift MTKView 下一帧 blit。
- 用户键鼠 → `NSView` 事件 → QMP `input-send-event` → QEMU input 子系统 → virtio-kbd / virtio-tablet。

---

## 2. QEMU 侧设计

### 2.1 文件布局(patch 内容)

```
qemu-src/
├── ui/
│   ├── iosurface.m              ← 新增,Objective-C++
│   └── meson.build              ← 改,注册源码
├── qapi/
│   └── ui.json                  ← 改,DisplayType enum 加 'iosurface'
└── meson.build                  ← 改,darwin 时定义 CONFIG_IOSURFACE
```

补丁文件:`patches/0001-ui-add-iosurface-display-backend.patch`。

### 2.2 DCL 接口实现

实现 `DisplayChangeListenerOps`(`include/ui/console.h:205`),只接图形模式回调,不管 text/GL:

| 回调 | 时机 | 实现要点 |
|---|---|---|
| `dpy_gfx_switch(dcl, new_surface)` | guest 变分辨率/像素格式 | 销毁旧 IOSurface → `IOSurfaceCreate` 新的 → 通过 socket 把新 mach port 发给所有客户端 |
| `dpy_gfx_update(dcl, x, y, w, h)` | dirty region 更新 | `IOSurfaceLock` → 按 stride 复制 → `IOSurfaceUnlock`;可合并多个 dirty rect(定时 flush) |
| `dpy_gfx_check_format(dcl, fmt)` | 格式协商 | 仅返回 true for `PIXMAN_x8r8g8b8` / `PIXMAN_a8r8g8b8`(BGRA on LE);其他让 pixman 转换 |
| `dpy_refresh(dcl)` | 主循环定时器(~60Hz) | 调 `graphic_hw_update(dcl->con)` 推动 guest 刷新 |
| `dpy_cursor_define(dcl, cursor)` | 光标图像变化 | 第一版不合成,转发图像 + hotspot 给 Swift,Swift 用 `NSCursor` 或 Metal overlay |
| `dpy_mouse_set(dcl, x, y, on)` | 绝对坐标更新 | 转发给 Swift 做光标合成 |

源访问用 `surface_data/stride/width/height/format`(`include/ui/surface.h:57-77`)。

### 2.3 命令行语法

```
-display iosurface,socket=/path/to/vm.iosurface.sock
```

- `socket=` 必填。不填报错退出。
- 不支持 `gl=on`(第一版只做 2D pixman 路径,virtio-gpu 加速留 P4.5)。

在 `qapi/ui.json:1518` 的 `DisplayType` enum 加:
```
{ 'name': 'iosurface', 'if': 'CONFIG_IOSURFACE' }
```
并在 `qapi/ui.json` `DisplayOptions` union 的 data 里加对应子类型(可先空对象,只有 socket 字段通过 `-display` 解析时自己处理)。

### 2.4 注册方式

模仿 `ui/cocoa.m` 结尾的注册模式:

```c
static QemuDisplay qemu_display_iosurface = {
    .type       = DISPLAY_TYPE_IOSURFACE,
    .init       = iosurface_display_init,
};

static void register_iosurface(void) {
    qemu_display_register(&qemu_display_iosurface);
}

type_init(register_iosurface);
```

### 2.5 握手协议(最终:POSIX 共享内存, 非 IOSurface)

**关键变更(Sprint 2 实施后):** 原设计走 IOSurface + `IOSurfaceCreateMachPort`,但 macOS 禁止跨进程 `IOSurfaceLookup(id)`,而 mach port 只能靠 XPC / bootstrap / launchd 传递,不能经 AF_UNIX `SCM_RIGHTS`(fileport 只接受 `IOT_FILEPORT`,IOSurface 的 mach port 是 `IOT_PORT`)。折中: framebuffer 改为 POSIX 共享内存(`shm_open` + `ftruncate` + `mmap`),通过 `SCM_RIGHTS` 把 fd 传给客户端。

在 Apple Silicon unified memory 上,Swift 侧用 `MTLDevice.makeBuffer(bytesNoCopy:)` 包装 mmap 区域 → blit 到 MTLTexture,**仍是零拷贝**,性能对等原 IOSurface 方案。后端名沿用 `iosurface` 作为项目命名。

**消息格式**(小端二进制):
```
struct Msg {
    uint32_t  type;
    uint32_t  payload_len;
    uint8_t   payload[];
};
```

**消息类型:**

| type | 方向 | payload | 附带 fd (SCM_RIGHTS) | 说明 |
|---|---|---|---|---|
| `0x01 HELLO` | C→S | `protocol_version:u32` | — | 客户端连入首包,服务端收到后发 SURFACE |
| `0x02 SURFACE` | S→C | `width,height,stride,format:u32` | **shm fd** | 每次 gfx_switch 都发;fd 是 guest framebuffer 的共享内存,mmap 后即可读像素 |
| `0x03 UPDATE_HINT` | S→C | `x,y,w,h:u32, seq:u64` | — | 可选;可让 Swift 跳过轮询直接刷 dirty rect |
| `0x04 CURSOR` | S→C | `hot_x,hot_y:i32, w,h:u32, bgra[w*h*4]` | — | 光标定义 |
| `0x05 MOUSE_SET` | S→C | `x,y:i32, visible:u8` | — | 绝对坐标 |

**共享内存分配方式:**
- QEMU 在 `dpy_gfx_switch` 里 `shm_open("/hellvm.<pid>.<seq>", O_RDWR|O_CREAT|O_EXCL)` + `shm_unlink`(仅取匿名 fd,不在全局 namespace 留痕)+ `ftruncate(w*h*4)` + `mmap(MAP_SHARED)`
- pixman DisplaySurface 的 dirty region 在 `dpy_gfx_update` 里按 stride memcpy 到 mmap
- 客户端 recvmsg 拿 fd,`mmap(PROT_READ, MAP_SHARED)` 同一块内存,Metal render pass 读即可
- gfx_switch 时旧 shm fd 被 QEMU `close` 后释放;客户端仍持有自己的 fd 映射,直到收到新 SURFACE 才 munmap 旧的

**协议版本字段** 预留 `HELLO.protocol_version`,第一版固定 `1`,不匹配直接关连接。

**多客户端:** 只接受单个客户端。第二个连进来时关掉第一个。够用,也避免并发。

### 2.6 线程模型

- QEMU 主循环(BQL 下)回调 DCL → 只做 IOSurface 写入(`IOSurfaceLock/Unlock`)
- socket I/O 放 `qemu_chr_*` 或独立 pthread(不能阻塞 BQL)
- Dirty region 合并:`dpy_gfx_update` 把 rect 塞进 ring buffer,`dpy_refresh` flush UPDATE_HINT

---

## 3. Swift 侧设计

### 3.1 新 target `HVMDisplay`

`Package.swift` 加:

```swift
.target(
    name: "HVMDisplay",
    dependencies: ["HVMCore", "HVMBundle"]
),
// HellVM target 依赖它
```

目录 `Sources/HVMDisplay/`,初始文件:

| 文件 | 职责 |
|---|---|
| `DisplayChannel.swift` | AF_UNIX 客户端,实现握手协议,暴露 `AsyncStream<DisplayEvent>` |
| `IOSurfaceBridge.swift` | `SCM_RIGHTS` 接 mach port,`IOSurfaceLookupFromMachPort` |
| `FramebufferRenderer.swift` | Metal 渲染:`MTLDevice.makeTexture(descriptor:iosurface:plane:)` + fullscreen quad blit |
| `FramebufferView.swift` | `NSViewRepresentable` 包 `MTKView`,绑定 DisplayChannel |
| `InputForwarder.swift` | 捕获 `NSView` 键鼠 → 翻译成 QMP `input-send-event` JSON |

### 3.2 Metal 渲染要点

- `MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, ...)` + `usage = .shaderRead`
- `device.makeTexture(descriptor:, iosurface:, plane: 0)` → 零拷贝拿到 guest framebuffer
- fragment shader 是最简 passthrough,未来扩 CRT/scanline/缩放滤镜
- HiDPI:`MTKView.drawableSize` = point size × backingScaleFactor,纹理按整数倍缩放或 Lanczos

### 3.3 生命周期

```
用户打开 VM 详情页的 Console 标签
  ↓
FramebufferView.makeNSView
  ↓
DisplayChannel.connect(socketPath: bundle.iosurfaceSocketURL)
  ↓ 握手
  ← HELLO → SURFACE(mach_port, w, h, stride)
  ↓
IOSurfaceBridge 建 IOSurfaceRef + MTLTexture
  ↓
MTKView 60Hz 刷新,每帧 blit texture → drawable
  ↓
收到 SURFACE 新消息 → 重建 texture,继续刷
  ↓
用户切走标签 / 关窗 → DisplayChannel.close()
```

**状态容错:**
- socket 连不上(VM 没开 / 刚启动竞态):指数退避重试 5 次,全失败提示"显示连接失败"
- VM 停止:channel EOF → 清空 texture,显示"VM 已停止"占位
- QEMU 崩溃:Channel EOF + VM 状态机会同步变 `.stopped`

---

## 4. 输入注入(通道 A)

### 4.1 QMP `input-send-event` 协议

```jsonc
{
  "execute": "input-send-event",
  "arguments": {
    "events": [
      { "type": "key", "data": { "down": true,
                                 "key": { "type": "qcode", "data": "a" } } },
      { "type": "btn", "data": { "down": true, "button": "left" } },
      { "type": "abs", "data": { "axis": "x", "value": 16384 } },  // 0..32767
      { "type": "abs", "data": { "axis": "y", "value":  8192 } },
      { "type": "rel", "data": { "axis": "x", "value": 5 } }
    ]
  }
}
```

**批量发送:** 一次 `input-send-event` 带多个事件(如鼠标移动同时按键),减少 QMP round-trip。

### 4.2 键盘 scancode 翻译

macOS `NSEvent.keyCode` → QEMU QKeyCode:
- 查表实现,参考 `ui/cocoa.m` 已有的 `cocoa_keycode_to_qemu()` 映射
- 复用或重写一份放 `InputForwarder.swift`

### 4.3 鼠标路径

- 默认用 **virtio-tablet**(绝对坐标,不需要 pointer lock),启动参数加 `-device virtio-tablet-pci`
- 坐标归一化到 `[0, 32767]`(QEMU 协议)
- 滚轮映射 `NSEvent.scrollingDeltaY` → `{type:"btn", button:"wheel-up/down"}`

### 4.4 快捷键拦截

在 `InputForwarder` 里定义白名单过滤:
- `cmd+Q` — 默认不转发给 guest,触发 App 的"确认关闭 VM"流程
- `cmd+ctrl+F` — 本地切全屏(不转发)
- `cmd+T`(预留) — "释放键盘"(恢复 macOS 快捷键,类似 UTM)

---

## 5. VM 详情页改版

`VMDetailPane` 加标签切换(分段控件):

```
┌─ VM: Ubuntu Arm64 ─────────────────────────┐
│  [启动] [停止] [暂停]                      │
│  ┌────────────────────────────────────┐    │
│  │  [Console]  [Settings]  [Logs]     │    │
│  └────────────────────────────────────┘    │
│                                            │
│  ┌────────────────────────────────────┐    │
│  │                                    │    │
│  │     FramebufferView (Metal)        │    │
│  │                                    │    │
│  └────────────────────────────────────┘    │
└────────────────────────────────────────────┘
```

- 默认打开 Console 标签
- VM 未启动时 Console 显示"VM 未运行,点击启动"占位
- Settings 标签是现有的 CPU/内存/磁盘信息
- Logs 维持现状(日志查看 modal 或嵌入标签)

---

## 6. Sprint 拆分与验收

| Sprint | 工期 | 产出 | 验收命令 |
|---|---|---|---|
| S1 · 补丁基建 | 0.5-1 天 | `patches/0001-*.patch` 空骨架、`build-qemu.sh` apply 流程 | `make build` 通过;`./Vendor/qemu/bin/qemu-system-aarch64 -display help` 能看到 `iosurface` |
| S2 · QEMU iosurface backend | 3-5 天 | `ui/iosurface.m` 完整实现 + socket 协议 | ✅ 用 C 测试客户端连上,截一帧 UEFI 画面存 PPM(1280x800, 2.5% 非零像素) |
| S3 · Swift Metal 渲染 | 3-5 天 | `HVMDisplay` target 全套 + Console 标签 | App 启动 VM 能看到 UEFI / Linux 启动画面 |
| S4 · 键鼠注入 | 2-3 天 | `InputForwarder` + QMP 批量发送 + virtio-tablet | 能用鼠标点 GRUB,能用键盘输入登录 |
| S5 · 收尾 | 2-3 天 | 光标合成、guest resize、全屏、`-nographic` fallback | 调分辨率画面自适应;全屏快捷键生效 |

每个 sprint 结束:`make build` 必须通过,GUI 手动冒烟。

---

## 7. 风险与未决

### 高风险
- **QEMU 主循环 BQL 和 socket 读写的线程交互**:参考 `ui/dbus.c` 的做法(用 GSource / qemu_chr_fe_set_handlers)。最坏情况单开 pthread + `qemu_mutex_lock_iothread()` 回到主循环。
- **Pixman 格式不是 BGRA 时**:virtio-gpu 默认会是,但 stdvga 可能 RGB565。`dpy_gfx_check_format` 只接 8888,让 pixman 自己转。

### 已消解
- ~~**IOSurface ownership 跨进程**~~:改走 POSIX shm 路径,fd 生命周期用 mmap/munmap 管理,不再有 mach port ref count 问题(详见 §2.5)。

### 中风险
- **多 VM 并发**:每个 VM 一个 socket + 独立 shm fd,不冲突。MTLDevice 共享全局 default device 就行。
- **Swift MTLBuffer(bytesNoCopy:) 的 deallocator**:mmap 的内存在 VM 停止后 munmap,Metal 需要收到 EOF 先停用 buffer,避免 use-after-free。Sprint 3 处理。

### 未决
- P5 快照能否保存 framebuffer 状态:DisplaySurface 是 pixman,QEMU migrate 不带它,重启后 guest 会自己重画。跳过。
- virtio-gpu + GL 加速(dmabuf 路径):第一版只做 2D,留 P4.5。
- 剪贴板:SPICE vdagent 太重,自写 virtio-port 放 P5 之后。

---

## 8. 第一步

Sprint 1 展开:

1. 建 `patches/` 目录与 `.gitkeep`
2. 写 `patches/0001-ui-add-iosurface-display-backend.patch`(手写 diff):
   - `ui/iosurface.m` 骨架:空的 DCL + `iosurface_display_init` 打印 "hello from iosurface"
   - `ui/meson.build` darwin 分支加 `iosurface.m`
   - `qapi/ui.json` 的 `DisplayType` 加 `iosurface`
   - 顶层 `meson.build` 在 host_os=='darwin' 时 `config_host_data.set('CONFIG_IOSURFACE', 1)`
3. 改 `scripts/build-qemu.sh`:
   - 取源码后 `cd "$SRC" && git am "$ROOT/patches/"*.patch`
   - apply 失败立即 exit 1(不要静默跳过)
   - 重建场景:源码切回 `FETCH_HEAD` 时先 `git reset --hard` 再重新 apply
4. `make build` 验证

确认无误后动手。
