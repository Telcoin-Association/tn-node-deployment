#!/usr/bin/env bash
#
# install-ui.sh -- Install the Telcoin Node Manager UI on this server.
#
# Run as root ON THE NODE. Installs the Flask app under /opt/telcoin-ui and runs
# it as the unprivileged `telcoin-ui` system user. The UI binds to 127.0.0.1
# only; reach it over an SSH tunnel.
#
# Root access the UI gets, all through the sudoers drop-in /etc/sudoers.d/telcoin-ui
# written below:
#   - `systemctl start|stop|restart` on the node unit: the unified `telcoin`, or the
#     legacy `telcoin-observer` / `telcoin-validator`. No other systemctl command.
#   - A fixed list of subcommands of one root-owned helper,
#     /usr/local/sbin/telcoin-ui-helper: the helper API version, Jaeger and node
#     tracing, node updates and the restart count, node config edits, the
#     advertised node name, node-log truncation, rotation and cleanup, the Caddy
#     dashboard and public RPC sites, the three node firewall ports, first-time
#     node setup, the node metadata and add-on status, read-only docker queries,
#     and the internal IP. Most lines allow one exact call; lines ending in *
#     allow arguments, which the helper validates before it runs anything. The
#     helper runs root-owned copies of update-node.sh, edit-config.sh,
#     setup-node.sh, install-caddy.sh and firewall-setup.sh from
#     /opt/telcoin-ui-update.
#   - sudo passes the helper only TN_BLS_PASSPHRASE, TN_CADDY_PASSWORD and the
#     TN_SETUP_* setup values (env_keep), so secrets and setup values never reach
#     argv.
#
# The live sudoers file is replaced last, after everything it grants is
# installed (see step 11).
#
set -euo pipefail

readonly SCRIPT_VERSION="1.4.0"

INSTALL_DIR="/opt/telcoin-ui"
SVC_USER="telcoin-ui"
SUDOERS_FILE="/etc/sudoers.d/telcoin-ui"
# sudo skips files in /etc/sudoers.d whose names contain a dot, so the candidate
# built in step 5 is inert until step 11 renames it.
SUDOERS_TMP_TEMPLATE="/etc/sudoers.d/.telcoin-ui.XXXXXX"
SUDOERS_TMP=""
HELPER_DST="/usr/local/sbin/telcoin-ui-helper"
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

# Remove the sudoers candidate if the script stops before step 11 renames it.
remove_sudoers_candidate() {
    if [[ -n "${SUDOERS_TMP}" && -e "${SUDOERS_TMP}" ]]; then
        rm -f "${SUDOERS_TMP}"
    fi
}
trap remove_sudoers_candidate EXIT

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

# ---- 2. Python 3, pip and Flask ---------------------------------------------
# Before anything of the UI is touched: if Flask cannot be installed, the
# installer stops here and the running UI is left exactly as it was.
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

# --ignore-installed blinker: on Ubuntu the apt package `python3-blinker` is a
# distutils install pip cannot cleanly uninstall, so a plain `pip install flask`
# aborts with "Cannot uninstall blinker". Skip touching it and let Flask use the
# already-present version.
info "Installing Flask..."
pip3 install flask --break-system-packages --ignore-installed blinker >/dev/null 2>&1 \
    || pip3 install flask >/dev/null 2>&1 \
    || { err "Failed to install Flask -- the UI was not changed."; exit 1; }
ok "Flask installed"

# ---- 3. System user -----------------------------------------------------------
if id "${SVC_USER}" >/dev/null 2>&1; then
    ok "User ${SVC_USER} already exists"
else
    useradd --system --no-create-home --shell /usr/sbin/nologin "${SVC_USER}"
    ok "Created system user ${SVC_USER}"
fi

# ---- 4. Sources present, helper parses ----------------------------------------
for f in server.py requirements.txt static/index.html telcoin-ui-helper.sh telcoin-ui.service; do
    if [[ ! -f "${SRC_DIR}/${f}" ]]; then
        err "${SRC_DIR}/${f} is missing -- the UI was not changed. Fetch the full ui/ directory and run this again."
        exit 1
    fi
done
if ! bash -n "${SRC_DIR}/telcoin-ui-helper.sh"; then
    err "${SRC_DIR}/telcoin-ui-helper.sh does not parse -- the UI was not changed."
    exit 1
fi
ok "UI sources present in ${SRC_DIR}"

# ---- 5. Sudoers candidate (validated now, swapped in at step 11) --------------
# Built beside the live file under a dotted name, which sudo ignores, so nothing
# changes until step 11 renames it over /etc/sudoers.d/telcoin-ui. If visudo
# rejects it, the installer stops with the live file untouched.
#
# A line with no arguments after the subcommand allows exactly that call; a line
# ending in * allows any arguments, which the helper validates. Every line must
# match the helper argv ui/server.py sends, byte for byte.
info "Building sudoers whitelist for ${SUDOERS_FILE}..."
SUDOERS_TMP="$(mktemp "${SUDOERS_TMP_TEMPLATE}")"
cat > "${SUDOERS_TMP}" <<EOF
# Managed by install-ui.sh -- Telcoin Node Manager UI. Rewritten on every run.
# Grants ${SVC_USER} start/stop/restart on the node unit and the subcommands of
# the root-owned helper listed below, nothing else.
# Unified unit (post-unification installs: single \`telcoin.service\`).
${SVC_USER} ALL=(ALL) NOPASSWD: /bin/systemctl start telcoin
${SVC_USER} ALL=(ALL) NOPASSWD: /bin/systemctl stop telcoin
${SVC_USER} ALL=(ALL) NOPASSWD: /bin/systemctl restart telcoin
# legacy per-role units (pre-unification installs)
${SVC_USER} ALL=(ALL) NOPASSWD: /bin/systemctl start telcoin-observer
${SVC_USER} ALL=(ALL) NOPASSWD: /bin/systemctl stop telcoin-observer
${SVC_USER} ALL=(ALL) NOPASSWD: /bin/systemctl restart telcoin-observer
${SVC_USER} ALL=(ALL) NOPASSWD: /bin/systemctl start telcoin-validator
${SVC_USER} ALL=(ALL) NOPASSWD: /bin/systemctl stop telcoin-validator
${SVC_USER} ALL=(ALL) NOPASSWD: /bin/systemctl restart telcoin-validator
# Helper API version, so the UI can tell when the helper is older than it needs.
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper helper-version
# Observability helper -- the Jaeger container and the node's tracing flags.
# No arguments: the helper finds the node unit and wrapper itself.
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper jaeger-start
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper jaeger-stop
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper jaeger-status
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper tracing-enable
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper tracing-disable
# Update helper -- check/apply/discard take no arguments. update-prepare takes a
# <ref>; the ref value is wildcarded here but strictly validated
# (^[A-Za-z0-9._/-]+$) inside the helper before it is ever used.
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper update-check
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper update-prepare *
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper update-apply
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper update-discard
# Restart-count helper -- reads the (root-only) unit journal to count starts
# since the current install. No arguments.
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper restart-count
# Log-clear helper -- truncates the node log file (root-owned). No arguments.
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper log-clear
# Config helper -- config-set takes <field> <value>. Both are wildcarded here,
# but the field is checked against a fixed allowlist and the value against a
# per-field regex inside the helper before edit-config.sh runs.
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper config-set *
# Set-hostname helper -- writes the network-config 'hostname' (Advertised Node
# Name) and restarts the node. Value wildcarded here, charset-validated in the
# helper + server before use.
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper set-hostname *
# Set-logrotate helper -- rewrites /etc/logrotate.d/telcoin with the node-log
# rotation size (e.g. 1G). Value wildcarded, validated (^[0-9]+[KMG]$) in the
# helper + server.
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper set-logrotate *
# Clear-rotated helper -- deletes rotated node logs (*.log.N/.gz) only, never
# the live *.log. No args (fixed glob, can't be steered to another path).
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper clear-rotated
# Caddy (external dashboard access) helper -- status/dns-check/enable/disable.
# enable takes <domain> <username> (wildcarded, validated in the helper +
# install-caddy.sh); the password travels in TN_CADDY_PASSWORD (env_keep below).
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper caddy-status
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper caddy-dns-check *
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper caddy-enable *
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper caddy-disable
# Public RPC endpoint (Caddy) helper -- status/dns-check/enable/disable. enable
# takes <domain> [<inbound-public-ip>|-] [<dashboard-domain>] (wildcarded,
# validated in the helper + install-caddy.sh). NO password env_keep -- a public
# RPC endpoint has no auth.
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper rpc-status
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper rpc-dns-check *
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper rpc-enable *
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper rpc-disable
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
# Testnet add-ons status -- READ-ONLY (reads .node-meta + probes services). No
# arguments.
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper addons-status
# Node metadata -- READ-ONLY cat of the root-owned (mode 600) .node-meta so the
# unprivileged UI can resolve the data dir, network, etc. (no secrets in it).
# No arguments.
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper meta-cat
# (Node removal is intentionally NOT exposed in the UI -- it is irreversible and
# runs on the server via remove-node.sh -- so the telcoin-ui user gets no
# node-remove grant.)
# Setup helper -- no arguments. All config travels in TN_SETUP_* env vars and
# the BLS passphrase in TN_BLS_PASSPHRASE; env_keep preserves them across sudo
# so NO config or secret is ever placed in argv. The helper validates every
# value before invoking setup-node.sh --json.
Defaults!/usr/local/sbin/telcoin-ui-helper env_keep += "TN_BLS_PASSPHRASE TN_CADDY_PASSWORD TN_SETUP_NETWORK TN_SETUP_INSTALL_METHOD TN_SETUP_PASSPHRASE_METHOD TN_SETUP_ADDRESS TN_SETUP_BUILD_REF TN_SETUP_DOCKER_IMAGE TN_SETUP_EXT_PRIMARY TN_SETUP_EXT_WORKER TN_SETUP_LIS_PRIMARY TN_SETUP_LIS_WORKER TN_SETUP_PUBLIC_IP TN_SETUP_RPC_DOMAIN TN_SETUP_SERVICE_USER TN_SETUP_SERVICE_GROUP TN_SETUP_ADVERTISED_NAME TN_SETUP_DATA_DIR"
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper setup-keygen
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper setup-finalize
# Docker-detection helper -- READ-ONLY observation of an externally-deployed
# (dev-team docker) node. docker-detect takes no args; the others take a
# container name (wildcarded here, charset-validated inside the helper). None of
# these can start/stop/mutate a container or the host.
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper docker-detect
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper docker-status *
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper docker-logs *
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper docker-logs-full *
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper docker-node-info *
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper docker-stats *
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper docker-log-size *
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper internal-ip
# TRANSITIONAL: removed once ui/server.py 1.9.0 ships.
# ui/server.py before 1.9.0 puts observer|validator ahead of the arguments of
# these 14 node subcommands, and the no-argument lines above match only the call
# without it. The helper drops the role argument and resolves the node itself.
# The six lines ending in * are also covered by the wildcard lines above; they
# stay so this block is removed in one piece.
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper tracing-enable observer
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper tracing-enable validator
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper tracing-disable observer
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper tracing-disable validator
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper update-check observer
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper update-check validator
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper update-prepare observer *
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper update-prepare validator *
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper update-apply observer
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper update-apply validator
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper update-discard observer
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper update-discard validator
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper restart-count observer
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper restart-count validator
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper log-clear observer
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper log-clear validator
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper config-set observer *
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper config-set validator *
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper set-hostname observer *
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper set-hostname validator *
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper addons-status observer
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper addons-status validator
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper meta-cat observer
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper meta-cat validator
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper setup-keygen observer
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper setup-keygen validator
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper setup-finalize observer
${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper setup-finalize validator
# END TRANSITIONAL
EOF
chmod 440 "${SUDOERS_TMP}"
if visudo -cf "${SUDOERS_TMP}" >/dev/null 2>&1; then
    ok "Sudoers whitelist validated (installed at step 11)"
else
    err "Sudoers validation failed -- ${SUDOERS_FILE} and the UI were not changed."
    exit 1
fi

# ---- 6. Privileged helper (root-owned, OUTSIDE /opt/telcoin-ui) ---------------
# Installed to /usr/local/sbin so the `chown -R telcoin-ui ${INSTALL_DIR}` below
# can never make it user-writable. This is the single privileged entry point the
# sudoers drop-in names. Written beside the live helper and renamed over it, so
# a sudo call never sees a half-written file. It accepts the old call form (with
# observer|validator) and the new one, so it works with either sudoers file.
info "Installing privileged helper ${HELPER_DST}..."
install -o root -g root -m 0755 "${SRC_DIR}/telcoin-ui-helper.sh" "${HELPER_DST}.new"
mv -f "${HELPER_DST}.new" "${HELPER_DST}"
ok "Helper installed (root:root 0755)"

# ---- 7. Engine scripts (root-owned, OUTSIDE /opt/telcoin-ui) ------------------
# Ship update-node.sh + its lib/ so the helper can drive the non-interactive
# --json updater. Root-owned and outside the user-writable UI dir, so the
# `chown -R telcoin-ui` below can never make the update path user-writable.
UPDATE_DIR="/opt/telcoin-ui-update"
REPO_DIR="$(cd "${SRC_DIR}/.." && pwd)"
install -o root -g root -m 0755 -d "${UPDATE_DIR}" "${UPDATE_DIR}/lib"
if [[ -f "${REPO_DIR}/update-node.sh" && -f "${REPO_DIR}/lib/common.sh" && -f "${REPO_DIR}/lib/fallback.sh" ]]; then
    info "Installing update engine to ${UPDATE_DIR}..."
    install -o root -g root -m 0755 "${REPO_DIR}/update-node.sh" "${UPDATE_DIR}/update-node.sh"
    install -o root -g root -m 0644 "${REPO_DIR}/lib/common.sh"  "${UPDATE_DIR}/lib/common.sh"
    # common.sh sources lib/fallback.sh under `set -e`, so any helper-driven script
    # that sources it (e.g. install-caddy.sh) aborts at source time unless fallback.sh
    # is shipped alongside. Ship it next to common.sh in the same engine lib dir.
    install -o root -g root -m 0644 "${REPO_DIR}/lib/fallback.sh" "${UPDATE_DIR}/lib/fallback.sh"
    ok "Update engine installed (root:root)"
else
    warn "update-node.sh / lib/common.sh / lib/fallback.sh not found beside install-ui.sh -- the UI Update tab will be unavailable until they are present."
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

# firewall-setup.sh, setup-node.sh and install-caddy.sh drive the UI's Firewall,
# Setup and Caddy features via their --json modes; remove-node.sh is shipped
# beside them. Same root-owned dir / pattern as edit-config.sh.
for s in firewall-setup.sh remove-node.sh setup-node.sh install-caddy.sh; do
    if [[ -f "${REPO_DIR}/${s}" ]]; then
        install -o root -g root -m 0755 "${REPO_DIR}/${s}" "${UPDATE_DIR}/${s}"
        ok "${s} installed to ${UPDATE_DIR} (root:root)"
    else
        warn "${s} not found beside install-ui.sh -- the related UI feature will be unavailable until it is present."
    fi
done
# The helper calls setup-node.sh directly now. Remove the copies of the two
# deprecated setup shims that earlier versions of this installer shipped.
for s in setup-observer.sh setup-validator.sh; do
    if [[ -e "${UPDATE_DIR}/${s}" ]]; then
        rm -f "${UPDATE_DIR}/${s}"
        ok "Removed stale ${UPDATE_DIR}/${s}"
    fi
done

# ---- 8. UI files and ownership ------------------------------------------------
info "Installing UI files to ${INSTALL_DIR}..."
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
chown -R "${SVC_USER}:${SVC_USER}" "${INSTALL_DIR}"
ok "UI files copied to ${INSTALL_DIR} (owner ${SVC_USER})"

# ---- 9. Node-log rotation -----------------------------------------------------
# Seed a logrotate config for the node logs so /var/log/telcoin doesn't grow
# unbounded (the unit appends). Default 1G; PRESERVE an existing file so an
# operator's custom size (set from the UI) survives UI updates. copytruncate is
# required because the node holds the log open.
LOGROTATE_CONF="/etc/logrotate.d/telcoin"
if [[ -f "${LOGROTATE_CONF}" ]]; then
    ok "Node-log rotation already configured (${LOGROTATE_CONF}) -- left as-is"
else
    cat > "${LOGROTATE_CONF}" <<'LREOF'
# Managed by the Telcoin Node Manager. Node logs rotate when they reach 'size'.
/var/log/telcoin/*.log {
    size 1G
    rotate 3
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
}
LREOF
    chmod 644 "${LOGROTATE_CONF}"
    ok "Node-log rotation configured: rotate at 1G (${LOGROTATE_CONF})"
fi

# ---- 10. systemd unit and daemon-reload ---------------------------------------
info "Installing systemd unit ${UNIT_DST}..."
cp "${SRC_DIR}/telcoin-ui.service" "${UNIT_DST}"
systemctl daemon-reload
ok "Unit installed, systemd reloaded"

# ---- 11. Swap in the sudoers whitelist ----------------------------------------
# Last, because the helper from step 6 accepts both call forms and the sudoers
# file does not. The states an interrupted run can leave:
#   - Stopped in steps 2 to 5: nothing live changed.
#   - Stopped after step 6: old sudoers, new helper. The running server keeps
#     working. If a newer server.py on disk is started later, its helper-version
#     call is refused and the UI banner says to re-run this installer.
#   - Between this rename and the restart in step 12, a server.py that still sends
#     observer|validator is refused once the TRANSITIONAL lines are gone, for
#     under a second.
# Open browser tabs keep working throughout: routes and payloads are unchanged.
# Node resolution needs no sudoers change: a box with one legacy unit resolves to
# it, and a box with both legacy units targets telcoin-validator, as
# lib/fallback.sh does.
mv -f "${SUDOERS_TMP}" "${SUDOERS_FILE}"
SUDOERS_TMP=""
ok "Sudoers whitelist installed: ${SUDOERS_FILE}"

# ---- 12. Start / restart / enable, then access instructions -------------------
echo ""
if [[ $UPDATE_MODE -eq 1 || $WAS_ACTIVE -eq 1 ]]; then
    # Update path (or a re-run over a live service): restart to load the new
    # code, and leave the enabled-on-boot state exactly as the operator set it.
    systemctl restart telcoin-ui && ok "telcoin-ui restarted (new code loaded)"
    verify_started
else
    # Fresh install: ask the operator what they want. The answers are lowercased
    # with tr because bash 3.2 has no case-changing expansion.
    read -r -p "Start the UI now? [Y/n] " start_now
    start_now="$(printf '%s' "$start_now" | tr '[:upper:]' '[:lower:]')"
    if [[ ! "$start_now" =~ ^n ]]; then
        systemctl start telcoin-ui && ok "telcoin-ui started"
        verify_started
    fi
    read -r -p "Enable the UI on boot? [Y/n] " enable_boot
    enable_boot="$(printf '%s' "$enable_boot" | tr '[:upper:]' '[:lower:]')"
    if [[ ! "$enable_boot" =~ ^n ]]; then
        systemctl enable telcoin-ui >/dev/null 2>&1 && ok "telcoin-ui enabled on boot"
    fi
fi

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
