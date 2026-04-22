#!/usr/bin/env bash
# 从源码编译 QEMU 到 Vendor/qemu/
#
# 环境变量:
#   QEMU_VERSION   默认 v9.2.0
#   QEMU_GIT_URL   默认 https://github.com/qemu/qemu.git
#   QEMU_TARGETS   默认 aarch64-softmmu
#   QEMU_JOBS      默认 $(sysctl -n hw.ncpu)
#   SKIP_SIGN      非空则跳过签名步骤(用于调试)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/Vendor"
SRC="$VENDOR/qemu-src"
BUILD="$VENDOR/qemu-build"
PREFIX="$VENDOR/qemu"
ENTITLEMENTS="$ROOT/Resources/qemu.entitlements"
PATCHES_DIR="$ROOT/patches"

QEMU_VERSION="${QEMU_VERSION:-v10.2.0}"
QEMU_GIT_URL="${QEMU_GIT_URL:-https://github.com/qemu/qemu.git}"
QEMU_TARGETS="${QEMU_TARGETS:-aarch64-softmmu}"
QEMU_JOBS="${QEMU_JOBS:-$(sysctl -n hw.ncpu)}"

# 幂等:已构建且包含预期架构 target 就跳过(除非 FORCE=1)
EXPECTED_BIN=""
case "$QEMU_TARGETS" in
    *aarch64-softmmu*) EXPECTED_BIN="$PREFIX/bin/qemu-system-aarch64" ;;
    *x86_64-softmmu*)  EXPECTED_BIN="$PREFIX/bin/qemu-system-x86_64" ;;
esac
if [ -z "${FORCE:-}" ] && [ -n "$EXPECTED_BIN" ] && [ -x "$EXPECTED_BIN" ]; then
    echo "==> 跳过:QEMU 已存在 ($EXPECTED_BIN)"
    echo "    若要重建,设置 FORCE=1 或删除 $PREFIX"
    exit 0
fi

# ---------- 依赖检查 ----------
check_brew_dep() {
    local pkg="$1"
    if ! brew list --formula "$pkg" >/dev/null 2>&1; then
        echo "缺少依赖:$pkg"
        return 1
    fi
}

echo "==> 检查编译依赖"
missing=()
for pkg in ninja pkg-config glib pixman dtc libslirp meson; do
    check_brew_dep "$pkg" || missing+=("$pkg")
done

if [ ${#missing[@]} -gt 0 ]; then
    echo ""
    echo "缺少以下 Homebrew 包,请先安装:"
    echo "  brew install ${missing[*]}"
    exit 1
fi

# ---------- 签名身份 ----------
resolve_sign_identity() {
    if [ -n "${SIGN_IDENTITY:-}" ]; then echo "$SIGN_IDENTITY"; return; fi
    if security find-identity -v -p codesigning 2>/dev/null | grep -q '"Hell Dev"'; then
        echo "Hell Dev"; return
    fi
    echo "-"
}
SIGN_ID="$(resolve_sign_identity)"

# ---------- 获取源码 ----------
mkdir -p "$VENDOR"

if [ -d "$SRC/.git" ]; then
    echo "==> 源码已存在,检出 $QEMU_VERSION"
    # 先重置到 tag, 清掉上次 apply 的 patch 和任何本地改动
    # (不 clean untracked: 保留 subprojects/ 里已下载的 wrap 依赖, 省重新下载时间)
    (cd "$SRC" && git fetch --depth 1 origin "$QEMU_VERSION" && git checkout FETCH_HEAD && git reset --hard FETCH_HEAD)
else
    echo "==> 克隆 QEMU $QEMU_VERSION ($QEMU_GIT_URL)"
    git clone --depth 1 --branch "$QEMU_VERSION" "$QEMU_GIT_URL" "$SRC"
fi

# ---------- 应用 HellVM 补丁 ----------
if [ -d "$PATCHES_DIR" ] && ls "$PATCHES_DIR"/*.patch >/dev/null 2>&1; then
    echo "==> 应用 HellVM 补丁 ($PATCHES_DIR)"
    # git am 需要 user.name/email, 这里用仓库级配置避免污染全局
    (cd "$SRC" \
        && git config user.name  "HellVM Build" \
        && git config user.email "build@hellvm.local" \
        && git am --keep-cr "$PATCHES_DIR"/*.patch) \
        || { echo "补丁应用失败, 终止构建"; exit 1; }
fi

# QEMU 的 pc-bios/ 携带预编译 UEFI/BIOS 固件,不需要 EDK2 源码。
# 构建期 meson 会按需下载少量 subprojects(keycodemapdb/slirp),不做 --disable-download

# ---------- 配置 ----------
echo "==> configure (prefix=$PREFIX targets=$QEMU_TARGETS)"
rm -rf "$BUILD"
mkdir -p "$BUILD"
cd "$BUILD"

# 构建参数:
#   - 启用 HVF(Apple Silicon 硬件加速)
#   - 启用 slirp(用户态网络)
#   - 禁用所有显示后端(P4 接入自定义 IOSurface 后端)
#   - 禁用文档生成(省时间)
#   - 禁用 guest-agent / bsd-user / linux-user(不需要)
"$SRC/configure" \
    --prefix="$PREFIX" \
    --target-list="$QEMU_TARGETS" \
    --enable-hvf \
    --enable-slirp \
    --disable-docs \
    --disable-gtk \
    --disable-sdl \
    --disable-cocoa \
    --disable-vnc \
    --disable-guest-agent \
    --disable-bsd-user \
    --disable-linux-user \
    --disable-fuse \
    --disable-opengl

# ---------- 编译 ----------
echo "==> make -j$QEMU_JOBS (可能需要 20-40 分钟)"
make -j"$QEMU_JOBS"

# ---------- 安装 ----------
echo "==> make install -> $PREFIX"
rm -rf "$PREFIX"
make install

# ---------- 签名 ----------
if [ -z "${SKIP_SIGN:-}" ]; then
    echo "==> 签名 QEMU 二进制 (身份: $SIGN_ID)"
    # QEMU 10.2 的 make install 会通过 entitlement.sh 给 qemu-system-* 做一次 ad-hoc 签名,
    # 留下 resource fork / xattr, 再次 codesign 会报 "detritus not allowed", 先清掉
    xattr -cr "$PREFIX"/bin
    for bin in "$PREFIX"/bin/qemu-*; do
        [ -f "$bin" ] || continue
        codesign --force --sign "$SIGN_ID" \
            --entitlements "$ENTITLEMENTS" \
            --options runtime \
            "$bin" 2>&1 | sed 's/^/    /'
    done
fi

echo ""
echo "==> 完成"
echo "    前缀:$PREFIX"
echo "    二进制:$(ls "$PREFIX"/bin/qemu-system-* 2>/dev/null | head -n1)"
echo "    固件:$(ls "$PREFIX"/share/qemu/edk2-*code*.fd 2>/dev/null | head -n1)"
