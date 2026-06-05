#!/usr/bin/env bash
#
# open-ui.sh -- Open the Telcoin Node Manager UI from your LOCAL machine.
#
# Runs on your laptop/workstation, NOT on the node. Opens an SSH tunnel to the
# server's localhost:8080 and launches your browser. Works on macOS, Linux, and
# Windows (Git Bash / WSL). Ctrl+C closes the tunnel.
#
#   Usage:  ./open-ui.sh user@SERVER_IP
#           ./open-ui.sh            (prompts for the target)
#
set -euo pipefail

PORT=8080
URL="http://localhost:${PORT}"

c_green='\033[0;32m'; c_blue='\033[0;34m'; c_yellow='\033[1;33m'; c_off='\033[0m'

TARGET="${1:-}"
if [[ -z "$TARGET" ]]; then
    read -r -p "Enter SSH target (user@SERVER_IP): " TARGET
fi
if [[ -z "$TARGET" ]]; then
    echo "No target provided. Exiting." >&2
    exit 1
fi

# Open the browser (best effort -- tunnel proceeds regardless).
open_browser() {
    case "$(uname -s)" in
        Darwin*) open "$URL" >/dev/null 2>&1 || true ;;
        Linux*)  xdg-open "$URL" >/dev/null 2>&1 || true ;;
        MINGW*|MSYS*|CYGWIN*) start "$URL" >/dev/null 2>&1 || true ;;
        *) echo -e "${c_yellow}Open ${URL} in your browser manually.${c_off}" ;;
    esac
}

echo ""
echo -e "${c_green}Telcoin Node Manager -- SSH tunnel${c_off}"
echo -e "  Target:  ${c_blue}${TARGET}${c_off}"
echo -e "  Tunnel:  localhost:${PORT}  ->  ${TARGET} : 127.0.0.1:${PORT}"
echo -e "  Browser: ${c_blue}${URL}${c_off}"
echo ""
echo -e "  ${c_yellow}Press Ctrl+C to close the tunnel.${c_off}"
echo ""

# Give the tunnel a moment to come up before opening the browser.
( sleep 2; open_browser ) &

# -N: no remote command, just forward. Exec replaces this shell so Ctrl+C goes
# straight to ssh and tears the tunnel down cleanly.
exec ssh -N -L "${PORT}:localhost:${PORT}" "${TARGET}"
