#!/usr/bin/env bash
# 检查 + 自动安装 Homebrew 构建依赖(QEMU 编译所需)
set -euo pipefail

REQUIRED=(ninja pkg-config meson glib pixman dtc libslirp)

if ! command -v brew >/dev/null 2>&1; then
    echo "错误: 未检测到 Homebrew。请先访问 https://brew.sh 安装"
    exit 1
fi

missing=()
for pkg in "${REQUIRED[@]}"; do
    if ! brew list --formula "$pkg" >/dev/null 2>&1; then
        missing+=("$pkg")
    fi
done

if [ ${#missing[@]} -gt 0 ]; then
    echo "==> 安装缺失依赖: ${missing[*]}"
    brew install "${missing[@]}"
else
    echo "==> 依赖已就绪"
fi
