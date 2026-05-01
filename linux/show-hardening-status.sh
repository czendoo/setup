#!/usr/bin/env bash

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: show-hardening-status.sh [options]

Options:
  --wg-interface <name>   WireGuard interface to inspect
  -h, --help              Show this help message

This script is read-only. It reports hardening status, relevant config files,
service names, and example commands for inspecting logs and live state.
EOF
}

WG_INTERFACE=""
SSH_HARDENING_FILE="/etc/ssh/sshd_config.d/70-hardening.conf"
FAIL2BAN_JAIL_FILE="/etc/fail2ban/jail.d/sshd-hardening.local"
AUTO_UPGRADES_FILE="/etc/apt/apt.conf.d/20auto-upgrades"
JOURNALD_FILE="/etc/systemd/journald.conf.d/60-hardening.conf"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --wg-interface)
            WG_INTERFACE="${2:-}"
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

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

print_section() {
    echo
    echo "== $1 =="
}

print_kv() {
    printf '%-24s %s\n' "$1" "$2"
}

yes_no() {
    if [[ "$1" == true ]]; then
        printf '%s\n' yes
    else
        printf '%s\n' no
    fi
}

file_present() {
    [[ -f "$1" ]]
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

    if command_exists wg; then
        interface_name="$(wg show interfaces 2>/dev/null | awk '{ print $1; exit }')"
        if [[ -n "${interface_name}" ]]; then
            printf '%s\n' "${interface_name}"
            return 0
        fi
    fi

    for env_file in /etc/wireguard/*.conf; do
        [[ -f "${env_file}" ]] || continue
        basename "${env_file}" .conf
        return 0
    done
}

detect_wg_port() {
    local interface_name="$1"
    local env_file="/etc/wireguard/${interface_name}.env"
    local conf_file="/etc/wireguard/${interface_name}.conf"
    local port_value=""

    if [[ -f "${env_file}" ]]; then
        port_value="$(awk -F= '/^WG_PORT=/ { print $2; exit }' "${env_file}")"
    fi

    if [[ -z "${port_value}" && -f "${conf_file}" ]]; then
        port_value="$(awk -F= '/^ListenPort[[:space:]]*=/ { gsub(/[[:space:]]/, "", $2); print $2; exit }' "${conf_file}")"
    fi

    if [[ -z "${port_value}" && $(command -v wg >/dev/null 2>&1; echo $?) -eq 0 ]]; then
        port_value="$(wg show "${interface_name}" listen-port 2>/dev/null | awk 'NF { print $1; exit }')"
    fi

    printf '%s\n' "${port_value}"
}

detect_ssh_port() {
    if command_exists sshd; then
        sshd -T 2>/dev/null | awk '/^port / { print $2; exit }'
    fi
}

detect_password_auth() {
    if command_exists sshd; then
        sshd -T 2>/dev/null | awk '/^passwordauthentication / { print $2; exit }'
    fi
}

detect_allow_users() {
    if command_exists sshd; then
        sshd -T 2>/dev/null | awk '/^allowusers / { $1=""; sub(/^ /, ""); print; exit }'
    fi
}

service_state() {
    local service_name="$1"

    if command_exists systemctl; then
        if systemctl is-active --quiet "${service_name}"; then
            printf '%s\n' active
        else
            printf '%s\n' inactive
        fi
        return 0
    fi

    printf '%s\n' unknown
}

package_state() {
    local package_name="$1"

    if command_exists dpkg-query && dpkg-query -W -f='${Status}' "${package_name}" 2>/dev/null | grep -q 'install ok installed'; then
        printf '%s\n' installed
    else
        printf '%s\n' absent
    fi
}

ufw_active=false
ssh_hardened=false
fail2ban_configured=false
updates_configured=false
journald_persistent=false
auditd_present=false

if [[ -z "${WG_INTERFACE}" ]]; then
    WG_INTERFACE="$(detect_wg_interface)"
fi

WG_PORT=""
if [[ -n "${WG_INTERFACE}" ]]; then
    WG_PORT="$(detect_wg_port "${WG_INTERFACE}")"
fi

SSH_PORT="$(detect_ssh_port)"
PASSWORD_AUTH="$(detect_password_auth)"
ALLOW_USERS="$(detect_allow_users)"

if command_exists ufw && ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw_active=true
fi

if file_present "${SSH_HARDENING_FILE}"; then
    ssh_hardened=true
fi

if file_present "${FAIL2BAN_JAIL_FILE}"; then
    fail2ban_configured=true
fi

if file_present "${AUTO_UPGRADES_FILE}" && grep -q 'APT::Periodic::Unattended-Upgrade "1";' "${AUTO_UPGRADES_FILE}"; then
    updates_configured=true
fi

if file_present "${JOURNALD_FILE}" && grep -q '^Storage=persistent$' "${JOURNALD_FILE}"; then
    journald_persistent=true
fi

if [[ "$(package_state auditd)" == installed ]]; then
    auditd_present=true
fi

print_section "SSH"
print_kv "Hardened config" "$(yes_no "${ssh_hardened}")"
print_kv "Password auth" "${PASSWORD_AUTH:-unknown}"
print_kv "SSH port" "${SSH_PORT:-unknown}"
print_kv "AllowUsers" "${ALLOW_USERS:-not set}"
print_kv "Config path" "${SSH_HARDENING_FILE}"
print_kv "Service" "ssh ($(service_state ssh))"
echo "Inspect: sshd -T | grep -E '^(port|passwordauthentication|allowusers) '"
echo "Inspect logs: journalctl -u ssh -n 50"

print_section "Firewall"
print_kv "UFW active" "$(yes_no "${ufw_active}")"
if [[ -n "${SSH_PORT}" ]]; then
    print_kv "Expected SSH rule" "${SSH_PORT}/tcp"
fi
if [[ -n "${WG_PORT}" ]]; then
    print_kv "Expected WG rule" "${WG_PORT}/udp"
fi
echo "Inspect: ufw status verbose"

print_section "WireGuard"
print_kv "Interface" "${WG_INTERFACE:-unknown}"
print_kv "UDP port" "${WG_PORT:-unknown}"
if [[ -n "${WG_INTERFACE}" ]]; then
    print_kv "Config path" "/etc/wireguard/${WG_INTERFACE}.conf"
    print_kv "Env path" "/etc/wireguard/${WG_INTERFACE}.env"
    print_kv "Service" "wg-quick@${WG_INTERFACE} ($(service_state "wg-quick@${WG_INTERFACE}"))"
    echo "Inspect: wg show ${WG_INTERFACE}"
    echo "Inspect logs: journalctl -u wg-quick@${WG_INTERFACE} -n 50"
else
    echo "Inspect: wg show"
fi

print_section "Fail2ban"
print_kv "Package" "$(package_state fail2ban)"
print_kv "Configured" "$(yes_no "${fail2ban_configured}")"
print_kv "Service" "fail2ban ($(service_state fail2ban))"
print_kv "Config path" "${FAIL2BAN_JAIL_FILE}"
echo "Inspect: fail2ban-client status"
echo "Inspect jail: fail2ban-client status sshd"
echo "Inspect logs: journalctl -u fail2ban -n 50"

print_section "Updates"
print_kv "Package" "$(package_state unattended-upgrades)"
print_kv "Configured" "$(yes_no "${updates_configured}")"
print_kv "Config path" "${AUTO_UPGRADES_FILE}"
echo "Inspect: apt-config dump | grep -i unattended"
echo "Inspect logs: journalctl -u unattended-upgrades -n 50"

print_section "Logging"
print_kv "Journald persistent" "$(yes_no "${journald_persistent}")"
print_kv "Journald config" "${JOURNALD_FILE}"
print_kv "Auditd package" "$(package_state auditd)"
print_kv "Auditd active" "$(service_state auditd)"
if [[ "${auditd_present}" == true ]]; then
    print_kv "Audit log path" "/var/log/audit/audit.log"
fi
echo "Inspect SSH logs: journalctl -S today -u ssh"
echo "Inspect auth failures: journalctl -S today | grep -i 'failed\|invalid'"
if [[ "${auditd_present}" == true ]]; then
    echo "Inspect audit: ausearch -m USER_AUTH -ts today"
fi