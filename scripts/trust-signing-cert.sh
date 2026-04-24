#!/usr/bin/env bash
# 把本机 login keychain 里的 "Hell Dev" 自签证书注入 System keychain
# 并 trust 为 code-signing root。
#
# 为什么需要:
#   macOS 26 (Tahoe) 下 amfid 对带 restricted entitlement
#   (com.apple.security.hypervisor) 的二进制会严格校验签名证书链,
#   如果签名者不在 System keychain 信任里, amfid 判为 "adhoc signed or
#   signed by an unknown certificate chain", 父进程 posix_spawn 该二进制
#   直接 EPERM "Operation not permitted"。
#
#   "Hell Dev" 是 bundle 脚本常规使用的本地自签证书, 位于用户 login
#   keychain。System keychain 默认不识别它, 所以 amfid 拒。
#
# 幂等:
#   - 若 System keychain 已收录且 SHA-256 匹配 login 里的, 静默退出
#   - 否则 sudo 调用 security add-trusted-cert (首次弹一次 admin 密码)
#
# 触发位置: scripts/bundle.sh 最后一步 (签名完成后)。

set -euo pipefail
source "$(dirname "$0")/common.sh"

CERT_NAME="Hell Dev"
SYSTEM_KEYCHAIN="/Library/Keychains/System.keychain"

# 1. 找 login keychain 里的证书 SHA-256 (确认签名用的证书存在)
LOGIN_SHA=$(security find-certificate -c "$CERT_NAME" -Z 2>/dev/null \
            | awk '/^SHA-256 hash:/ {print $3; exit}')

if [ -z "$LOGIN_SHA" ]; then
    log_info "login keychain 未找到 '$CERT_NAME' 证书, 跳过系统信任注入"
    log_info "(表示 bundle.sh 走的是 ad-hoc '-' 签名, 不需要信任注入)"
    exit 0
fi

# 2. 检测 System 级 trust settings 是否已信任该证书为 codeSign root
# 注意: 只 System.keychain 里"存在"证书不够, 必须 trust settings 实际生效。
# `security dump-trust-settings -d` 输出里每条 trust 记录都有 "Cert N: <CN>"
# 段, 配合后面 "Policy OID : Code Signing" 来确认是 codeSign trust。
# 匹配 CN + Code Signing policy, 精准判断此证书是否已作为 codeSign root。
if security dump-trust-settings -d 2>/dev/null \
   | awk -v cn="$CERT_NAME" '
       $0 ~ "^Cert .*: " cn "$" { in_block = 1; next }
       in_block && /Policy OID.*Code Signing/ { found = 1; exit }
       $0 ~ "^Cert " && in_block { in_block = 0 }
       END { exit (found ? 0 : 1) }'; then
    log_info "'$CERT_NAME' 已在 System keychain trust settings 里 (Code Signing), 跳过"
    exit 0
fi

# 3. 未信任
# 策略:
#   - 若本脚本已在 root 下 (e.g. install-system 流程)      -> 直接写入
#   - 若已有 sudo credential cache (sudo -n true 成功)     -> 直接 sudo 写入
#   - 否则 (普通 make build, 非交互下避免 block)           -> 只 warn, 提示用户手动
TMP_CERT=$(mktemp -t hell-dev-cert.XXXXXX).pem
trap 'rm -f "$TMP_CERT"' EXIT
security find-certificate -c "$CERT_NAME" -p > "$TMP_CERT"

install_trust() {
    # 首参可空 (root 下直跑, 非 root 下传 "sudo"); 用 "$@" 不经 local 数组,
    # 空的情况下不会触发 set -u 的 unbound variable 报错。
    "$@" security add-trusted-cert \
        -d -r trustRoot -p codeSign \
        -k "$SYSTEM_KEYCHAIN" \
        "$TMP_CERT"
}

if [ "$(id -u)" = "0" ]; then
    log_info "以 root 身份注入 '$CERT_NAME' 到 System keychain trust"
    install_trust
    log_info "已信任 '$CERT_NAME' 为 System code-signing root"
elif sudo -n true 2>/dev/null; then
    log_info "sudo credential cache 有效, 静默注入 '$CERT_NAME' 到 System keychain trust"
    install_trust sudo
    log_info "已信任 '$CERT_NAME' 为 System code-signing root"
elif [ -t 0 ] && [ -t 1 ]; then
    # 有交互 TTY: 让 sudo 正常提示终端密码
    log_info "sudo 注入 '$CERT_NAME' 到 System keychain trust (请输入密码)"
    install_trust sudo
    log_info "已信任 '$CERT_NAME' 为 System code-signing root"
else
    # 无 TTY (Claude Code 的 Bash / CI): 尝试 osascript 弹 GUI admin 密码框
    # 注意: 这是权限提升用途, 不是 "osascript UI scripting 模拟点击"。
    # 若 osascript 失败(例如在无 WindowServer 的子进程里), 不 block, 只 warn。
    log_info "无 TTY, 尝试 osascript 弹 GUI 密码对话"
    CMD="/usr/bin/security add-trusted-cert -d -r trustRoot -p codeSign -k '$SYSTEM_KEYCHAIN' '$TMP_CERT'"
    if osascript -e "do shell script \"$CMD\" with administrator privileges with prompt \"HellVM: 把自签证书 'Hell Dev' 注册为系统级 code-signing 信任根 (一次性操作)\"" \
        >/dev/null 2>&1; then
        log_info "已信任 '$CERT_NAME' 为 System code-signing root"
    else
        log_warn "osascript 提权失败 (可能无 GUI session)。不 block 本次 build。"
        log_warn "'$CERT_NAME' 仍未加入 System keychain 信任, QEMU 会被 amfid 拒绝 spawn。"
        log_warn "请在自己的终端里手动跑一次:"
        log_warn ""
        log_warn "    sudo bash $(cd "$(dirname "$0")" && pwd)/trust-signing-cert.sh"
        log_warn ""
    fi
fi
