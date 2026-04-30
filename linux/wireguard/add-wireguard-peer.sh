#!/usr/bin/env bash

set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
    echo "Run this script as root." >&2
    exit 1
fi

if [[ $# -ne 3 ]]; then
    echo "Usage: $0 <peer-name> <client-ip> <server-endpoint>" >&2
    echo "Example: $0 laptop 10.44.0.2 vpn.example.com" >&2
    exit 1
fi

PEER_NAME="$1"
CLIENT_IP="$2"
SERVER_ENDPOINT="$3"
WG_CONFIG_DIR="/etc/wireguard"

ENV_FILE="${WG_CONFIG_DIR}/wg0.env"
if [[ ! -f "${ENV_FILE}" ]]; then
    echo "Missing ${ENV_FILE}. Run install-wireguard-server.sh first." >&2
    exit 1
fi

source "${ENV_FILE}"

WG_CONFIG_FILE="${WG_CONFIG_DIR}/${WG_INTERFACE}.conf"
PEER_DIR="${WG_CONFIG_DIR}/peers/${PEER_NAME}"
PEER_PRIVATE_KEY_FILE="${PEER_DIR}/${PEER_NAME}.key"
PEER_PUBLIC_KEY_FILE="${PEER_DIR}/${PEER_NAME}.pub"
PEER_CONFIG_FILE="${PEER_DIR}/${PEER_NAME}.conf"

if [[ -d "${PEER_DIR}" ]]; then
    echo "Peer '${PEER_NAME}' already exists." >&2
    exit 1
fi

install -d -m 0700 "${PEER_DIR}"

umask 077
wg genkey | tee "${PEER_PRIVATE_KEY_FILE}" | wg pubkey > "${PEER_PUBLIC_KEY_FILE}"

PEER_PRIVATE_KEY="$(<"${PEER_PRIVATE_KEY_FILE}")"
PEER_PUBLIC_KEY="$(<"${PEER_PUBLIC_KEY_FILE}")"

cat >> "${WG_CONFIG_FILE}" <<EOF

[Peer]
# ${PEER_NAME}
PublicKey = ${PEER_PUBLIC_KEY}
AllowedIPs = ${CLIENT_IP}/32
EOF

cat > "${PEER_CONFIG_FILE}" <<EOF
[Interface]
PrivateKey = ${PEER_PRIVATE_KEY}
Address = ${CLIENT_IP}/32
DNS = 1.1.1.1

[Peer]
PublicKey = ${SERVER_PUBLIC_KEY}
Endpoint = ${SERVER_ENDPOINT}:${WG_PORT}
AllowedIPs = ${WG_NETWORK_CIDR}
PersistentKeepalive = 25
EOF

chmod 600 "${PEER_PRIVATE_KEY_FILE}" "${PEER_PUBLIC_KEY_FILE}" "${PEER_CONFIG_FILE}"

systemctl restart "wg-quick@${WG_INTERFACE}"

echo
echo "Peer '${PEER_NAME}' added."
echo "Client config: ${PEER_CONFIG_FILE}"
echo
echo "QR code:"
qrencode -t ansiutf8 < "${PEER_CONFIG_FILE}"