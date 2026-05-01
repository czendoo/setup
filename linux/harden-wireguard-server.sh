#!/usr/bin/env bash

set -Eeuo pipefail

trap 'echo "ERROR: command failed at line ${LINENO}: ${BASH_COMMAND}" >&2' ERR

usage() {
    cat <<'EOF'
Usage: harden-wireguard-vps.sh [options]

Options:
  --admin-user <user>     SSH admin user to keep allowed
  --ssh-port <port>       SSH port to preserve or configure
  --wg-interface <name>   WireGuard interface to verify and preserve
  --wg-port <port>        WireGuard UDP port to verify and preserve
  --dry-run               Show changes without applying them
  --validate              Show a short validation summary and exit
  -h, --help              Show this help message

When a required option is not provided, the script prompts for it.
The WireGuard interface and port are treated as existing server state.
If the supplied or entered WireGuard port does not match the detected
running configuration, the script aborts instead of changing it.
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

DRY_RUN=false
VALIDATE_ONLY=false
ADMIN_USER=""
SSH_PORT=""
WG_INTERFACE=""
WG_PORT=""
SCRIPT_NAME="$(basename "$0")"
SSH_HARDENING_FILE="/etc/ssh/sshd_config.d/70-hardening.conf"
FAIL2BAN_JAIL_FILE="/etc/fail2ban/jail.d/sshd-hardening.local"
AUTO_UPGRADES_FILE="/etc/apt/apt.conf.d/20auto-upgrades"
JOURNALD_FILE="/etc/systemd/journald.conf.d/60-hardening.conf"
BACKUP_STAMP="$(date +%Y%m%d%H%M%S)"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --admin-user)
            ADMIN_USER="${2:-}"
            shift 2
            ;;
        --ssh-port)
            SSH_PORT="${2:-}"
            shift 2
            ;;
        --wg-interface)
            WG_INTERFACE="${2:-}"
            shift 2
            ;;
        --wg-port)
            WG_PORT="${2:-}"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --validate)
            VALIDATE_ONLY=true
            shift
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

run_cmd() {
    if [[ "${DRY_RUN}" == true ]]; then
        echo "DRY-RUN: $*"
        return 0
    fi

    "$@"
}

write_file() {
    local file_path="$1"
    local file_mode="$2"
    local file_content="$3"

    if [[ "${DRY_RUN}" == true ]]; then
        echo "DRY-RUN: write ${file_path} (${file_mode})"
        return 0
    fi

    install -D -m "${file_mode}" /dev/null "${file_path}"
    printf '%s' "${file_content}" > "${file_path}"
}

backup_file_if_exists() {
    local file_path="$1"

    if [[ ! -f "${file_path}" ]]; then
        return 0
    fi

    run_cmd cp "${file_path}" "${file_path}.bak.${BACKUP_STAMP}"
}

build_ssh_hardening_content() {
    local admin_user="$1"
    local ssh_port="$2"
    local permit_root_login="no"
    local allow_users_line="AllowUsers ${admin_user}"

    if [[ "${admin_user}" == "root" ]]; then
        # Root-only hosts can still be hardened safely if root is limited to SSH keys.
        permit_root_login="prohibit-password"
    fi

    cat <<EOF
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PubkeyAuthentication yes
PermitRootLogin ${permit_root_login}
${allow_users_line}
Port ${ssh_port}
LoginGraceTime 30
MaxAuthTries 3
ClientAliveInterval 300
ClientAliveCountMax 2
X11Forwarding no
EOF
}

service_enable_now() {
    local service_name="$1"

    if command -v systemctl >/dev/null 2>&1; then
        run_cmd systemctl enable --now "${service_name}"
    else
        run_cmd service "${service_name}" start
    fi
}

service_restart() {
    local service_name="$1"

    if command -v systemctl >/dev/null 2>&1; then
        run_cmd systemctl restart "${service_name}"
    else
        run_cmd service "${service_name}" restart
    fi
}

validate_port() {
    local port="$1"

    [[ "${port}" =~ ^[0-9]+$ ]] || return 1
    (( port >= 1 && port <= 65535 ))
}

normalize_port() {
    local port="$1"

    printf '%s' "${port}" | tr -d '[:space:]'
}

validate_user_name() {
    local user_name="$1"

    [[ "${user_name}" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]]
}

prompt_yes_no() {
    local prompt_message="$1"
    local answer=""

    while true; do
        read -r -p "${prompt_message} [y/n]: " answer
        case "${answer}" in
            y|Y|yes|YES)
                return 0
                ;;
            n|N|no|NO)
                return 1
                ;;
        esac
    done
}

prompt_password_for_user() {
    local user_name="$1"
    local first_password=""
    local second_password=""

    while true; do
        read -r -s -p "Enter the password for ${user_name}: " first_password
        printf '\n' >&2
        read -r -s -p "Confirm the password for ${user_name}: " second_password
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

ensure_user_home_ssh_dir() {
    local user_name="$1"
    local home_dir
    local primary_group

    home_dir="$(getent passwd "${user_name}" | cut -d: -f6)"
    if [[ -z "${home_dir}" ]]; then
        echo "Could not determine home directory for '${user_name}'." >&2
        exit 1
    fi

    primary_group="$(id -gn "${user_name}")"
    if [[ -z "${primary_group}" ]]; then
        echo "Could not determine primary group for '${user_name}'." >&2
        exit 1
    fi

    run_cmd install -d -m 0700 -o "${user_name}" -g "${primary_group}" "${home_dir}/.ssh"
    printf '%s\n' "${home_dir}"
}

merge_root_authorized_keys() {
    local user_name="$1"
    local home_dir="$2"
    local primary_group=""
    local root_authorized_keys="/root/.ssh/authorized_keys"
    local target_authorized_keys="${home_dir}/.ssh/authorized_keys"
    local temp_file=""

    if [[ ! -f "${root_authorized_keys}" ]]; then
        echo "No ${root_authorized_keys} file found. Skipping SSH key copy."
        return 0
    fi

    if [[ "${DRY_RUN}" == true ]]; then
        echo "DRY-RUN: merge ${root_authorized_keys} into ${target_authorized_keys}"
        return 0
    fi

    touch "${target_authorized_keys}"
    chmod 600 "${target_authorized_keys}"

    temp_file="$(mktemp)"
    awk 'NF && !seen[$0]++' "${target_authorized_keys}" "${root_authorized_keys}" > "${temp_file}"
    mv "${temp_file}" "${target_authorized_keys}"

    primary_group="$(id -gn "${user_name}")"
    chown "${user_name}:${primary_group}" "${target_authorized_keys}"
}

create_admin_user() {
    local user_name="$1"
    local user_password=""
    local user_home=""

    if ! validate_user_name "${user_name}"; then
        echo "Invalid user name: ${user_name}" >&2
        exit 1
    fi

    if [[ "${user_name}" == "root" ]]; then
        echo "Refusing to create root. Choose a non-root user name." >&2
        exit 1
    fi

    if [[ "${DRY_RUN}" == true ]]; then
        echo "DRY-RUN: apt-get update"
        echo "DRY-RUN: apt-get install -y sudo"
        echo "DRY-RUN: useradd -m -s /bin/bash ${user_name}"
        echo "DRY-RUN: prompt for password and add ${user_name} to sudo group"
        echo "DRY-RUN: copy /root/.ssh/authorized_keys to ${user_name}"
        return 0
    fi

    user_password="$(prompt_password_for_user "${user_name}")"

    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y sudo

    echo "Creating user '${user_name}'..."
    useradd -m -s /bin/bash "${user_name}"
    printf '%s:%s\n' "${user_name}" "${user_password}" | chpasswd

    echo "Adding '${user_name}' to sudo group..."
    usermod -aG sudo "${user_name}"

    user_home="$(ensure_user_home_ssh_dir "${user_name}")"
    echo "Copying root SSH authorized keys to ${user_home}/.ssh/authorized_keys..."
    merge_root_authorized_keys "${user_name}" "${user_home}"
}

ensure_sudo_access() {
    local user_name="$1"

    if [[ "${user_name}" == "root" ]]; then
        return 0
    fi

    if id -nG "${user_name}" | tr ' ' '\n' | grep -Fxq sudo; then
        return 0
    fi

    echo "User '${user_name}' is not in the sudo group. Adding it now..."

    if [[ "${DRY_RUN}" == true ]]; then
        echo "DRY-RUN: apt-get update"
        echo "DRY-RUN: apt-get install -y sudo"
        echo "DRY-RUN: usermod -aG sudo ${user_name}"
        return 0
    fi

    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y sudo
    usermod -aG sudo "${user_name}"
}

require_existing_user() {
    local user_name="$1"

    if ! id "${user_name}" >/dev/null 2>&1; then
        echo "User '${user_name}' does not exist." >&2
        if prompt_yes_no "Create '${user_name}' now with sudo access and root SSH keys copied"; then
            create_admin_user "${user_name}"
            return 0
        fi
        exit 1
    fi
}

require_authorized_keys() {
    local user_name="$1"
    local home_dir
    local auth_keys

    home_dir="$(ensure_user_home_ssh_dir "${user_name}")"
    if [[ -z "${home_dir}" ]]; then
        echo "Could not determine home directory for '${user_name}'." >&2
        exit 1
    fi

    auth_keys="${home_dir}/.ssh/authorized_keys"
    if [[ ! -s "${auth_keys}" ]]; then
        echo "Missing or empty authorized_keys for '${user_name}' at ${auth_keys}." >&2
        echo "Copying root SSH authorized keys into '${user_name}'..."
        merge_root_authorized_keys "${user_name}" "${home_dir}"
    fi

    if [[ ! -s "${auth_keys}" ]]; then
        echo "No authorized_keys available for '${user_name}' after the copy step." >&2
        exit 1
    fi
}

read_sshd_setting_from_files() {
    local setting_name="$1"

    awk -v key="${setting_name}" '
        /^[[:space:]]*#/ { next }
        NF >= 2 && tolower($1) == key {
            value = $2
        }
        END {
            if (value != "") {
                print value
            }
        }
    ' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null
}

read_sshd_effective_setting() {
    local setting_name="$1"
    local sshd_output=""
    local setting_value=""

    if command -v sshd >/dev/null 2>&1; then
        sshd_output="$(sshd -T 2>/dev/null || true)"
        if [[ -n "${sshd_output}" ]]; then
            setting_value="$(awk -v key="${setting_name}" '$1 == key { print $2; exit }' <<< "${sshd_output}")"
            if [[ -n "${setting_value}" ]]; then
                printf '%s\n' "${setting_value}"
                return 0
            fi
        fi
    fi

    read_sshd_setting_from_files "${setting_name}"
}

detect_ssh_port() {
    read_sshd_effective_setting port
}

detect_wg_interface() {
    local interface_name=""
    local env_file=""

    for env_file in /etc/wireguard/*.env; do
        [[ -f "${env_file}" ]] || continue
        interface_name="$(awk -F= '/^WG_INTERFACE=/ { print $2; exit }' "${env_file}")"
        if [[ -n "${interface_name}" ]]; then
            printf '%s\n' "${interface_name}"
            return 0
        fi
    done

    interface_name="$(wg show interfaces 2>/dev/null | awk '{ print $1; exit }')"
    if [[ -n "${interface_name}" ]]; then
        printf '%s\n' "${interface_name}"
        return 0
    fi

    for env_file in /etc/wireguard/*.conf; do
        [[ -f "${env_file}" ]] || continue
        basename "${env_file}" .conf
        return 0
    done

    return 0
}

detect_wg_port_from_env() {
    local interface_name="$1"
    local env_file="/etc/wireguard/${interface_name}.env"

    if [[ -f "${env_file}" ]]; then
        awk -F= '/^WG_PORT=/ { print $2; exit }' "${env_file}"
    fi
}

detect_wg_port_from_conf() {
    local interface_name="$1"
    local conf_file="/etc/wireguard/${interface_name}.conf"

    if [[ -f "${conf_file}" ]]; then
        awk -F= '/^ListenPort[[:space:]]*=/ { gsub(/[[:space:]]/, "", $2); print $2; exit }' "${conf_file}"
    fi
}

detect_wg_port_from_runtime() {
    local interface_name="$1"

    if command -v wg >/dev/null 2>&1; then
        wg show "${interface_name}" listen-port 2>/dev/null | awk 'NF { print $1; exit }'
    fi
}

prompt_required_value() {
    local prompt_message="$1"
    local value=""

    while [[ -z "${value}" ]]; do
        read -r -p "${prompt_message}: " value
    done

    printf '%s\n' "${value}"
}

prompt_wg_port_confirmation() {
    local detected_port="$1"
    local entered_port=""

    if [[ -n "${detected_port}" ]]; then
        echo "Detected WireGuard UDP port: ${detected_port}" >&2
        entered_port="$(prompt_required_value "Enter the preserved WireGuard UDP port")"
        if [[ "${entered_port}" != "${detected_port}" ]]; then
            echo "Entered WireGuard port does not match the detected active port." >&2
            echo "Refusing to change the active WireGuard port from this script." >&2
            exit 1
        fi
    else
        entered_port="$(prompt_required_value "WireGuard UDP port could not be detected. Enter the preserved WireGuard UDP port")"
    fi

    if ! validate_port "${entered_port}"; then
        echo "Invalid WireGuard UDP port: ${entered_port}" >&2
        exit 1
    fi

    printf '%s\n' "${entered_port}"
}

ensure_wireguard_present() {
    if ! compgen -G "/etc/wireguard/*.conf" >/dev/null; then
        echo "No WireGuard configuration found in /etc/wireguard." >&2
        exit 1
    fi
}

print_short_status() {
    local current_password_auth="unknown"
    local current_ssh_port="$(detect_ssh_port)"
    local ufw_active="no"
    local fail2ban_active="no"
    local unattended_enabled="no"
    local journald_persistent="no"

    current_password_auth="$(read_sshd_effective_setting passwordauthentication)"
    if [[ -z "${current_password_auth}" ]]; then
        current_password_auth="unknown"
    fi

    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
        ufw_active="yes"
    fi

    if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet fail2ban; then
        fail2ban_active="yes"
    fi

    if [[ -f "${AUTO_UPGRADES_FILE}" ]] && grep -q 'APT::Periodic::Unattended-Upgrade "1";' "${AUTO_UPGRADES_FILE}"; then
        unattended_enabled="yes"
    fi

    if [[ -f "${JOURNALD_FILE}" ]] && grep -q '^Storage=persistent$' "${JOURNALD_FILE}"; then
        journald_persistent="yes"
    fi

    echo "SSH password authentication: ${current_password_auth}"
    echo "SSH port: ${current_ssh_port:-unknown}"
    echo "UFW active: ${ufw_active}"
    echo "Fail2ban active: ${fail2ban_active}"
    echo "Unattended upgrades enabled: ${unattended_enabled}"
    echo "Persistent journald configured: ${journald_persistent}"
    if [[ -n "${WG_INTERFACE}" ]]; then
        echo "WireGuard interface: ${WG_INTERFACE}"
    fi
    if [[ -n "${WG_PORT}" ]]; then
        echo "WireGuard UDP port: ${WG_PORT}"
    fi
}

if [[ "${VALIDATE_ONLY}" == true ]]; then
    if [[ -z "${WG_INTERFACE}" ]]; then
        WG_INTERFACE="$(detect_wg_interface)"
    fi
    if [[ -n "${WG_INTERFACE}" && -z "${WG_PORT}" ]]; then
        WG_PORT="$(detect_wg_port_from_env "${WG_INTERFACE}")"
        if [[ -z "${WG_PORT}" ]]; then
            WG_PORT="$(detect_wg_port_from_conf "${WG_INTERFACE}")"
        fi
        if [[ -z "${WG_PORT}" ]]; then
            WG_PORT="$(detect_wg_port_from_runtime "${WG_INTERFACE}")"
        fi
    fi
    print_short_status
    exit 0
fi

ensure_wireguard_present

if [[ -z "${ADMIN_USER}" ]]; then
    ADMIN_USER="$(prompt_required_value "Enter the SSH admin user to keep")"
fi
require_existing_user "${ADMIN_USER}"
ensure_sudo_access "${ADMIN_USER}"
require_authorized_keys "${ADMIN_USER}"

if [[ -z "${SSH_PORT}" ]]; then
    detected_ssh_port="$(detect_ssh_port)"
    if [[ -n "${detected_ssh_port}" ]]; then
        detected_ssh_port="$(normalize_port "${detected_ssh_port}")"
        echo "Detected SSH port: ${detected_ssh_port}"
    fi
    SSH_PORT="$(prompt_required_value "Enter the SSH port to preserve or configure")"
fi

SSH_PORT="$(normalize_port "${SSH_PORT}")"

if ! validate_port "${SSH_PORT}"; then
    echo "Invalid SSH port: ${SSH_PORT}" >&2
    exit 1
fi

if [[ -z "${WG_INTERFACE}" ]]; then
    detected_wg_interface="$(detect_wg_interface)"
    if [[ -n "${detected_wg_interface}" ]]; then
        echo "Detected WireGuard interface: ${detected_wg_interface}"
    fi
    WG_INTERFACE="$(prompt_required_value "Enter the WireGuard interface to preserve")"
fi

if [[ ! -f "/etc/wireguard/${WG_INTERFACE}.conf" ]]; then
    echo "Missing /etc/wireguard/${WG_INTERFACE}.conf." >&2
    exit 1
fi

detected_wg_port="$(detect_wg_port_from_env "${WG_INTERFACE}")"
if [[ -z "${detected_wg_port}" ]]; then
    detected_wg_port="$(detect_wg_port_from_conf "${WG_INTERFACE}")"
fi
if [[ -z "${detected_wg_port}" ]]; then
    detected_wg_port="$(detect_wg_port_from_runtime "${WG_INTERFACE}")"
fi

detected_wg_port="$(normalize_port "${detected_wg_port}")"

if [[ -n "${WG_PORT}" ]]; then
    WG_PORT="$(normalize_port "${WG_PORT}")"
    if ! validate_port "${WG_PORT}"; then
        echo "Invalid WireGuard UDP port: ${WG_PORT}" >&2
        exit 1
    fi

    if [[ -n "${detected_wg_port}" && "${WG_PORT}" != "${detected_wg_port}" ]]; then
        echo "Supplied WireGuard port does not match the detected active port (${detected_wg_port})." >&2
        exit 1
    fi
else
    WG_PORT="$(prompt_wg_port_confirmation "${detected_wg_port}")"
fi

WG_PORT="$(normalize_port "${WG_PORT}")"

if ! validate_port "${WG_PORT}"; then
    echo "Invalid normalized WireGuard UDP port: ${WG_PORT}" >&2
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive

echo "Installing required packages..."
run_cmd apt-get update
run_cmd apt-get install -y openssh-server ufw fail2ban unattended-upgrades

backup_file_if_exists "${SSH_HARDENING_FILE}"
backup_file_if_exists "${FAIL2BAN_JAIL_FILE}"
backup_file_if_exists "${AUTO_UPGRADES_FILE}"
backup_file_if_exists "${JOURNALD_FILE}"

ssh_hardening_content="$(build_ssh_hardening_content "${ADMIN_USER}" "${SSH_PORT}")"

fail2ban_content=$(cat <<EOF
[sshd]
enabled = true
port = ${SSH_PORT}
backend = systemd
findtime = 10m
bantime = 1h
maxretry = 5
EOF
)

auto_upgrades_content=$(cat <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
)

journald_content=$(cat <<'EOF'
[Journal]
Storage=persistent
Compress=yes
SystemMaxUse=200M
EOF
)

write_file "${SSH_HARDENING_FILE}" 0644 "${ssh_hardening_content}"

if [[ "${DRY_RUN}" != true ]]; then
    sshd -t
else
    echo "DRY-RUN: sshd -t"
fi

write_file "${FAIL2BAN_JAIL_FILE}" 0644 "${fail2ban_content}"
write_file "${AUTO_UPGRADES_FILE}" 0644 "${auto_upgrades_content}"
write_file "${JOURNALD_FILE}" 0644 "${journald_content}"

echo "Applying firewall policy..."
echo "Allowing SSH rule: ${SSH_PORT}/tcp"
run_cmd ufw allow "${SSH_PORT}/tcp"
echo "Allowing WireGuard rule: ${WG_PORT}/udp"
run_cmd ufw allow "${WG_PORT}/udp"
run_cmd ufw default deny incoming
run_cmd ufw default allow outgoing
run_cmd ufw --force enable

echo "Restarting and enabling services..."
if command -v systemctl >/dev/null 2>&1; then
    run_cmd systemctl enable ssh
else
    run_cmd service ssh start
fi
service_restart ssh
service_enable_now fail2ban
if command -v systemctl >/dev/null 2>&1; then
    run_cmd systemctl restart systemd-journald
fi

echo
echo "Hardening applied by ${SCRIPT_NAME}."
print_short_status
echo "SSH hardening file: ${SSH_HARDENING_FILE}"
echo "Fail2ban jail file: ${FAIL2BAN_JAIL_FILE}"
echo "Auto upgrades file: ${AUTO_UPGRADES_FILE}"
echo "Journald config file: ${JOURNALD_FILE}"