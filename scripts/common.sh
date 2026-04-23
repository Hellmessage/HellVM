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
# 优先级: 环境变量 SIGN_IDENTITY > 本地 "Hell Dev" 证书 > ad-hoc "-"
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
