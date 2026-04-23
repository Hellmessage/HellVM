#!/usr/bin/env bash
# 检查 + 自动安装 Homebrew 依赖
#   BUILD   —— QEMU 编译所需
#   RUNTIME —— VM 运行期可选外挂 helper(socket_vmnet 提供 vmnet shared/host/bridged 网络)
# 两类都缺就装。socket_vmnet 的 launchd daemon 需要 sudo 才能拉起,这里不代跑,
# 只打印指引(避免让 make build 意外要求 root 权限)。
set -euo pipefail

BUILD=(ninja pkg-config meson glib pixman dtc libslirp)
RUNTIME=(socket_vmnet)

if ! command -v brew >/dev/null 2>&1; then
    echo "错误: 未检测到 Homebrew。请先访问 https://brew.sh 安装"
    exit 1
fi

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

# socket_vmnet daemon 状态检查:二进制装了不等于 daemon 在跑
# 默认 shared 模式 socket 路径是 /var/run/socket_vmnet
if printf '%s\n' "${RUNTIME[@]}" | grep -qx socket_vmnet; then
    if [ ! -S /var/run/socket_vmnet ]; then
        cat <<'EOF'
==> 提示: socket_vmnet 已安装,但 shared 模式 daemon 未启动
    若需要 vmnet 桥接/host-only 网络, 请手动执行一次(需 sudo):
        sudo brew services start socket_vmnet
    仅用 user (NAT) 模式时可忽略本提示。
EOF
    fi
fi
