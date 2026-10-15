#!/usr/bin/env bash
#
# open-ui.sh -- Open the Telcoin Node Manager UI from your LOCAL machine.
#
# Runs on your laptop/workstation, NOT on the node. Reads the UI access token
# over SSH (sudo cat /etc/telcoin-ui/token), opens an SSH tunnel to the server's
# 127.0.0.1:8080 and launches your browser at http://127.0.0.1:8080/#t=<token>.
# The token travels in the URL fragment, which the browser never sends to the
# server. Works on macOS, Linux, and Windows (Git Bash / WSL). Ctrl+C closes the
# tunnel.
#
#   Usage:  ./open-ui.sh user@SERVER_IP
#           ./open-ui.sh            (prompts for the target)
#
# The tunnel listens on 127.0.0.1 only, and the browser opens that same address
# (not "localhost", which may resolve to ::1 first and reach a different
# listener). If another local process already holds 127.0.0.1:8080, the tunnel
# fails (ExitOnForwardFailure) and no browser opens, so a page squatting on the
# port never receives the token.
#
set -euo pipefail

PORT=8080
LOCAL_HOST="127.0.0.1"
URL="http://${LOCAL_HOST}:${PORT}"

c_green='\033[0;32m'; c_blue='\033[0;34m'; c_yellow='\033[1;33m'; c_red='\033[0;31m'; c_off='\033[0m'

TARGET="${1:-}"
if [[ -z "$TARGET" ]]; then
    read -r -p "Enter SSH target (user@SERVER_IP): " TARGET
fi
if [[ -z "$TARGET" ]]; then
    echo "No target provided. Exiting." >&2
    exit 1
fi
case "$TARGET" in
    -*) echo "The SSH target may not start with '-'." >&2; exit 1 ;;
esac

# Open the browser (best effort -- tunnel proceeds regardless).
open_browser() {
    local u="$1"
    case "$(uname -s)" in
        Darwin*) open "$u" >/dev/null 2>&1 || true ;;
        Linux*)  xdg-open "$u" >/dev/null 2>&1 || true ;;
        MINGW*|MSYS*|CYGWIN*) start "" "$u" >/dev/null 2>&1 || true ;;
        *) echo -e "${c_yellow}Open ${URL}/#t=<token> in your browser manually.${c_off}" ;;
    esac
}

# Read the token: first without a password (sudo -n), then with a terminal so
# sudo can ask for one. Its prompt is not shown while the output is captured;
# type the password and press Enter. The token is the last line printed.
echo -e "Reading the UI access token from ${c_blue}${TARGET}${c_off}..."
TOKEN="$(ssh -- "$TARGET" 'sudo -n cat /etc/telcoin-ui/token' 2>/dev/null | tr -d '\r' | tail -n 1 || true)"
if [[ ! "$TOKEN" =~ ^[0-9a-f]{64}$ ]]; then
    echo -e "${c_yellow}sudo on ${TARGET} needs your password: type it (it is not shown) and press Enter.${c_off}"
    TOKEN="$(ssh -t -- "$TARGET" 'sudo cat /etc/telcoin-ui/token' | tr -d '\r' | tail -n 1 || true)"
fi
if [[ ! "$TOKEN" =~ ^[0-9a-f]{64}$ ]]; then
    echo -e "${c_red}Could not read the UI token from ${TARGET}.${c_off} Is the UI installed (sudo bash ui/install-ui.sh)?" >&2
    exit 1
fi

echo ""
echo -e "${c_green}Telcoin Node Manager -- SSH tunnel${c_off}"
echo -e "  Target:  ${c_blue}${TARGET}${c_off}"
echo -e "  Tunnel:  ${LOCAL_HOST}:${PORT}  ->  ${TARGET} : 127.0.0.1:${PORT}"
echo -e "  Browser: ${c_blue}${URL}${c_off}"
echo ""
echo -e "  ${c_yellow}Press Ctrl+C to close the tunnel.${c_off}"
echo ""

# Open the browser only once the tunnel is up: ssh -f backgrounds itself after
# the forward is established (ExitOnForwardFailure makes a busy local port an
# error instead), then the foreground wait keeps Ctrl+C closing it.
CTL="$(mktemp -u "${TMPDIR:-/tmp}/tn-ui-ssh.XXXXXX")"
if ! ssh -f -N -M -S "$CTL" -o ExitOnForwardFailure=yes \
        -L "${LOCAL_HOST}:${PORT}:127.0.0.1:${PORT}" -- "$TARGET"; then
    echo -e "${c_red}The tunnel did not start.${c_off} Is something on this machine already using port ${PORT}?" >&2
    exit 1
fi
close_tunnel() { ssh -S "$CTL" -O exit -- "$TARGET" >/dev/null 2>&1 || true; }
trap close_tunnel EXIT INT TERM

open_browser "${URL}/#t=${TOKEN}"
unset TOKEN

# Wait until Ctrl+C or the tunnel ends.
while ssh -S "$CTL" -O check -- "$TARGET" >/dev/null 2>&1; do
    sleep 2
done
