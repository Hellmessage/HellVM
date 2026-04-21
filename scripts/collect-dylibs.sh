#!/usr/bin/env bash
# 递归收集一个二进制依赖的 brew dylib 到 <Frameworks> 目录,
# 并重写所有 install_name 为 @rpath/<basename>,
# 给二进制自身加 rpath -> 相对 Frameworks/。
#
# 用法: collect-dylibs.sh <binary> <frameworks-dir> [<rpath-spec>]
#   rpath-spec 默认 '@executable_path/../../../Frameworks'
#              (即二进制位于 <bundle>/Contents/Resources/qemu/bin/)
set -euo pipefail

BIN="$1"
FRAMEWORKS="$2"
RPATH_SPEC="${3:-@executable_path/../../../Frameworks}"

mkdir -p "$FRAMEWORKS"

SEEN_FILE="$(mktemp)"
trap 'rm -f "$SEEN_FILE"' EXIT

already_seen() {
    grep -Fxq "$1" "$SEEN_FILE" 2>/dev/null
}
mark_seen() {
    echo "$1" >> "$SEEN_FILE"
}

# 只打包 brew 路径(/opt/homebrew 或 /usr/local),跳过系统库
is_external() {
    case "$1" in
        /opt/homebrew/*|/usr/local/*) return 0 ;;
        *) return 1 ;;
    esac
}

collect_one() {
    local bin="$1"
    # 跳过首行(二进制自身)
    local deps
    deps=$(otool -L "$bin" 2>/dev/null | tail -n +2 | awk '{print $1}')

    while IFS= read -r dep; do
        [ -z "$dep" ] && continue
        if ! is_external "$dep"; then
            continue
        fi

        local name
        name=$(basename "$dep")

        if ! already_seen "$name"; then
            mark_seen "$name"
            # 复制 dylib(若源文件是 symlink,cp 默认跟随)
            cp "$dep" "$FRAMEWORKS/$name"
            chmod u+w "$FRAMEWORKS/$name"
            # 重置 dylib 自身的 ID
            install_name_tool -id "@rpath/$name" "$FRAMEWORKS/$name" 2>/dev/null || true
            # 递归处理这个 dylib
            collect_one "$FRAMEWORKS/$name"
        fi

        # 在 caller 二进制里把引用改写成 @rpath/<name>
        install_name_tool -change "$dep" "@rpath/$name" "$bin" 2>/dev/null || true
    done <<< "$deps"
}

collect_one "$BIN"

# 给二进制加 rpath(若没有)
if ! otool -l "$BIN" 2>/dev/null | grep -A2 LC_RPATH | grep -qF "$RPATH_SPEC"; then
    install_name_tool -add_rpath "$RPATH_SPEC" "$BIN" 2>/dev/null || true
fi
