#!/usr/bin/env bash
# logo.png → AppIcon.icns(生成 macOS 多分辨率图标)
# 用法: make-icon.sh <source.png> <output.icns>
set -euo pipefail

SRC="${1:-Resources/logo.png}"
OUT="${2:-build/AppIcon.icns}"

if [ ! -f "$SRC" ]; then
    echo "错误: 源图标不存在: $SRC"
    exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ICONSET="$TMP/AppIcon.iconset"
mkdir -p "$ICONSET"

# macOS 标准 icns 需要以下尺寸(包含 @2x 高分屏)
sips -z 16 16     "$SRC" --out "$ICONSET/icon_16x16.png"       >/dev/null
sips -z 32 32     "$SRC" --out "$ICONSET/icon_16x16@2x.png"    >/dev/null
sips -z 32 32     "$SRC" --out "$ICONSET/icon_32x32.png"       >/dev/null
sips -z 64 64     "$SRC" --out "$ICONSET/icon_32x32@2x.png"    >/dev/null
sips -z 128 128   "$SRC" --out "$ICONSET/icon_128x128.png"     >/dev/null
sips -z 256 256   "$SRC" --out "$ICONSET/icon_128x128@2x.png"  >/dev/null
sips -z 256 256   "$SRC" --out "$ICONSET/icon_256x256.png"     >/dev/null
sips -z 512 512   "$SRC" --out "$ICONSET/icon_256x256@2x.png"  >/dev/null
sips -z 512 512   "$SRC" --out "$ICONSET/icon_512x512.png"     >/dev/null
sips -z 1024 1024 "$SRC" --out "$ICONSET/icon_512x512@2x.png"  >/dev/null

mkdir -p "$(dirname "$OUT")"
iconutil -c icns "$ICONSET" -o "$OUT"
echo "==> 生成: $OUT"
