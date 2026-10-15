#!/usr/bin/env bash
#
# install-ui.sh -- Install the Telcoin Node Manager UI on this server.
#
# Run as root ON THE NODE:
#   sudo bash ui/install-ui.sh                 install, or re-install over a running UI
#   sudo bash ui/install-ui.sh --update        non-interactive update (update-scripts.sh)
#   sudo bash ui/install-ui.sh --rotate-token  replace the UI access token and restart
#
# The Flask app runs as the unprivileged `telcoin-ui` system user and binds to
# 127.0.0.1:8080 only; reach it over an SSH tunnel (open-ui.sh). Everything it
# runs is root-owned:
#   - /opt/telcoin-ui        the app (server.py, static/), root:root, go-w
#   - /opt/telcoin-ui-venv   Python venv holding Flask, installed with
#                            pip --require-hashes from ui/requirements.txt
#   - /opt/telcoin-ui-update the engine scripts and lib/ the helper runs
#   - /usr/local/sbin/telcoin-ui-helper
# Each tree is built in a fresh root-only temp directory and renamed into
# place, so nothing is ever copied into a path the UI account can write. The
# service writes only its state directory, /var/lib/telcoin-ui.
#
# Access token: /etc/telcoin-ui/token (root:telcoin-ui 0640, 32 random bytes in
# hex), created on first install and replaced by --rotate-token. Every API call
# carries it in the X-TN-UI-Token header; open-ui.sh reads it over SSH and hands
# it to the browser in the URL fragment.
#
# Root access the UI gets, all through the sudoers drop-in /etc/sudoers.d/telcoin-ui
# written below:
#   - `systemctl start|stop|restart` on the node unit: the unified `telcoin`, or the
#     legacy `telcoin-observer` / `telcoin-validator`. No other systemctl command.
#   - A fixed list of subcommands of one root-owned helper,
#     /usr/local/sbin/telcoin-ui-helper. Most lines allow one exact call; lines
#     ending in * allow arguments, which the helper checks against a pattern per
#     argument before it runs anything.
#   - Secrets never pass through sudo: the server writes the BLS passphrase and
#     the dashboard password to the helper's stdin. Only the non-secret TN_SETUP_*
#     values are kept across sudo, and only for setup-keygen and setup-finalize.
#
# The live sudoers file is replaced last, after everything it grants is
# installed.
#
set -euo pipefail

readonly SCRIPT_VERSION="2.0.0"

INSTALL_DIR="/opt/telcoin-ui"
VENV_DIR="/opt/telcoin-ui-venv"
UPDATE_DIR="/opt/telcoin-ui-update"
STATE_DIR="/var/lib/telcoin-ui"
TOKEN_DIR="/etc/telcoin-ui"
TOKEN_FILE="${TOKEN_DIR}/token"
SVC_USER="telcoin-ui"
LOG_GROUP="telcoin-log"
SUDOERS_FILE="/etc/sudoers.d/telcoin-ui"
# sudo skips files in /etc/sudoers.d whose names contain a dot, so the candidate
# built in step 6 is inert until step 12 renames it.
SUDOERS_TMP_TEMPLATE="/etc/sudoers.d/.telcoin-ui.XXXXXX"
SUDOERS_TMP=""
HELPER_DST="/usr/local/sbin/telcoin-ui-helper"
UNIT_DST="/etc/systemd/system/telcoin-ui.service"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SRC_DIR}/.." && pwd)"
# Temp trees built by this run; removed on exit unless renamed into place.
TMP_TREES=()

MODE="install"
case "${1:-}" in
    "") ;;
    --update) MODE="update" ;;
    --rotate-token) MODE="rotate" ;;
    -h|--help)
        sed -n '3,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
        exit 0 ;;
    *) echo "Unknown option: $1 (use --update, --rotate-token or no option)" >&2; exit 2 ;;
esac
UPDATE_MODE=0
[[ "$MODE" == "update" ]] && UPDATE_MODE=1

c_green='\033[0;32m'; c_red='\033[0;31m'; c_blue='\033[0;34m'; c_yellow='\033[1;33m'; c_off='\033[0m'
ok()   { echo -e "${c_green}[OK]${c_off}   $*"; }
info() { echo -e "${c_blue}[INFO]${c_off} $*"; }
warn() { echo -e "${c_yellow}[WARN]${c_off} $*"; }
err()  { echo -e "${c_red}[ERROR]${c_off} $*" >&2; }

# Remove the sudoers candidate and any temp tree if the script stops before
# they are renamed into place.
cleanup() {
    local d
    if [[ -n "${SUDOERS_TMP}" && -e "${SUDOERS_TMP}" ]]; then
        rm -f "${SUDOERS_TMP}"
    fi
    for d in ${TMP_TREES[@]+"${TMP_TREES[@]}"}; do
        [[ -n "$d" && -d "$d" ]] && rm -rf -- "$d"
    done
    return 0
}
trap cleanup EXIT

# A root-only temp directory next to DEST (same filesystem, so the final rename
# is atomic). Prints its path.
new_tree() {
    local dest="$1" t
    t="$(mktemp -d "${dest%/*}/.${dest##*/}.XXXXXX")" || return 1
    TMP_TREES+=("$t")
    printf '%s\n' "$t"
}

# Rename the finished tree NEW over DEST. DEST may be absent, a directory or a
# symlink; whatever was there is moved aside first and removed after the new
# tree is in place. Readers see the old tree or the new one.
swap_tree() {
    local new="$1" dest="$2" old=""
    chown -R root:root "$new"
    chmod -R u=rwX,go=rX "$new"
    if [[ -e "$dest" || -L "$dest" ]]; then
        old="$(mktemp -u "${dest%/*}/.${dest##*/}.old.XXXXXX")"
        mv -T -- "$dest" "$old"
    fi
    if ! mv -T -- "$new" "$dest"; then
        [[ -n "$old" ]] && mv -T -- "$old" "$dest"
        return 1
    fi
    [[ -n "$old" ]] && rm -rf -- "$old"
    return 0
}

# Write stdin to DEST as root:GROUP with MODE through a temp file in the same
# directory and one rename. Uses the library's tn_write_root_file when this
# checkout has it; the fallback does the same steps.
write_file() {
    local dest="$1" mode="$2" group="${3:-root}" tmp
    if declare -F tn_write_root_file >/dev/null; then
        tn_write_root_file "$dest" "$mode" "$group"
        return
    fi
    [[ -L "$dest" || -d "$dest" ]] && { err "refusing to write ${dest}: symlink or directory"; return 1; }
    tmp="$(mktemp "${dest%/*}/.tn.XXXXXX")" || return 2
    if ! cat > "$tmp" || ! chown "root:${group}" "$tmp" || ! chmod "$mode" "$tmp" \
        || ! mv -f -T -- "$tmp" "$dest"; then
        rm -f -- "$tmp"
        return 2
    fi
}

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
    holder="$(ss -ltnpH 'sport = :8080' 2>/dev/null | head -n1 || true)"
    if [[ -n "$holder" ]]; then
        local who="${holder##*users:}"
        warn "Port 8080 is held by another process: ${who:-$holder}"
        warn "If this is a hand-run 'python3 server.py', stop it, then:"
        warn "    systemctl restart telcoin-ui"
    fi
    warn "Recent telcoin-ui logs:"
    journalctl -u telcoin-ui -n 5 --no-pager 2>/dev/null || true
}

# Create the token directory (root:telcoin-ui 0750) and, when ROTATE is 1 or
# there is no token yet, a new token: 32 bytes from /dev/urandom in hex, written
# root:telcoin-ui 0640. An existing token keeps its value; its owner and mode
# are reset.
ensure_token() {
    local rotate="$1" tok
    if [[ -L "$TOKEN_DIR" || ( -e "$TOKEN_DIR" && ! -d "$TOKEN_DIR" ) ]]; then
        err "${TOKEN_DIR} is not a plain directory -- remove it and run this again."
        return 1
    fi
    install -d -o root -g "$SVC_USER" -m 0750 "$TOKEN_DIR"
    if [[ -L "$TOKEN_FILE" ]]; then
        err "${TOKEN_FILE} is a symlink -- remove it and run this again."
        return 1
    fi
    if [[ "$rotate" == 1 || ! -s "$TOKEN_FILE" ]]; then
        tok="$(od -An -tx1 -N32 /dev/urandom | tr -d ' \n')"
        if [[ ! "$tok" =~ ^[0-9a-f]{64}$ ]]; then
            err "could not read 32 random bytes for the UI token"
            return 1
        fi
        printf '%s\n' "$tok" | write_file "$TOKEN_FILE" 0640 "$SVC_USER" || {
            err "could not write ${TOKEN_FILE}"
            return 1
        }
        ok "UI access token written: ${TOKEN_FILE} (root:${SVC_USER} 0640)"
    else
        chown "root:${SVC_USER}" "$TOKEN_FILE"
        chmod 0640 "$TOKEN_FILE"
        ok "UI access token kept: ${TOKEN_FILE}"
    fi
}

# ---- 1. Root check ----------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    err "This installer must be run as root (try: sudo bash install-ui.sh)"
    exit 1
fi
# The UI account must never drive its own installer or feed it files: refuse a
# sudo from it, and a checkout anyone but root or the operator who ran sudo can
# write. Every file and directory down to the depth this script reads from
# (lib/release-keys/*.asc, ui/static/*) must be a real file or directory owned
# by root or that operator, not writable by others, and writable by its group
# only when the group is root's or the operator's own primary group (a umask
# of 002 makes a checkout group-writable). Nothing from the checkout is read
# before these checks pass.
if [[ "${SUDO_USER:-}" == "$SVC_USER" ]]; then
    err "install-ui.sh refuses to run for the ${SVC_USER} account."
    exit 1
fi
OP_UID="${SUDO_UID:-0}"
OP_GID="${SUDO_GID:-0}"
if [[ ! "$OP_UID" =~ ^[0-9]+$ || ! "$OP_GID" =~ ^[0-9]+$ ]]; then
    err "SUDO_UID/SUDO_GID are not numeric; run this with sudo or as root."
    exit 1
fi
# A group the UI account belongs to never counts as the operator's own.
if id -G "$SVC_USER" 2>/dev/null | tr ' ' '\n' | grep -qx "$OP_GID"; then
    OP_GID=0
fi
if ! CHECKOUT_BAD="$(find -H "$REPO_DIR" -maxdepth 3 \( -type l -o -perm -002 \
        -o \( -perm -020 ! -group 0 ! -group "$OP_GID" \) \
        -o \( ! -user 0 ! -user "$OP_UID" \) \) -print -quit)"; then
    err "could not check the files under ${REPO_DIR}."
    exit 1
fi
if [[ -n "$CHECKOUT_BAD" ]]; then
    err "${CHECKOUT_BAD} is a symlink, or is owned or writable by an account other than root or the operator; install from a checkout only root or you can write."
    exit 1
fi

# The library brings tn_write_root_file (and, once present, other helpers this
# script prefers over its own fallbacks). Sourcing it turns on set -euo pipefail,
# which this script runs under anyway.
if [[ -f "${REPO_DIR}/lib/common.sh" ]]; then
    # shellcheck source=../lib/common.sh
    source "${REPO_DIR}/lib/common.sh"
fi

if [[ "$MODE" == "rotate" ]]; then
    id "${SVC_USER}" >/dev/null 2>&1 || { err "the UI is not installed (no ${SVC_USER} user)"; exit 1; }
    ensure_token 1
    if systemctl is-active --quiet telcoin-ui 2>/dev/null; then
        systemctl restart telcoin-ui && ok "telcoin-ui restarted with the new token"
        verify_started
    fi
    echo ""
    info "Open the UI again with open-ui.sh; links holding the old token stop working."
    exit 0
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

# ---- 2. Python venv with the hashed requirements --------------------------------
# Before anything of the UI is touched: if Flask cannot be installed, the
# installer stops here and the running UI is left exactly as it was. The venv is
# root-owned and holds only what ui/requirements.txt pins by hash
# (--require-hashes, wheels only). A stamp with the file's sha256 skips the
# install when nothing changed, so a routine update makes no PyPI request.
if ! command -v python3 >/dev/null 2>&1; then
    info "Installing python3..."
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq && apt-get install -y python3 python3-venv
    else
        err "python3 not found and apt-get unavailable -- install Python 3 manually."
        exit 1
    fi
fi
if ! python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)'; then
    err "Python 3.10 or later is required ($(python3 --version 2>&1) found) -- the UI was not changed."
    exit 1
fi
[[ -f "${SRC_DIR}/requirements.txt" ]] || { err "${SRC_DIR}/requirements.txt is missing -- the UI was not changed."; exit 1; }
REQ_SHA="$(sha256sum "${SRC_DIR}/requirements.txt" | awk '{print $1}')"
VENV_STAMP="${VENV_DIR}/.requirements.sha256"
venv_current() {
    [[ -d "$VENV_DIR" && ! -L "$VENV_DIR" && -x "${VENV_DIR}/bin/python" && -f "$VENV_STAMP" ]] || return 1
    [[ "$(stat -c '%u' "$VENV_DIR")" == 0 ]] || return 1
    [[ "$(cat "$VENV_STAMP" 2>/dev/null)" == "$REQ_SHA" ]] || return 1
    "${VENV_DIR}/bin/python" -c 'import flask' >/dev/null 2>&1
}
if venv_current; then
    ok "Python venv ${VENV_DIR} is current (requirements unchanged)"
else
    info "Building the Python venv ${VENV_DIR} from ui/requirements.txt (hashed)..."
    VENV_NEW="$(new_tree "$VENV_DIR")"
    if ! python3 -m venv "$VENV_NEW" >/dev/null 2>&1; then
        if command -v apt-get >/dev/null 2>&1; then
            apt-get install -y python3-venv >/dev/null 2>&1 || true
        fi
        rm -rf -- "$VENV_NEW" && mkdir -m 0700 "$VENV_NEW"
        python3 -m venv "$VENV_NEW" || { err "python3 -m venv failed (install python3-venv) -- the UI was not changed."; exit 1; }
    fi
    if ! "${VENV_NEW}/bin/python" -m pip install --no-cache-dir --disable-pip-version-check \
            --no-input --require-hashes --only-binary=:all: \
            -r "${SRC_DIR}/requirements.txt" >/dev/null; then
        err "Installing the hashed requirements failed -- the UI was not changed."
        exit 1
    fi
    "${VENV_NEW}/bin/python" -c 'import flask' || { err "Flask does not import from the new venv -- the UI was not changed."; exit 1; }
    printf '%s\n' "$REQ_SHA" > "${VENV_NEW}/.requirements.sha256"
    swap_tree "$VENV_NEW" "$VENV_DIR"
    ok "Python venv installed: ${VENV_DIR} (root:root)"
fi

# ---- 3. System user -----------------------------------------------------------
if id "${SVC_USER}" >/dev/null 2>&1; then
    ok "User ${SVC_USER} already exists"
else
    useradd --system --no-create-home --shell /usr/sbin/nologin "${SVC_USER}"
    ok "Created system user ${SVC_USER}"
fi
# Node logs are root:telcoin-log 0640 on current installs; the UI reads them as a
# member of that group. Older installs have no such group and need nothing.
if getent group "$LOG_GROUP" >/dev/null 2>&1; then
    usermod -aG "$LOG_GROUP" "$SVC_USER"
    ok "${SVC_USER} reads node logs as a member of ${LOG_GROUP}"
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
# ending in * allows any arguments, which the helper checks one by one against a
# fixed pattern. Every line must match the helper argv ui/server.py sends, byte
# for byte. No secret is kept across sudo: the passphrase and the dashboard
# password reach the helper on stdin.
info "Building sudoers whitelist for ${SUDOERS_FILE}..."
SUDOERS_TMP="$(mktemp "${SUDOERS_TMP_TEMPLATE}")"
cat > "${SUDOERS_TMP}" <<EOF
# Managed by install-ui.sh -- Telcoin Node Manager UI. Rewritten on every run.
# Grants ${SVC_USER} start/stop/restart on the node unit and the subcommands of
# the root-owned helper listed below, nothing else.
# Unified unit (post-unification installs: single \`telcoin.service\`).
${SVC_USER} ALL=(root) NOPASSWD: /bin/systemctl start telcoin
${SVC_USER} ALL=(root) NOPASSWD: /bin/systemctl stop telcoin
${SVC_USER} ALL=(root) NOPASSWD: /bin/systemctl restart telcoin
# legacy per-role units (pre-unification installs)
${SVC_USER} ALL=(root) NOPASSWD: /bin/systemctl start telcoin-observer
${SVC_USER} ALL=(root) NOPASSWD: /bin/systemctl stop telcoin-observer
${SVC_USER} ALL=(root) NOPASSWD: /bin/systemctl restart telcoin-observer
${SVC_USER} ALL=(root) NOPASSWD: /bin/systemctl start telcoin-validator
${SVC_USER} ALL=(root) NOPASSWD: /bin/systemctl stop telcoin-validator
${SVC_USER} ALL=(root) NOPASSWD: /bin/systemctl restart telcoin-validator
# Helper API version, so the UI can tell when the helper is older than it needs.
${SVC_USER} ALL=(root) NOPASSWD: /usr/local/sbin/telcoin-ui-helper helper-version
# Jaeger container and the node's tracing flags. No arguments.
${SVC_USER} ALL=(root) NOPASSWD: /usr/local/sbin/telcoin-ui-helper jaeger-start
${SVC_USER} ALL=(root) NOPASSWD: /usr/local/sbin/telcoin-ui-helper jaeger-stop
${SVC_USER} ALL=(root) NOPASSWD: /usr/local/sbin/telcoin-ui-helper jaeger-status
${SVC_USER} ALL=(root) NOPASSWD: /usr/local/sbin/telcoin-ui-helper tracing-enable
${SVC_USER} ALL=(root) NOPASSWD: /usr/local/sbin/telcoin-ui-helper tracing-disable
# Updates. update-prepare takes one release tag of the node's network
# (vX.Y.Z-adiri on testnet, vX.Y.Z on mainnet); the helper refuses anything else.
${SVC_USER} ALL=(root) NOPASSWD: /usr/local/sbin/telcoin-ui-helper update-check
${SVC_USER} ALL=(root) NOPASSWD: /usr/local/sbin/telcoin-ui-helper update-prepare *
${SVC_USER} ALL=(root) NOPASSWD: /usr/local/sbin/telcoin-ui-helper update-apply
${SVC_USER} ALL=(root) NOPASSWD: /usr/local/sbin/telcoin-ui-helper update-discard
# Read-only: restart count from the unit journal, and the committee quorum check
# behind the restart badge.
${SVC_USER} ALL=(root) NOPASSWD: /usr/local/sbin/telcoin-ui-helper restart-count
${SVC_USER} ALL=(root) NOPASSWD: /usr/local/sbin/telcoin-ui-helper quorum-check
# Node logs: truncate the live log file, and read the unit journal when the node
# logs there (journal-tail takes a line count).
${SVC_USER} ALL=(root) NOPASSWD: /usr/local/sbin/telcoin-ui-helper log-clear
${SVC_USER} ALL=(root) NOPASSWD: /usr/local/sbin/telcoin-ui-helper journal-tail *
${SVC_USER} ALL=(root) NOPASSWD: /usr/local/sbin/telcoin-ui-helper journal-follow
# Config edits through edit-config.sh --json: a field from a fixed allowlist and
# a value checked against that field's pattern.
${SVC_USER} ALL=(root) NOPASSWD: /usr/local/sbin/telcoin-ui-helper config-set *
# BLS passphrase: move it into the encrypted credential, or seal that again
# (edit-config.sh --migrate-credential / --reseal). Exactly these two calls.
${SVC_USER} ALL=(root) NOPASSWD: /usr/local/sbin/telcoin-ui-helper credential migrate
${SVC_USER} ALL=(root) NOPASSWD: /usr/local/sbin/telcoin-ui-helper credential reseal
# Advertised node name (network-config hostname); written as the node's service
# user, then the node restarts.
${SVC_USER} ALL=(root) NOPASSWD: /usr/local/sbin/telcoin-ui-helper set-hostname *
# Node-log rotation size (^[0-9]+[KMG]$), and removal of rotated logs only.
${SVC_USER} ALL=(root) NOPASSWD: /usr/local/sbin/telcoin-ui-helper set-logrotate *
${SVC_USER} ALL=(root) NOPASSWD: /usr/local/sbin/telcoin-ui-helper clear-rotated
# Caddy dashboard. enable takes <domain> <username> [<inbound-public-ip>]; the
# password arrives on the helper's stdin.
${SVC_USER} ALL=(root) NOPASSWD: /usr/local/sbin/telcoin-ui-helper caddy-status
${SVC_USER} ALL=(root) NOPASSWD: /usr/local/sbin/telcoin-ui-helper caddy-dns-check *
${SVC_USER} ALL=(root) NOPASSWD: /usr/local/sbin/telcoin-ui-helper caddy-enable *
${SVC_USER} ALL=(root) NOPASSWD: /usr/local/sbin/telcoin-ui-helper caddy-disable
# Public RPC endpoint (Caddy). enable takes <domain> [<inbound-public-ip>|-]
# [<dashboard-domain>]. A public RPC endpoint has no auth, so no password.
${SVC_USER} ALL=(root) NOPASSWD: /usr/local/sbin/telcoin-ui-helper rpc-status
${SVC_USER} ALL=(root) NOPASSWD: /usr/local/sbin/telcoin-ui-helper rpc-dns-check *
${SVC_USER} ALL=(root) NOPASSWD: /usr/local/sbin/telcoin-ui-helper rpc-enable *
${SVC_USER} ALL=(root) NOPASSWD: /usr/local/sbin/telcoin-ui-helper rpc-disable
# Firewall: read-only status, open/close for ONLY the three node ports,
# enumerated (3 ports x on|off), and enable with firewall-setup.sh's lockout-safe
# defaults, optionally with an SSH source list (addresses or CIDRs, checked by
# the helper). No other SSH or default-policy setting is reachable.
${SVC_USER} ALL=(root) NOPASSWD: /usr/local/sbin/telcoin-ui-helper firewall-status
${SVC_USER} ALL=(root) NOPASSWD: /usr/local/sbin/telcoin-ui-helper firewall-enable
${SVC_USER} ALL=(root) NOPASSWD: /usr/local/sbin/telcoin-ui-helper firewall-enable *
${SVC_USER} ALL=(root) NOPASSWD: /usr/local/sbin/telcoin-ui-helper firewall-port 49590/udp on
${SVC_USER} ALL=(root) NOPASSWD: /usr/local/sbin/telcoin-ui-helper firewall-port 49590/udp off
${SVC_USER} ALL=(root) NOPASSWD: /usr/local/sbin/telcoin-ui-helper firewall-port 49594/udp on
${SVC_USER} ALL=(root) NOPASSWD: /usr/local/sbin/telcoin-ui-helper firewall-port 49594/udp off
${SVC_USER} ALL=(root) NOPASSWD: /usr/local/sbin/telcoin-ui-helper firewall-port 43174/tcp on
${SVC_USER} ALL=(root) NOPASSWD: /usr/local/sbin/telcoin-ui-helper firewall-port 43174/tcp off
# Read-only: add-on status, the root-only .node-meta (no secrets in it) and the
# node's listener addresses in /etc/telcoin/node.env.
${SVC_USER} ALL=(root) NOPASSWD: /usr/local/sbin/telcoin-ui-helper addons-status
${SVC_USER} ALL=(root) NOPASSWD: /usr/local/sbin/telcoin-ui-helper meta-cat
${SVC_USER} ALL=(root) NOPASSWD: /usr/local/sbin/telcoin-ui-helper node-env-cat
# Read-only: the host hardening summary (check-node.sh --audit; never a secret).
${SVC_USER} ALL=(root) NOPASSWD: /usr/local/sbin/telcoin-ui-helper host-audit
# (Node removal is intentionally NOT exposed in the UI -- it is irreversible and
# runs on the server via remove-node.sh -- so the telcoin-ui user gets no
# node-remove grant.)
# First-time setup. No arguments: the non-secret settings travel in the TN_SETUP_*
# variables kept below for these two commands only, and the BLS passphrase on
# stdin. The helper refuses both once a node is installed.
Cmnd_Alias TN_SETUP = /usr/local/sbin/telcoin-ui-helper setup-keygen, /usr/local/sbin/telcoin-ui-helper setup-finalize
Defaults!TN_SETUP env_keep += "TN_SETUP_NETWORK TN_SETUP_INSTALL_METHOD TN_SETUP_ADDRESS TN_SETUP_BUILD_REF TN_SETUP_DOCKER_IMAGE TN_SETUP_EXT_PRIMARY TN_SETUP_EXT_WORKER TN_SETUP_LIS_PRIMARY TN_SETUP_LIS_WORKER TN_SETUP_PUBLIC_IP TN_SETUP_RPC_DOMAIN TN_SETUP_SERVICE_USER TN_SETUP_SERVICE_GROUP TN_SETUP_ADVERTISED_NAME TN_SETUP_DATA_DIR TN_SETUP_LOG_TARGET TN_SETUP_ALLOW_NO_TPM"
${SVC_USER} ALL=(root) NOPASSWD: TN_SETUP
# Read-only views of an externally deployed (dev-team docker) node. The
# container argument must be one docker-detect reports; none of these can start,
# stop or change a container or the host.
${SVC_USER} ALL=(root) NOPASSWD: /usr/local/sbin/telcoin-ui-helper docker-detect
${SVC_USER} ALL=(root) NOPASSWD: /usr/local/sbin/telcoin-ui-helper docker-status *
${SVC_USER} ALL=(root) NOPASSWD: /usr/local/sbin/telcoin-ui-helper docker-logs *
${SVC_USER} ALL=(root) NOPASSWD: /usr/local/sbin/telcoin-ui-helper docker-logs-full *
${SVC_USER} ALL=(root) NOPASSWD: /usr/local/sbin/telcoin-ui-helper docker-node-info *
${SVC_USER} ALL=(root) NOPASSWD: /usr/local/sbin/telcoin-ui-helper docker-stats *
${SVC_USER} ALL=(root) NOPASSWD: /usr/local/sbin/telcoin-ui-helper docker-log-size *
${SVC_USER} ALL=(root) NOPASSWD: /usr/local/sbin/telcoin-ui-helper internal-ip
EOF
chmod 440 "${SUDOERS_TMP}"
if visudo -cf "${SUDOERS_TMP}" >/dev/null 2>&1; then
    ok "Sudoers whitelist validated (installed at step 11)"
else
    err "Sudoers validation failed -- ${SUDOERS_FILE} and the UI were not changed."
    exit 1
fi

# ---- 6. Privileged helper (root-owned, OUTSIDE /opt/telcoin-ui) ---------------
# The single privileged entry point the sudoers drop-in names. Written beside the
# live helper and renamed over it, so a sudo call never sees a half-written file.
info "Installing privileged helper ${HELPER_DST}..."
install -o root -g root -m 0755 "${SRC_DIR}/telcoin-ui-helper.sh" "${HELPER_DST}.new"
mv -f "${HELPER_DST}.new" "${HELPER_DST}"
ok "Helper installed (root:root 0755)"

# ---- 7. Engine scripts (root-owned, OUTSIDE /opt/telcoin-ui) ------------------
# update-node.sh, edit-config.sh, setup-node.sh, install-caddy.sh,
# firewall-setup.sh and remove-node.sh drive the UI's features through their
# --json modes (check-node.sh through its read-only --audit), with every lib/ file they source (lib/*.sh, lib/*.env) and the
# release signing keys (lib/release-keys/*.asc) when this checkout has them.
# Built in a fresh root-only directory and renamed over the old one.
if [[ -f "${REPO_DIR}/update-node.sh" && -f "${REPO_DIR}/lib/common.sh" && -f "${REPO_DIR}/lib/fallback.sh" ]]; then
    info "Installing the engine scripts to ${UPDATE_DIR}..."
    ENGINE_NEW="$(new_tree "$UPDATE_DIR")"
    mkdir -p "${ENGINE_NEW}/lib"
    install -m 0755 "${REPO_DIR}/update-node.sh" "${ENGINE_NEW}/update-node.sh"
    for s in edit-config.sh firewall-setup.sh remove-node.sh setup-node.sh install-caddy.sh check-node.sh; do
        if [[ -f "${REPO_DIR}/${s}" ]]; then
            install -m 0755 "${REPO_DIR}/${s}" "${ENGINE_NEW}/${s}"
        else
            warn "${s} not found beside install-ui.sh -- the related UI feature will be unavailable until it is present."
        fi
    done
    for f in "${REPO_DIR}"/lib/*.sh "${REPO_DIR}"/lib/*.env; do
        [[ -f "$f" ]] && install -m 0644 "$f" "${ENGINE_NEW}/lib/${f##*/}"
    done
    for f in "${REPO_DIR}"/lib/release-keys/*.asc; do
        [[ -f "$f" ]] || continue
        mkdir -p "${ENGINE_NEW}/lib/release-keys"
        install -m 0644 "$f" "${ENGINE_NEW}/lib/release-keys/${f##*/}"
    done
    swap_tree "$ENGINE_NEW" "$UPDATE_DIR"
    ok "Engine scripts installed: ${UPDATE_DIR} (root:root)"
else
    warn "update-node.sh / lib/common.sh / lib/fallback.sh not found beside install-ui.sh -- the UI Update, Config and Setup features stay unavailable until they are present."
fi

# ---- 8. UI files (root-owned) and the service state directory ------------------
# The app tree is root:root with no group or other write, built in a temp
# directory and renamed into place. The service keeps its only state file,
# node-role.json, in /var/lib/telcoin-ui (StateDirectory= in the unit); a copy an
# older install left in /opt/telcoin-ui moves there once.
info "Installing UI files to ${INSTALL_DIR}..."
UI_NEW="$(new_tree "$INSTALL_DIR")"
mkdir -p "${UI_NEW}/static"
cp "${SRC_DIR}/server.py"          "${UI_NEW}/server.py"
cp "${SRC_DIR}/requirements.txt"   "${UI_NEW}/requirements.txt"
cp "${SRC_DIR}/static/index.html"  "${UI_NEW}/static/index.html"
# Brand logo (optional). The UI falls back to a built-in "TN" badge without it.
if [[ -f "${SRC_DIR}/static/telcoin-logo.png" ]]; then
    cp "${SRC_DIR}/static/telcoin-logo.png" "${UI_NEW}/static/telcoin-logo.png"
elif [[ -f "${INSTALL_DIR}/static/telcoin-logo.png" && ! -L "${INSTALL_DIR}/static/telcoin-logo.png" ]]; then
    cp "${INSTALL_DIR}/static/telcoin-logo.png" "${UI_NEW}/static/telcoin-logo.png"
fi
OLD_ROLE="${INSTALL_DIR}/node-role.json"
install -d -o "$SVC_USER" -g "$SVC_USER" -m 0750 "$STATE_DIR"
if [[ -f "$OLD_ROLE" && ! -L "$OLD_ROLE" && ! -e "${STATE_DIR}/node-role.json" ]]; then
    install -o "$SVC_USER" -g "$SVC_USER" -m 0640 "$OLD_ROLE" "${STATE_DIR}/node-role.json"
    ok "Moved node-role.json to ${STATE_DIR}"
fi
swap_tree "$UI_NEW" "$INSTALL_DIR"
ok "UI files installed: ${INSTALL_DIR} (root:root, read-only for ${SVC_USER})"

# ---- 9. Node-log rotation -----------------------------------------------------
# The helper seeds /etc/logrotate.d/telcoin with the library's writer
# (tn_install_logrotate) or its own copy of the same template. An existing file
# is kept, so a size the operator set from the UI survives updates.
LOGROTATE_CONF="/etc/logrotate.d/telcoin"
if bash "${HELPER_DST}" logrotate-seed >/dev/null; then
    ok "Node-log rotation configured (${LOGROTATE_CONF})"
else
    warn "Could not configure node-log rotation (${LOGROTATE_CONF}); see the message above, then re-run this installer or set it from the UI."
fi

# ---- 10. Access token, systemd unit and daemon-reload ------------------------
ensure_token 0
info "Installing systemd unit ${UNIT_DST}..."
install -o root -g root -m 0644 "${SRC_DIR}/telcoin-ui.service" "${UNIT_DST}.new"
mv -f "${UNIT_DST}.new" "${UNIT_DST}"
systemctl daemon-reload
ok "Unit installed, systemd reloaded"

# ---- 11. Swap in the sudoers whitelist ----------------------------------------
# Last, so every subcommand it grants is installed. A run stopped earlier leaves
# the old whitelist in place; the running server keeps working, and a newer
# server.py started later finds its helper-version call refused and asks the
# operator to re-run this installer.
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
    # Fresh install: ask the operator what they want. Without a terminal on stdin
    # (a scripted install) nothing is read and both answers default to yes, so a
    # closed or empty stdin cannot stop the script under set -e this late. The
    # answers are lowercased with tr because bash 3.2 has no case-changing expansion.
    start_now="y"
    if [ -t 0 ]; then
        read -r -p "Start the UI now? [Y/n] " start_now || start_now="y"
    fi
    start_now="$(printf '%s' "$start_now" | tr '[:upper:]' '[:lower:]')"
    if [[ ! "$start_now" =~ ^n ]]; then
        systemctl start telcoin-ui && ok "telcoin-ui started"
        verify_started
    fi
    enable_boot="y"
    if [ -t 0 ]; then
        read -r -p "Enable the UI on boot? [Y/n] " enable_boot || enable_boot="y"
    fi
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
echo "The UI listens on 127.0.0.1:8080 (localhost only) and answers only requests"
echo "that carry its access token. From your local machine, run:"
echo ""
echo -e "    ${c_blue}./open-ui.sh user@<server-ip>${c_off}"
echo ""
echo "It opens the SSH tunnel, reads the token over SSH (sudo cat ${TOKEN_FILE})"
echo "and opens http://127.0.0.1:8080/#t=<token> in your browser. The token stays"
echo "in the URL fragment, which the browser never sends to the server."
echo ""
echo "Jaeger tracing (separate tunnel):"
echo -e "    ${c_blue}ssh -L 16686:localhost:16686 user@<server-ip>${c_off}"
echo ""
echo "Replace the token (closes every open UI session): sudo bash ui/install-ui.sh --rotate-token"
echo ""
echo "Service management:"
echo "    systemctl status telcoin-ui"
echo "    journalctl -u telcoin-ui -f"
echo ""
