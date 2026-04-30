#!/usr/bin/env bash

set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
    echo "Run this script as root." >&2
    exit 1
fi

if ! command -v apt-get >/dev/null 2>&1; then
    echo "This script is intended for Ubuntu, Raspberry Pi OS, or other apt-based systems." >&2
    exit 1
fi

if [[ $# -lt 1 || $# -gt 2 ]]; then
    echo "Usage: $0 <client-config-path> [interface-name]" >&2
    echo "Example: $0 ./laptop.conf" >&2
    exit 1
fi

SOURCE_CONFIG="$1"

if [[ ! -f "${SOURCE_CONFIG}" ]]; then
    echo "Config file not found: ${SOURCE_CONFIG}" >&2
    exit 1
fi

INTERFACE_NAME="${2:-$(basename "${SOURCE_CONFIG}")}"
INTERFACE_NAME="${INTERFACE_NAME%.conf}"

if [[ -z "${INTERFACE_NAME}" ]]; then
    echo "Could not determine the WireGuard interface name." >&2
    exit 1
fi

WG_CONFIG_DIR="/etc/wireguard"
TARGET_CONFIG="${WG_CONFIG_DIR}/${INTERFACE_NAME}.conf"

SOURCE_CONFIG_RESOLVED="$(readlink -f "${SOURCE_CONFIG}")"
TARGET_CONFIG_RESOLVED="$(readlink -m "${TARGET_CONFIG}")"

export DEBIAN_FRONTEND=noninteractive

echo "Installing WireGuard packages..."
apt-get update
apt-get install -y wireguard wireguard-tools resolvconf

install -d -m 0700 "${WG_CONFIG_DIR}"

if [[ "${SOURCE_CONFIG_RESOLVED}" != "${TARGET_CONFIG_RESOLVED}" ]]; then
    install -m 0600 "${SOURCE_CONFIG}" "${TARGET_CONFIG}"
else
    chmod 600 "${TARGET_CONFIG}"
fi

if systemctl is-active --quiet "wg-quick@${INTERFACE_NAME}"; then
    systemctl restart "wg-quick@${INTERFACE_NAME}"
else
    systemctl enable --now "wg-quick@${INTERFACE_NAME}"
fi

echo
echo "WireGuard client configured."
echo "Interface: ${INTERFACE_NAME}"
echo "Config:    ${TARGET_CONFIG}"
echo "Status:    systemctl status wg-quick@${INTERFACE_NAME}"