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

systemctl restart rathole.service

echo "RatHole restarted."
echo "Status: systemctl status rathole.service"