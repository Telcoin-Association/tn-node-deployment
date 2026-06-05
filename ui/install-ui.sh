#!/usr/bin/env bash
#
# install-ui.sh -- Install the Telcoin Node Manager UI on this server.
#
# Run as root ON THE NODE. Installs the Flask app under /opt/telcoin-ui, runs
# it as an unprivileged `telcoin-ui` system user, and grants that user ONLY the
# six `systemctl start|stop|restart telcoin-{observer,validator}` commands via a
# locked-down sudoers drop-in. The UI binds to 127.0.0.1 only; reach it over an
# SSH tunnel.
#
set -euo pipefail

readonly SCRIPT_VERSION="1.0.0"

INSTALL_DIR="/opt/telcoin-ui"
SVC_USER="telcoin-ui"
SUDOERS_FILE="/etc/sudoers.d/telcoin-ui"
UNIT_DST="/etc/systemd/system/telcoin-ui.service"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Non-interactive update mode (used by update-scripts.sh): skips the start/enable
# prompts and always restarts the service so new code loads. All copy / helper /
# sudoers / unit / daemon-reload steps below are idempotent and run regardless.
UPDATE_MODE=0
if [[ "${1:-}" == "--update" ]]; then
    UPDATE_MODE=1
fi

c_green='\033[0;32m'; c_red='\033[0;31m'; c_blue='\033[0;34m'; c_yellow='\033[1;33m'; c_off='\033[0m'
ok()   { echo -e "${c_green}[OK]${c_off}   $*"; }
info() { echo -e "${c_blue}[INFO]${c_off} $*"; }
warn() { echo -e "${c_yellow}[WARN]${c_off} $*"; }
err()  { echo -e "${c_red}[ERROR]${c_off} $*" >&2; }

# ---- 1. Root check ----------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    err "This installer must be run as root (try: sudo bash install-ui.sh)"
    exit 1
fi

echo ""
info "Installing Telcoin Node Manager UI"
echo ""

# Remember whether the service was already running so we can restart it (to load
# the new code) even outside --update mode -- a plain re-run should not silently
# leave the old process serving stale files.
WAS_ACTIVE=0
if systemctl is-active --quiet telcoin-ui 2>/dev/null; then
    WAS_ACTIVE=1
fi

# ---- 2. Python 3 + pip ------------------------------------------------------
if ! command -v python3 >/dev/null 2>&1; then
    info "Installing python3..."
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq && apt-get install -y python3 python3-pip
    else
        err "python3 not found and apt-get unavailable -- install Python 3 manually."
        exit 1
    fi
fi
if ! command -v pip3 >/dev/null 2>&1; then
    info "Installing python3-pip..."
    command -v apt-get >/dev/null 2>&1 && apt-get install -y python3-pip || true
fi
ok "Python 3 present: $(python3 --version 2>&1)"

# ---- 3 & 4. Create dir + copy files ----------------------------------------
info "Creating ${INSTALL_DIR}..."
mkdir -p "${INSTALL_DIR}/static"
cp "${SRC_DIR}/server.py"          "${INSTALL_DIR}/server.py"
cp "${SRC_DIR}/requirements.txt"   "${INSTALL_DIR}/requirements.txt"
cp "${SRC_DIR}/static/index.html"  "${INSTALL_DIR}/static/index.html"
ok "UI files copied to ${INSTALL_DIR}"

# ---- 4b. Privileged helper (root-owned, OUTSIDE /opt/telcoin-ui) ------------
# Installed to /usr/local/sbin so the `chown -R telcoin-ui ${INSTALL_DIR}` below
# can never make it user-writable. This is the single privileged entry point
# for Jaeger / tracing operations; the sudoers drop-in pins exactly its args.
HELPER_DST="/usr/local/sbin/telcoin-ui-helper"
info "Installing privileged helper ${HELPER_DST}..."
install -o root -g root -m 0755 "${SRC_DIR}/telcoin-ui-helper.sh" "${HELPER_DST}"
ok "Helper installed (root:root 0755)"

# ---- 5. Install Flask -------------------------------------------------------
info "Installing Flask..."
pip3 install flask --break-system-packages >/dev/null 2>&1 \
    || pip3 install flask >/dev/null 2>&1 \
    || { err "Failed to install Flask"; exit 1; }
ok "Flask installed"

# ---- 6. Create system user --------------------------------------------------
if id "${SVC_USER}" >/dev/null 2>&1; then
    ok "User ${SVC_USER} already exists"
else
    useradd --system --no-create-home --shell /usr/sbin/nologin "${SVC_USER}"
    ok "Created system user ${SVC_USER}"
fi

# ---- 7. Sudoers whitelist (only the six service-control commands) -----------
info "Writing sudoers whitelist ${SUDOERS_FILE}..."
cat > "${SUDOERS_FILE}" <<EOF
# Managed by install-ui.sh -- Telcoin Node Manager UI.
# Grants ${SVC_USER} ONLY start/stop/restart on the two node services.
${SVC_USER} ALL=(ALL) NOPASSWD: /bin/systemctl start telcoin-observer
${SVC_USER} ALL=(ALL) NOPASSWD: /bin/systemctl stop telcoin-observer
${SVC_USER} ALL=(ALL) NOPASSWD: /bin/systemctl restart telcoin-observer
${SVC_USER} ALL=(ALL) NOPASSWD: /bin/systemctl start telcoin-validator
${SVC_USER} ALL=(ALL) NOPASSWD: /bin/systemctl stop telcoin-validator
${SVC_USER} ALL=(ALL) NOPASSWD: /bin/systemctl restart telcoin-validator
# Observability helper -- one root-owned script, explicit no-wildcard args.
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper jaeger-start
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper jaeger-stop
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper jaeger-status
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper tracing-enable observer
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper tracing-enable validator
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper tracing-disable observer
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper tracing-disable validator
EOF
chmod 440 "${SUDOERS_FILE}"
if visudo -cf "${SUDOERS_FILE}" >/dev/null 2>&1; then
    ok "Sudoers file validated"
else
    err "Sudoers validation failed -- removing ${SUDOERS_FILE}"
    rm -f "${SUDOERS_FILE}"
    exit 1
fi

# ---- 8. Ownership -----------------------------------------------------------
chown -R "${SVC_USER}:${SVC_USER}" "${INSTALL_DIR}"
ok "Ownership set to ${SVC_USER}"

# ---- 9. systemd unit --------------------------------------------------------
info "Installing systemd unit ${UNIT_DST}..."
cp "${SRC_DIR}/telcoin-ui.service" "${UNIT_DST}"
ok "Unit installed"

# ---- 10. daemon-reload ------------------------------------------------------
systemctl daemon-reload
ok "systemd reloaded"

# ---- 11. Start / restart / enable -------------------------------------------
echo ""
if [[ $UPDATE_MODE -eq 1 || $WAS_ACTIVE -eq 1 ]]; then
    # Update path (or a re-run over a live service): restart to load the new
    # code, and leave the enabled-on-boot state exactly as the operator set it.
    systemctl restart telcoin-ui && ok "telcoin-ui restarted (new code loaded)"
else
    # Fresh install: ask the operator what they want.
    read -r -p "Start the UI now? [Y/n] " start_now
    if [[ ! "${start_now,,}" =~ ^n ]]; then
        systemctl start telcoin-ui && ok "telcoin-ui started"
    fi
    read -r -p "Enable the UI on boot? [Y/n] " enable_boot
    if [[ ! "${enable_boot,,}" =~ ^n ]]; then
        systemctl enable telcoin-ui >/dev/null 2>&1 && ok "telcoin-ui enabled on boot"
    fi
fi

# ---- 12. Access instructions ------------------------------------------------
SERVER_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
echo ""
echo -e "${c_green}============================================================${c_off}"
echo -e "${c_green} Telcoin Node Manager UI installed${c_off}"
echo -e "${c_green}============================================================${c_off}"
echo ""
echo "The UI listens on 127.0.0.1:8080 (localhost only). Access it from your"
echo "local machine over an SSH tunnel:"
echo ""
echo -e "    ${c_blue}ssh -L 8080:localhost:8080 ${USER:-user}@${SERVER_IP:-YOUR_SERVER_IP}${c_off}"
echo ""
echo "Then open in your browser:"
echo ""
echo -e "    ${c_blue}http://localhost:8080${c_off}"
echo ""
echo "Service management:"
echo "    systemctl status telcoin-ui"
echo "    journalctl -u telcoin-ui -f"
echo ""
