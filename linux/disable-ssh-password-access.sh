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

config_file="/etc/ssh/sshd_config.d/60-password-auth.conf"

if [[ -f "${config_file}" ]]; then
  rm -f "${config_file}"
  echo "Removed ${config_file}."
else
  echo "No password-auth override file found at ${config_file}."
fi

if command -v systemctl >/dev/null 2>&1; then
  systemctl restart ssh
else
  service ssh restart
fi

echo
echo "SSH password login override has been disabled."
echo "If password login is still enabled, check /etc/ssh/sshd_config and other files in /etc/ssh/sshd_config.d/."