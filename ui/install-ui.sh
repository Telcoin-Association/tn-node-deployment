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

readonly SCRIPT_VERSION="1.2.7"

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

# After a start/restart, confirm the service actually came up. The most common
# silent failure is a leftover hand-run `python3 server.py` already holding
# 127.0.0.1:8080, which makes telcoin-ui crash-loop on "Address already in use".
# Detect a FOREIGN holder of 8080 and surface an actionable error instead of
# leaving a quiet crash-loop. Never auto-kill (unsafe -- could be unrelated).
verify_started() {
    if systemctl is-active --quiet telcoin-ui 2>/dev/null; then
        return 0
    fi
    err "telcoin-ui did not become active after start/restart."
    # Who owns 8080? ss -H = no header; pick the first holder.
    local holder
    holder="$(ss -ltnpH 'sport = :8080' 2>/dev/null | head -n1)"
    if [[ -n "$holder" ]]; then
        local who="${holder##*users:}"
        warn "Port 8080 is held by another process: ${who:-$holder}"
        warn "If this is a hand-run 'python3 server.py', stop it, then:"
        warn "    systemctl restart telcoin-ui"
    fi
    warn "Recent telcoin-ui logs:"
    journalctl -u telcoin-ui -n 5 --no-pager 2>/dev/null || true
}

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
# Brand logo (optional). Flask serves /static/* from this dir; the UI falls back
# to a built-in "TN" badge if the file is absent. Prefer the local copy; if it is
# missing (e.g. update-scripts.sh shipped the bundle before it knew about the
# logo), self-heal by fetching it straight from the repo so the deploy is not
# coupled to the updater's bootstrap timing.
LOGO_DST="${INSTALL_DIR}/static/telcoin-logo.png"
LOGO_URL="https://raw.githubusercontent.com/Telcoin-Association/tn-node-deployment/main/ui/static/telcoin-logo.png"
if [[ -f "${SRC_DIR}/static/telcoin-logo.png" ]]; then
    cp "${SRC_DIR}/static/telcoin-logo.png" "${LOGO_DST}"
elif [[ ! -f "${LOGO_DST}" ]]; then
    curl -sf --max-time 20 "${LOGO_URL}" -o "${LOGO_DST}" \
        && ok "Brand logo fetched from repo" \
        || warn "Could not fetch brand logo -- UI will show the fallback badge"
fi
ok "UI files copied to ${INSTALL_DIR}"

# ---- 4b. Privileged helper (root-owned, OUTSIDE /opt/telcoin-ui) ------------
# Installed to /usr/local/sbin so the `chown -R telcoin-ui ${INSTALL_DIR}` below
# can never make it user-writable. This is the single privileged entry point
# for Jaeger / tracing operations; the sudoers drop-in pins exactly its args.
HELPER_DST="/usr/local/sbin/telcoin-ui-helper"
info "Installing privileged helper ${HELPER_DST}..."
install -o root -g root -m 0755 "${SRC_DIR}/telcoin-ui-helper.sh" "${HELPER_DST}"
ok "Helper installed (root:root 0755)"

# ---- 4c. Update engine (root-owned, OUTSIDE /opt/telcoin-ui) ----------------
# Ship update-node.sh + its lib/ so the helper can drive the non-interactive
# --json updater. Root-owned and outside the user-writable UI dir, so the
# `chown -R telcoin-ui` below can never make the update path user-writable.
UPDATE_DIR="/opt/telcoin-ui-update"
REPO_DIR="$(cd "${SRC_DIR}/.." && pwd)"
if [[ -f "${REPO_DIR}/update-node.sh" && -f "${REPO_DIR}/lib/common.sh" ]]; then
    info "Installing update engine to ${UPDATE_DIR}..."
    install -o root -g root -m 0755 -d "${UPDATE_DIR}" "${UPDATE_DIR}/lib"
    install -o root -g root -m 0755 "${REPO_DIR}/update-node.sh" "${UPDATE_DIR}/update-node.sh"
    install -o root -g root -m 0644 "${REPO_DIR}/lib/common.sh"  "${UPDATE_DIR}/lib/common.sh"
    ok "Update engine installed (root:root)"
else
    warn "update-node.sh / lib/common.sh not found beside install-ui.sh -- the UI Update tab will be unavailable until they are present."
fi

# edit-config.sh drives the UI's Config-edit feature via its --json mode (it
# sources lib/common.sh from the same dir, installed just above). Root-owned and
# outside the user-writable UI dir, like update-node.sh.
if [[ -f "${REPO_DIR}/edit-config.sh" ]]; then
    install -o root -g root -m 0755 "${REPO_DIR}/edit-config.sh" "${UPDATE_DIR}/edit-config.sh"
    ok "Config editor installed to ${UPDATE_DIR} (root:root)"
else
    warn "edit-config.sh not found beside install-ui.sh -- the UI Config-edit feature will be unavailable until it is present."
fi

# firewall-setup.sh + remove-node.sh + setup-*.sh drive the UI's Firewall,
# Danger Zone and Setup features via their --json modes. Same root-owned dir /
# pattern as edit-config.sh.
for s in firewall-setup.sh remove-node.sh setup-observer.sh setup-validator.sh; do
    if [[ -f "${REPO_DIR}/${s}" ]]; then
        install -o root -g root -m 0755 "${REPO_DIR}/${s}" "${UPDATE_DIR}/${s}"
        ok "${s} installed to ${UPDATE_DIR} (root:root)"
    else
        warn "${s} not found beside install-ui.sh -- the related UI feature will be unavailable until it is present."
    fi
done

# ---- 5. Install Flask -------------------------------------------------------
# --ignore-installed blinker: on Ubuntu the apt package `python3-blinker` is a
# distutils install pip cannot cleanly uninstall, so a plain `pip install flask`
# aborts with "Cannot uninstall blinker". Skip touching it and let Flask use the
# already-present version.
info "Installing Flask..."
pip3 install flask --break-system-packages --ignore-installed blinker >/dev/null 2>&1 \
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
# Update helper -- check/apply/discard take a fixed node-type arg. update-prepare
# also takes a <ref>; the ref value is wildcarded here but strictly validated
# (^[A-Za-z0-9._/-]+$) inside the helper before it is ever used.
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper update-check observer
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper update-check validator
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper update-prepare observer *
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper update-prepare validator *
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper update-apply observer
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper update-apply validator
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper update-discard observer
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper update-discard validator
# Restart-count helper -- reads the (root-only) unit journal to count starts
# since the current install. Fixed-arg, no wildcard.
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper restart-count observer
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper restart-count validator
# Log-clear helper -- truncates the node log file (root-owned). Fixed-arg.
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper log-clear observer
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper log-clear validator
# Config helper -- config-set takes <type> <field> <value>. The field+value are
# wildcarded here but the field is checked against a fixed allowlist and the
# value against a per-field regex inside the helper before edit-config.sh runs.
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper config-set observer *
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper config-set validator *
# Firewall helper -- read-only status, plus open/close for ONLY the three node
# ports. Enumerated fully (3 ports x on|off), so NO wildcard is needed. SSH /
# default-policy / password-auth are intentionally never reachable from here.
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper firewall-status
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper firewall-port 49590/udp on
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper firewall-port 49590/udp off
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper firewall-port 49594/udp on
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper firewall-port 49594/udp off
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper firewall-port 43174/tcp on
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper firewall-port 43174/tcp off
# Node-remove helper -- destructive. Enumerated (2 types x 3 scopes), no
# wildcard. The server requires a typed "DELETE" confirmation before calling.
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper node-remove observer service
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper node-remove observer data
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper node-remove observer keys
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper node-remove validator service
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper node-remove validator data
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper node-remove validator keys
# Setup helper -- fixed-arg (type only). All config travels in TN_SETUP_* env
# vars and the BLS passphrase in TN_BLS_PASSPHRASE; env_keep preserves them
# across sudo so NO config or secret is ever placed in argv. The helper
# validates every value before invoking setup-<type>.sh --json.
Defaults!/usr/local/sbin/telcoin-ui-helper env_keep += "TN_BLS_PASSPHRASE TN_SETUP_NETWORK TN_SETUP_INSTALL_METHOD TN_SETUP_PASSPHRASE_METHOD TN_SETUP_ADDRESS TN_SETUP_BUILD_REF TN_SETUP_DOCKER_IMAGE TN_SETUP_INSTANCE TN_SETUP_EXT_PRIMARY TN_SETUP_EXT_WORKER TN_SETUP_LIS_PRIMARY TN_SETUP_LIS_WORKER TN_SETUP_PUBLIC_IP"
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper setup-keygen observer
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper setup-keygen validator
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper setup-finalize observer
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper setup-finalize validator
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
    verify_started
else
    # Fresh install: ask the operator what they want.
    read -r -p "Start the UI now? [Y/n] " start_now
    if [[ ! "${start_now,,}" =~ ^n ]]; then
        systemctl start telcoin-ui && ok "telcoin-ui started"
        verify_started
    fi
    read -r -p "Enable the UI on boot? [Y/n] " enable_boot
    if [[ ! "${enable_boot,,}" =~ ^n ]]; then
        systemctl enable telcoin-ui >/dev/null 2>&1 && ok "telcoin-ui enabled on boot"
    fi
fi

# ---- 12. Access instructions ------------------------------------------------
echo ""
echo -e "${c_green}============================================================${c_off}"
echo -e "${c_green} Telcoin Node Manager UI installed${c_off}"
echo -e "${c_green}============================================================${c_off}"
echo ""
echo "The UI listens on 127.0.0.1:8080 (localhost only). Access it from your"
echo "local machine over an SSH tunnel."
echo ""
echo "Node Manager UI only:"
echo -e "    ${c_blue}ssh -L 8080:localhost:8080 user@<server-ip>${c_off}"
echo ""
echo "Jaeger tracing only:"
echo -e "    ${c_blue}ssh -L 16686:localhost:16686 user@<server-ip>${c_off}"
echo ""
echo "Both Node Manager UI and Jaeger tracing:"
echo -e "    ${c_blue}ssh -L 8080:localhost:8080 -L 16686:localhost:16686 user@<server-ip>${c_off}"
echo ""
echo "Add -p <port> if your server uses a non-default SSH port."
echo ""
echo "Then open in your browser:"
echo ""
echo -e "    Node Manager UI:  ${c_blue}http://localhost:8080${c_off}"
echo -e "    Jaeger tracing:   ${c_blue}http://localhost:16686${c_off}"
echo ""
echo "Service management:"
echo "    systemctl status telcoin-ui"
echo "    journalctl -u telcoin-ui -f"
echo ""
