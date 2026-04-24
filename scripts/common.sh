#!/usr/bin/env bash
# HellVM 构建脚本共用函数
#
# 调用方式: 在脚本顶部 set -euo pipefail 之后
#   source "$(dirname "$0")/common.sh"
#
# 提供:
#   resolve_sign_identity   -> 解析 codesign 身份 (env SIGN_IDENTITY > "Hell Dev" > ad-hoc "-")
#   log_info / log_warn / log_error   -> 带颜色的日志输出
#
# 不提供:
#   ROOT 的计算 —— 调用者用 $0 相对路径算,源脚本 $0 比 BASH_SOURCE 更可靠

# 防止被误当可执行脚本跑
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    echo "common.sh 只能被 source, 不能直接执行" >&2
    exit 1
fi

# ---------- 签名身份 ----------
# 优先级:
#   1. 环境变量 SIGN_IDENTITY (用户显式指定, 最高)
#   2. Developer ID Application —— Apple 根签发, amfid 直接认证书链,
#      不需要往 System keychain 注自签 root, 也方便走 notarization。
#      身份串形如: Developer ID Application: NAME (TEAMID)
#   3. 本地自签 "Hell Dev" —— 零环境构建的 fallback, 需配合
#      scripts/trust-signing-cert.sh 注入 System trust
#   4. ad-hoc "-" —— 最后兜底, amfid 基本不会放行带 restricted entitlement
#      的二进制, 仅供开发时 dry-run 用
resolve_sign_identity() {
    if [ -n "${SIGN_IDENTITY:-}" ]; then
        echo "$SIGN_IDENTITY"
        return
    fi
    # Developer ID Application: 从 keychain 里提取第一条匹配
    # `security find-identity -v -p codesigning` 输出格式:
    #   1) <SHA1> "Developer ID Application: Name (TEAMID)"
    local devid
    devid=$(security find-identity -v -p codesigning 2>/dev/null \
            | sed -nE 's/^[[:space:]]*[0-9]+\)[[:space:]]+[A-F0-9]+[[:space:]]+"(Developer ID Application:[^"]+)"$/\1/p' \
            | head -1)
    if [ -n "$devid" ]; then
        echo "$devid"
        return
    fi
    if security find-identity -v -p codesigning 2>/dev/null | grep -q '"Hell Dev"'; then
        echo "Hell Dev"
        return
    fi
    echo "-"
}

# 判断一个 codesign 身份是否是本地自签 (需要 System keychain trust 注入)
# 目前只 "Hell Dev" 一种自签身份; Developer ID / ad-hoc 都不需要。
is_self_signed_identity() {
    case "$1" in
        "Hell Dev") return 0 ;;
        *) return 1 ;;
    esac
}

# ---------- 日志 ----------
# 仅在 stdout 是 TTY 时用 ANSI 颜色,避免污染 CI/日志文件
if [ -t 1 ]; then
    HVM_C_RESET=$'\033[0m'
    HVM_C_BLUE=$'\033[0;34m'
    HVM_C_YELLOW=$'\033[0;33m'
    HVM_C_RED=$'\033[0;31m'
else
    HVM_C_RESET=''; HVM_C_BLUE=''; HVM_C_YELLOW=''; HVM_C_RED=''
fi

log_info()  { printf '%s==>%s %s\n' "$HVM_C_BLUE"   "$HVM_C_RESET" "$*"; }
log_warn()  { printf '%s==>%s %s\n' "$HVM_C_YELLOW" "$HVM_C_RESET" "$*" >&2; }
log_error() { printf '%s==>%s %s\n' "$HVM_C_RED"    "$HVM_C_RESET" "$*" >&2; }
