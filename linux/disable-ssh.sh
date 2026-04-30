#!/usr/bin/env bash

set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run this script with sudo or as root."
  exit 1
fi

if ! command -v apt-get >/dev/null 2>&1; then
  echo "This script is intended for Ubuntu or other apt-based systems."
  exit 1
fi

if command -v systemctl >/dev/null 2>&1; then
  systemctl stop ssh
  systemctl disable ssh
else
  service ssh stop
fi

echo
echo "The SSH service has been disabled on this machine."