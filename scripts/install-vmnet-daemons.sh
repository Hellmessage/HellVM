#!/usr/bin/env bash
# 安装 socket_vmnet 的 launchd daemon, 让 vmnet shared/host/bridged 三种模式
# 的 unix socket 开机自动拉起, HellVM 启动 VM 时不再需要每次 sudo.
#
# 用法:
#   sudo scripts/install-vmnet-daemons.sh            # shared + host (默认)
#   sudo scripts/install-vmnet-daemons.sh en0        # + bridged(en0)
#   sudo scripts/install-vmnet-daemons.sh en0 en1    # + bridged(en0) + bridged(en1)
#   sudo scripts/install-vmnet-daemons.sh --uninstall
#
# 行为:
#   - 生成 plist 到 /Library/LaunchDaemons/io.hell.vmnet.<mode>.plist
#   - launchctl bootstrap system/ 把 daemon 加载到系统域
#   - socket 路径遵循 socket_vmnet 约定:
#       shared          → /var/run/socket_vmnet
#       host            → /var/run/socket_vmnet.host
#       bridged.<iface> → /var/run/socket_vmnet.bridged.<iface>
#
# 必须以 root 运行 (vmnet.framework 要求).

set -euo pipefail

if [ "$(id -u)" != "0" ]; then
    echo "错误: 需要以 root 运行"
    echo "    sudo $0 $*"
    exit 1
fi

# 查 socket_vmnet 二进制位置. brew 装法有 Apple Silicon 和 Intel 两种前缀.
find_socket_vmnet() {
    for p in /opt/homebrew/opt/socket_vmnet/bin/socket_vmnet \
             /usr/local/opt/socket_vmnet/bin/socket_vmnet \
             /opt/homebrew/bin/socket_vmnet \
             /usr/local/bin/socket_vmnet; do
        if [ -x "$p" ]; then echo "$p"; return 0; fi
    done
    return 1
}

PLIST_DIR="/Library/LaunchDaemons"
LABEL_PREFIX="io.hell.vmnet"
SOCKET_BASE="/var/run/socket_vmnet"

# ---------- 卸载 ----------
uninstall_all() {
    shopt -s nullglob
    local removed=0
    for plist in "$PLIST_DIR"/${LABEL_PREFIX}.*.plist; do
        local label
        label=$(basename "$plist" .plist)
        echo "==> 卸载 $label"
        launchctl bootout "system/$label" 2>/dev/null || true
        rm -f "$plist"
        removed=$((removed + 1))
    done
    # 残留 socket 文件清掉, 避免下次用脏的
    rm -f "$SOCKET_BASE" "$SOCKET_BASE".host "$SOCKET_BASE".bridged.*
    echo "==> 共卸载 $removed 个 daemon"
}

if [ "${1:-}" = "--uninstall" ]; then
    uninstall_all
    exit 0
fi

# ---------- 安装 ----------
SOCKET_VMNET="$(find_socket_vmnet)" || {
    cat <<'EOF'
错误: 未找到 socket_vmnet 二进制
    请先装: brew install socket_vmnet
    然后重跑本脚本.
EOF
    exit 1
}
echo "==> socket_vmnet 路径: $SOCKET_VMNET"

# 生成单个 daemon plist + load
# 参数: <label_suffix> <socket_path> <extra args...>
install_one() {
    local suffix="$1"; shift
    local sock="$1"; shift
    local label="${LABEL_PREFIX}.${suffix}"
    local plist="$PLIST_DIR/${label}.plist"

    # ProgramArguments 里每一项一个 <string>
    local args_xml=""
    args_xml+="    <string>$SOCKET_VMNET</string>"$'\n'
    for a in "$@"; do
        args_xml+="    <string>$a</string>"$'\n'
    done
    args_xml+="    <string>$sock</string>"

    # 如果旧 daemon 存在, 先 bootout 再 bootstrap, 保证新参数生效
    launchctl bootout "system/$label" 2>/dev/null || true

    cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$label</string>
  <key>ProgramArguments</key>
  <array>
$args_xml
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>UserName</key>
  <string>root</string>
  <key>StandardOutPath</key>
  <string>/var/log/socket_vmnet.$suffix.log</string>
  <key>StandardErrorPath</key>
  <string>/var/log/socket_vmnet.$suffix.log</string>
</dict>
</plist>
EOF
    chmod 644 "$plist"
    chown root:wheel "$plist"

    # 旧残留 socket 先清掉, 避免 socket_vmnet 拒绝 bind
    rm -f "$sock"

    launchctl bootstrap system "$plist"
    # enable 一次, 下次系统重启也会自动起
    launchctl enable "system/$label" 2>/dev/null || true
    echo "    ✓ $label  →  $sock"
}

echo "==> 安装 shared (NAT + DHCP)"
install_one "shared" "$SOCKET_BASE" \
    "--vmnet-mode=shared" \
    "--vmnet-gateway=192.168.105.1" \
    "--vmnet-dhcp-end=192.168.105.254"

echo "==> 安装 host-only"
install_one "host" "${SOCKET_BASE}.host" \
    "--vmnet-mode=host" \
    "--vmnet-gateway=192.168.106.1" \
    "--vmnet-dhcp-end=192.168.106.254"

# 桥接: 每个传入的接口起一个 daemon
for iface in "$@"; do
    # 过滤参数, 不接受奇怪的字符
    if ! [[ "$iface" =~ ^[a-zA-Z0-9]+$ ]]; then
        echo "    ⚠ 跳过非法接口名 '$iface'"
        continue
    fi
    echo "==> 安装 bridged (iface=$iface)"
    install_one "bridged.$iface" "${SOCKET_BASE}.bridged.$iface" \
        "--vmnet-mode=bridged" \
        "--vmnet-interface=$iface"
done

echo ""
echo "==> 完成. 当前 socket:"
ls -la ${SOCKET_BASE}* 2>/dev/null || echo "    (socket 未立即出现, daemon 启动有 1-2 秒延迟)"
echo ""
echo "卸载: sudo $0 --uninstall"
