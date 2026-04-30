#!/usr/bin/env bash

set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run this script with sudo or as root."
  exit 1
fi

target_user="${SUDO_USER:-${USER:-}}"

if [[ -z "${target_user}" || "${target_user}" == "root" ]]; then
  echo "Could not determine a non-root target user."
  echo "Run it as: sudo $0"
  exit 1
fi

if ! id "${target_user}" >/dev/null 2>&1; then
  echo "User '${target_user}' does not exist."
  exit 1
fi

if ! command -v apt-get >/dev/null 2>&1; then
  echo "This script is intended for Ubuntu or other apt-based systems."
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

echo "Installing OpenSSH server if needed..."
apt-get update
apt-get install -y openssh-server

mkdir -p /etc/ssh/sshd_config.d

cat >/etc/ssh/sshd_config.d/60-password-auth.conf <<EOF
PasswordAuthentication yes
KbdInteractiveAuthentication yes
UsePAM yes
PermitRootLogin no
EOF

user_shell="$(getent passwd "${target_user}" | cut -d: -f7)"
if [[ -z "${user_shell}" || "${user_shell}" == "/usr/sbin/nologin" || "${user_shell}" == "/bin/false" ]]; then
  echo "User '${target_user}' is not configured with a login shell."
  exit 1
fi

echo
echo "Set the SSH password for '${target_user}'."
passwd "${target_user}"

if command -v systemctl >/dev/null 2>&1; then
  systemctl enable ssh
  systemctl restart ssh
else
  service ssh restart
fi

if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
  echo "Allowing OpenSSH through UFW..."
  ufw allow OpenSSH
fi

echo
echo "SSH password login is enabled for '${target_user}'."
echo "You can connect with: ssh ${target_user}@<server-ip>"