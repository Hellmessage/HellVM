#!/usr/bin/env bash
# 从源码编译 QEMU 并放到 Vendor/qemu/
# 编译目标:aarch64-softmmu + x86_64-softmmu
# P4 阶段实现
set -euo pipefail

echo "build-qemu.sh: 暂未实现 (P4)"
echo "将在 P4 阶段完成:"
echo "  1. git clone qemu --depth 1"
echo "  2. 应用 display 补丁(IOSurface 后端)"
echo "  3. configure --target-list=aarch64-softmmu,x86_64-softmmu"
echo "  4. make 并安装到 Vendor/qemu/"
exit 1
