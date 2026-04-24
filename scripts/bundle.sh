#!/usr/bin/env bash
# 一键构建完整 HellVM.app,流水线:
#   1. install-deps.sh  —— 检查 + 补装 Homebrew 依赖
#   2. build-qemu.sh    —— 若 Vendor/qemu 缺失则自编译
#   3. swift build      —— Swift 主 App 二进制
#   4. 组装 .app 目录    —— HellVM 主二进制 + QEMU + 固件
#   5. collect-dylibs   —— 递归拷贝 brew dylib + 重写 rpath
#   6. codesign         —— 自下而上:dylib → QEMU → 主 App
#   7. 验证
set -euo pipefail
source "$(dirname "$0")/common.sh"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT/build"
APP_DIR="$BUILD_DIR/HellVM.app"
CONTENTS="$APP_DIR/Contents"
FRAMEWORKS="$CONTENTS/Frameworks"
RES_QEMU="$CONTENTS/Resources/qemu"
CONFIG="${CONFIG:-release}"
ENTITLEMENTS="$ROOT/Resources/HellVM.entitlements"
QEMU_ENTITLEMENTS="$ROOT/Resources/qemu.entitlements"
VENDOR_QEMU="$ROOT/Vendor/qemu"

cd "$ROOT"

# ---------- 签名身份 ----------
# resolve_sign_identity 来自 scripts/common.sh

# ---------- 1. 依赖 ----------
# 首次构建提示: 若 CLT 或 Homebrew 缺失, 提前告知用户 sudo + 耗时
if ! command -v swift >/dev/null 2>&1 || ! command -v brew >/dev/null 2>&1; then
    cat <<'EOF'
==> 检测到空白环境, 即将自动安装:
    - Xcode Command Line Tools (若缺失, 需 sudo, 下载 10-30 分钟)
    - Homebrew                  (若缺失, 需 sudo)
    - brew formulas             (ninja/glib/meson/pixman/dtc/libslirp/socket_vmnet)
    - QEMU (首次编译 20-40 分钟)
    总耗时首次约 1 小时, 后续增量 < 1 分钟.
EOF
fi
bash scripts/install-deps.sh

# ---------- 2. QEMU ----------
if [ ! -x "$VENDOR_QEMU/bin/qemu-system-aarch64" ]; then
    echo "==> 首次构建 QEMU(耗时约 20-40 分钟)"
    bash scripts/build-qemu.sh
fi

# ---------- 2b. EDK2 firmware (patched for Win11 lowram 兼容) ----------
# QEMU patch 0002/0004 的 VIRT_LOWRAM 需要配套 EDK2 (改 QemuVirtMemInfoPeiLib).
# build-edk2.sh 幂等:.fd 已存在且 patch 已打就跳过, 首次 ~5-10 分钟.
bash scripts/build-edk2.sh

# ---------- 3. Swift ----------
echo "==> swift build ($CONFIG)"
swift build -c "$CONFIG" --product HellVM
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

# ---------- 4. .app 骨架 ----------
echo "==> 组装 .app 目录"
rm -rf "$APP_DIR"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" "$FRAMEWORKS" \
         "$RES_QEMU/bin" "$RES_QEMU/share"
ditto "$BIN_DIR/HellVM" "$CONTENTS/MacOS/HellVM"
cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"

# App 图标
if [ -f "$ROOT/Resources/logo.png" ]; then
    bash "$ROOT/scripts/make-icon.sh" "$ROOT/Resources/logo.png" "$CONTENTS/Resources/AppIcon.icns"
fi
for b in "$BIN_DIR"/*.bundle; do
    [ -e "$b" ] || continue
    cp -R "$b" "$CONTENTS/Resources/"
done

# runtime 脚本(VMnetSupervisor 运行时需要调 install-vmnet-daemons.sh)
mkdir -p "$CONTENTS/Resources/scripts"
cp "$ROOT/scripts/install-vmnet-daemons.sh" "$CONTENTS/Resources/scripts/"
chmod +x "$CONTENTS/Resources/scripts/install-vmnet-daemons.sh"

# ---------- 5. QEMU + 固件嵌入 ----------
echo "==> 嵌入 QEMU 二进制与固件"
cp "$VENDOR_QEMU/bin/"qemu-* "$RES_QEMU/bin/" 2>/dev/null || true
cp -R "$VENDOR_QEMU/share/qemu" "$RES_QEMU/share/"

# 修剪不支持架构的"大"固件(节省 ~170MB)
# 保留:aarch64(主力)、arm-vars(aarch64 也用它)、x86_64 edk2、
#       以及所有设备 ROM(efi-*.rom / pxe-*.rom / vgabios-*.bin,都只有百KB但 virtio 等设备需要)
echo "==> 修剪不需要的固件"
SHARE="$RES_QEMU/share/qemu"
rm -f "$SHARE"/edk2-arm-code.fd \
      "$SHARE"/edk2-riscv-code.fd "$SHARE"/edk2-riscv-vars.fd \
      "$SHARE"/edk2-loongarch64-code.fd "$SHARE"/edk2-loongarch64-vars.fd \
      "$SHARE"/openbios-* "$SHARE"/slof.bin "$SHARE"/skiboot.lid \
      "$SHARE"/s390-* "$SHARE"/hppa-ser-* "$SHARE"/hppa-firmware* \
      "$SHARE"/u-boot.e500 \
      "$SHARE"/qemu_vga.ndrv \
      2>/dev/null || true

# 清除 xattr,避免后续签名报 "detritus not allowed"
xattr -cr "$RES_QEMU"

# ---------- 6. dylib 收集 ----------
echo "==> 收集 brew dylib 到 Contents/Frameworks/"
for b in "$RES_QEMU/bin/"qemu-*; do
    [ -f "$b" ] || continue
    bash scripts/collect-dylibs.sh "$b" "$FRAMEWORKS"
done
DYLIB_COUNT=$(find "$FRAMEWORKS" -maxdepth 1 -name "*.dylib" 2>/dev/null | wc -l | tr -d ' ')
echo "    共收集 $DYLIB_COUNT 个 dylib"

# ---------- 6a. dylib 传递依赖二次重写 ----------
# collect-dylibs.sh 递归有时会漏改 FRAMEWORKS 内 dylib 之间的传递依赖
# (already_seen 命中时只 cp 不重写内部 LC_LOAD_DYLIB)。这里做 closure pass:
# 遍历 FRAMEWORKS, 对每个非 /usr/lib / @rpath 的依赖, 若同名 dylib 已在
# FRAMEWORKS 里, 改成 @rpath/<name>。
echo "==> 二次重写 dylib 传递依赖 (@rpath 闭包)"
rewrite_dylib_paths() {
    local target="$1"
    chmod u+w "$target" 2>/dev/null || true
    # 修 LC_ID_DYLIB
    local id
    id=$(otool -D "$target" 2>/dev/null | tail -n +2 | awk '{$1=$1};1')
    case "$id" in
        /opt/homebrew/*|/usr/local/*)
            install_name_tool -id "@rpath/$(basename "$target")" "$target" 2>/dev/null || true
            ;;
    esac
    # 修 LC_LOAD_DYLIB
    while IFS= read -r dep; do
        case "$dep" in
            /opt/homebrew/*|/usr/local/*)
                local name
                name=$(basename "$dep")
                if [ -f "$FRAMEWORKS/$name" ]; then
                    install_name_tool -change "$dep" "@rpath/$name" "$target" 2>/dev/null || true
                fi
                ;;
        esac
    done < <(otool -L "$target" 2>/dev/null | tail -n +2 | awk '{print $1}')
}
for d in "$FRAMEWORKS"/*.dylib; do
    [ -f "$d" ] || continue
    rewrite_dylib_paths "$d"
done
for b in "$RES_QEMU/bin/"qemu-*; do
    [ -f "$b" ] || continue
    rewrite_dylib_paths "$b"
done

# ---------- 6b. dylib 依赖完整性检查 ----------
# 所有 QEMU 二进制 + Frameworks 里的 dylib, 其依赖路径必须只是:
#   /usr/lib/*, /System/*              — macOS 系统库
#   @rpath/*, @executable_path/*, @loader_path/*  — bundle 内相对路径
# 任何残留的 /opt/homebrew/ 或 /usr/local/ 说明 collect-dylibs.sh 漏拷了传递依赖
echo "==> 校验 dylib 传递依赖"
FAILED=0
check_dylib_deps() {
    local target="$1"
    local bad
    bad=$(otool -L "$target" 2>/dev/null \
          | tail -n +2 \
          | awk '{print $1}' \
          | grep -vE '^(/usr/lib/|/System/|@rpath/|@executable_path/|@loader_path/)' \
          | grep -v "^$target:$" || true)
    if [ -n "$bad" ]; then
        echo "    ❌ $(basename "$target") 引用未打包的库:"
        echo "$bad" | sed 's/^/        /'
        FAILED=1
    fi
}
for b in "$RES_QEMU/bin/"qemu-*; do
    [ -f "$b" ] || continue
    check_dylib_deps "$b"
done
for d in "$FRAMEWORKS"/*.dylib; do
    [ -f "$d" ] || continue
    check_dylib_deps "$d"
done
if [ "$FAILED" = 1 ]; then
    echo "==> dylib 依赖完整性检查失败, 请检查 scripts/collect-dylibs.sh 是否遗漏"
    exit 1
fi
echo "    所有二进制/dylib 只引用系统库或 @rpath, 自包含"

# ---------- 7. 签名(自下而上) ----------
SIGN_ID="$(resolve_sign_identity)"
echo "==> 签名 (身份: $SIGN_ID)"

# 7a. dylib
for d in "$FRAMEWORKS"/*.dylib; do
    [ -f "$d" ] || continue
    codesign --force --sign "$SIGN_ID" --options runtime "$d" 2>&1 | sed 's/^/    /'
done

# 7b. QEMU 二进制(只带 hypervisor entitlement, **故意不启用 hardened runtime**)
#
# macOS 26 (Tahoe) 下 /Applications 里 hardened-runtime 的子二进制会被 amfid
# 严格校验证书链, "Hell Dev" 自签证书无 Team ID 会被判为 "adhoc signed or
# signed by an unknown certificate chain", 父 App posix_spawn 直接 EPERM
# (Operation not permitted)。
#
# 解决: QEMU 不启用 hardened runtime。amfid 就不再做证书链 trust 校验,
# hypervisor entitlement 不需要 hardened runtime 即可生效。
# 细节见 Resources/qemu.entitlements 里的注释。
for b in "$RES_QEMU/bin/"qemu-*; do
    [ -f "$b" ] || continue
    codesign --force --sign "$SIGN_ID" \
        --entitlements "$QEMU_ENTITLEMENTS" \
        "$b" 2>&1 | sed 's/^/    /'
done

# 7c. 主 App(最后)
codesign --force --sign "$SIGN_ID" \
    --entitlements "$ENTITLEMENTS" \
    --options runtime \
    "$APP_DIR" 2>&1 | sed 's/^/    /'

# ---------- 8. 验证 ----------
echo "==> 验证"
codesign --verify --deep --strict "$APP_DIR" 2>&1 | sed 's/^/    /' || echo "    (verify 警告可忽略)"
codesign -dv "$APP_DIR" 2>&1 | grep -E "Authority|Identifier|Signature" | sed 's/^/    /'

# ---------- 9. 注入签名证书到 System keychain (首次会弹 admin 密码) ----------
# 仅自签身份 (目前只 "Hell Dev") 需要这一步; Developer ID 已经是 Apple 根
# 签发, amfid 天然放行, 不用也不应该往 System trust 里塞它。
# 详见 scripts/trust-signing-cert.sh 头注释。
if is_self_signed_identity "$SIGN_ID"; then
    bash "$ROOT/scripts/trust-signing-cert.sh"
else
    echo "==> 使用 Apple 根签发身份 ($SIGN_ID), 跳过 System keychain trust 注入"
fi

APP_SIZE=$(du -sh "$APP_DIR" | awk '{print $1}')
echo "==> 完成: $APP_DIR ($APP_SIZE)"
