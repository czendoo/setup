#!/usr/bin/env bash

set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
    echo "Run this script as root." >&2
    exit 1
fi

if [[ $# -ne 0 ]]; then
    echo "Usage: $0" >&2
    exit 1
fi

if ! command -v systemctl >/dev/null 2>&1; then
    echo "systemctl was not found. This script requires systemd." >&2
    exit 1
fi

SERVICE_NAME=""
for candidate in rathole.service rathole-client.service rathole-server.service; do
    if systemctl list-unit-files --type=service | grep -q "^${candidate}"; then
        SERVICE_NAME="$candidate"
        break
    fi
done

if [[ -z "$SERVICE_NAME" ]]; then
    echo "No RatHole service is installed." >&2
    exit 1
fi

systemctl restart "$SERVICE_NAME"

echo "RatHole restarted."
echo "Status: systemctl status ${SERVICE_NAME}"