#!/usr/bin/env bash

set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
    echo "Run this script as root." >&2
    exit 1
fi

if ! command -v apt-get >/dev/null 2>&1; then
    echo "This script is intended for Ubuntu or other apt-based systems." >&2
    exit 1
fi

usage() {
    cat >&2 <<'EOF'
Usage: install-wireguard-server.sh <server-cidr>
Example: install-wireguard-server.sh 10.44.0.1/24
EOF
}

ipv4_network_from_cidr() {
    local cidr="$1"
    local ip prefix o1 o2 o3 o4 octet ip_int mask network

    if [[ ! "${cidr}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$ ]]; then
        echo "Invalid IPv4 CIDR: ${cidr}" >&2
        return 1
    fi

    IFS=/ read -r ip prefix <<< "${cidr}"
    IFS=. read -r o1 o2 o3 o4 <<< "${ip}"

    for octet in "${o1}" "${o2}" "${o3}" "${o4}"; do
        if (( octet < 0 || octet > 255 )); then
            echo "Invalid IPv4 CIDR: ${cidr}" >&2
            return 1
        fi
    done

    ip_int=$(( (o1 << 24) | (o2 << 16) | (o3 << 8) | o4 ))

    if (( prefix == 0 )); then
        mask=0
    else
        mask=$(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
    fi

    network=$(( ip_int & mask ))

    printf '%d.%d.%d.%d/%d\n' \
        $(( (network >> 24) & 255 )) \
        $(( (network >> 16) & 255 )) \
        $(( (network >> 8) & 255 )) \
        $(( network & 255 )) \
        "${prefix}"
}

if [[ $# -ne 1 ]]; then
    usage
    exit 1
fi

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    usage
    exit 0
fi

WG_INTERFACE="${WG_INTERFACE:-wg0}"

if [[ -n "${WG_PORT:-}" ]]; then
    WG_PORT="${WG_PORT}"
elif [[ -r /dev/tty ]]; then
    read -r -p "WireGuard UDP port [51820]: " WG_PORT < /dev/tty
    WG_PORT="${WG_PORT:-51820}"
else
    WG_PORT="51820"
fi

WG_SERVER_CIDR="$1"
WG_SERVER_IP="${WG_SERVER_CIDR%%/*}"
WG_NETWORK_CIDR="$(ipv4_network_from_cidr "${WG_SERVER_CIDR}")"
WG_CONFIG_DIR="/etc/wireguard"
WG_CONFIG_FILE="${WG_CONFIG_DIR}/${WG_INTERFACE}.conf"
WG_PARAMS_FILE="${WG_CONFIG_DIR}/${WG_INTERFACE}.env"
SERVER_PRIVATE_KEY_FILE="${WG_CONFIG_DIR}/${WG_INTERFACE}.key"
SERVER_PUBLIC_KEY_FILE="${WG_CONFIG_DIR}/${WG_INTERFACE}.pub"

DEFAULT_ROUTE_INTERFACE="$(ip route show default | awk '/default/ {print $5; exit}')"
PUBLIC_INTERFACE="${PUBLIC_INTERFACE:-${DEFAULT_ROUTE_INTERFACE:-eth0}}"

if [[ -z "${PUBLIC_INTERFACE}" ]]; then
    echo "Could not determine the public network interface." >&2
    echo "Set PUBLIC_INTERFACE and run the script again." >&2
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive

if systemctl is-active --quiet "wg-quick@${WG_INTERFACE}"; then
    echo "Stopping existing WireGuard interface..."
    systemctl stop "wg-quick@${WG_INTERFACE}"
fi

echo "Installing WireGuard packages..."
apt-get update
apt-get install -y wireguard wireguard-tools qrencode

install -d -m 0700 "${WG_CONFIG_DIR}"

if [[ ! -f "${SERVER_PRIVATE_KEY_FILE}" ]]; then
    umask 077
    wg genkey | tee "${SERVER_PRIVATE_KEY_FILE}" | wg pubkey > "${SERVER_PUBLIC_KEY_FILE}"
fi

SERVER_PRIVATE_KEY="$(<"${SERVER_PRIVATE_KEY_FILE}")"
SERVER_PUBLIC_KEY="$(<"${SERVER_PUBLIC_KEY_FILE}")"

cat > "${WG_CONFIG_FILE}" <<EOF
[Interface]
Address = ${WG_SERVER_CIDR}
ListenPort = ${WG_PORT}
PrivateKey = ${SERVER_PRIVATE_KEY}
SaveConfig = false

PostUp = sysctl -w net.ipv4.ip_forward=1
PostUp = iptables -A FORWARD -i ${WG_INTERFACE} -j ACCEPT
PostUp = iptables -A FORWARD -o ${WG_INTERFACE} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
PostUp = iptables -t nat -A POSTROUTING -s ${WG_NETWORK_CIDR} -o ${PUBLIC_INTERFACE} -j MASQUERADE

PostDown = iptables -D FORWARD -i ${WG_INTERFACE} -j ACCEPT
PostDown = iptables -D FORWARD -o ${WG_INTERFACE} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -s ${WG_NETWORK_CIDR} -o ${PUBLIC_INTERFACE} -j MASQUERADE
EOF

chmod 600 "${WG_CONFIG_FILE}" "${SERVER_PRIVATE_KEY_FILE}" "${SERVER_PUBLIC_KEY_FILE}"

cat > /etc/sysctl.d/99-wireguard-ip-forward.conf <<EOF
net.ipv4.ip_forward=1
EOF

sysctl --system >/dev/null

cat > "${WG_PARAMS_FILE}" <<EOF
WG_INTERFACE=${WG_INTERFACE}
WG_PORT=${WG_PORT}
WG_SERVER_CIDR=${WG_SERVER_CIDR}
WG_NETWORK_CIDR=${WG_NETWORK_CIDR}
PUBLIC_INTERFACE=${PUBLIC_INTERFACE}
SERVER_PUBLIC_KEY=${SERVER_PUBLIC_KEY}
EOF

chmod 600 "${WG_PARAMS_FILE}"

if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
    echo "Allowing WireGuard through UFW..."
    ufw allow "${WG_PORT}/udp"
fi

systemctl enable --now "wg-quick@${WG_INTERFACE}"

echo
echo "WireGuard server installed."
echo "Interface:    ${WG_INTERFACE}"
echo "Listen port:  ${WG_PORT}"
echo "VPN subnet:   ${WG_NETWORK_CIDR}"
echo "Public iface: ${PUBLIC_INTERFACE}"
echo "Server key:   ${SERVER_PUBLIC_KEY}"
echo
echo "Add a client with: sudo bash linux/wireguard/add-wireguard-peer.sh <peer-name> <client-ip> <server-endpoint>"