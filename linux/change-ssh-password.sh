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

target_user="${1:-}"

if [[ -z "${target_user}" ]]; then
  read -r -p "Enter the username to update: " target_user
fi

if [[ -z "${target_user}" ]]; then
  echo "A username is required."
  exit 1
fi

if ! id "${target_user}" >/dev/null 2>&1; then
  echo "User '${target_user}' does not exist."
  exit 1
fi

user_shell="$(getent passwd "${target_user}" | cut -d: -f7)"
if [[ -z "${user_shell}" || "${user_shell}" == "/usr/sbin/nologin" || "${user_shell}" == "/bin/false" ]]; then
  echo "User '${target_user}' is not configured with a login shell."
  exit 1
fi

echo
echo "Set the password for '${target_user}'."
passwd "${target_user}"

echo
echo "The SSH/login password has been updated for '${target_user}'."