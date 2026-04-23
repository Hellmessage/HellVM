#!/usr/bin/env bash
# 自举 + 依赖检查
#   0. 平台守卫 —— 仅 macOS
#   1. Command Line Tools —— git/clang/make/swift 运行基础; 缺则 softwareupdate 静默装
#   2. Homebrew —— 缺则 NONINTERACTIVE=1 官方脚本装, 装完 shellenv 注入当前 PATH
#   3. BUILD formulas —— QEMU 编译所需
#   4. RUNTIME formulas —— VM 运行期可选 helper (socket_vmnet)
#
# 目标: 在一台空白 Mac 上 `make build` 能一条到底. 首次会需要 sudo + ~30 分钟下载 CLT.
# socket_vmnet daemon 仍不代跑, 只打印指引 (避免日常 build 也要求 root).
set -euo pipefail

# ---------- 0. 平台守卫 ----------
if [[ "$(uname)" != "Darwin" ]]; then
    echo "错误: 本项目仅支持 macOS"
    exit 1
fi

# ---------- 1. Command Line Tools ----------
# 判据: xcode-select -p 有效路径 + swift 可执行. Xcode.app 或 CLT-only 都能满足.
clt_ready() {
    xcode-select -p >/dev/null 2>&1 || return 1
    command -v swift >/dev/null 2>&1 || return 1
    command -v git   >/dev/null 2>&1 || return 1
    command -v clang >/dev/null 2>&1 || return 1
    return 0
}

install_clt() {
    echo "==> 未检测到 Xcode Command Line Tools, 自动安装 (需 sudo, 下载约 10-30 分钟)"
    # softwareupdate 需要这个 sentinel 才会把 CLT 作为可选更新暴露出来
    local sentinel="/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress"
    sudo touch "$sentinel"

    # CLT 包的 Label 形如 "Command Line Tools for Xcode-16.0", 有多个版本时取最新的
    local label
    label=$(softwareupdate -l 2>/dev/null \
        | grep -E '^\s*\*\s*Label:.*Command Line Tools' \
        | tail -n1 \
        | sed -E 's/^[[:space:]]*\*[[:space:]]*Label:[[:space:]]*//')

    if [ -z "$label" ]; then
        sudo rm -f "$sentinel"
        cat <<'EOF'
错误: softwareupdate 没有找到可安装的 Command Line Tools 包.
      请手动运行: xcode-select --install
      (会弹出图形安装对话框, 装完后重新执行 make build)
EOF
        exit 1
    fi

    echo "    安装包: $label"
    sudo softwareupdate -i "$label" --verbose
    sudo rm -f "$sentinel"

    if ! clt_ready; then
        echo "错误: CLT 安装后仍无 swift/git/clang, 请检查 'xcode-select -p' 指向"
        exit 1
    fi
}

if ! clt_ready; then
    install_clt
fi

# ---------- 1b. Xcode license ----------
# 装了完整 Xcode.app 且首次使用时, xcodebuild / 某些编译链会因未接受 license 报错.
# 纯 CLT 环境通常没有 xcodebuild, 跳过.
# 检测: xcodebuild -version 失败且输出含 "license" 关键词 → 代跑 accept (需 sudo)
if command -v xcodebuild >/dev/null 2>&1; then
    if ! xcodebuild -version >/dev/null 2>&1; then
        if xcodebuild -version 2>&1 | grep -qi "license"; then
            echo "==> Xcode license 未接受, 自动接受 (需 sudo)"
            sudo xcodebuild -license accept
        fi
    fi
fi

# ---------- 2. Homebrew ----------
# Apple Silicon 在 /opt/homebrew, Intel 在 /usr/local
if [[ "$(uname -m)" == "arm64" ]]; then
    BREW_PREFIX="/opt/homebrew"
else
    BREW_PREFIX="/usr/local"
fi

install_brew() {
    echo "==> 未检测到 Homebrew, 自动安装 (需 sudo)"
    # NONINTERACTIVE=1 跳过官方脚本的 RETURN 确认, 仍会在内部调 sudo
    NONINTERACTIVE=1 /bin/bash -c \
        "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
}

if ! command -v brew >/dev/null 2>&1; then
    if [ -x "$BREW_PREFIX/bin/brew" ]; then
        # 装过但当前 shell PATH 没注入 (比如全新终端首次跑), 手动注入
        eval "$("$BREW_PREFIX/bin/brew" shellenv)"
    else
        install_brew
        if [ ! -x "$BREW_PREFIX/bin/brew" ]; then
            echo "错误: Homebrew 安装后在 $BREW_PREFIX/bin/brew 找不到, 请检查安装输出"
            exit 1
        fi
        eval "$("$BREW_PREFIX/bin/brew" shellenv)"
    fi
fi

# ---------- 3/4. formulas ----------
BUILD=(ninja pkg-config meson glib pixman dtc libslirp ccache
       aarch64-elf-gcc aarch64-elf-binutils)
RUNTIME=(socket_vmnet)

missing_build=()
for pkg in "${BUILD[@]}"; do
    if ! brew list --formula "$pkg" >/dev/null 2>&1; then
        missing_build+=("$pkg")
    fi
done

missing_runtime=()
for pkg in "${RUNTIME[@]}"; do
    if ! brew list --formula "$pkg" >/dev/null 2>&1; then
        missing_runtime+=("$pkg")
    fi
done

if [ ${#missing_build[@]} -gt 0 ]; then
    echo "==> 安装构建依赖: ${missing_build[*]}"
    brew install "${missing_build[@]}"
fi

if [ ${#missing_runtime[@]} -gt 0 ]; then
    echo "==> 安装运行期依赖: ${missing_runtime[*]}"
    brew install "${missing_runtime[@]}"
fi

if [ ${#missing_build[@]} -eq 0 ] && [ ${#missing_runtime[@]} -eq 0 ]; then
    echo "==> 依赖已就绪"
fi

# socket_vmnet daemon 状态检查: 二进制装了不等于 daemon 在跑
# 默认 shared 模式 socket 路径是 /var/run/socket_vmnet
if printf '%s\n' "${RUNTIME[@]}" | grep -qx socket_vmnet; then
    if [ ! -S /var/run/socket_vmnet ]; then
        cat <<'EOF'
==> 提示: socket_vmnet 已安装, 但 shared 模式 daemon 未启动
    若需要 vmnet 桥接/host-only 网络, 请手动执行一次 (需 sudo):
        sudo brew services start socket_vmnet
    仅用 user (NAT) 模式时可忽略本提示.
EOF
    fi
fi
