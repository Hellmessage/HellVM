#!/usr/bin/env bash
# 从源码编译带 HellVM 补丁的 EDK2 (ArmVirtPkg),
# 产出替换 QEMU 自带 stock firmware 的 edk2-aarch64-code.fd.
#
# 必须打补丁的原因: QEMU patch 0002/0004 的 VIRT_LOWRAM (0x10000000 小块 RAM)
# 会让 ArmVirtPkg 的 QemuVirtMemInfoPeiLib 把最低 RAM 取成它, 触发
#   ASSERT: 0x40000000 == NewBase
# patches/edk2/0001 改用 PcdSystemMemoryBase 选主 RAM + 用 GUID HOB 把额外
# /memory 节点注册为 EFI_RESOURCE_SYSTEM_MEMORY, Win11 bootmgr 才能在
# 0x10000000 调 ConvertPages 成功。
#
# 产出:
#   - Vendor/edk2-src/Build/ArmVirtQemu-AARCH64/RELEASE_GCC5/FV/QEMU_EFI.fd (2MB)
#   - pad 到 64MB → Vendor/qemu/share/qemu/edk2-aarch64-code.fd (QEMU -drive if=pflash 期望)
#
# 环境变量:
#   EDK2_VERSION    默认 edk2-stable202408(和 QEMU 自带版本对齐)
#   EDK2_GIT_URL    默认 https://github.com/tianocore/edk2.git
#   FORCE=1         强制重编(即使 .fd 已存在且版本对)

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/Vendor"
SRC="$VENDOR/edk2-src"
QEMU_PREFIX="$VENDOR/qemu"
FW_OUT="$QEMU_PREFIX/share/qemu/edk2-aarch64-code.fd"
PATCHES_DIR="$ROOT/patches/edk2"

EDK2_VERSION="${EDK2_VERSION:-edk2-stable202408}"
EDK2_GIT_URL="${EDK2_GIT_URL:-https://github.com/tianocore/edk2.git}"
TOOLCHAIN_PREFIX="aarch64-elf-"
TARGET_ARCH="AARCH64"
TARGET="RELEASE"
TOOL_CHAIN="GCC5"

BUILT_FD="$SRC/Build/ArmVirtQemu-AARCH64/${TARGET}_${TOOL_CHAIN}/FV/QEMU_EFI.fd"

# ---------- 0. 跳过检测 ----------
# 判据: 已有 pad 后的 .fd + 源码里最后一个 commit 是我们的 HellVM patch
#       (通过 commit subject 前缀识别)
hellvm_patch_applied() {
    [ -d "$SRC/.git" ] || return 1
    local subj
    subj=$(cd "$SRC" && git log -1 --format=%s 2>/dev/null || true)
    echo "$subj" | grep -q "^ArmVirtPkg:.*HellVM\|^ArmVirtPkg:.*extra RAM" 2>/dev/null
}

if [ -z "${FORCE:-}" ] && [ -f "$FW_OUT" ] && [ -f "$BUILT_FD" ] && hellvm_patch_applied; then
    echo "==> 跳过: 已有打过 HellVM 补丁的 EDK2 ($FW_OUT)"
    echo "    重编: FORCE=1 bash scripts/build-edk2.sh"
    exit 0
fi

# ---------- 1. 依赖检查 ----------
if ! command -v aarch64-elf-gcc >/dev/null 2>&1; then
    cat <<'EOF'
错误: 需要 aarch64-elf-gcc 工具链
    brew install aarch64-elf-gcc aarch64-elf-binutils
EOF
    exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
    echo "错误: 需要 python3"
    exit 1
fi

# ---------- 2. 源码 ----------
mkdir -p "$VENDOR"
if [ -d "$SRC/.git" ]; then
    echo "==> 源码已存在, 重置到 $EDK2_VERSION"
    (cd "$SRC" \
        && git fetch --depth 1 origin "$EDK2_VERSION" \
        && git checkout FETCH_HEAD \
        && git reset --hard FETCH_HEAD \
        && git submodule update --init --recursive --depth 1)
else
    echo "==> 克隆 EDK2 $EDK2_VERSION"
    git clone --depth 1 --branch "$EDK2_VERSION" \
        --recurse-submodules --shallow-submodules \
        "$EDK2_GIT_URL" "$SRC"
fi

# ---------- 3. 打 HellVM 补丁 ----------
if [ -d "$PATCHES_DIR" ] && ls "$PATCHES_DIR"/*.patch >/dev/null 2>&1; then
    echo "==> 应用 HellVM EDK2 补丁"
    (cd "$SRC" \
        && git config user.name  "HellVM Build" \
        && git config user.email "build@hellvm.local" \
        && git am --keep-cr "$PATCHES_DIR"/*.patch) \
        || { echo "补丁应用失败"; exit 1; }
fi

# ---------- 3.5 ccache ----------
# EDK2 通过 $GCC5_AARCH64_PREFIX + gcc/g++ 走 PATH 查找。brew ccache 的 libexec 里
# 只 symlink 了常见编译器,没有 aarch64-elf-gcc。自己造 wrapper 目录,塞到 PATH 前面。
# 没装 ccache 就静默跳过。
if command -v ccache >/dev/null 2>&1; then
    CCACHE_WRAPPERS="$VENDOR/.ccache-wrappers"
    mkdir -p "$CCACHE_WRAPPERS"
    CCACHE_BIN="$(command -v ccache)"
    for tool in aarch64-elf-gcc aarch64-elf-g++ clang clang++ cc c++; do
        ln -sf "$CCACHE_BIN" "$CCACHE_WRAPPERS/$tool"
    done
    export PATH="$CCACHE_WRAPPERS:$PATH"
    echo "==> ccache 已启用 (wrappers: $CCACHE_WRAPPERS)"
else
    echo "==> ccache 未安装, 使用原生交叉工具链 (brew install ccache 可加速重编)"
fi

# ---------- 4. BaseTools ----------
# EDK2 的 Python 构建系统首次需要编译 C 小工具链
export WORKSPACE="$SRC"
export EDK_TOOLS_PATH="$SRC/BaseTools"
export CONF_PATH="$SRC/Conf"
cd "$SRC"

echo "==> 初始化 EDK2 BuildEnv (edksetup.sh)"
# edksetup.sh 要求用 . 而不是 bash, 手动模拟关键步骤
mkdir -p "$CONF_PATH"
# 拷 template (如果尚未拷过)
for f in target tools_def build_rule; do
    if [ ! -f "$CONF_PATH/${f}.txt" ]; then
        cp "$EDK_TOOLS_PATH/Conf/${f}.template" "$CONF_PATH/${f}.txt"
    fi
done
export PATH="$EDK_TOOLS_PATH/Bin/${PY_ARCH:-Posix}:$EDK_TOOLS_PATH/BinWrappers/PosixLike:$PATH"

# 增量跳过: 若 BaseTools 产物已存在, 且 C 源码自产物生成后没动过, 跳过 make.
# GenFv 是 BaseTools 必产物, 作为 sentinel 判断是否已编译过.
BASETOOLS_SENTINEL="$EDK_TOOLS_PATH/Source/C/bin/GenFv"
if [ -x "$BASETOOLS_SENTINEL" ] \
   && ! find "$EDK_TOOLS_PATH/Source" -type f \( -name '*.c' -o -name '*.h' -o -name 'Makefile*' \) \
        -newer "$BASETOOLS_SENTINEL" -print -quit 2>/dev/null | grep -q .; then
    echo "==> BaseTools 已是最新, 跳过重编 (删 $EDK_TOOLS_PATH/Source/C/bin 强制重编)"
else
    echo "==> 编译 BaseTools (首次 ~2 分钟)"
    make -C "$EDK_TOOLS_PATH" -j"$(sysctl -n hw.ncpu)"
fi

# ---------- 5. 配置交叉工具链 ----------
export GCC5_AARCH64_PREFIX="$TOOLCHAIN_PREFIX"

# ---------- 6. 编译 ArmVirtQemu ----------
echo "==> 编译 EDK2 ArmVirtQemu (AARCH64, GCC5 RELEASE, ~5-10 分钟)"
build \
    -a "$TARGET_ARCH" \
    -t "$TOOL_CHAIN" \
    -p ArmVirtPkg/ArmVirtQemu.dsc \
    -b "$TARGET" \
    -n "$(sysctl -n hw.ncpu)"

if [ ! -f "$BUILT_FD" ]; then
    echo "错误: build 成功但产物缺失: $BUILT_FD"
    exit 1
fi

# ---------- 7. Pad 到 64MB + 安装 ----------
# QEMU 的 -drive if=pflash 要求固定 64MB 大小. EDK2 产出的 QEMU_EFI.fd 只有 2MB,
# 尾部用 0xFF (NOR flash 未编程态) 填充, QEMU 加载时会正确识别实际 FV 内容。
echo "==> pad 到 64MB 并安装到 $FW_OUT"
PADDED="$(mktemp)"
dd if=/dev/zero bs=1048576 count=64 2>/dev/null | tr '\000' '\377' > "$PADDED"
dd if="$BUILT_FD" of="$PADDED" bs=1 conv=notrunc 2>/dev/null

mkdir -p "$(dirname "$FW_OUT")"
mv "$PADDED" "$FW_OUT"
chmod 644 "$FW_OUT"

echo ""
echo "==> 完成"
echo "    源: $BUILT_FD  ($(du -h "$BUILT_FD" | awk '{print $1}'))"
echo "    装: $FW_OUT    ($(du -h "$FW_OUT" | awk '{print $1}'))"
