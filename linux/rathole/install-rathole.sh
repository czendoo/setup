#!/usr/bin/env bash

set -euo pipefail

# This script prepares a Linux machine to run RatHole as a systemd service.
# It installs build dependencies, compiles RatHole from source, creates a
# dedicated non-admin service account, installs the binary, and enables either
# the server or client service using the config file that matches the role.

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

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_SOURCE="${SCRIPT_DIR}/config/${ROLE}.toml"
SERVICE_USER="rathole"
SERVICE_GROUP="rathole"
INSTALL_ROOT="/opt/rathole"
SOURCE_ROOT="${INSTALL_ROOT}/src"
RATHOLE_REPO="${SOURCE_ROOT}/rathole"
CONFIG_ROOT="/etc/rathole"
CONFIG_TARGET="${CONFIG_ROOT}/${ROLE}.toml"
SERVICE_NAME="rathole-${ROLE}.service"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}"

if [[ ! -f "$CONFIG_SOURCE" ]]; then
    echo "Missing config template: ${CONFIG_SOURCE}" >&2
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive

# Install the packages needed to build RatHole and link it against OpenSSL.
apt-get update
apt-get install -y git build-essential pkg-config libssl-dev curl ca-certificates

# Create a dedicated non-admin account for the systemd service.
if ! id -u "$SERVICE_USER" >/dev/null 2>&1; then
    useradd --create-home --home-dir "$INSTALL_ROOT" --shell /usr/sbin/nologin "$SERVICE_USER"
fi

install -d -m 0755 -o "$SERVICE_USER" -g "$SERVICE_GROUP" "$SOURCE_ROOT"
install -d -m 0755 "$CONFIG_ROOT"

# Install Rust for the service account and build RatHole in release mode.
runuser -u "$SERVICE_USER" -- bash -lc '
set -euo pipefail

if [[ ! -x "$HOME/.cargo/bin/rustup" ]]; then
    curl https://sh.rustup.rs -sSf | sh -s -- -y
fi

source "$HOME/.cargo/env"

if [[ ! -d "'"$RATHOLE_REPO"'/.git" ]]; then
    git clone https://github.com/rathole-org/rathole.git "'"$RATHOLE_REPO"'"
else
    git -C "'"$RATHOLE_REPO"'" fetch origin
    git -C "'"$RATHOLE_REPO"'" reset --hard origin/main
fi

cd "'"$RATHOLE_REPO"'"
cargo build --release
'

install -m 0755 "$RATHOLE_REPO/target/release/rathole" /usr/local/bin/rathole
install -m 0640 -o root -g "$SERVICE_GROUP" "$CONFIG_SOURCE" "$CONFIG_TARGET"

# Create a systemd unit that runs RatHole with the selected role config.
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=RatHole ${ROLE} service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_GROUP}
ExecStart=/usr/local/bin/rathole ${CONFIG_TARGET}
Restart=always
RestartSec=5
WorkingDirectory=${INSTALL_ROOT}

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now "$SERVICE_NAME"

echo "RatHole ${ROLE} installed."
echo "Service: ${SERVICE_NAME}"
echo "Config:  ${CONFIG_TARGET}"
echo "Status:  systemctl status ${SERVICE_NAME}"