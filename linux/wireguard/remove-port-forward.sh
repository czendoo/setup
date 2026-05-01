#!/usr/bin/env bash

set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
    echo "Run this script as root." >&2
    exit 1
fi

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <interface-name>" >&2
    echo "Example: $0 rpi" >&2
    exit 1
fi

INTERFACE_NAME="$1"
FORWARD_SCRIPT="/usr/local/sbin/wg-rdp-forward-${INTERFACE_NAME}.sh"
SERVICE_NAME="wg-rdp-forward-${INTERFACE_NAME}.service"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}"

if systemctl list-unit-files --type=service | grep -Fq "${SERVICE_NAME}"; then
    systemctl stop "${SERVICE_NAME}" || true
    systemctl disable "${SERVICE_NAME}" || true
fi

rm -f "${SERVICE_FILE}" "${FORWARD_SCRIPT}"

systemctl daemon-reload

echo
echo "Port forwarding removed for interface '${INTERFACE_NAME}'."
echo "Service: ${SERVICE_NAME}"