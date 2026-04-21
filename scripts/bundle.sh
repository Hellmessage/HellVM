#!/usr/bin/env bash
# 将 swift build 的产物包装成 HellVM.app 并签名
#
# 签名身份优先级:
#   1. 环境变量 SIGN_IDENTITY(例如 SIGN_IDENTITY="Apple Development: xxx")
#   2. Keychain 中的 "Hell Dev" 自签证书(推荐:TCC 授权持久化)
#   3. ad-hoc 签名("-")   # 每次 rebuild 会重弹权限
#
# P4 接入 QEMU 时,会在此脚本中对 Vendor/qemu 二进制同样调用 sign_item,
# 顺序为:嵌入二进制 → 主 App(自下而上,Apple 官方推荐)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT/build"
APP_DIR="$BUILD_DIR/HellVM.app"
CONFIG="${CONFIG:-release}"
ENTITLEMENTS="$ROOT/Resources/HellVM.entitlements"

cd "$ROOT"

# ---------- 选择签名身份 ----------
resolve_sign_identity() {
    if [ -n "${SIGN_IDENTITY:-}" ]; then
        echo "$SIGN_IDENTITY"
        return
    fi
    if security find-identity -v -p codesigning 2>/dev/null | grep -q '"Hell Dev"'; then
        echo "Hell Dev"
        return
    fi
    echo "-"
}

SIGN_ID="$(resolve_sign_identity)"

# ---------- 签名单个条目 ----------
sign_item() {
    local item="$1"
    local use_entitlements="${2:-no}"
    if [ "$use_entitlements" = "yes" ]; then
        codesign --force --sign "$SIGN_ID" \
            --entitlements "$ENTITLEMENTS" \
            --options runtime \
            "$item" 2>&1 | sed 's/^/    /'
    else
        codesign --force --sign "$SIGN_ID" \
            --options runtime \
            "$item" 2>&1 | sed 's/^/    /'
    fi
}

# ---------- 构建 ----------
echo "==> swift build ($CONFIG)"
swift build -c "$CONFIG" --product HellVM

BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

echo "==> 构建 .app 目录"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BIN_DIR/HellVM" "$APP_DIR/Contents/MacOS/HellVM"
cp "$ROOT/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"

# SPM 生成的资源 bundle(如果有)
for b in "$BIN_DIR"/*.bundle; do
    [ -e "$b" ] || continue
    cp -R "$b" "$APP_DIR/Contents/Resources/"
done

# ---------- 签名 (自下而上) ----------
if [ "$SIGN_ID" = "-" ]; then
    echo "==> 签名 (ad-hoc 兜底,未发现 Hell Dev 证书)"
else
    echo "==> 签名 (身份: $SIGN_ID)"
fi

# P4 预留:签名嵌入的 QEMU 二进制
# for bin in "$APP_DIR"/Contents/Resources/qemu-*; do
#     [ -e "$bin" ] || continue
#     sign_item "$bin" no
# done

# 主 App(最后签,携带 entitlements)
sign_item "$APP_DIR" yes

# ---------- 验证 ----------
echo "==> 验证签名"
codesign -dv "$APP_DIR" 2>&1 | grep -E "Signature|Authority|Identifier" | sed 's/^/    /' || true

echo "==> 完成: $APP_DIR"
