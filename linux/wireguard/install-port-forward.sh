#!/usr/bin/env bash

set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
    echo "Run this script as root." >&2
    exit 1
fi

if [[ $# -lt 4 || $# -gt 4 ]]; then
    echo "Usage: $0 <windows-lan-ip> <listen-port> <interface-name> <target-port>" >&2
    echo "Example: $0 192.168.1.50 3389 rpi 3389" >&2
    exit 1
fi

WINDOWS_IP="$1"
LISTEN_PORT="$2"
INTERFACE_NAME="$3"
TARGET_PORT="$4"
WG_CONFIG_DIR="/etc/wireguard"

if ! command -v systemctl >/dev/null 2>&1; then
    echo "systemctl is required." >&2
    exit 1
fi

FORWARD_SCRIPT="/usr/local/sbin/wg-rdp-forward-${INTERFACE_NAME}.sh"
SERVICE_FILE="/etc/systemd/system/wg-rdp-forward-${INTERFACE_NAME}.service"

cat > "${FORWARD_SCRIPT}" <<EOF
#!/usr/bin/env bash

set -euo pipefail

ACTION="\${1:-start}"
WG_INTERFACE="${INTERFACE_NAME}"
WINDOWS_IP="${WINDOWS_IP}"
LISTEN_PORT="${LISTEN_PORT}"
TARGET_PORT="${TARGET_PORT}"

WG_IP="\$(ip -4 -o addr show dev "\${WG_INTERFACE}" | awk '{print \$4}' | cut -d/ -f1 | head -n 1)"
LAN_INTERFACE="\$(ip route get "\${WINDOWS_IP}" | awk '{for (i = 1; i <= NF; i++) if (\$i == "dev") {print \$(i + 1); exit}}')"

if [[ -z "\${WG_IP}" ]]; then
    echo "Could not determine an IPv4 address for interface \${WG_INTERFACE}" >&2
    exit 1
fi

if [[ -z "\${LAN_INTERFACE}" ]]; then
    echo "Could not determine the LAN interface used to reach \${WINDOWS_IP}" >&2
    exit 1
fi

ensure_rule() {
    local table="\$1"
    shift

    if [[ "\${table}" == "filter" ]]; then
        if ! iptables -C "\$@" 2>/dev/null; then
            iptables -A "\$@"
        fi
    else
        if ! iptables -t "\${table}" -C "\$@" 2>/dev/null; then
            iptables -t "\${table}" -A "\$@"
        fi
    fi
}

delete_rule() {
    local table="\$1"
    shift

    if [[ "\${table}" == "filter" ]]; then
        iptables -D "\$@" 2>/dev/null || true
    else
        iptables -t "\${table}" -D "\$@" 2>/dev/null || true
    fi
}

case "\${ACTION}" in
    start)
        sysctl -w net.ipv4.ip_forward=1 >/dev/null
        ensure_rule nat PREROUTING -i "\${WG_INTERFACE}" -p tcp -d "\${WG_IP}" --dport "\${LISTEN_PORT}" -j DNAT --to-destination "\${WINDOWS_IP}:\${TARGET_PORT}"
        ensure_rule nat POSTROUTING -o "\${LAN_INTERFACE}" -p tcp -d "\${WINDOWS_IP}" --dport "\${TARGET_PORT}" -j MASQUERADE
        ensure_rule filter FORWARD -i "\${WG_INTERFACE}" -p tcp -d "\${WINDOWS_IP}" --dport "\${TARGET_PORT}" -j ACCEPT
        ensure_rule filter FORWARD -o "\${WG_INTERFACE}" -p tcp -s "\${WINDOWS_IP}" --sport "\${TARGET_PORT}" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
        ;;
    stop)
        delete_rule nat PREROUTING -i "\${WG_INTERFACE}" -p tcp -d "\${WG_IP}" --dport "\${LISTEN_PORT}" -j DNAT --to-destination "\${WINDOWS_IP}:\${TARGET_PORT}"
        delete_rule nat POSTROUTING -o "\${LAN_INTERFACE}" -p tcp -d "\${WINDOWS_IP}" --dport "\${TARGET_PORT}" -j MASQUERADE
        delete_rule filter FORWARD -i "\${WG_INTERFACE}" -p tcp -d "\${WINDOWS_IP}" --dport "\${TARGET_PORT}" -j ACCEPT
        delete_rule filter FORWARD -o "\${WG_INTERFACE}" -p tcp -s "\${WINDOWS_IP}" --sport "\${TARGET_PORT}" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
        ;;
    *)
        echo "Usage: \$0 [start|stop]" >&2
        exit 1
        ;;
esac
EOF

chmod 700 "${FORWARD_SCRIPT}"

cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=Forward RDP from WireGuard interface ${INTERFACE_NAME} to ${WINDOWS_IP}:${TARGET_PORT}
After=wg-quick@${INTERFACE_NAME}.service
Requires=wg-quick@${INTERFACE_NAME}.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${FORWARD_SCRIPT} start
ExecStop=${FORWARD_SCRIPT} stop

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now "wg-rdp-forward-${INTERFACE_NAME}.service"

echo
echo "RDP forwarding configured."
echo "WireGuard interface: ${INTERFACE_NAME}"
echo "Forwarded port:       ${LISTEN_PORT}"
echo "Windows target:       ${WINDOWS_IP}:${TARGET_PORT}"
echo "Service:              wg-rdp-forward-${INTERFACE_NAME}.service"
