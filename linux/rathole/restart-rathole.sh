#!/usr/bin/env bash

set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
    echo "Run this script as root." >&2
    exit 1
fi

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <server|client>" >&2
    exit 1
fi

ROLE="$1"
if [[ "$ROLE" != "server" && "$ROLE" != "client" ]]; then
    echo "Role must be either 'server' or 'client'." >&2
    exit 1
fi

if ! command -v systemctl >/dev/null 2>&1; then
    echo "systemctl was not found. This script requires systemd." >&2
    exit 1
fi

SERVICE_NAME="rathole-${ROLE}.service"

if ! systemctl list-unit-files --type=service | grep -q "^${SERVICE_NAME}"; then
    echo "Service ${SERVICE_NAME} is not installed." >&2
    exit 1
fi

systemctl restart "$SERVICE_NAME"

echo "RatHole ${ROLE} restarted."
echo "Status: systemctl status ${SERVICE_NAME}"