#!/usr/bin/env bash

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: create-sudo-admin-user.sh [options]

Options:
  --user <name>          Admin user name to create or update
  -h, --help             Show this help message

If --user is not provided, the script prompts for it.
The script then prompts for the user's password, ensures sudo is installed,
creates the user if needed, adds the user to the sudo group, and copies the
root user's authorized SSH keys into the new user's ~/.ssh/authorized_keys.
EOF
}

if [[ "${EUID}" -ne 0 ]]; then
    echo "Run this script as root." >&2
    exit 1
fi

if ! command -v apt-get >/dev/null 2>&1; then
    echo "This script is intended for Ubuntu or other apt-based systems." >&2
    exit 1
fi

ADMIN_USER=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --user)
            ADMIN_USER="${2:-}"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

prompt_required_value() {
    local prompt_message="$1"
    local value=""

    while [[ -z "${value}" ]]; do
        read -r -p "${prompt_message}: " value
    done

    printf '%s\n' "${value}"
}

prompt_password() {
    local first_password=""
    local second_password=""

    while true; do
        read -r -s -p "Enter the password for ${ADMIN_USER}: " first_password
        printf '\n' >&2
        read -r -s -p "Confirm the password for ${ADMIN_USER}: " second_password
        printf '\n' >&2

        if [[ -z "${first_password}" ]]; then
            echo "Password cannot be empty." >&2
            continue
        fi

        if [[ "${first_password}" != "${second_password}" ]]; then
            echo "Passwords do not match. Try again." >&2
            continue
        fi

        printf '%s\n' "${first_password}"
        return 0
    done
}

validate_user_name() {
    local user_name="$1"

    [[ "${user_name}" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]]
}

ensure_home_directory() {
    local user_name="$1"
    local home_dir

    home_dir="$(getent passwd "${user_name}" | cut -d: -f6)"
    if [[ -z "${home_dir}" ]]; then
        echo "Could not determine home directory for '${user_name}'." >&2
        exit 1
    fi

    install -d -m 0700 -o "${user_name}" -g "${user_name}" "${home_dir}/.ssh"
    printf '%s\n' "${home_dir}"
}

merge_root_authorized_keys() {
    local user_name="$1"
    local home_dir="$2"
    local root_authorized_keys="/root/.ssh/authorized_keys"
    local target_authorized_keys="${home_dir}/.ssh/authorized_keys"
    local line=""

    if [[ ! -f "${root_authorized_keys}" ]]; then
        echo "No ${root_authorized_keys} file found. Skipping SSH key copy."
        return 0
    fi

    touch "${target_authorized_keys}"
    chmod 600 "${target_authorized_keys}"

    while IFS= read -r line || [[ -n "${line}" ]]; do
        [[ -n "${line}" ]] || continue
        if ! grep -Fqx "${line}" "${target_authorized_keys}"; then
            printf '%s\n' "${line}" >> "${target_authorized_keys}"
        fi
    done < "${root_authorized_keys}"

    chown "${user_name}:${user_name}" "${target_authorized_keys}"
}

export DEBIAN_FRONTEND=noninteractive

if [[ -z "${ADMIN_USER}" ]]; then
    ADMIN_USER="$(prompt_required_value "Enter the new sudo admin user name")"
fi

if ! validate_user_name "${ADMIN_USER}"; then
    echo "Invalid user name: ${ADMIN_USER}" >&2
    exit 1
fi

if [[ "${ADMIN_USER}" == "root" ]]; then
    echo "Choose a non-root user name." >&2
    exit 1
fi

ADMIN_PASSWORD="$(prompt_password)"

echo "Installing sudo if needed..."
apt-get update
apt-get install -y sudo

if id "${ADMIN_USER}" >/dev/null 2>&1; then
    echo "User '${ADMIN_USER}' already exists. Updating its password and access."
else
    echo "Creating user '${ADMIN_USER}'..."
    useradd -m -s /bin/bash "${ADMIN_USER}"
fi

printf '%s:%s\n' "${ADMIN_USER}" "${ADMIN_PASSWORD}" | chpasswd

echo "Adding '${ADMIN_USER}' to sudo group..."
usermod -aG sudo "${ADMIN_USER}"

ADMIN_HOME="$(ensure_home_directory "${ADMIN_USER}")"

echo "Copying root SSH authorized keys to ${ADMIN_HOME}/.ssh/authorized_keys..."
merge_root_authorized_keys "${ADMIN_USER}" "${ADMIN_HOME}"

echo
echo "Admin user ready: ${ADMIN_USER}"
echo "Home directory: ${ADMIN_HOME}"
echo "Sudo group added: yes"
echo "Authorized keys copied from: /root/.ssh/authorized_keys"
echo
echo "Next steps:"
echo "1. Open a second SSH session and confirm login as ${ADMIN_USER}."
echo "2. Confirm sudo works: sudo -v"
echo "3. Only after that, switch the hardening script to use --admin-user ${ADMIN_USER} and disable direct root SSH."