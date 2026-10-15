#!/usr/bin/env bash
# =============================================================================
# install-caddy.sh -- External (public) access via Caddy: dashboard + RPC
#
# Unified manager for the single /etc/caddy/Caddyfile this repo owns. It hosts up
# to TWO independent vhosts, each fenced by markers inside the one managed file so
# toggling one PRESERVES the other verbatim:
#
#   1) Dashboard  (# >>> tn-dashboard >>> ... # <<< tn-dashboard <<<)
#        https://<domain> -> 127.0.0.1:8080 (Node Manager UI), Caddy basic_auth.
#        The public path is READ-ONLY: Caddy stamps X-TN-Dashboard-Public, which
#        the UI server enforces (every write -> 403). Management stays on the SSH
#        tunnel (localhost, no such header).
#
#   2) Public RPC (# >>> tn-rpc >>> ... # <<< tn-rpc <<<), block v2:
#        https://<rpc-domain>/  -> 127.0.0.1:${RPC_PORT}  (JSON-RPC; CORS + OPTIONS;
#                                  request bodies capped at 2 MB)
#        wss://<rpc-domain>/    -> 127.0.0.1:${WS_PORT}   (WebSocket upgrade; the
#                                  Connection/Upgrade match ignores case)
#        GET/HEAD from a browser -> 405 with a short page saying what the hostname is.
#        reth stays loopback-only; the public reach is exclusively the Caddy TLS
#        edge. Enabling also ADVERTISES the endpoint in node-info.yaml (worker 0's
#        rpc, written by `keytool set-rpc`; legacy `worker:` map too) so
#        gateways/wallets discover it, then restarts the node (with a brick guard).
#        A block written by an older version (no `# tn-rpc block v2` stamp) is
#        reported as stale; running rpc-enable again with the same hostname
#        rewrites it.
#
# SAFETY RULES (every Caddyfile change, enable/disable/teardown alike):
#   - The new file is rendered to a temp file inside /etc/caddy and checked with
#     `caddy validate`, whose output is shown (bcrypt / base64 hashes redacted). A
#     failure leaves the live Caddyfile untouched and exits non-zero.
#   - The live file is backed up to /etc/caddy/Caddyfile.bak.<YYYYmmdd_HHMMSS> (root
#     0600, path printed; the five newest are kept), then replaced by an atomic rename
#     (tn_write_root_file) as root:caddy 0640.
#   - The managed file puts Caddy's admin API on a unix socket only
#     (unix//run/caddy/admin.sock, mode 0600); the drop-in
#     /etc/systemd/system/caddy.service.d/tn-admin.conf gives Caddy /run/caddy.
#   - Caddy running -> `systemctl reload` only, never a blind restart. A rejected reload
#     restores that backup over the live file and exits non-zero (rpc-enable then stops:
#     nothing is advertised, the node is not restarted); a reload that succeeds but leaves
#     Caddy down exits non-zero with the new file kept. Caddy stopped -> first start.
#     One exception: when the admin address changes (the first switch to the socket, a
#     hand-made Caddyfile with `admin off`, a teardown back to Caddy's default) no reload
#     can reach the running Caddy, so that apply restarts Caddy once, saying why.
#   - Caddy comes from its apt repository, whose signing key must have the pinned
#     fingerprint (CADDY_APT_KEY_FPR); any other key stops the install before apt-get
#     update.
#   - Dashboard and public RPC are refused on a staked mainnet validator (and on a
#     mainnet node whose stake cannot be read).
#   - Hostnames are normalised first (trimmed, lowercased, one trailing dot dropped) and
#     must pass the UI's rule (two or more labels, at most 253 characters, not an IP
#     address: Caddy needs a DNS name for the certificate); only the normalised name is
#     written anywhere.
#   - Same-domain rule: the dashboard and the public RPC endpoint need DIFFERENT
#     hostnames. The node's public name (e.g. nodeN.adiri.telcoin.network) carries RPC;
#     the dashboard goes on another name (e.g. dashboard.nodeN.adiri.telcoin.network).
#     A clash dies before anything is written; the dashboard block is never dropped.
#     rpc-enable --move-dashboard-to <host> moves a dashboard sitting on the RPC
#     hostname (site address only; same login) in the same swap + reload.
#   - WebSocket plan (rpc-enable): wss:// is advertised only when reth's WS endpoint
#     will exist -- the node itself listens on WS_PORT, or the node launch already
#     carries --ws; otherwise `--ws --ws.addr 127.0.0.1 --ws.port <WS_PORT>` is added to
#     the node's launch line (checked first on a copy). When that is not possible (or
#     another process holds WS_PORT) only https:// is advertised, with a warning.
#   - Node-restart brick guard (rpc-enable, rpc-disable): after restarting the node it
#     checks up to 30 times, about 2 s apart (~60 s), for RPC to answer. Only a unit that
#     reaches systemd's `failed` state inside that window (a crash loop that used up its
#     start limit) gets node-info.yaml and the launch edit rolled back and the node
#     restarted on the previous config. A node still auto-restarting (RestartSec) or
#     replaying its DB when the window ends is NOT rolled back -- the change is kept,
#     with a warning.
#   - Update lock and epoch boundary (rpc-enable, rpc-disable): what the node needs is
#     decided first, without changing anything. Only when a launch edit, a node-info
#     edit or a restart will follow does the run take the update lock (refused while
#     update-node.sh or edit-config.sh holds it) and, when the node votes in the current
#     committee, wait for the epoch to close (tn_wait_restart_window, lib/common.sh)
#     before the first node edit. Nothing is edited and nothing restarts when
#     node-info.yaml already holds the wanted URLs. TN_SKIP_EPOCH_WAIT=1 skips the wait.
#     The restart that recovers from a rollback never waits.
#   - rpc-disable takes the public site down first (Caddy reload, no lock, no wait), then
#     clears the advertisement in node-info.yaml and restarts the node.
#   - Older lib/common.sh: nothing dies on it. rpc-disable always takes the endpoint
#     down; rpc-enable warns about what it skips (update lock, epoch wait, adding --ws,
#     keytool) and says to run update-scripts.sh.
#   - --json runs: every refusal is an `error` event, then `done ok:false`; a run that
#     succeeded with something left undone (not advertised, node not restarted) sends a
#     `warn` event when it happens and names it in the closing `done` message.
#
# IMPORTANT: set the DNS A record (<domain> -> this server's INBOUND public IP)
# BEFORE enabling. Caddy requests the cert on first start; if DNS isn't pointing here
# (and ports 80/443 reachable), ACME fails and Let's Encrypt rate-limits you. On a
# multi-IP host or behind 1:1 NAT the inbound IP differs from the egress (outbound)
# IP ipify reports -- pass the inbound IP with --public-ip (or $TN_CADDY_PUBLIC_IP).
#
# USAGE (interactive menu: dashboard / RPC / status):
#   sudo bash install-caddy.sh
# USAGE (non-interactive, human-readable -- e.g. from setup-node.sh): any phase below
# without --json, e.g.
#   sudo bash install-caddy.sh --phase=rpc-check-dns --rpc-domain <d>   (exit 0 = DNS reaches this host)
#   sudo bash install-caddy.sh --phase=rpc-enable --rpc-domain <d> [--move-dashboard-to <host>]
# USAGE (JSON, driven by the Node Manager UI helper):
#   install-caddy.sh --json --phase=status
#   install-caddy.sh --json --phase=check-dns --domain <d> [--public-ip <inbound-ip>]
#   install-caddy.sh --json --phase=enable --domain <d> --username <u> --password-stdin
#       (the password, at least 16 characters, is one line on stdin; $TN_CADDY_PASSWORD
#       is still read, and unset at once, when --password-stdin is not given)
#   install-caddy.sh --json --phase=disable
#   install-caddy.sh --json --phase=rpc-status
#   install-caddy.sh --json --phase=rpc-check-dns --rpc-domain <d> [--public-ip <inbound-ip>]
#   install-caddy.sh --json --phase=rpc-enable --rpc-domain <d> [--move-dashboard-to <host>]
#       (the exposure summary goes out as a `warn` event; the UI action is the consent)
#   install-caddy.sh --json --phase=rpc-disable
# rpc-enable without --json prints the same summary and asks for a yes on a terminal;
# without a terminal it needs --yes.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

# common.sh provides the print_*/check_root helpers but not die(); define our own
# so error paths exit cleanly (print_error goes to stderr, which the UI surfaces).
# In a --json event run (enable, disable, rpc-enable, rpc-disable) the reason also
# goes out as an `error` event and the closing `done ok:false`, so the UI shows why.
die() {
    print_error "$*"
    if [[ "${JSON_STREAM:-false}" == "true" ]]; then
        json_event error "$*"
        json_done "{\"event\":\"done\",\"ok\":false,\"msg\":\"$(json_escape "$*")\"}"
    fi
    exit 1
}

readonly SCRIPT_VERSION="1.4.0"
# basic_auth (the dashboard block) and heredocs (the RPC block page) need Caddy 2.8.0.
readonly CADDY_MIN_VERSION="2.8.0"
# Timestamped Caddyfile backups kept by caddy_prune_backups.
readonly CADDY_KEEP_BACKUPS=5
# Stamp line of the RPC block write_rpc_block emits. A tn-rpc block without it was
# written by install-caddy.sh 1.3.0 or older (caddy_rpc_block_stale).
readonly RPC_BLOCK_STAMP="# tn-rpc block v2"
# TN_ROOT_PREFIX points the file paths at a fixture tree (tests only).
readonly CADDYFILE="${TN_ROOT_PREFIX:-}/etc/caddy/Caddyfile"
readonly CADDY_DIR="${CADDYFILE%/*}"
readonly CADDYFILE_ORIG="${TN_ROOT_PREFIX:-}/etc/caddy/Caddyfile.tn-orig"
# Caddy's apt repository and the primary key fingerprint its signing key must have
# (checked against the key served at CADDY_APT_KEY_URL and the Ubuntu keyserver,
# 2026-10-15). A different key stops the install.
readonly CADDY_APT_KEY_URL="https://dl.cloudsmith.io/public/caddy/stable/gpg.key"
readonly CADDY_APT_KEY_FPR="65760C51EDEA2017CEA2CA15155B6D79CA56EA34"
readonly CADDY_APT_KEYRING="/usr/share/keyrings/caddy-stable-archive-keyring.gpg"
readonly CADDY_APT_LIST="/etc/apt/sources.list.d/caddy-stable.list"
readonly CADDY_APT_REPO="https://dl.cloudsmith.io/public/caddy/stable/deb/debian"
# Admin API: a unix socket only. The drop-in gives Caddy its runtime directory.
readonly CADDY_ADMIN_ADDR="unix//run/caddy/admin.sock|0600"
readonly CADDY_ADMIN_DROPIN="${TN_ROOT_PREFIX:-}/etc/systemd/system/caddy.service.d/tn-admin.conf"
# Dashboard password floor, in bytes.
readonly CADDY_PASSWORD_MIN=16
# The Node Manager UI port: never a proxy target for the public RPC site.
readonly CADDY_UI_PORT=8080
readonly UI_UPSTREAM="127.0.0.1:${CADDY_UI_PORT}"
readonly PUBLIC_HEADER="X-TN-Dashboard-Public"
# First line of every Caddyfile we generate -- lets us tell our own managed
# config apart from one the operator (or another tool) set up by hand.
readonly CADDY_MARKER="# Managed by the Telcoin Node Manager"

# Per-vhost fence markers inside the single managed Caddyfile. Toggling one vhost
# rewrites the file from the OTHER block's bytes verbatim (extracted between its
# fences) + the regenerated block -- so e.g. the dashboard's bcrypt hash is never
# re-parsed when RPC is toggled, and vice-versa.
readonly DASH_BEGIN="# >>> tn-dashboard >>>"
readonly DASH_END="# <<< tn-dashboard <<<"
readonly RPC_BEGIN="# >>> tn-rpc >>>"
readonly RPC_END="# <<< tn-rpc <<<"

# Set true (interactive only, after explicit confirmation) to allow overwriting a
# Caddyfile we did not create. The JSON/UI path never sets it -- it refuses to
# clobber a foreign config and tells the operator to resolve it on the CLI.
CADDY_OVERWRITE_FOREIGN=false

# Temp files this run created (space-separated; mktemp names carry no spaces). The
# EXIT trap (caddy_cleanup_tmp, also run by json_on_exit) removes them on EVERY exit
# path, so a die() mid-swap never leaves a half-written Caddyfile (or a copy of the
# dashboard hash) behind.
CADDY_TMP_FILES=""
# Set by caddy_swap_in: the timestamped backup of the live Caddyfile it replaced (''
# when there was none) -- what caddy_apply_live restores when a reload is rejected.
CADDY_LAST_BACKUP=""
CADDY_SWAPPED=false
# Set by caddy_ws_plan / caddy_ws_inject: the launch file to edit and the install
# method, and (once caddy_ws_inject added --ws) its pre-edit backup. The node-restart
# brick guard rolls the launch edit back with node-info.yaml, and the node restarts
# even when node-info.yaml itself is unchanged (otherwise the new flag would never
# take effect).
CADDY_LAUNCH_FILE=""
CADDY_LAUNCH_BAK=""
CADDY_LAUNCH_METHOD=""
# Outcome flags of do_rpc_enable for the final messages: whether wss:// was advertised
# (false when caddy_ws_plan / caddy_ws_inject fell back to http only) and where the
# dashboard moved.
CADDY_WS_OK=true
CADDY_DASH_MOVED_TO=""
# caddy_restart_window has run for the current operation (guard and wait happen once).
CADDY_WINDOW_DONE=false
# A node edit of this run (node-info.yaml, the --ws launch flags) waits for the
# restart that applies it; caddy_restart_abandon puts it back when the run stops
# first (a guard refusal, a failed wait, a signal).
CADDY_RESTART_PENDING=false
# Library helpers already reported missing by caddy_lib_has (space-separated names).
CADDY_LIB_WARNED=""
# The update lock is held by this run (caddy_node_lock); CADDY_LOCK_NOTE is appended
# to the refusal when another run holds it, saying what this run already changed.
CADDY_LOCK_HELD=false
CADDY_LOCK_NOTE=""
# Short notes for the closing `done` message and the human summary when a run that
# succeeded left something undone (not advertised, node not restarted, ...); each
# one also went out as a warning when it happened. "; "-separated.
CADDY_DONE_NOTES=""
# caddy_ws_plan's decision for rpc-enable: ok (reth's WebSocket is or will be
# there), inject (add CADDY_WS_FLAGS to the launch file; a dry run on a copy
# passed), http (advertise https:// only; the warning is out).
CADDY_WS_PLAN=""
CADDY_WS_FLAGS=""
# Launch-file backup made by caddy_ws_inject (tn_backup_file): its hash and the
# launch file's mode and group, for tn_restore_backup.
CADDY_LAUNCH_BAK_SHA=""
CADDY_LAUNCH_MODE=""
CADDY_LAUNCH_GROUP=""
# Root-only run directory (mktemp -d under TN_CADDY_RUN_PARENT, default /run) holding
# the node-info.yaml backup and the launch dry-run copy; removed on exit.
CADDY_RUN_DIR=""
CADDY_NI_BAK=""
CADDY_NI_FILE=""
# Proxy targets for the RPC site (caddy_rpc_enable_precheck): reth's HTTP and WS
# ports from the node launch, else .node-meta, else 8545/8546.
CADDY_RPC_PORT=""
CADDY_WS_PORT_SET=""
# The dashboard password: --password-stdin, else TN_CADDY_PASSWORD read and unset by
# main. Never exported.
CADDY_PASSWORD=""
CADDY_PASSWORD_STDIN=false
# --yes: the operator accepts the public RPC exposure summary without a prompt.
CADDY_YES=false
# caddy_mainnet_gate has passed in this run; .node-meta may be written (caddy_meta_ready).
CADDY_GATE_DONE=false
CADDY_META_READY=false

# =============================================================================
# JSON / NON-INTERACTIVE MODE (mirrors setup-*.sh)
# =============================================================================
JSON_MODE=false
JSON_PHASE=""
JSON_DOMAIN=""
JSON_USERNAME=""
JSON_RPC_DOMAIN=""
JSON_MOVE_DASH=""
JSON_DONE_EMITTED=false
# true once json_setup_fds has opened fd 3: from then on die() reports through events.
JSON_STREAM=false

json_mode() { [[ "$JSON_MODE" == "true" ]]; }

json_setup_fds() { exec 3>&1; exec 1>&2; JSON_STREAM=true; }   # fd3 = JSON; stdout -> stderr (noise)

# JSON string body for <s>: backslash and double quote escaped, and every control
# character (U+0001..U+001F; a bash string cannot hold NUL) as \u00XX, so an event
# stays valid JSON whatever a tool printed (keytool's colour codes, a stray CR).
json_escape() {
    local s="$1" i oct c hex
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    if [[ "$s" == *[[:cntrl:]]* ]]; then
        i=1
        while [[ "$i" -lt 32 ]]; do
            printf -v oct '%03o' "$i"
            printf -v c '%b' "\\0${oct}"
            if [[ "$s" == *"$c"* ]]; then
                printf -v hex '\\u%04x' "$i"
                s="${s//"$c"/$hex}"
            fi
            i=$(( i + 1 ))
        done
    fi
    printf '%s' "$s"
}
# Emit the args as a JSON array of strings:  a b -> ["a","b"];  (no args) -> [].
json_str_array() {
    local out="" s
    for s in "$@"; do out+="${out:+,}\"$(json_escape "$s")\""; done
    printf '[%s]' "$out"
}
json_emit()  { printf '%s\n' "$1" >&3; }
json_event() { json_emit "{\"event\":\"${1}\",\"msg\":\"$(json_escape "${2:-}")\"}"; }
json_done()  { JSON_DONE_EMITTED=true; json_emit "$1"; }
json_on_exit() {
    local rc=$?
    caddy_exit_cleanup
    [[ "$JSON_DONE_EMITTED" == "true" ]] && return
    json_emit "{\"event\":\"done\",\"ok\":false,\"msg\":\"install-caddy exited early (rc=${rc}) -- see server logs\"}"
}

# Stream a command's output to the UI as JSON `log` events (json mode); run it
# plainly otherwise.
run_streamed() {
    if json_mode; then
        "$@" 2>&1 | while IFS= read -r _line; do
            json_emit "{\"event\":\"log\",\"msg\":\"$(json_escape "$_line")\"}"
        done
        return "${PIPESTATUS[0]}"
    fi
    "$@"
}

# Register temp file(s) for removal by the EXIT trap.
caddy_tmp_track() {
    local f
    for f in "$@"; do CADDY_TMP_FILES="${CADDY_TMP_FILES} ${f}"; done
}
# Remove every registered temp file. Idempotent, never fails.
caddy_cleanup_tmp() {
    local f
    for f in $CADDY_TMP_FILES; do rm -rf "$f" 2>/dev/null || true; done
    CADDY_TMP_FILES=""
}
# EXIT-trap body (json_on_exit runs it too): a node edit still waiting for its
# restart is put back, then temp files, then the update lock.
caddy_exit_cleanup() {
    caddy_restart_abandon || true
    caddy_cleanup_tmp
    caddy_node_unlock
}

# Mask password hashes in tool output (stdin -> stdout): bcrypt ($2a$ / $2b$ / $2x$ /
# $2y$ ...) and the base64 form Caddy stores it in (JDJ... is base64 of "$2"). The
# dashboard basic_auth hash must never reach a terminal, the UI stream or server logs.
caddy_redact_hashes() {
    # shellcheck disable=SC2016  # literal $ in the regex, not an expansion
    sed -E -e 's#\$2[abxy]?\$[0-9]{1,2}\$[./A-Za-z0-9]+#<redacted-hash>#g' \
           -e 's#JDJ[A-Za-z0-9+/]{6,}={0,2}#<redacted-hash>#g'
}

# Show stdin to the operator line by line: JSON `log` events in --json mode (the UI
# already renders them, cf. run_streamed), indented text otherwise.
caddy_emit_lines() {
    local _line
    while IFS= read -r _line || [[ -n "$_line" ]]; do
        if json_mode; then
            json_emit "{\"event\":\"log\",\"msg\":\"$(json_escape "$_line")\"}"
        else
            printf '    %s\n' "$_line"
        fi
    done
}

# caddy_say <ok|warn|step|info> <msg> -- print_* for the terminal; in a --json event
# run ALSO an event, because there stdout is redirected to stderr (server logs only)
# and the operator should still see backups, WebSocket changes, the epoch wait and
# warnings in the UI: warn and step go out as events of that name, ok and info as
# `log`. Never called by the status phases, whose stdout is one JSON object.
caddy_say() {
    local level="$1" msg ev="log"
    shift
    msg="$*"
    case "$level" in
        ok)   print_ok "$msg" ;;
        warn) print_warn "$msg"; ev="warn" ;;
        step) print_step "$msg"; ev="step" ;;
        *)    print_info "$msg" ;;
    esac
    if [[ "$JSON_STREAM" == "true" ]]; then
        json_emit "{\"event\":\"${ev}\",\"msg\":\"$(json_escape "$msg")\"}" 2>/dev/null || true
    fi
}

# caddy_note <text> -- record a short note for the closing `done` message and the human
# summary (the matching warning has already been said).
caddy_note() {
    case "; ${CADDY_DONE_NOTES}; " in
        *"; ${1}; "*) return 0 ;;
    esac
    CADDY_DONE_NOTES="${CADDY_DONE_NOTES:+${CADDY_DONE_NOTES}; }${1}"
}

# caddy_wait_say <step|log|warn> <msg> -- progress printer handed to
# tn_wait_restart_window (lib/common.sh), routed through caddy_say.
caddy_wait_say() {
    case "${1:-}" in
        step) caddy_say step "${2:-}" ;;
        warn) caddy_say warn "${2:-}" ;;
        *)    caddy_say info "${2:-}" ;;
    esac
    return 0
}

# caddy_lib_has <what-happens-instead> <fn>... -- 0 when lib/common.sh defines every
# <fn>. Otherwise warn once per first-named helper that this run falls back to the
# older behaviour described by <what-happens-instead>, and return 1. The soft guard
# for helpers that arrived in lib/common.sh 1.5.0 / 1.6.0: a box with an older
# library keeps working (rpc-disable must always be able to take the endpoint down).
caddy_lib_has() {
    local instead="$1" fn missing=""
    shift
    for fn in "$@"; do
        declare -F "$fn" >/dev/null 2>&1 || missing="${missing:+${missing}, }${fn}"
    done
    [[ -z "$missing" ]] && return 0
    case " ${CADDY_LIB_WARNED} " in
        *" ${1} "*) return 1 ;;
    esac
    CADDY_LIB_WARNED="${CADDY_LIB_WARNED} ${1}"
    caddy_say warn "lib/common.sh ${COMMON_VERSION:-unknown} has no ${missing}, so ${instead}. Run update-scripts.sh to update the library."
    return 1
}

# =============================================================================
# HELPERS
# =============================================================================

# Egress (outbound) IP of this host as an external service sees it -- the address
# used for connections OUT of the box. On a multi-IP host or behind 1:1 NAT this can
# DIFFER from the inbound IP where ACME challenges on 80/443 arrive, so it is NOT
# necessarily where the A record should point. '' on failure. (Best-effort, mirrors
# the setup scripts.)
caddy_egress_ip() {
    local ip
    ip=$(curl -s --max-time 8 https://api.ipify.org 2>/dev/null || true)
    [[ "$ip" =~ ^[0-9a-fA-F.:]+$ ]] && echo "$ip" || echo ""
}

# Effective public IP the A record should point at. Honours an operator-supplied
# override (TN_CADDY_PUBLIC_IP, set via --public-ip or the interactive prompt) -- the
# single lever for naming the real INBOUND IP when it differs from egress (multi-IP /
# NAT hosts) -- else falls back to the detected egress IP. Mirrors how
# lib/common.sh:select_ipv4_binding() lets the operator confirm/override the IP.
caddy_public_ip() {
    local override="${TN_CADDY_PUBLIC_IP:-}"
    if [[ -n "$override" ]] && validate_public_ip "$override"; then
        echo "$override"; return 0
    fi
    caddy_egress_ip
}

# This host's own bound IPv4 addresses, space-separated, via `hostname -I` (the idiom
# lib/common.sh:detect_internal_ip/select_ipv4_binding use). Loopback is filtered out.
# On a multi-IP host the inbound public IP appears here; behind 1:1 NAT only a private
# IP shows -- which is exactly when the operator must supply --public-ip. '' if none.
caddy_local_ips() {
    local out="" ip
    for ip in $(hostname -I 2>/dev/null || true); do
        [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue   # IPv4 only
        [[ "$ip" == 127.* ]] && continue                             # drop loopback
        out+="${ip} "
    done
    echo "${out% }"
}

# 0 (true) when <resolved> (the A record) points at an address that actually reaches
# THIS box inbound: either the effective public IP, or any of the host's own bound
# local IPs. This is the propagation test -- it replaces the old "resolved == egress"
# check, which misfired on multi-IP / NAT hosts where the (correct) inbound A record
# never equals the egress IP. NOTE: a pass means DNS targets this host, NOT that
# 80/443 are open -- external TLS verification remains the real proof.
caddy_ip_reaches_host() {
    local resolved="$1" pub="$2" local_ips="$3" ip
    [[ -z "$resolved" ]] && return 1
    [[ -n "$pub" && "$resolved" == "$pub" ]] && return 0
    for ip in $local_ips; do
        [[ "$resolved" == "$ip" ]] && return 0
    done
    return 1
}

# A record for <domain> as seen by PUBLIC resolvers (most representative of what
# Let's Encrypt sees), falling back to the system resolver. '' when unresolved.
caddy_resolve_domain() {
    local domain="$1" ip="" r
    if command -v dig >/dev/null 2>&1; then
        for r in 1.1.1.1 8.8.8.8; do
            ip=$(dig +short +time=3 +tries=1 @"$r" "$domain" A 2>/dev/null | grep -Eo '^[0-9.]+$' | head -1 || true)
            [[ -n "$ip" ]] && { echo "$ip"; return 0; }
        done
    fi
    ip=$(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | head -1 || true)
    echo "$ip"
}

# Name of the process LISTENING on <port> ('unknown' when unreadable), or '' when
# free. Needs root to read the process name (the UI helper runs as root).
caddy_port_proc() {
    local port="$1" line proc
    line=$(ss -ltnHp 2>/dev/null | awk -v p=":${port}" '$4 ~ p"$"{print; exit}' || true)
    [[ -z "$line" ]] && { echo ""; return 0; }
    proc=$(printf '%s' "$line" | grep -oE '"[^"]+"' | head -1 | tr -d '"' || true)
    echo "${proc:-unknown}"
}

# Name of the process LISTENING on <port>, or '' when free / it's caddy.
caddy_port_holder() {
    local proc
    proc="$(caddy_port_proc "$1")"
    [[ "$proc" == "caddy" ]] && { echo ""; return 0; }
    echo "$proc"
}

# 0 (true) when something LISTENS on TCP <port> (any address). No root needed.
caddy_port_listening() {
    local port="$1"
    ss -ltnH 2>/dev/null | awk -v p=":${port}" '$4 ~ p"$" {f=1} END {exit !f}'
}

# 0 (true) when /etc/caddy/Caddyfile holds a REAL config we did not create -- so we
# never silently clobber an operator's existing Caddy setup. Our own managed file
# (CADDY_MARKER), the stock package default, and an empty/comment-only file are all
# treated as safe to (re)write.
caddy_foreign_config() {
    [[ -f "$CADDYFILE" ]] || return 1
    grep -q "$CADDY_MARKER" "$CADDYFILE" 2>/dev/null && return 1          # ours
    grep -q "The Caddyfile is an easy way to configure" "$CADDYFILE" 2>/dev/null && return 1  # package default
    grep -qE '^[[:space:]]*[^#[:space:]]' "$CADDYFILE" 2>/dev/null || return 1               # empty / comments only
    return 0
}

# Echo hostname <h> normalised: surrounding whitespace trimmed, lowercased, one
# trailing dot dropped -- what the Node Manager UI and its helper do. Every phase
# normalises first and uses only the normalised name afterwards (Caddyfile,
# node-info.yaml, .node-meta), so a mixed-case or dotted re-run matches what is stored.
caddy_norm_host() {
    local h="${1:-}"
    h="${h#"${h%%[![:space:]]*}"}"
    h="${h%"${h##*[![:space:]]}"}"
    h="$(printf '%s' "$h" | tr '[:upper:]' '[:lower:]')"
    printf '%s' "${h%.}"
}

# 0 (true) for a multi-label DNS hostname within the RFC 1035 limits, the rule the UI
# helper and server apply: at most 253 characters, two or more labels of 1-63 letters,
# digits and inner hyphens, and not all digits and dots (an IPv4 address). Used for
# --domain, --rpc-domain and --move-dashboard-to (and the interactive prompts), on the
# normalised name.
caddy_validate_domain() {
    [[ "${#1}" -le 253 ]] || return 1
    [[ "$1" =~ ^[0-9.]+$ ]] && return 1
    [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+$ ]]
}

# Echo why <h> (normalised) cannot be used as a site hostname; nothing when it can.
caddy_domain_problem() {
    if [[ -z "$1" ]]; then
        printf 'no hostname was given'
    elif [[ "$1" =~ ^[0-9.]+$ ]]; then
        printf '%s is an IP address; Caddy needs a DNS name (an A record pointing at this server) to get a certificate' "$1"
    elif ! caddy_validate_domain "$1"; then
        printf '%s is not a valid hostname (two or more labels of letters, digits and inner hyphens, at most 253 characters)' "$1"
    fi
}

# Die unless <h> (normalised) is a usable hostname; <what> names it in the message.
caddy_require_domain() {
    local why
    why="$(caddy_domain_problem "$1")"
    [[ -z "$why" ]] || die "invalid ${2}: ${why}"
}
caddy_validate_username() { [[ "$1" =~ ^[A-Za-z0-9._-]{2,32}$ ]]; }

# 0 (true) when <url> is a well-formed http(s):// (scheme=http) or ws(s):// (scheme=ws)
# URL no longer than 2048 chars. Defense-in-depth before writing worker.rpc into
# node-info.yaml: an invalid value crash-loops the node at startup (node.rs:526-531),
# so we refuse to write anything that isn't a clean scheme://host[/] URL.
caddy_validate_rpc_url() {
    local scheme="$1" url="$2"
    [[ "${#url}" -le 2048 ]] || return 1
    case "$scheme" in
        http) [[ "$url" =~ ^https?://[A-Za-z0-9.-]+/?$ ]] || return 1 ;;
        ws)   [[ "$url" =~ ^wss?://[A-Za-z0-9.-]+/?$ ]] || return 1 ;;
        *) return 1 ;;
    esac
    return 0
}

# Version of the installed caddy as X.Y.Z ("v2.8.4 h1:..." -> 2.8.4); '' when it
# cannot be read.
caddy_installed_version() {
    local v
    v="$(caddy version 2>/dev/null | head -1 || true)"
    v="${v%% *}"
    v="${v#v}"
    [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] || { echo ""; return 0; }
    echo "${BASH_REMATCH[0]}"
}

# Die unless the installed caddy is CADDY_MIN_VERSION or newer: the dashboard block
# uses basic_auth (named basicauth before 2.8.0) and the RPC block's page is a
# heredoc. Distribution packages lag (Ubuntu 24.04 ships 2.6.2); the official apt
# repository has the current release. An unreadable version is a warning only --
# `caddy validate` still checks the new file before it goes live.
caddy_check_version() {
    local v out
    v="$(caddy_installed_version)"
    if [[ -z "$v" ]]; then
        out="$(caddy version 2>/dev/null | head -1 || true)"
        caddy_say warn "Could not read the Caddy version${out:+ from \"${out}\"}. This script needs Caddy ${CADDY_MIN_VERSION} or newer; caddy validate checks the new config before it is used."
        return 0
    fi
    version_gte "$v" "$CADDY_MIN_VERSION" && return 0
    die "Caddy ${v} is installed, and this script needs ${CADDY_MIN_VERSION} or newer (basic_auth, heredocs). Install the current release from the official Caddy apt repository (https://caddyserver.com/docs/install#debian-ubuntu-raspbian): add the repository, then sudo apt-get update && sudo apt-get install caddy. Run this again afterwards. The Caddyfile was not changed."
}

# caddy_key_primary_fpr <keyring> <gpg-home> -- print the primary key fingerprint of a
# binary keyring holding exactly one primary key; rc 1 otherwise (no key, several
# keys, gpg cannot read it).
caddy_key_primary_fpr() {
    local out
    out="$(gpg --homedir "$2" --batch --with-colons --show-keys "$1" 2>/dev/null)" || return 1
    printf '%s\n' "$out" | awk -F: '
        $1 == "pub" { n++; want = 1; next }
        $1 == "fpr" && want { fpr = $10 }
        { want = 0 }
        END { if (n != 1 || fpr == "") exit 1; print fpr }'
}

# Fetch Caddy's apt signing key over https into a root-only temp directory, dearmor
# it there, and install it as CADDY_APT_KEYRING (root 0644) only when it holds one
# primary key whose fingerprint is CADDY_APT_KEY_FPR. rc 1 (message said, nothing
# installed) on a download failure, an unreadable key or another fingerprint.
caddy_install_apt_key() {
    local dir fpr
    dir="$(mktemp -d "${TMPDIR:-/tmp}/tn-caddy-key.XXXXXX")" || return 1
    caddy_tmp_track "$dir"
    if ! mkdir -m 0700 "${dir}/gpg"; then
        print_error "Could not create a temporary GnuPG home in ${dir}."
        return 1
    fi
    if ! curl -fsSL --proto '=https' --tlsv1.2 -o "${dir}/key.asc" "$CADDY_APT_KEY_URL"; then
        print_error "Could not download the Caddy apt signing key from ${CADDY_APT_KEY_URL}."
        return 1
    fi
    if ! gpg --homedir "${dir}/gpg" --batch --yes --dearmor -o "${dir}/key.gpg" "${dir}/key.asc" >/dev/null 2>&1; then
        print_error "The file served at ${CADDY_APT_KEY_URL} is not an OpenPGP key."
        return 1
    fi
    if ! fpr="$(caddy_key_primary_fpr "${dir}/key.gpg" "${dir}/gpg")"; then
        print_error "The Caddy apt key from ${CADDY_APT_KEY_URL} does not hold exactly one primary key."
        return 1
    fi
    if [[ "$fpr" != "$CADDY_APT_KEY_FPR" ]]; then
        print_error "The Caddy apt key has fingerprint ${fpr}, not the expected ${CADDY_APT_KEY_FPR}. Nothing was installed. If Caddy rotated its key, check the new one with the Caddy project before updating install-caddy.sh."
        return 1
    fi
    if [[ ! -d "${TN_ROOT_PREFIX:-}${CADDY_APT_KEYRING%/*}" ]]; then
        install -d -o root -g root -m 0755 -- "${TN_ROOT_PREFIX:-}${CADDY_APT_KEYRING%/*}" || return 1
    fi
    tn_write_root_file "${TN_ROOT_PREFIX:-}${CADDY_APT_KEYRING}" 0644 < "${dir}/key.gpg" || return 1
    print_ok "Caddy apt key verified (${CADDY_APT_KEY_FPR})."
}

# Write the Caddy apt source line (signed-by the pinned keyring), root 0644.
caddy_write_apt_list() {
    tn_write_root_file "${TN_ROOT_PREFIX:-}${CADDY_APT_LIST}" 0644 <<EOF
# Caddy stable, written by install-caddy.sh. Signed by the key in ${CADDY_APT_KEYRING}
# (primary fingerprint ${CADDY_APT_KEY_FPR}).
deb [signed-by=${CADDY_APT_KEYRING}] ${CADDY_APT_REPO} any-version main
EOF
}

# Install Caddy from the official (cloudsmith) apt repo if missing, then check the
# version floor (an installed caddy may be an older distribution package). The
# repository key is checked against CADDY_APT_KEY_FPR before apt-get update; any
# failure stops the run.
install_caddy_pkg() {
    if command -v caddy >/dev/null 2>&1; then
        print_ok "Caddy already installed: $(caddy version 2>/dev/null | head -1)"
        caddy_check_version
        return 0
    fi
    print_info "Installing Caddy from the official repository..."
    run_streamed apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl gpg \
        || die "apt-get could not install curl and gpg, which the Caddy install needs. Nothing was changed."
    caddy_install_apt_key || die "the Caddy apt key was not installed (see the message above); Caddy was not installed."
    caddy_write_apt_list || die "could not write ${CADDY_APT_LIST}; Caddy was not installed."
    run_streamed apt-get update || die "apt-get update failed; Caddy was not installed."
    run_streamed apt-get install -y caddy || die "apt-get install caddy failed."
    command -v caddy >/dev/null 2>&1 || die "Caddy installation failed"
    caddy_check_version
}

# Allow / remove 80 and 443 in ufw. Done while ufw is inactive too: ufw keeps the
# rules and applies them when it is enabled, so a later `ufw enable` neither blocks
# a served site nor leaves the ports open after the last site is gone.
caddy_open_ports() {
    command -v ufw >/dev/null 2>&1 || return 0
    ufw allow 80/tcp  >/dev/null 2>&1 || true
    ufw allow 443/tcp >/dev/null 2>&1 || true
}
caddy_close_ports() {
    command -v ufw >/dev/null 2>&1 || return 0
    ufw delete allow 80/tcp  >/dev/null 2>&1 || true
    ufw delete allow 443/tcp >/dev/null 2>&1 || true
}

# =============================================================================
# MANAGED CADDYFILE: per-vhost block model
# =============================================================================

# Echo the bytes BETWEEN <begin>..<end> fence lines (exclusive), verbatim. Empty if
# absent. awk does no expansion, so a block's $-bearing bytes (bcrypt hash) survive
# untouched -- the whole point of preserve-the-other-block toggling.
caddy_extract_block() {
    local begin="$1" end="$2" file="${3:-$CADDYFILE}"
    [[ -f "$file" ]] || return 0
    awk -v b="$begin" -v e="$end" '
        $0==b {inb=1; next}
        $0==e {inb=0; next}
        inb {print}
    ' "$file"
}

# 0 (true) when <begin> fence is present in the managed file.
caddy_block_present() {
    local begin="$1" file="${2:-$CADDYFILE}"
    [[ -f "$file" ]] && grep -qF "$begin" "$file" 2>/dev/null
}

# Echo the dashboard vhost block content (verbatim). New (fenced) file: between the
# dashboard fences. Legacy fence-less managed file (created before this two-vhost
# layout): the whole body after our header comments -- a one-time migration that
# folds the old single-vhost dashboard config into a fenced block. Empty when the
# file isn't ours, has no dashboard, or is a disabled stub.
caddy_current_dashboard_block() {
    if caddy_block_present "$DASH_BEGIN"; then
        caddy_extract_block "$DASH_BEGIN" "$DASH_END"
        return 0
    fi
    [[ -f "$CADDYFILE" ]] || return 0
    grep -qF "$CADDY_MARKER" "$CADDYFILE" 2>/dev/null || return 0
    grep -qF "reverse_proxy ${UI_UPSTREAM}" "$CADDYFILE" 2>/dev/null || return 0
    # Skip our leading comment/blank header lines; emit the rest (the <domain> {...} block).
    awk 'started==0 && (/^#/ || /^[[:space:]]*$/){next} {started=1; print}' "$CADDYFILE"
}

# 0 (true) when any managed vhost (dashboard or RPC) is configured.
caddy_any_vhost_enabled() {
    [[ -n "$(caddy_current_dashboard_block)" ]] && return 0
    caddy_block_present "$RPC_BEGIN" && return 0
    return 1
}

# Site address (the first `<host> {` line) of the vhost block on stdin; '' when none.
caddy_block_domain() {
    grep -m1 -E '^[A-Za-z0-9].*\{[[:space:]]*$' | sed -E 's/[[:space:]]*\{.*$//' | tr -d ' ' || true
}
# Hostname the dashboard / RPC vhost currently serves; '' when that vhost is absent.
caddy_current_dashboard_domain() {
    local dash; dash="$(caddy_current_dashboard_block)"
    [[ -n "$dash" ]] || return 0
    printf '%s\n' "$dash" | caddy_block_domain
}
caddy_current_rpc_domain() {
    local block
    caddy_block_present "$RPC_BEGIN" || return 0
    block="$(caddy_extract_block "$RPC_BEGIN" "$RPC_END")"
    printf '%s\n' "$block" | caddy_block_domain
}

# 0 (true) when two hostnames name the same site (case-insensitive, trailing dot ignored).
caddy_same_host() {
    local a b
    a="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"; a="${a%.}"
    b="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"; b="${b%.}"
    [[ -n "$a" && "$a" == "$b" ]]
}

# Same-domain guard. The dashboard and the public RPC endpoint are two Caddy sites and
# cannot share a hostname (caddy rejects the pair as an "ambiguous site definition").
# Echo why <domain> cannot host <kind> (rpc|dashboard) because the OTHER vhost already
# serves it, and return 0; return 1 (echo nothing) when there is no clash. Callers die
# BEFORE writing anything. Never resolve a clash by dropping the dashboard block --
# that would silently lose the operator's password hash.
caddy_domain_clash() {
    local kind="$1" domain="$2" other
    if [[ "$kind" == "rpc" ]]; then
        other="$(caddy_current_dashboard_domain)"
        caddy_same_host "$domain" "$other" || return 1
        printf '%s' "${domain} already serves the Node Manager dashboard -- the dashboard and the public RPC endpoint need DIFFERENT hostnames. The node's public name (e.g. nodeN.adiri.telcoin.network) should carry the RPC endpoint, with the dashboard on another hostname (e.g. dashboard.${domain}). Nothing was changed. To move the dashboard (same login) and enable RPC in one step, first create the DNS A record for dashboard.${domain} pointing at this server (Caddy requests a certificate for it), then run: sudo bash ${SCRIPT_DIR}/install-caddy.sh --phase=rpc-enable --rpc-domain ${domain} --move-dashboard-to dashboard.${domain}"
    else
        other="$(caddy_current_rpc_domain)"
        caddy_same_host "$domain" "$other" || return 1
        printf '%s' "${domain} already serves the public RPC endpoint -- the dashboard and the public RPC endpoint need DIFFERENT hostnames. The node's public name (e.g. nodeN.adiri.telcoin.network) should carry the RPC endpoint; put the dashboard on another hostname (e.g. dashboard.${domain}). Nothing was changed."
    fi
    return 0
}

# Compose + write the single managed Caddyfile from two block bodies (each a file
# path; empty/missing -> that vhost omitted) through caddy_swap_in (validate, backup,
# atomic rename). Never clobbers a working live config: a validation failure dies with
# the live file untouched. Each block's bytes are emitted verbatim (no re-parsing).
caddy_write_managed() {
    local dash="$1" rpc="$2" tmp
    mkdir -p "$CADDY_DIR"
    tmp="$(mktemp "${CADDYFILE}.tn-new.XXXXXX")"   # same filesystem -> atomic mv
    caddy_tmp_track "$tmp"
    {
        printf '%s\n' "$CADDY_MARKER"
        printf '# Single managed Caddyfile. Per-vhost blocks are fenced below; install-caddy.sh\n'
        printf '# toggles each independently and preserves the other block verbatim.\n'
        printf '# Global options: the admin API listens on a unix socket only.\n'
        printf '{\n'
        printf '\tadmin %s\n' "$CADDY_ADMIN_ADDR"
        printf '}\n'
        if [[ -n "$dash" && -s "$dash" ]]; then
            printf '\n%s\n' "$DASH_BEGIN"
            cat "$dash"
            printf '%s\n' "$DASH_END"
        fi
        if [[ -n "$rpc" && -s "$rpc" ]]; then
            printf '\n%s\n' "$RPC_BEGIN"
            cat "$rpc"
            printf '%s\n' "$RPC_END"
        fi
    } > "$tmp"
    caddy_swap_in "$tmp"
}

# Install candidate <tmp> (created INSIDE ${CADDY_DIR}, so the final mv is an atomic
# same-filesystem rename) as the live Caddyfile:
#   1. `caddy validate` it with the output SHOWN to the operator (hashes redacted); on
#      failure remove it and die -- the live file is untouched;
#   2. keep the true pre-Telcoin config once (Caddyfile.tn-orig, root 0600, never our
#      own file);
#   3. back up the live file to Caddyfile.bak.<YYYYmmdd_HHMMSS> (root 0600; never
#      clobbers an existing backup) and record it in CADDY_LAST_BACKUP for
#      caddy_apply_live;
#   4. write <tmp> over the live file through tn_write_root_file: root:caddy 0640
#      (root:root 0644 while there is no caddy group), then remove <tmp>;
#   5. prune the timestamped backups to the newest CADDY_KEEP_BACKUPS.
# <validate>=novalidate skips step 1 (said so) -- only caddy_teardown passes it, when
# the caddy binary is gone and there is nothing to validate with.
caddy_swap_in() {
    local tmp="$1" validate="${2:-validate}" rc=0 bak=""
    CADDY_LAST_BACKUP=""
    CADDY_SWAPPED=false
    if [[ "$validate" == "novalidate" ]]; then
        caddy_say info "Caddy is not installed -- writing the new Caddyfile without 'caddy validate'."
    else
        print_info "Validating the new Caddyfile (caddy validate)..."
        caddy validate --adapter caddyfile --config "$tmp" 2>&1 | caddy_redact_hashes | caddy_emit_lines || rc="${PIPESTATUS[0]}"
    fi
    if [[ "$rc" -ne 0 ]]; then
        rm -f "$tmp"
        die "the new Caddyfile failed validation (caddy validate exit ${rc}, output above) -- live config ${CADDYFILE} left unchanged"
    fi
    if [[ -f "$CADDYFILE" && ! -f "$CADDYFILE_ORIG" ]] && ! grep -qF "$CADDY_MARKER" "$CADDYFILE" 2>/dev/null; then
        tn_write_root_file "$CADDYFILE_ORIG" 0600 < "$CADDYFILE" \
            || { rm -f "$tmp"; die "could not keep a copy of the current Caddyfile as ${CADDYFILE_ORIG} -- live config ${CADDYFILE} left unchanged"; }
    fi
    if [[ -f "$CADDYFILE" ]]; then
        bak="${CADDYFILE}.bak.$(date +%Y%m%d_%H%M%S)"
        while [[ -e "$bak" || -L "$bak" ]]; do
            sleep 1
            bak="${CADDYFILE}.bak.$(date +%Y%m%d_%H%M%S)"
        done
        tn_write_root_file "$bak" 0600 < "$CADDYFILE" \
            || { rm -f "$tmp"; die "could not back up the live Caddyfile to ${bak} -- live config ${CADDYFILE} left unchanged"; }
        CADDY_LAST_BACKUP="$bak"
        caddy_say info "Backed up the live Caddyfile to ${bak}"
    fi
    caddy_live_write < "$tmp" || { rm -f "$tmp"; die "could not write ${CADDYFILE} -- it is unchanged"; }
    rm -f "$tmp"
    CADDY_SWAPPED=true
    caddy_prune_backups
}

# caddy_live_group -- the group the live Caddyfile gets: caddy when that group
# exists (Caddy runs as user caddy), else root.
caddy_live_group() {
    if getent group caddy >/dev/null 2>&1; then echo caddy; else echo root; fi
}

# Write stdin over the live Caddyfile: root:caddy 0640, or root:root 0644 when there
# is no caddy group (Caddy not installed). tn_write_root_file's return code.
caddy_live_write() {
    if [[ "$(caddy_live_group)" == "caddy" ]]; then
        tn_write_root_file "$CADDYFILE" 0640 caddy
    else
        tn_write_root_file "$CADDYFILE" 0644
    fi
}

# Delete all but the newest CADDY_KEEP_BACKUPS timestamped backups
# (Caddyfile.bak.<YYYYmmdd_HHMMSS>; the names sort in time order). Never deletes
# CADDY_LAST_BACKUP (what this run restores if Caddy rejects the reload) or
# Caddyfile.tn-orig, nor a file whose suffix is not exactly that timestamp. Best
# effort: a file that cannot be removed is left.
caddy_prune_backups() {
    local f suffix n i
    local -a found=() sorted=()
    for f in "${CADDYFILE}".bak.[0-9]*_[0-9]*; do
        [[ -f "$f" && ! -L "$f" ]] || continue
        suffix="${f#"${CADDYFILE}.bak."}"
        [[ "$suffix" =~ ^[0-9]{8}_[0-9]{6}$ ]] || continue
        # Backups written by an older release were 0644; none stays readable.
        chmod 0600 "$f" 2>/dev/null || true
        found+=("$f")
    done
    if [[ -f "$CADDYFILE_ORIG" && ! -L "$CADDYFILE_ORIG" ]]; then
        chmod 0600 "$CADDYFILE_ORIG" 2>/dev/null || true
    fi
    n=${#found[@]}
    [[ "$n" -gt "$CADDY_KEEP_BACKUPS" ]] || return 0
    while IFS= read -r f; do
        sorted+=("$f")
    done < <(printf '%s\n' "${found[@]}" | LC_ALL=C sort)
    i=0
    while [[ "$i" -lt $(( n - CADDY_KEEP_BACKUPS )) ]]; do
        f="${sorted[$i]}"
        if [[ "$f" != "$CADDY_LAST_BACKUP" && "$f" != "$CADDYFILE_ORIG" ]]; then
            rm -f "$f" 2>/dev/null || true
        fi
        i=$(( i + 1 ))
    done
    return 0
}

# Put CADDY_LAST_BACKUP back as the live Caddyfile (byte-identical, root:caddy 0640
# through tn_write_root_file). 1 when this run swapped nothing / there is no backup.
caddy_restore_backup() {
    local bak="$CADDY_LAST_BACKUP"
    [[ "$CADDY_SWAPPED" == "true" && -n "$bak" && -f "$bak" && ! -L "$bak" ]] || return 1
    caddy_live_write < "$bak"
}

# The command an operator runs to put <backup> back by hand.
caddy_restore_hint() {
    printf 'sudo install -m 0640 -o root -g caddy %s %s && sudo systemctl restart caddy' "$1" "${CADDYFILE#"${TN_ROOT_PREFIX:-}"}"
}

# caddy_admin_addr <file> -- print the admin address <file> gives Caddy in its global
# options (`off`, `unix//path|mode`, `localhost:2019`, ...), or `default` when it sets
# none. Comments are ignored.
caddy_admin_addr() {
    local a
    a="$(awk '{ sub(/(^|[[:space:]])#.*$/, "") }
        match($0, /(^|[[:space:]{])admin[[:space:]]+[^[:space:]{}]+/) {
            s = substr($0, RSTART, RLENGTH); sub(/^.*admin[[:space:]]+/, "", s); print s; exit
        }' "$1" 2>/dev/null)" || a=""
    printf '%s\n' "${a:-default}"
}

# 0 (true) when the Caddyfile this run replaced (CADDY_LAST_BACKUP; Caddy's default
# when there was none) and the live one name different admin addresses. `systemctl
# reload caddy` sends the new config to the admin address the NEW file names, which
# the running Caddy is not listening on, so such a change needs a restart.
caddy_admin_changed() {
    local old="default" new
    [[ "$CADDY_SWAPPED" == "true" ]] || return 1
    if [[ -n "$CADDY_LAST_BACKUP" && -f "$CADDY_LAST_BACKUP" ]]; then
        old="$(caddy_admin_addr "$CADDY_LAST_BACKUP")"
    fi
    new="$(caddy_admin_addr "$CADDYFILE")"
    [[ "$old" != "$new" ]]
}

# Write (or, with `remove`, delete) the caddy.service drop-in that gives Caddy its
# runtime directory /run/caddy (0750) for the admin socket, then reload systemd when
# the drop-in changed. rc 1 when it could not be written.
caddy_admin_dropin() {
    local want body dir="${CADDY_ADMIN_DROPIN%/*}"
    if [[ "${1:-}" == "remove" ]]; then
        [[ -e "$CADDY_ADMIN_DROPIN" || -L "$CADDY_ADMIN_DROPIN" ]] || return 0
        rm -f -- "$CADDY_ADMIN_DROPIN"
        rmdir -- "$dir" 2>/dev/null || true
        systemctl daemon-reload 2>/dev/null || true
        return 0
    fi
    want="$(printf '%s\n' '# Written by install-caddy.sh: runtime directory for the admin API socket.' \
        '[Service]' 'RuntimeDirectory=caddy' 'RuntimeDirectoryMode=0750')"
    if [[ -f "$CADDY_ADMIN_DROPIN" && ! -L "$CADDY_ADMIN_DROPIN" ]]; then
        body="$(cat "$CADDY_ADMIN_DROPIN" 2>/dev/null || true)"
        [[ "$body" == "$want" ]] && return 0
    fi
    if [[ ! -d "$dir" ]]; then
        install -d -o root -g root -m 0755 -- "$dir" || return 1
    fi
    tn_write_root_file "$CADDY_ADMIN_DROPIN" 0644 <<< "$want" || return 1
    systemctl daemon-reload 2>/dev/null || caddy_say warn "systemctl daemon-reload failed after writing ${CADDY_ADMIN_DROPIN}."
    return 0
}

# Put the freshly swapped-in Caddyfile into effect. Caddy ACTIVE -> `systemctl reload`
# (graceful: Caddy keeps serving its old config when it rejects the new one). Only a
# FAILED reload command restores the backup over the live file, so disk matches what
# Caddy still runs, and dies non-zero naming the backup -- NEVER a fallback restart,
# which would take every vhost down on a bad config. A reload that succeeds but leaves
# Caddy inactive a second later dies saying exactly that (the new config stays on
# disk). One exception to reload-only: when the admin address changes between the
# replaced file and the new one (the first switch to the admin socket, an operator
# Caddyfile with `admin off` taken over after confirmation, a teardown back to Caddy's
# default) no reload can reach the running Caddy, so that apply is a `systemctl
# restart`, with the reason printed. Caddy NOT active -> `systemctl restart` (first
# start) and die if it does not come up. Every caller stops on that die, so e.g.
# rpc-enable never advertises an endpoint whose vhost failed to load.
caddy_apply_live() {
    if systemctl is-active --quiet caddy 2>/dev/null; then
        if caddy_admin_changed; then
            caddy_say info "The new Caddyfile moves Caddy's admin API ($(caddy_admin_addr "${CADDY_LAST_BACKUP:-/dev/null}") -> $(caddy_admin_addr "$CADDYFILE")), and 'systemctl reload' cannot reach the running Caddy across that change -- restarting Caddy once to apply the new config (later changes reload)."
            systemctl restart caddy || die "caddy failed to restart with the new config and is DOWN (check: journalctl -u caddy). To go back: $(caddy_restore_hint "${CADDY_LAST_BACKUP:-<backup>}")"
            sleep 1
            systemctl is-active --quiet caddy || die "caddy is not active after the restart with the new config (check: journalctl -u caddy). To go back: $(caddy_restore_hint "${CADDY_LAST_BACKUP:-<backup>}")"
            return 0
        fi
        if ! systemctl reload caddy; then
            if caddy_restore_backup; then
                die "caddy rejected the new config on reload -- restored the previous Caddyfile from ${CADDY_LAST_BACKUP} (Caddy was NOT restarted and keeps serving the previous config). Check: journalctl -u caddy"
            fi
            die "caddy rejected the new config on reload and there is no previous Caddyfile to restore -- ${CADDYFILE} holds the rejected config (Caddy was NOT restarted). Check: journalctl -u caddy"
        fi
        sleep 1
        systemctl is-active --quiet caddy 2>/dev/null && return 0
        die "caddy accepted the new config (the reload succeeded) but is no longer active a second later -- ${CADDYFILE} holds the NEW config (not restored; previous Caddyfile: ${CADDY_LAST_BACKUP:-none}). Check: journalctl -u caddy"
    fi
    systemctl restart caddy || die "caddy failed to start with the new config (check: journalctl -u caddy). Previous Caddyfile: ${CADDY_LAST_BACKUP:-none}"
    sleep 1
    systemctl is-active --quiet caddy || die "caddy is not active after start (check: journalctl -u caddy). Previous Caddyfile: ${CADDY_LAST_BACKUP:-none}"
}

# Enable caddy at boot, give it the admin socket directory, then apply the new config
# (reload if running, else first start).
caddy_reload() {
    systemctl enable caddy >/dev/null 2>&1 || true
    caddy_admin_dropin || die "could not write ${CADDY_ADMIN_DROPIN}, which Caddy needs for its admin socket. ${CADDYFILE} holds the new config; Caddy was not reloaded."
    caddy_apply_live
}

# Full teardown when NO managed vhost remains: restore the pre-Telcoin config (or a
# disabled stub) through the same validate -> backup -> atomic swap -> reload path,
# then close 80/443. A failed validate or reload says so and exits non-zero (a rejected
# reload restores the backup); the pre-Telcoin copy is consumed only after success.
# Caddy uninstalled but a Caddyfile left behind: the file is still rewritten (no
# validate, no reload -- said so) and 80/443 closed, so no stale RPC block keeps
# rpc-status reporting "enabled" and no port stays open for a proxy that is gone.
caddy_teardown() {
    local tmp restored_orig=false have_caddy=true
    command -v caddy >/dev/null 2>&1 || have_caddy=false
    if [[ "$have_caddy" != "true" && ! -f "$CADDYFILE" && ! -f "$CADDYFILE_ORIG" ]]; then
        print_info "Caddy is not installed and there is no ${CADDYFILE} -- nothing to tear down."
        return 0
    fi
    mkdir -p "$CADDY_DIR"
    tmp="$(mktemp "${CADDYFILE}.tn-new.XXXXXX")"
    caddy_tmp_track "$tmp"
    if [[ -f "$CADDYFILE_ORIG" ]]; then
        print_info "No managed vhost remains -- restoring the pre-Telcoin Caddy config (${CADDYFILE_ORIG})."
        cat "$CADDYFILE_ORIG" > "$tmp"
        restored_orig=true
    else
        print_info "No managed vhost remains -- writing a disabled Caddyfile stub."
        printf '# Telcoin Node Manager: external access disabled.\n' > "$tmp"
    fi
    if [[ "$have_caddy" == "true" ]]; then
        caddy_swap_in "$tmp"
        # The restored or stub file names its own admin address (or the default);
        # Caddy no longer needs the socket directory.
        caddy_admin_dropin remove
        caddy_apply_live
    else
        caddy_admin_dropin remove
        caddy_swap_in "$tmp" novalidate
        caddy_say info "Caddy is not installed -- ${CADDYFILE} was rewritten; there is no Caddy service to reload."
    fi
    [[ "$restored_orig" == "true" ]] && rm -f "$CADDYFILE_ORIG"
    caddy_close_ports
}

# Write the DASHBOARD vhost block (content only, no fences) to <outfile>. printf (not
# heredoc) so the bcrypt hash -- which contains $ and / -- is inserted verbatim with
# no shell re-expansion. header_up is a Set, which REPLACES any client-supplied value
# -- unforgeable (a public client cannot strip it; the SSH-tunnel path never carries
# it). Do NOT also delete it: Caddy applies header ops in Add->Set->Delete order.
# The response headers: HSTS, no MIME sniffing, no framing, no referrer, and no
# Server header; request bodies are capped at 64KB (the public dashboard is read-only).
write_dashboard_block() {
    local domain="$1" username="$2" hash="$3" outfile="$4"
    {
        printf '# Node Manager dashboard. Public access is READ-ONLY (X-TN-Dashboard-Public);\n'
        printf '# management stays on the SSH tunnel.\n'
        printf '%s {\n' "$domain"
        printf '\tencode zstd gzip\n'
        printf '\theader {\n'
        printf '\t\tStrict-Transport-Security "max-age=31536000"\n'
        printf '\t\tX-Content-Type-Options "nosniff"\n'
        printf '\t\tX-Frame-Options "DENY"\n'
        printf '\t\tReferrer-Policy "no-referrer"\n'
        printf '\t\t-Server\n'
        printf '\t}\n'
        printf '\trequest_body {\n'
        printf '\t\tmax_size 64KB\n'
        printf '\t}\n'
        printf '\treverse_proxy %s {\n' "$UI_UPSTREAM"
        printf '\t\theader_up %s "1"\n' "$PUBLIC_HEADER"
        printf '\t\tflush_interval -1\n'
        printf '\t}\n'
        printf '\tbasic_auth {\n'
        printf '\t\t%s %s\n' "$username" "$hash"
        printf '\t}\n'
        printf '}\n'
    } > "$outfile"
}

# Print the page a browser gets from the public RPC hostname <domain> (GET or HEAD
# without an Upgrade header; the RPC block answers it with 405), each line prefixed
# with <indent>. Lines tagged @WS@ (the wss:// sentence) are printed only when
# <with_ws> is true, i.e. when the WebSocket endpoint is served. It is authored here
# and served inline from the Caddyfile, so rpc-disable removes it with the block,
# `caddy validate` checks it and the backups keep it. Rules that keep it safe inside a
# Caddy heredoc: no blank lines, no curly braces anywhere (the curl example writes them
# as &#123; and &#125;, which browsers decode) and inline style="" only. <domain> is a
# validated [a-z0-9.-] name.
caddy_rpc_page() {
    local domain="$1" indent="$2" with_ws="${3:-true}" line
    while IFS= read -r line; do
        if [[ "$line" == @WS@* ]]; then
            [[ "$with_ws" == "true" ]] || continue
            line="${line#@WS@}"
        fi
        printf '%s%s\n' "$indent" "${line//@DOMAIN@/$domain}"
    done <<'HTML'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>@DOMAIN@ - Telcoin Network JSON-RPC</title>
</head>
<body style="margin:0;padding:24px 16px;background:#f4f5f7;color:#1c2330;font-family:system-ui,-apple-system,Segoe UI,Roboto,sans-serif;font-size:16px;line-height:1.5">
<main style="max-width:640px;margin:0 auto;padding:24px;background:#ffffff;border:1px solid #d5d9e0;border-radius:8px">
<h1 style="margin:0 0 12px;font-size:20px;overflow-wrap:anywhere">@DOMAIN@</h1>
<p style="margin:0 0 12px">This is the JSON-RPC endpoint of a Telcoin Network node, for wallets, dapps and scripts. Send JSON-RPC requests to https://@DOMAIN@/ with HTTP POST. A browser visit only shows this page.</p>
@WS@<p style="margin:0 0 12px">WebSocket clients (subscriptions) connect to wss://@DOMAIN@/.</p>
<p style="margin:0 0 8px">Check that it answers (the result is the chain id in hex):</p>
<pre style="margin:0 0 12px;padding:12px;background:#f4f5f7;border:1px solid #d5d9e0;border-radius:6px;overflow-x:auto;font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:13px">curl -s -X POST -H "Content-Type: application/json" --data '&#123;"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1&#125;' https://@DOMAIN@/</pre>
<p style="margin:0">Network documentation: <a href="https://docs.telcoin.network/" style="color:#1554c0">docs.telcoin.network</a></p>
</main>
</body>
</html>
HTML
}

# Write the RPC vhost block (content only, no fences) to <outfile>: block v2, stamped
# with RPC_BLOCK_STAMP on its first comment line. Self-contained (no `import`):
#   - OPTIONS preflight -> empty 200 + CORS;
#   - WebSocket upgrade -> reth WS port. The Connection / Upgrade match ignores case:
#     Caddy's `header` matcher is case-sensitive, and Google's balancer and nginx send
#     `Connection: upgrade`, which block v1 answered with 405;
#   - GET / HEAD without an Upgrade header (a browser) -> 405 with Allow and the page
#     from caddy_rpc_page, instead of reth's bare error;
#   - everything else -> reth HTTP port + CORS, request bodies capped at 2 MB (the
#     largest legitimate JSON-RPC request is about 256 KiB; reth's own cap is 15 MB).
#     No server timeouts (they would cut WebSocket sessions and long eth_getLogs
#     answers) and no per-IP limits (carrier NAT puts many users behind one address).
# 127.0.0.1 (not localhost) matches reth's IPv4 loopback bind (http_addr/ws_addr
# default to Ipv4Addr::LOCALHOST). Tabs keep the file `caddy fmt`-clean, heredoc
# included. Ports come from the node launch (--http.port / --ws.port), else
# .node-meta (RPC_PORT / WS_PORT), else 8545/8546 (caddy_node_port); a port outside
# 1024-65535 or the Node Manager's own port is refused before anything is written.
# <with_ws> (default true) only decides whether the page mentions wss://; the
# WebSocket route is always there.
write_rpc_block() {
    local domain="$1" outfile="$2" with_ws="${3:-true}"
    local rpc_port ws_port
    rpc_port="${CADDY_RPC_PORT:-}"
    [[ -n "$rpc_port" ]] || rpc_port="$(caddy_node_port --http.port RPC_PORT 8545)" || die "no usable reth HTTP port for the public RPC site (see above). Nothing was changed."
    ws_port="$(caddy_ws_port)" || die "no usable reth WebSocket port for the public RPC site (see above). Nothing was changed."
    {
        printf '%s: public JSON-RPC + WebSocket endpoint, written by\n' "$RPC_BLOCK_STAMP"
        printf '# install-caddy.sh rpc-enable (run it again with the same hostname to rewrite\n'
        printf '# this block). Reverse proxy to reth on loopback; CORS and the OPTIONS preflight\n'
        printf '# are answered here, a browser GET gets a short page (405), and request bodies\n'
        printf '# are capped at 2 MB.\n'
        printf '%s {\n' "$domain"
        printf '\tencode zstd gzip\n'
        printf '\t@preflight method OPTIONS\n'
        printf '\thandle @preflight {\n'
        printf '\t\theader Access-Control-Allow-Origin "*"\n'
        printf '\t\theader Access-Control-Allow-Methods "POST, GET, OPTIONS"\n'
        printf '\t\theader Access-Control-Allow-Headers "X-Requested-With, Content-Type"\n'
        printf '\t\trespond 200\n'
        printf '\t}\n'
        printf '\t@websocket {\n'
        printf '\t\theader_regexp wsconn Connection (?i)upgrade\n'
        printf '\t\theader_regexp wsup Upgrade (?i)websocket\n'
        printf '\t}\n'
        printf '\thandle @websocket {\n'
        printf '\t\treverse_proxy 127.0.0.1:%s\n' "$ws_port"
        printf '\t}\n'
        printf '\t@browser {\n'
        printf '\t\tmethod GET HEAD\n'
        printf '\t\theader !Upgrade\n'
        printf '\t}\n'
        printf '\thandle @browser {\n'
        printf '\t\theader Allow "POST, OPTIONS"\n'
        printf '\t\theader Content-Type "text/html; charset=utf-8"\n'
        printf '\t\trespond <<TNPAGE\n'
        caddy_rpc_page "$domain" $'\t\t\t' "$with_ws"
        printf '\t\t\tTNPAGE 405\n'
        printf '\t}\n'
        printf '\thandle {\n'
        printf '\t\theader Access-Control-Allow-Origin "*"\n'
        printf '\t\theader Access-Control-Allow-Methods "POST, GET, OPTIONS"\n'
        printf '\t\theader Access-Control-Allow-Headers "X-Requested-With, Content-Type"\n'
        printf '\t\trequest_body {\n'
        printf '\t\t\tmax_size 2MB\n'
        printf '\t\t}\n'
        printf '\t\treverse_proxy 127.0.0.1:%s\n' "$rpc_port"
        printf '\t}\n'
        printf '}\n'
    } > "$outfile"
}

# caddy_proxy_port_ok <port> -- 0 when <port> is a decimal port 1024-65535 other than
# the Node Manager UI's (CADDY_UI_PORT): the only ports the public RPC site may proxy to.
caddy_proxy_port_ok() {
    local p="${1:-}"
    [[ "$p" =~ ^[0-9]{1,5}$ ]] || return 1
    p=$((10#$p))
    [[ "$p" -ge 1024 && "$p" -le 65535 && "$p" -ne "$CADDY_UI_PORT" ]]
}

# caddy_launch_port <flag> -- print the value the node launch file gives <flag>
# (--http.port, --ws.port); rc 1 when there is no readable launch file or no flag.
caddy_launch_port() {
    local target svc method file
    declare -F tn_node_launch_target >/dev/null 2>&1 || return 1
    declare -F tn_launch_flag_get >/dev/null 2>&1 || return 1
    target="$(tn_node_launch_target 2>/dev/null)" || return 1
    read -r svc method file <<< "$target"
    [[ -n "$file" && -f "$file" ]] || return 1
    tn_launch_flag_get "$file" "$1" 2>/dev/null
}

# caddy_node_port <flag> <meta-key> <default> -- print the port reth listens on for
# <flag>: the node launch file first (what the node really runs with), else
# .node-meta <meta-key>, else <default>. rc 1 (message on stderr) when the value is
# not a port 1024-65535 or is the Node Manager UI port; rc 2 when <meta-key> is
# set more than once in .node-meta.
caddy_node_port() {
    local flag="$1" key="$2" dflt="$3" v src
    src="the node launch (${flag})"
    v="$(caddy_launch_port "$flag")" || v=""
    if [[ -z "$v" ]]; then
        src=".node-meta ${key}"
        v="$(addon_meta_get "$key" "")" || return 2
    fi
    if [[ -z "$v" ]]; then
        src="the default"
        v="$dflt"
    fi
    if ! caddy_proxy_port_ok "$v"; then
        print_error "Refusing port '${v}' from ${src} as a proxy target: it must be 1024-65535 and not the Node Manager port ${CADDY_UI_PORT}." >&2
        return 1
    fi
    printf '%s\n' "$((10#$v))"
}

# 0 (true) when the managed Caddyfile holds a tn-rpc block without RPC_BLOCK_STAMP:
# written by install-caddy.sh 1.3.0 or older (case-sensitive WebSocket match, no body
# cap, no browser page). rpc-enable with the same hostname rewrites it: a Caddy
# reload, and no node restart when node-info.yaml and the launch file need no change.
caddy_rpc_block_stale() {
    local block
    caddy_block_present "$RPC_BEGIN" || return 1
    block="$(caddy_extract_block "$RPC_BEGIN" "$RPC_END")"
    [[ "$block" != *"$RPC_BLOCK_STAMP"* ]]
}

# Shared preflight for any vhost enable: ports 80/443 free (caddy itself ignored) and
# we are not about to clobber a foreign Caddy config.
caddy_assert_ports_free() {
    local h80 h443
    h80=$(caddy_port_holder 80); h443=$(caddy_port_holder 443)
    [[ -n "$h80" ]]  && die "port 80 is in use by '${h80}' -- Caddy needs it and cannot share with another web server. Stop/remove it first (Apache: 'sudo systemctl disable --now apache2'), or run 'sudo bash install-caddy.sh' on the server to be guided through removing it."
    [[ -n "$h443" ]] && die "port 443 is in use by '${h443}' -- Caddy needs it and cannot share with another web server. Stop/remove it first (Apache: 'sudo systemctl disable --now apache2'), or run 'sudo bash install-caddy.sh' on the server to be guided through removing it."
    return 0
}
caddy_assert_not_foreign() {
    if caddy_foreign_config && [[ "$CADDY_OVERWRITE_FOREIGN" != "true" ]]; then
        die "an existing Caddy configuration at ${CADDYFILE} was not created by the Node Manager -- refusing to overwrite it. Run 'sudo bash install-caddy.sh' on the server to review and confirm, or back up and remove the existing config first."
    fi
}

# =============================================================================
# node-info.yaml advertisement (worker.rpc)
# =============================================================================

# Echo the running node's node-info.yaml path: <datadir>/node-info.yaml, with the
# datadir resolved exactly like fallback.sh (unified -> /var/lib/telcoin; legacy ->
# /var/lib/telcoin/<role>). May not exist; the caller checks -f. rc 2 (nothing
# printed) when DATA_DIR is set more than once in .node-meta.
caddy_node_info_path() {
    local dd rc=0
    # A DATA_DIR on more than one line has no single value: stop (rc 2, said by
    # addon_meta_get) instead of falling back to the default data dir.
    addon_meta_get DATA_DIR >/dev/null || return 2
    dd="$(tn_resolve_data_dir 2>/dev/null)" || rc=$?
    [[ "$rc" -ne 2 ]] || return 2
    printf '%s/node-info.yaml\n' "${dd:-/var/lib/telcoin}"
}

# Read or edit ONLY worker 0's `rpc:` in node-info.yaml via a python3 stdlib line editor
# (PyYAML is not guaranteed on a node) -- the fallback for `keytool set-rpc`, which
# caddy_node_info_write prefers, and the reader when lib/common.sh has no
# tn_node_info_rpc. Handles BOTH on-disk shapes:
#   current (telcoin-network >= v0.15 keytool):  p2p_info: {primary, workers: [ {..}, .. ]}
#     -> set/clear `rpc` on the FIRST workers entry, as `keytool set-rpc` does;
#   legacy:                                       p2p_info: {primary, worker: {..}}
#     -> set/clear worker.rpc.
# mode=set writes http (+ ws when non-empty); mode=clear resets to `~`; mode=get prints
# "<http>|<ws>" of the FIRST worker ('' parts when absent) and never writes. Idempotent:
# a semantic no-op (same URLs, even if quoted differently) leaves the file byte-identical
# and unwritten. Key order and every other line are kept; primary, execution_address
# and the other workers are never touched. A change is written to a temp file in the
# same directory (the file's mode kept) and renamed over the file. Returns the python
# rc (0 ok, 2 read/write error, 3 unexpected shape).
caddy_edit_node_info() {
    local ni="$1" mode="$2" http_url="${3:-}" ws_url="${4:-}"
    # Runs as the service user (the data dir is that user's): a link planted in the
    # data dir gives the editor nothing beyond that user's own rights.
    tn_as_service_user env TN_NI_FILE="$ni" TN_NI_MODE="$mode" TN_NI_HTTP="$http_url" TN_NI_WS="$ws_url" python3 -I - <<'PYEOF'
import os, sys

path = os.environ["TN_NI_FILE"]
mode = os.environ["TN_NI_MODE"]            # "set", "clear" or "get"
http_url = os.environ.get("TN_NI_HTTP", "")
ws_url = os.environ.get("TN_NI_WS", "")
NULLS = ("", "~", "null", "Null", "NULL")

def indent(s):
    return len(s) - len(s.lstrip(" "))

def skip(s):                               # blank or comment-only line
    t = s.strip()
    return t == "" or t.startswith("#")

def key_of(text):                          # "rpc: ~" -> "rpc"
    return text.split(":", 1)[0].strip() if ":" in text else ""

def val_of(text):                          # "http: 'x'  # c" -> "x"
    v = text.split(":", 1)[1] if ":" in text else ""
    v = v.split(" #", 1)[0].strip()
    if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
        v = v[1:-1]
    return v

def fail(msg):
    sys.stderr.write("node-info.yaml: %s\n" % msg)
    sys.exit(3)

try:
    with open(path) as f:
        lines = f.readlines()
except OSError as exc:
    sys.stderr.write("cannot read %s: %s\n" % (path, exc))
    sys.exit(2)
n = len(lines)

# Top-level p2p_info: mapping (indent 0) and its extent.
p = -1
for i in range(n):
    if not skip(lines[i]) and indent(lines[i]) == 0 and key_of(lines[i]) == "p2p_info":
        p = i
        break
if p < 0:
    fail("no top-level p2p_info:")
pe = p + 1
while pe < n and (skip(lines[pe]) or indent(lines[pe]) > 0):
    pe += 1

# p2p_info's child keys (primary, workers|worker) share one indent (2 in practice).
ci = -1
for i in range(p + 1, pe):
    if not skip(lines[i]):
        ci = indent(lines[i])
        break
if ci <= 0:
    fail("empty p2p_info:")
w, wkey = -1, ""
for i in range(p + 1, pe):
    if skip(lines[i]) or indent(lines[i]) != ci:
        continue
    k = key_of(lines[i])
    if k == "workers" or (k == "worker" and wkey != "workers"):
        w, wkey = i, k
        if k == "workers":
            break
if w < 0:
    fail("no workers: (or legacy worker:) under p2p_info:")
if val_of(lines[w]).strip():
    fail("inline (flow-style) %s: is not supported" % wkey)

# Extent of the worker(s) value. A block sequence may sit at the parent key's own indent
# ("workers:\n  - ..."), so dash lines at indent ci still belong to it.
we = w + 1
while we < n:
    s = lines[we]
    if skip(s) or indent(s) > ci or (wkey == "workers" and indent(s) == ci and s.lstrip().startswith("-")):
        we += 1
        continue
    break

# Targets: one mapping per worker = (first line, end, key indent, dash line or -1).
targets = []
if wkey == "worker":
    ki = -1
    for i in range(w + 1, we):
        if not skip(lines[i]):
            ki = indent(lines[i])
            break
    if ki < 0:
        fail("empty worker:")
    targets.append((w + 1, we, ki, -1))
else:
    body = [i for i in range(w + 1, we) if not skip(lines[i])]
    if not body or not lines[body[0]].lstrip().startswith("-"):
        fail("workers: is not a non-empty block list")
    di = indent(lines[body[0]])
    items = [i for i in body if indent(lines[i]) == di and lines[i].lstrip().startswith("-")]
    for x, s0 in enumerate(items):
        e0 = items[x + 1] if x + 1 < len(items) else we
        after = lines[s0].lstrip()[1:].rstrip("\n")
        if after.strip() and not after.strip().startswith("#"):
            ki = di + 1 + (len(after) - len(after.lstrip(" ")))   # "- key:" -> key column
        else:
            ki = -1
            for i in range(s0 + 1, e0):
                if not skip(lines[i]):
                    ki = indent(lines[i])
                    break
            if ki < 0:
                fail("empty workers: entry")
        targets.append((s0, e0, ki, s0))

def key_text(i, ki, dl):                   # key text of line i in a target, else None
    if i == dl:
        return lines[i].lstrip()[1:].strip()
    return lines[i].strip() if indent(lines[i]) == ki else None

def scan(t):                               # -> (rpc line, rpc value end, last content line, current)
    s0, e0, ki, dl = t
    rpc, last = -1, s0
    for i in range(s0, e0):
        if skip(lines[i]):
            continue
        last = i
        kt = key_text(i, ki, dl)
        if rpc < 0 and kt is not None and key_of(kt) == "rpc":
            rpc = i
    if rpc < 0:
        return -1, -1, last, None
    r_end = rpc + 1
    while r_end < e0 and not skip(lines[r_end]) and indent(lines[r_end]) > ki:
        r_end += 1
    inline = val_of(key_text(rpc, ki, dl))
    if inline in NULLS and r_end == rpc + 1:
        cur = None
    elif inline == "":
        cur = {}
        for i in range(rpc + 1, r_end):
            k, v = key_of(lines[i]), val_of(lines[i])
            if v not in NULLS:
                cur[k] = v
    else:
        cur = "unparsed:" + inline         # flow style etc. -> always rewritten
    return rpc, r_end, last, cur

if mode == "get":
    rpc, r_end, last, cur = scan(targets[0])
    if isinstance(cur, dict):
        print("%s|%s" % (cur.get("http", ""), cur.get("ws", "")))
    else:
        print("|")
    sys.exit(0)

if mode == "set":
    want = {"http": http_url}
    if ws_url:
        want["ws"] = ws_url
else:
    want = None

edits = []                                 # (start, end, replacement lines)
for t in targets[:1]:                      # worker 0 only, matching keytool set-rpc
    s0, e0, ki, dl = t
    rpc, r_end, last, cur = scan(t)
    if cur == want:
        continue                           # already as wanted (null/absent == cleared)
    pad = " " * ki
    if want is None:
        new = [pad + "rpc: ~\n"]
    else:
        new = [pad + "rpc:\n", pad + "  http: " + http_url + "\n"]
        if ws_url:
            new.append(pad + "  ws: " + ws_url + "\n")
    if rpc < 0:
        if want is None:
            continue                       # absent == not advertised -> no change
        edits.append((last + 1, last + 1, new))
    else:
        if rpc == dl:                      # rpc was the entry's first key: keep its "- "
            d = indent(lines[rpc])
            new[0] = " " * d + "-" + " " * (ki - d - 1) + new[0].lstrip(" ")
        edits.append((rpc, r_end, new))

if not edits:
    sys.exit(0)
out = list(lines)
for start, end, new in sorted(edits, reverse=True):
    out[start:end] = new

# Write a temp file in the same directory, then rename it over the file: a stop at
# any point leaves the old file or the new one, never a half-written one. The temp
# file is removed on an error or on TERM, INT or HUP.
import signal, stat, tempfile

def _stop(signum, frame):
    raise SystemExit(128 + signum)

for _sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
    signal.signal(_sig, _stop)
tmp = None
try:
    try:
        mode_bits = stat.S_IMODE(os.stat(path).st_mode)
        fd, tmp = tempfile.mkstemp(prefix=".node-info.", suffix=".tmp",
                                   dir=os.path.dirname(os.path.abspath(path)))
        with os.fdopen(fd, "w") as f:
            f.writelines(out)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, mode_bits)
        os.replace(tmp, path)
        tmp = None
    except OSError as exc:
        sys.stderr.write("cannot write %s: %s\n" % (path, exc))
        sys.exit(2)
finally:
    if tmp is not None:
        try:
            os.unlink(tmp)
        except OSError:
            pass
sys.exit(0)
PYEOF
}

# Echo "<http> <ws>" that worker 0 of <ni> advertises, "none" for an absent part:
# tn_node_info_rpc (lib/common.sh 1.6.0), else the python3 reader. rc 1 when it
# cannot be read (no reader, missing file, unexpected layout). Prints nothing else:
# the status phases use it, and their stdout is one JSON object.
caddy_node_info_rpc_get() {
    local ni="$1" out h w
    if declare -F tn_node_info_rpc >/dev/null 2>&1; then
        out="$(tn_node_info_rpc "$ni" 0 2>/dev/null)" || return 1
        [[ -n "$out" ]] || return 1
        printf '%s\n' "$out"
        return 0
    fi
    [[ -r "$ni" ]] || return 1
    command -v python3 >/dev/null 2>&1 || return 1
    out="$(caddy_edit_node_info "$ni" get 2>/dev/null)" || return 1
    [[ "$out" == *"|"* ]] || return 1
    h="${out%%|*}"
    w="${out#*|}"
    printf '%s %s\n' "${h:-none}" "${w:-none}"
}

# 0 (true) when node-info.yaml can be edited on this host: python3 is present, or
# lib/common.sh can run keytool through the runner named in the node launch file.
caddy_node_info_can_edit() {
    command -v python3 >/dev/null 2>&1 && return 0
    declare -F tn_keytool >/dev/null 2>&1 || return 1
    declare -F tn_launch_runner >/dev/null 2>&1 || return 1
    tn_launch_runner >/dev/null 2>&1
}

# caddy_run_dir -- create this run's root-only directory on first use (mktemp -d
# under TN_CADDY_RUN_PARENT, default /run; mode 0700) and set CADDY_RUN_DIR to it.
# It holds the node-info.yaml backup and the launch dry-run copy, and the EXIT trap
# removes it. Call it directly, never in $(...): CADDY_RUN_DIR and the EXIT trap's
# list must be set in this shell. rc 1 when it cannot be created.
caddy_run_dir() {
    if [[ -z "$CADDY_RUN_DIR" || ! -d "$CADDY_RUN_DIR" ]]; then
        CADDY_RUN_DIR="$(mktemp -d "${TN_CADDY_RUN_PARENT:-/run}/tn-caddy.XXXXXX")" || { CADDY_RUN_DIR=""; return 1; }
        caddy_tmp_track "$CADDY_RUN_DIR"
        chmod 0700 "$CADDY_RUN_DIR" || return 1
    fi
    return 0
}

# caddy_ni_backup <ni> -- copy node-info.yaml, read as the service user, into the
# root-only run directory (CADDY_NI_BAK). rc 1 when it cannot be read or copied.
caddy_ni_backup() {
    caddy_run_dir || return 1
    CADDY_NI_FILE="$1"
    CADDY_NI_BAK="${CADDY_RUN_DIR}/node-info.yaml"
    if ! tn_as_service_user cat -- "$1" > "$CADDY_NI_BAK"; then
        rm -f -- "$CADDY_NI_BAK"
        CADDY_NI_BAK=""
        return 1
    fi
    return 0
}

# caddy_ni_restore <ni> -- write the backup back over <ni> as the service user (root
# only opens the backup). rc 1 when there is no backup or the write failed.
caddy_ni_restore() {
    [[ -n "$CADDY_NI_BAK" && -f "$CADDY_NI_BAK" ]] || return 1
    # shellcheck disable=SC2016  # $1 expands in the service user's sh, not here
    tn_as_service_user sh -c 'cat > "$1"' sh "$1" < "$CADDY_NI_BAK"
}

# Drop the node-info.yaml backup (the edit was kept).
caddy_ni_discard() {
    [[ -n "$CADDY_NI_BAK" ]] && rm -f -- "$CADDY_NI_BAK"
    CADDY_NI_BAK=""
    return 0
}

# Make worker 0 of <ni> advertise <http> (+ <ws> when non-empty) for mode=set, or
# nothing for mode=clear, then read it back and compare. The caller has backed <ni>
# up (caddy_ni_backup). Prefers `keytool set-rpc` run by the node's own release, through
# tn_launch_runner + tn_keytool (lib/common.sh 1.6.0): the node that reads the file
# writes it. When keytool cannot run or fails, or worker 0 does not read back as
# wanted, the backup is restored and the python3 editor (caddy_edit_node_info) tries.
# Both editors run as the service user, which owns the data dir.
# rc 0 written and verified; 1 failed, <ni> restored from the backup; 2 no editor
# could run (no keytool runner, no python3), <ni> untouched.
caddy_node_info_write() {
    local ni="$1" mode="$2" http_url="${3:-}" ws_url="${4:-}"
    local want spec="" out rc first cur tried=false
    local -a args=()
    if [[ "$mode" == "set" ]]; then
        want="${http_url} ${ws_url:-none}"
        args=(set-rpc --http "$http_url")
        if [[ -n "$ws_url" ]]; then args+=(--ws "$ws_url"); fi
    else
        want="none none"
        args=(set-rpc --clear)
    fi
    if caddy_lib_has "node-info.yaml is edited by the python3 fallback instead of keytool set-rpc" tn_keytool tn_launch_runner tn_node_info_rpc; then
        rc=0
        spec="$(tn_launch_runner 2>/dev/null)" || rc=$?
        if [[ "$rc" -ne 0 || -z "$spec" ]]; then
            caddy_say info "Could not read the node runner from its launch file (rc ${rc}); editing node-info.yaml with the python3 fallback."
            spec=""
        fi
    fi
    if [[ -n "$spec" ]]; then
        tried=true
        rc=0
        out="$(tn_keytool "$spec" "${ni%/*}" "${args[@]}" 2>&1)" || rc=$?
        if [[ "$rc" -eq 0 ]]; then
            cur="$(caddy_node_info_rpc_get "$ni" || echo unreadable)"
            if [[ "$cur" == "$want" ]]; then
                caddy_say info "node-info.yaml written by keytool set-rpc (${spec})."
                return 0
            fi
            caddy_say warn "After keytool set-rpc, worker 0 of node-info.yaml reads '${cur}' instead of '${want}'. Restoring the file and trying the python3 editor."
        else
            first="$(printf '%s\n' "$out" | awk 'NF {print; exit}' || true)"
            caddy_say info "keytool set-rpc failed (rc ${rc}${first:+: ${first}}). Restoring node-info.yaml and trying the python3 editor."
        fi
        caddy_ni_restore "$ni" 2>/dev/null || true
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        if [[ "$tried" == "true" ]]; then
            caddy_say warn "python3 is not installed, so there is no fallback editor for node-info.yaml."
            return 1
        fi
        return 2
    fi
    if caddy_edit_node_info "$ni" "$mode" "$http_url" "$ws_url"; then
        cur="$(caddy_node_info_rpc_get "$ni" || echo unreadable)"
        [[ "$cur" == "$want" ]] && return 0
        caddy_say warn "After the python3 edit, worker 0 of node-info.yaml reads '${cur}' instead of '${want}'."
    fi
    caddy_ni_restore "$ni" 2>/dev/null || true
    return 1
}

# Undo / keep a launch-file --ws edit made by caddy_ws_inject (no-op when none). The
# backup (tn_backup_file, /var/backups/telcoin) goes back through tn_restore_backup,
# which refuses a backup whose hash changed.
caddy_launch_rollback() {
    [[ -n "$CADDY_LAUNCH_BAK" && -f "$CADDY_LAUNCH_BAK" ]] || return 0
    if ! tn_restore_backup "$CADDY_LAUNCH_BAK" "$CADDY_LAUNCH_BAK_SHA" "$CADDY_LAUNCH_FILE" "$CADDY_LAUNCH_MODE" "$CADDY_LAUNCH_GROUP"; then
        caddy_say warn "Could not restore the node launch file ${CADDY_LAUNCH_FILE} from ${CADDY_LAUNCH_BAK}; it still carries the --ws change. Put it back by hand from that backup."
        CADDY_LAUNCH_BAK=""
        return 0
    fi
    rm -f -- "$CADDY_LAUNCH_BAK"
    if [[ "$CADDY_LAUNCH_METHOD" == "docker" ]]; then systemctl daemon-reload 2>/dev/null || true; fi
    caddy_say warn "Restored the node launch file ${CADDY_LAUNCH_FILE} (the --ws change was undone)."
    CADDY_LAUNCH_BAK=""
}
caddy_launch_commit() {
    [[ -n "$CADDY_LAUNCH_BAK" ]] && rm -f -- "$CADDY_LAUNCH_BAK"
    CADDY_LAUNCH_BAK=""
}

# 0 (true) when <svc> is active after a short observation (~10 s: failed at any check
# -> 1 at once). Used by the brick guard after its recovery restart, so the die
# message states whether the node actually came back.
caddy_node_stays_active() {
    local svc="$1" i
    for i in 1 2 3 4 5; do
        sleep 2
        systemctl is-failed --quiet "$svc" 2>/dev/null && return 1
    done
    systemctl is-active --quiet "$svc" 2>/dev/null
}

# Take the update lock (tn_acquire_update_lock, lib/common.sh) before the first node
# edit and before the epoch wait, so rpc-enable / rpc-disable never edit the launch
# file or node-info.yaml, or restart the node, while update-node.sh or edit-config.sh
# changes it: update-node backs the launch file up before its own epoch wait and puts
# that copy back on a rollback, which would silently undo an edit made in between.
# Held until the operation ends (caddy_node_unlock; the EXIT trap releases it on every
# other path). Another live run holding it is a refusal (die: an `error` event and
# `done ok:false` in --json runs) followed by CADDY_LOCK_NOTE, which says what this run
# has already changed. Soft guard: without tn_release_update_lock (lib/common.sh older
# than 1.5.0, whose lock replaces the EXIT trap) the run goes on without the lock.
caddy_node_lock() {
    [[ "$CADDY_LOCK_HELD" == "true" ]] && return 0
    caddy_lib_has "this run does not take the update lock and cannot tell whether update-node.sh or edit-config.sh is changing the node" tn_acquire_update_lock tn_release_update_lock || return 0
    TN_EXIT_TRAP_OWNED=1
    if ! tn_acquire_update_lock >/dev/null 2>&1; then
        die "an update is in progress${TN_UPDATE_LOCK_HOLDER:+ (PID ${TN_UPDATE_LOCK_HOLDER})}; try again when it has finished.${CADDY_LOCK_NOTE:+ ${CADDY_LOCK_NOTE}}"
    fi
    CADDY_LOCK_HELD=true
}
# Release the update lock when this run holds it. Never fails.
caddy_node_unlock() {
    [[ "$CADDY_LOCK_HELD" == "true" ]] || return 0
    tn_release_update_lock 2>/dev/null || true
    CADDY_LOCK_HELD=false
}

# caddy_restart_window -- right before a node restart (caddy_restart_node_guarded),
# with the update lock held (caddy_node_lock): the committee guard first
# (tn_committee_down_guard; it passes with a warning on testnet, devnet and an
# unstaked node when the committee cannot be read, and with TN_ALLOW_QUORUM_RISK=1),
# then the epoch wait (tn_wait_restart_window: while the node votes in the current
# committee and the boundary is close, it waits for the epoch to close and settle,
# at most TN_EPOCH_WAIT_MAX seconds; TN_SKIP_EPOCH_WAIT=1 skips it). When the guard
# refuses (rc 1; rc 2 on a staked mainnet node or an unknown network) or the wait
# fails, this run's node edits are put back (caddy_restart_abandon) and the run
# stops; the node is not restarted. Once per operation. The restart that recovers
# from a rollback never calls it. Progress goes through caddy_say (step / log / warn
# events in --json runs).
caddy_restart_window() {
    local rc url why
    [[ "$CADDY_WINDOW_DONE" == "true" ]] && return 0
    CADDY_WINDOW_DONE=true
    caddy_node_lock
    url="$(tn_local_rpc_url)"
    rc=0
    tn_committee_down_guard "$url" caddy_wait_say || rc=$?
    # TN_ALLOW_QUORUM_RISK=1 (which the guard honours itself) lets a refusal through.
    if [[ "$rc" -ne 0 && "${TN_ALLOW_QUORUM_RISK:-}" == "1" ]]; then
        caddy_say warn "TN_ALLOW_QUORUM_RISK=1: restarting although the committee check did not pass."
        rc=0
    fi
    if [[ "$rc" -ne 0 ]]; then
        if [[ "$rc" -eq 2 ]]; then
            why="the committee could not be read on a node whose vote counts"
        else
            why="restarting this node now could leave the committee without a quorum"
        fi
        caddy_restart_abandon
        die "${why} (see above), so the node was not restarted and this run's node changes were put back. Run this again later, or set TN_ALLOW_QUORUM_RISK=1 for a coordinated restart.${CADDY_LOCK_NOTE:+ ${CADDY_LOCK_NOTE}}"
    fi
    rc=0
    tn_wait_restart_window "$url" caddy_wait_say || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        caddy_restart_abandon
        die "the epoch-boundary wait failed (rc ${rc}), so the node was not restarted and this run's node changes were put back.${CADDY_LOCK_NOTE:+ ${CADDY_LOCK_NOTE}}"
    fi
    return 0
}

# caddy_restart_abandon -- the run stops after a node edit and before the restart that
# applies it (CADDY_RESTART_PENDING): put node-info.yaml back from its backup (as the
# service user) and undo the --ws launch edit, so the node keeps its old settings and
# a later restart does not pick up an unchecked change. No-op otherwise.
caddy_restart_abandon() {
    [[ "$CADDY_RESTART_PENDING" == "true" ]] || return 0
    CADDY_RESTART_PENDING=false
    if [[ -n "$CADDY_NI_FILE" && -n "$CADDY_NI_BAK" ]]; then
        if caddy_ni_restore "$CADDY_NI_FILE"; then
            caddy_say warn "Put ${CADDY_NI_FILE} back as it was; the node was not restarted."
        else
            caddy_say warn "Could not put ${CADDY_NI_FILE} back from its backup; it keeps this run's change, which applies at the next node restart."
        fi
        caddy_ni_discard
    fi
    caddy_launch_rollback
    return 0
}

# Restart the node and verify RPC returns. FAST-FAIL if the unit enters `failed` (an
# invalid worker.rpc crash-loops at startup: Restart=on-failure, StartLimitBurst=5):
# restore node-info.yaml from its backup AND any launch-file --ws edit, restart to recover, and
# die naming what was rolled back and whether the node came back. A slow DB-replay
# (neither up nor failed) is NON-fatal -- the change is kept and advertises once the
# node finishes starting (a warning and a closing note say so). <ni> is '' when only
# the launch file changed. Works for binary AND docker installs (the host
# node-info.yaml is bind-mounted). The committee guard and the epoch wait
# (caddy_restart_window) run right before the restart; the recovery restart never
# waits.
caddy_restart_node_guarded() {
    local ni="${1:-}"
    local svc rpc_port i rpc_up=false failed=false what="" node_state
    svc="$(tn_resolve_service 2>/dev/null || true)"
    if [[ -z "$svc" ]]; then
        caddy_say warn "No telcoin node service was found, so the node was not restarted. The change takes effect when the node next starts."
        caddy_note "node not restarted: no node service found"
        CADDY_RESTART_PENDING=false
        caddy_ni_discard
        caddy_launch_commit
        return 0
    fi
    rpc_port="${CADDY_RPC_PORT:-}"
    [[ -n "$rpc_port" ]] || rpc_port="$(caddy_node_port --http.port RPC_PORT 8545)" || die "no usable reth HTTP port to check the node after its restart (see above); the node was not restarted.${CADDY_LOCK_NOTE:+ ${CADDY_LOCK_NOTE}}"

    caddy_restart_window
    CADDY_RESTART_PENDING=false
    caddy_say step "Restarting ${svc} to apply the change"
    systemctl restart "$svc" 2>/dev/null || true

    for i in $(seq 1 30); do
        if systemctl is-failed --quiet "$svc" 2>/dev/null; then failed=true; break; fi
        if curl -s --max-time 3 -X POST -H 'Content-Type: application/json' \
               --data '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' \
               "http://127.0.0.1:${rpc_port}" 2>/dev/null | grep -q '"result"'; then
            rpc_up=true; break
        fi
        sleep 2
    done

    if [[ "$failed" == "true" ]]; then
        [[ -n "$ni" ]] && what="node-info.yaml (worker rpc)"
        if [[ -n "$CADDY_LAUNCH_BAK" ]]; then what="${what:+${what} and }the --ws launch flags"; fi
        what="${what:-the change}"
        caddy_say warn "${svc} entered the failed state after the change; rolling back ${what}."
        if [[ -n "$ni" ]] && ! caddy_ni_restore "$ni"; then
            caddy_say warn "Could not restore ${ni} from its backup as the service user; it keeps the new worker rpc."
        fi
        caddy_ni_discard
        caddy_launch_rollback
        # A unit that crash-looped into `failed` has also used up its start-rate limit
        # (Restart=on-failure + StartLimitBurst), and systemd refuses a manual restart
        # until that is cleared. Docker installs run under the same unit (its wrapper
        # execs `docker run`; ExecStartPre removes a stale container), so this covers both.
        systemctl reset-failed "$svc" 2>/dev/null || true
        systemctl restart "$svc" 2>/dev/null || true
        if caddy_node_stays_active "$svc"; then
            node_state="${svc} is running again on its previous configuration."
        else
            node_state="${svc} is still down; start it with: sudo systemctl start ${svc} (the Caddy site answers 502 until it runs)."
        fi
        die "${svc} failed after the change, so ${what} was rolled back. ${node_state} Find the cause in: journalctl -u ${svc} -n 100, then run this again."
    fi

    if [[ "$rpc_up" == "true" ]]; then
        caddy_ni_discard
        caddy_launch_commit
        caddy_say ok "Node restarted; RPC responding on 127.0.0.1:${rpc_port}."
        return 0
    fi

    caddy_ni_discard
    caddy_say warn "${svc} is still starting (DB replay?) and RPC has not answered yet. The change is kept and takes effect once the node is up.${CADDY_LAUNCH_BAK:+ Launch file backup: ${CADDY_LAUNCH_BAK}}"
    caddy_note "node still starting; the change applies once it is up"
    return 0
}

# Restart the node only because caddy_ws_inject edited its launch file (no-op otherwise).
caddy_restart_for_launch() {
    [[ -n "$CADDY_LAUNCH_BAK" ]] || return 0
    caddy_restart_node_guarded ""
}

# Echo the "<http> <ws|none>" pair worker 0 of node-info.yaml should hold: for
# mode=set https://<domain>/ and, when <with_ws> is true, wss://<domain>/; for
# mode=clear "none none".
caddy_node_info_want() {
    if [[ "$1" == "set" ]]; then
        if [[ "${3:-true}" == "true" ]]; then
            printf 'https://%s/ wss://%s/\n' "$2" "$2"
        else
            printf 'https://%s/ none\n' "$2"
        fi
    else
        printf 'none none\n'
    fi
}

# Dry check for caddy_node_info_advertise: 0 (true) when it would edit node-info.yaml
# for <mode> <domain> <with_ws> -- the file exists, an editor can run, and worker 0
# does not already read as wanted (or cannot be read). Changes nothing.
caddy_node_info_needs_edit() {
    local ni cur want
    ni="$(caddy_node_info_path)" || return 1
    [[ -f "$ni" ]] || return 1
    caddy_node_info_can_edit || return 1
    want="$(caddy_node_info_want "$1" "${2:-}" "${3:-true}")"
    cur="$(caddy_node_info_rpc_get "$ni" 2>/dev/null || true)"
    [[ "$cur" != "$want" ]]
}

# Advertise (mode=set) or un-advertise (mode=clear) the worker RPC endpoint in
# node-info.yaml, then restart the node under the brick guard. <with_ws> (set only,
# default true) also advertises wss://<domain>/; false writes http only (decided by
# caddy_ws_plan / caddy_ws_inject). Worker 0's current value is read first: when it
# already is what is wanted, nothing is edited, there is no epoch wait and no restart
# (unless caddy_ws_inject edited the launch file). Otherwise the update lock is taken,
# caddy_node_info_write edits and verifies, and caddy_restart_node_guarded runs the
# committee guard and the epoch wait right before the restart (a refusal puts the
# edit back). Best-effort: a missing node-info.yaml, or no way to edit it (no
# keytool runner and no python3), is a warning plus a closing note (the proxy still
# works; it just won't be discovered on-network). A launch file edited by
# caddy_ws_inject gets its node restart on every path.
caddy_node_info_advertise() {
    local mode="$1" domain="${2:-}" with_ws="${3:-true}"
    local ni http_url="" ws_url="" want cur="" rc svc
    if ! ni="$(caddy_node_info_path 2>/dev/null)"; then
        caddy_say warn "DATA_DIR is set more than once in .node-meta, so node-info.yaml cannot be located and was not changed; remove the extra lines and run this again."
        caddy_note "node-info.yaml not changed (DATA_DIR set more than once)"
        caddy_restart_for_launch
        return 0
    fi
    if [[ ! -f "$ni" ]]; then
        if [[ "$mode" == "set" ]]; then
            caddy_say warn "node-info.yaml not found (${ni}), so the endpoint is not advertised on-network: peers and wallets that discover endpoints through the node will not find it."
            caddy_note "not advertised in node-info.yaml"
        else
            caddy_say info "node-info.yaml not found (${ni}); there is no advertisement to clear."
        fi
        caddy_restart_for_launch
        return 0
    fi

    if [[ "$mode" == "set" ]]; then
        http_url="https://${domain}/"
        if [[ "$with_ws" == "true" ]]; then ws_url="wss://${domain}/"; fi
        # Validate BEFORE writing -- an invalid worker rpc crash-loops the node.
        caddy_validate_rpc_url http "$http_url" || { caddy_launch_rollback; die "refusing to write an invalid http URL into node-info.yaml: ${http_url}"; }
        if [[ -n "$ws_url" ]]; then
            caddy_validate_rpc_url ws "$ws_url" || { caddy_launch_rollback; die "refusing to write an invalid ws URL into node-info.yaml: ${ws_url}"; }
        fi
    fi
    want="$(caddy_node_info_want "$mode" "$domain" "$with_ws")"

    # Read before writing: keytool may reformat the file, so an unchanged value is
    # detected here rather than by comparing bytes afterwards.
    if cur="$(caddy_node_info_rpc_get "$ni")" && [[ "$cur" == "$want" ]]; then
        if [[ "$mode" == "set" ]]; then
            caddy_say ok "node-info.yaml already advertises ${http_url}${ws_url:+ and ${ws_url}}."
        else
            caddy_say ok "node-info.yaml worker rpc already cleared."
        fi
        if [[ -n "$CADDY_LAUNCH_BAK" ]]; then
            caddy_restart_node_guarded ""
        else
            caddy_say ok "No node restart needed."
        fi
        return 0
    fi

    svc="$(tn_resolve_service 2>/dev/null || true)"
    svc="${svc:-telcoin}"
    if ! caddy_node_info_can_edit; then
        if [[ "$mode" == "set" ]]; then
            caddy_say warn "Cannot edit ${ni}: python3 is not installed and keytool cannot be run through the node launch file. The endpoint works but is not advertised on-network; install python3 (or run update-scripts.sh) and re-run rpc-enable to advertise it."
            caddy_note "not advertised in node-info.yaml"
        else
            caddy_say warn "Cannot clear the worker rpc in ${ni}: python3 is not installed and keytool cannot be run through the node launch file. The file is unchanged and still advertises the removed endpoint. Clear it by hand (set 'rpc: ~' on the first entry under p2p_info.workers), then restart the node (sudo systemctl restart ${svc})."
            caddy_note "node-info.yaml still advertises the endpoint"
        fi
        caddy_restart_for_launch
        return 0
    fi

    # The update lock before anything is edited; the committee guard and the epoch
    # wait run right before the restart (caddy_restart_node_guarded).
    caddy_node_lock
    if ! caddy_ni_backup "$ni"; then
        if [[ "$mode" == "clear" ]]; then
            caddy_say warn "Could not back up ${ni} as the service user, so the worker rpc was not cleared; it still advertises the removed endpoint. Clear it by hand (set 'rpc: ~' on the first entry under p2p_info.workers), then restart the node (sudo systemctl restart ${svc})."
            caddy_note "node-info.yaml still advertises the endpoint"
            caddy_restart_for_launch
            return 0
        fi
        caddy_launch_rollback
        die "could not back up node-info.yaml as the service user (${SERVICE_USER:-unset}), so it was not edited."
    fi
    rc=0
    caddy_node_info_write "$ni" "$mode" "$http_url" "$ws_url" || rc=$?
    if [[ "$rc" -eq 0 ]]; then
        CADDY_RESTART_PENDING=true
    else
        # caddy_node_info_write restored the file from the backup (or never touched it).
        caddy_ni_discard
        if [[ "$mode" == "clear" ]]; then
            # rpc-disable has already removed the public site; a node-info.yaml that
            # cannot be edited is a warning, not a failure of the takedown.
            caddy_say warn "Could not clear the worker rpc in ${ni} (unexpected layout or read/write error) -- the file is unchanged and still advertises the removed endpoint. Clear it by hand: set 'rpc: ~' on the first entry under p2p_info.workers (legacy layout: p2p_info.worker.rpc), then restart the node (sudo systemctl restart ${svc})."
            caddy_note "node-info.yaml still advertises the endpoint"
            caddy_restart_for_launch
            return 0
        fi
        caddy_launch_rollback
        die "failed to edit node-info.yaml (worker rpc) -- node-info restored unchanged"
    fi
    if [[ "$mode" == "set" ]]; then
        caddy_say ok "node-info.yaml now advertises ${http_url}${ws_url:+ and ${ws_url}} (worker 0)."
    else
        caddy_say ok "Cleared the worker rpc in node-info.yaml (worker 0)."
    fi
    caddy_restart_node_guarded "$ni"
}

# reth WebSocket port: the node launch --ws.port, else .node-meta WS_PORT, else 8546
# (caddy_node_port). rc 1/2 as caddy_node_port.
caddy_ws_port() {
    if [[ -n "$CADDY_WS_PORT_SET" ]]; then
        printf '%s\n' "$CADDY_WS_PORT_SET"
        return 0
    fi
    caddy_node_port --ws.port WS_PORT 8546
}

# 0 (true) when <file> carries launch flag <flag-regex> as a whole word (`--f`, `--f v`,
# `--f=v`, also quoted "--f" / '--f') on a non-comment line. `--ws` alone turns reth's WS
# server on; --ws.addr / --ws.port without it do not. The reader for a lib/common.sh
# older than 1.6.0; caddy_launch_carries prefers tn_launch_flag_get.
caddy_launch_has_flag() {
    awk -v f="$2" '/^[[:space:]]*#/ {next} $0 ~ ("(^|[[:space:]])[\"\047]?" f "([\"\047[:space:]=]|$)") {x=1} END {exit !x}' "$1" 2>/dev/null
}

# caddy_launch_carries <file> <flag> -- 0 (true) when the node command in launch file
# <file> carries <flag> (a literal name such as --ws.addr): tn_launch_flag_get
# (lib/common.sh 1.6.0), which reads only the node command and skips comments; else
# the awk reader above.
caddy_launch_carries() {
    if declare -F tn_launch_flag_get >/dev/null 2>&1; then
        tn_launch_flag_get "$1" "$2" >/dev/null 2>&1
        return
    fi
    caddy_launch_has_flag "$1" "${2//./[.]}"
}

# 0 (true) when launch file <file> still parses: `bash -n` for a start wrapper. A
# systemd unit is not a shell script and passes.
caddy_launch_syntax_ok() {
    [[ "$1" == *.service ]] && return 0
    bash -n "$1" 2>/dev/null
}

# 0 (true) when process <proc> (as ss names it) listening on the reth WebSocket port is
# the node: the stock binary name (telcoin-network), the container entrypoint on host
# networking (telcoin), docker-proxy (a published container port), or the binary of the
# `<binary> node` invocation in launch file <file> (basename, cut to the kernel's
# 15-character process name).
caddy_ws_holder_is_node() {
    local proc="$1" file="${2:-}" bin=""
    case "$proc" in
        telcoin|telcoin-network|docker-proxy) return 0 ;;
    esac
    if [[ -n "$file" && -f "$file" ]]; then
        bin="$(awk '/^[[:space:]]*#/ {next} {for (i = 2; i <= NF; i++) if ($i == "node") {print $(i - 1); exit}}' "$file" 2>/dev/null || true)"
        bin="${bin##*/}"; bin="${bin:0:15}"
    fi
    [[ -n "$bin" && "$proc" == "$bin" ]]
}

# WebSocket plan, run by rpc-enable BEFORE anything changes. Decides whether wss:// is
# advertised, without editing or waiting, and sets CADDY_WS_PLAN:
#   ok     -- reth's WS endpoint is or will be there: the NODE already LISTENS on TCP
#             <ws_port> (ss -ltnp), or the node launch file -- resolved by
#             tn_node_launch_target (lib/common.sh), the resolver setup-observability.sh
#             uses: the start wrapper, or the unit for legacy inline-docker installs --
#             already carries --ws (the node restart that follows picks it up);
#   inject -- the missing parts of `--ws --ws.addr 127.0.0.1 --ws.port <ws_port>`
#             (CADDY_WS_FLAGS) can be added with the shared tn_node_inject_flags
#             (lib/common.sh 1.6.0): a dry run on a copy of the launch file returned 0,
#             the copy reads back --ws (tn_launch_flag_get) and still parses;
#   http   -- advertise https:// only; the warning says why (port held by another
#             process, no node service or launch file, an older lib/common.sh, or a
#             launch line the helper refuses to edit).
# A dry run that answers 1 (--ws already on a live line) counts as ok. The real edit
# (caddy_ws_inject) runs later, under the update lock.
caddy_ws_plan() {
    local ws_port="$1" target="" svc="" method="" file="" holder rc why dir copy
    local by_hand="add --ws --ws.addr 127.0.0.1 --ws.port ${ws_port} to the node launch by hand and re-run rpc-enable to advertise wss:// too"
    CADDY_WS_PLAN="http"
    CADDY_WS_FLAGS=""
    CADDY_LAUNCH_FILE=""
    CADDY_LAUNCH_METHOD=""
    target="$(tn_node_launch_target 2>/dev/null || true)"
    [[ -n "$target" ]] && read -r svc method file <<< "$target"
    holder="$(caddy_port_proc "$ws_port")"
    if [[ -n "$holder" ]]; then
        if caddy_ws_holder_is_node "$holder" "$file"; then
            caddy_say ok "reth WebSocket already listening on port ${ws_port}."
            CADDY_WS_PLAN="ok"
            return 0
        fi
        caddy_say warn "The reth WebSocket port ${ws_port} is held by '${holder}', not the node, so public wss:// traffic would reach that process. Advertising https:// only (no wss://) and leaving the node launch unchanged; free port ${ws_port} (or give the node another WS_PORT) and re-run rpc-enable to advertise wss:// too."
        return 0
    fi
    if [[ -z "$target" ]]; then
        caddy_say warn "Nothing listens on the reth WebSocket port ${ws_port} and no telcoin node service was found, so --ws cannot be checked or enabled. Advertising https:// only (no wss://); re-run rpc-enable once the node runs with --ws to advertise wss:// too."
        return 0
    fi
    if [[ ! -f "$file" ]]; then
        caddy_say warn "Nothing listens on the reth WebSocket port ${ws_port} and the node launch file (${file}) was not found, so --ws cannot be checked or enabled. Advertising https:// only (no wss://); add --ws --ws.addr 127.0.0.1 --ws.port ${ws_port} to the ${svc} launch and re-run rpc-enable to advertise wss:// too."
        return 0
    fi
    if caddy_launch_carries "$file" --ws; then
        caddy_say ok "The node launch (${file}) already enables --ws; the WebSocket binds on port ${ws_port} once ${svc} (re)starts."
        CADDY_WS_PLAN="ok"
        return 0
    fi
    if ! caddy_lib_has "--ws is not added to the node launch automatically" tn_launch_flag_get tn_node_inject_flags; then
        caddy_say warn "The node launch (${file}) lacks --ws. Advertising https:// only (no wss://); run update-scripts.sh and then rpc-enable again, or ${by_hand}."
        return 0
    fi
    CADDY_WS_FLAGS="--ws"
    caddy_launch_carries "$file" --ws.addr || CADDY_WS_FLAGS="${CADDY_WS_FLAGS} --ws.addr 127.0.0.1"
    caddy_launch_carries "$file" --ws.port || CADDY_WS_FLAGS="${CADDY_WS_FLAGS} --ws.port ${ws_port}"
    # Dry run on a copy with the same name (a .service file follows unit rules), so a
    # refused edit is known before any wait.
    # The copy sits in a root-only directory under /run: the launch writer refuses a
    # directory that is not root-owned and closed to others (as /tmp is).
    rc=4
    dir=""
    if caddy_run_dir 2>/dev/null; then
        dir="$(mktemp -d "${CADDY_RUN_DIR}/ws-dry.XXXXXX" 2>/dev/null)" || dir=""
    fi
    if [[ -n "$dir" ]]; then
        copy="${dir}/${file##*/}"
        if cp -p "$file" "$copy" 2>/dev/null; then
            rc=0
            tn_node_inject_flags "$copy" '(^|[[:space:]])--ws([[:space:]]|$)' "$CADDY_WS_FLAGS" || rc=$?
            if [[ "$rc" -eq 0 ]] && ! { tn_launch_flag_get "$copy" --ws >/dev/null 2>&1 && caddy_launch_syntax_ok "$copy"; }; then
                rc=5
            fi
        fi
        rm -rf "$dir"
    fi
    case "$rc" in
        0)
            CADDY_WS_PLAN="inject"
            CADDY_LAUNCH_FILE="$file"
            CADDY_LAUNCH_METHOD="$method"
            return 0
            ;;
        1)
            caddy_say ok "The node launch (${file}) already carries --ws on a live line; the WebSocket binds on port ${ws_port} once ${svc} (re)starts."
            CADDY_WS_PLAN="ok"
            return 0
            ;;
        2) why="no node launch line (a live line with --http in the node command) was found" ;;
        3) why="the launch line ends in a comment or cannot be parsed, so it is not edited automatically" ;;
        5) why="the edited launch file would not read back --ws (or would no longer parse)" ;;
        *) why="a copy of the launch file could not be made to check the edit" ;;
    esac
    caddy_say warn "Could not add --ws to the node launch (${file}): ${why}. Advertising https:// only (no wss://); ${by_hand}."
    return 0
}

# Carry out an `inject` plan: the update lock (caddy_node_lock), then back the launch
# file up (under the lock, so the copy holds the file as it is at the edit), add CADDY_WS_FLAGS with tn_node_inject_flags and keep the edit only when the
# helper returns 0, the node command reads back --ws and a start wrapper still passes
# `bash -n`; otherwise the backup goes back. The brick guard restores the file if the
# node then fails to start. 0 = advertise ws; 1 = advertise http only (warning said).
caddy_ws_inject() {
    local ws_port="$1" file="$CADDY_LAUNCH_FILE" rc why
    local by_hand="add --ws --ws.addr 127.0.0.1 --ws.port ${ws_port} to the node launch by hand and re-run rpc-enable to advertise wss:// too"
    local out st
    caddy_node_lock
    st="$(stat -c '%a %g' -- "$file" 2>/dev/null)" || st=""
    out=""
    if [[ -n "$st" ]]; then
        out="$(tn_backup_file "$file" "caddy-launch.${file##*/}" 2>/dev/null)" || out=""
    fi
    if [[ -z "$out" ]]; then
        caddy_say warn "Could not back up the node launch (${file}), so --ws is not added. Advertising https:// only (no wss://)."
        return 1
    fi
    CADDY_LAUNCH_MODE="$(_tn_strip_gw "${st%% *}")"
    CADDY_LAUNCH_GROUP="${st##* }"
    CADDY_LAUNCH_BAK_SHA="${out##* }"
    out="${out% *}"
    # Marker: a whole-word --ws on a live line. rc per the launch-flag family: 0 added,
    # 1 already there, 2 no node launch line, 3 refused, 4 could not write.
    rc=0
    tn_node_inject_flags "$file" '(^|[[:space:]])--ws([[:space:]]|$)' "$CADDY_WS_FLAGS" || rc=$?
    if [[ "$rc" -eq 0 ]] && tn_launch_flag_get "$file" --ws >/dev/null 2>&1 && caddy_launch_syntax_ok "$file"; then
        if [[ "$CADDY_LAUNCH_METHOD" == "docker" ]]; then systemctl daemon-reload || caddy_say warn "systemctl daemon-reload failed"; fi
        CADDY_LAUNCH_BAK="$out"
        CADDY_RESTART_PENDING=true
        caddy_say ok "Enabled the reth WebSocket: added '${CADDY_WS_FLAGS}' to the node launch (${file}); it takes effect on the node restart below."
        return 0
    fi
    # Anything else leaves the file as it was: the helper wrote nothing (rc 1-4), or
    # the edit did not read back and the backup goes back.
    if [[ "$rc" -ne 0 ]]; then
        rm -f -- "$out"
    elif tn_restore_backup "$out" "$CADDY_LAUNCH_BAK_SHA" "$file" "$CADDY_LAUNCH_MODE" "$CADDY_LAUNCH_GROUP"; then
        rm -f -- "$out"
    else
        caddy_say warn "Could not restore ${file} from ${out}; put it back by hand from that backup."
    fi
    case "$rc" in
        0) why="the edited launch file did not read back --ws (or no longer parses), so the edit was undone" ;;
        1)
            caddy_say ok "The node launch (${file}) already carries --ws on a live line."
            return 0
            ;;
        2) why="no node launch line (a live line with --http in the node command) was found" ;;
        3) why="the launch line ends in a comment or cannot be parsed, so it is not edited automatically" ;;
        *) why="the launch file could not be written" ;;
    esac
    caddy_say warn "Could not add --ws to the node launch (${file}): ${why}. Advertising https:// only (no wss://); ${by_hand}."
    return 1
}

# After the node restart: warn (never fail) while reth's WebSocket is still not listening.
caddy_ws_verify() {
    local ws_port="$1" domain="$2" i
    for i in 1 2 3 4 5; do
        if caddy_port_listening "$ws_port"; then
            caddy_say ok "reth WebSocket listening on port ${ws_port} -- wss://${domain}/ is served."
            return 0
        fi
        sleep 2
    done
    caddy_say warn "Nothing listens on the reth WebSocket port ${ws_port} yet, so wss://${domain}/ returns 502 until it does. If the node is still starting (DB replay) this clears on its own; otherwise confirm the node launch carries --ws and check journalctl for the node service."
    caddy_note "wss:// not answering yet"
}

# =============================================================================
# PHASES -- DASHBOARD
# =============================================================================

# caddy_password_len <value> -- its length in bytes.
caddy_password_len() {
    local LC_ALL=C v="${1:-}"
    printf '%s\n' "${#v}"
}

# caddy_password_problem <value> -- print why <value> cannot be the dashboard password
# (empty when it can): at least CADDY_PASSWORD_MIN bytes, no control characters.
caddy_password_problem() {
    local v="${1:-}"
    if [[ "$(caddy_password_len "$v")" -lt "$CADDY_PASSWORD_MIN" ]]; then
        printf 'the password must be at least %s characters\n' "$CADDY_PASSWORD_MIN"
    elif [[ "$v" == *[[:cntrl:]]* ]]; then
        printf 'the password must not contain control characters\n'
    fi
}

# Print a new random dashboard password (24 characters, letters and digits).
caddy_generate_password() {
    local p=""
    if command -v openssl >/dev/null 2>&1; then
        p="$(openssl rand -base64 33 2>/dev/null | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-24)" || p=""
    fi
    if [[ "${#p}" -lt 24 ]]; then
        # A fixed read, so no stage of the pipe is cut off early (pipefail).
        p="$(head -c 512 /dev/urandom 2>/dev/null | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-24)" || p=""
    fi
    printf '%s\n' "$p"
}

# Read the dashboard password for --password-stdin: one line from stdin, one trailing
# CR dropped, into CADDY_PASSWORD.
caddy_read_password_stdin() {
    local line=""
    IFS= read -r line || [[ -n "$line" ]] || line=""
    CADDY_PASSWORD="${line%$'\r'}"
}

# caddy_mainnet_gate -- refuse (die) the dashboard and public RPC on a mainnet node
# that is a staked validator, or whose stake status cannot be read: Caddy is not for
# mainnet validators. NETWORK comes from .node-meta (else the genesis chain id); the
# stake from node_is_staked_validator for VALIDATOR_ADDRESS, asked of the local node
# first, then of the network's public RPC when the local answer is unreadable. Runs
# once per run; testnet and devnet pass. A network that cannot be told (no NETWORK
# and no readable genesis chain id) is refused like an unreadable stake.
caddy_mainnet_gate() {
    local net addr rc
    [[ "$CADDY_GATE_DONE" == "true" ]] && return 0
    net="$(addon_meta_get NETWORK "")" || die "NETWORK is set more than once in .node-meta; fix the file before enabling external access. Nothing was changed."
    if [[ -z "$net" ]]; then
        net="$(tn_detect_network 2>/dev/null)" || net=""
    fi
    [[ -n "$net" ]] || die "The network of this node cannot be told (no NETWORK in .node-meta and no readable genesis chain id), so this run cannot confirm it is not a staked mainnet validator. Caddy (dashboard and public RPC) is not offered on mainnet validators. Nothing was changed."
    if [[ "$net" != "mainnet" ]]; then
        CADDY_GATE_DONE=true
        return 0
    fi
    addr="$(addon_meta_get VALIDATOR_ADDRESS "")" || die "VALIDATOR_ADDRESS is set more than once in .node-meta; fix the file first. Nothing was changed."
    [[ -n "$addr" ]] || die "This mainnet node has no VALIDATOR_ADDRESS in .node-meta, so this run cannot confirm it is not a staked validator. Caddy (dashboard and public RPC) is not offered on mainnet validators. Nothing was changed."
    rc=0
    node_is_staked_validator "$addr" || rc=$?
    if [[ "$rc" -eq 2 ]]; then
        rc=0
        node_is_staked_validator "$addr" "$MAINNET_RPC_URL" || rc=$?
    fi
    case "$rc" in
        1) CADDY_GATE_DONE=true; return 0 ;;
        0) die "This mainnet node (${addr}) is a staked validator. Caddy (dashboard and public RPC) is not offered on mainnet validators: serve the dashboard over the SSH tunnel, and public RPC from a separate RPC node. Nothing was changed." ;;
        *) die "Could not read the stake status of ${addr} from the local node or ${MAINNET_RPC_URL}. Caddy is not offered on mainnet validators, so this run stops until the status can be read. Nothing was changed." ;;
    esac
}

# Refusals for a dashboard enable, checked before anything is written (and, in a
# --json run, before any step is announced): a staked mainnet validator, the hostname
# <domain> (normalised), the username, the password and the one-hostname-per-site rule.
caddy_dashboard_precheck() {
    local domain="$1" username="$2" clash why
    caddy_require_domain "$domain" "domain"
    caddy_validate_username "$username" || die "invalid username (2-32 chars: letters, digits, . _ -)"
    why="$(caddy_password_problem "$CADDY_PASSWORD")"
    [[ -z "$why" ]] || die "${why} (give it on stdin with --password-stdin)"
    if clash="$(caddy_domain_clash dashboard "$domain")"; then die "$clash"; fi
    caddy_mainnet_gate
    return 0
}

# Enable the dashboard vhost: install + configure + start, preserving any RPC vhost
# verbatim. The password is CADDY_PASSWORD (from --password-stdin, or the
# TN_CADDY_PASSWORD that main read and unset; never argv, logs or a child's
# environment). Caddy only: the node is not edited or restarted, so no update lock or
# epoch wait.
do_enable() {
    local domain username="$2" pw="$CADDY_PASSWORD"
    domain="$(caddy_norm_host "$1")"
    caddy_dashboard_precheck "$domain" "$username"

    caddy_assert_ports_free
    caddy_assert_not_foreign
    install_caddy_pkg

    # caddy hash-password reads a newline-terminated line from stdin -- without the
    # trailing \n it errors "EOF" and emits nothing. --algorithm bcrypt pins the
    # output to a $2 hash (matching basic_auth's default; newer Caddy can default
    # to argon2id). The password stays on stdin, never in argv/logs.
    local hash
    hash=$(printf '%s\n' "$pw" | caddy hash-password --algorithm bcrypt 2>/dev/null || true)
    [[ "$hash" == \$2* ]] || die "failed to hash the password (caddy hash-password produced no bcrypt hash)"

    local dash_tmp rpc_tmp
    dash_tmp="$(mktemp)"; rpc_tmp="$(mktemp)"
    caddy_tmp_track "$dash_tmp" "$rpc_tmp"
    caddy_extract_block "$RPC_BEGIN" "$RPC_END" > "$rpc_tmp"          # preserve RPC verbatim
    write_dashboard_block "$domain" "$username" "$hash" "$dash_tmp"
    caddy_write_managed "$dash_tmp" "$rpc_tmp"
    rm -f "$dash_tmp" "$rpc_tmp"

    caddy_open_ports
    caddy_reload
}

# Disable the dashboard vhost; preserve any RPC vhost. Full teardown only when no
# managed vhost remains.
do_disable() {
    local rpc_tmp; rpc_tmp="$(mktemp)"
    caddy_tmp_track "$rpc_tmp"
    caddy_extract_block "$RPC_BEGIN" "$RPC_END" > "$rpc_tmp"
    if [[ -s "$rpc_tmp" ]]; then
        caddy_write_managed "" "$rpc_tmp"
        caddy_reload
    else
        caddy_teardown
    fi
    rm -f "$rpc_tmp"
}

# Print a single JSON status object for the DASHBOARD vhost (UI dashboard card).
# Scoped to the dashboard block so a co-resident RPC domain never leaks in.
do_status() {
    local installed=false running=false enabled=false domain="" username="" dash=""
    command -v caddy >/dev/null 2>&1 && installed=true
    systemctl is-active --quiet caddy 2>/dev/null && running=true
    dash="$(caddy_current_dashboard_block)"
    if [[ -n "$dash" ]]; then
        enabled=true
        domain=$(printf '%s\n' "$dash" | grep -m1 -E '^[A-Za-z0-9].*\{[[:space:]]*$' | sed -E 's/[[:space:]]*\{.*$//' | tr -d ' ' || true)
        username=$(printf '%s\n' "$dash" | awk '/basic_auth[[:space:]]*\{/{f=1;next} f&&/\}/{f=0} f{print $1; exit}' || true)
    fi
    printf '{"installed":%s,"running":%s,"enabled":%s,"domain":"%s","username":"%s"}\n' \
        "$installed" "$running" "$enabled" "$(json_escape "$domain")" "$(json_escape "$username")"
}

# Evaluate DNS for <domain> into the DNS_* globals (egress / effective public IP, the
# resolved A record, bound local IPs, propagated true|false and a human note). Shared
# by the JSON and human DNS checks.
caddy_dns_eval() {
    local domain="$1" egress pub resolved local_ips propagated=false note=""
    egress=$(caddy_egress_ip)
    pub=$(caddy_public_ip)            # override-aware (TN_CADDY_PUBLIC_IP), else egress
    resolved=$(caddy_resolve_domain "$domain")
    local_ips=$(caddy_local_ips)
    if caddy_ip_reaches_host "$resolved" "$pub" "$local_ips"; then
        propagated=true
        note="${domain} resolves to ${resolved}, an address that reaches this host. (A green check confirms DNS targets this box -- NOT that ports 80/443 are open; verify TLS from outside the network.)"
    elif [[ -z "$resolved" ]]; then
        note="${domain} does not resolve yet -- create the A record (-> ${pub:-the inbound public IP}) and re-check."
    else
        note="${domain} resolves to ${resolved}, which is neither this host's effective public IP (${pub:-unknown}) nor a bound local IP (${local_ips:-none}). Note that ${egress:-unknown} is this box's EGRESS (outbound) IP, which can differ from the INBOUND IP where ACME reaches you on a multi-IP or NAT host -- so the A record should not necessarily point there. If your inbound public IP differs from the detected egress IP, supply it with --public-ip <ip> (or set TN_CADDY_PUBLIC_IP) and re-check."
    fi
    DNS_EGRESS="$egress"; DNS_PUB="$pub"; DNS_RESOLVED="$resolved"; DNS_LOCAL_IPS="$local_ips"
    DNS_PROPAGATED="$propagated"; DNS_NOTE="$note"
}

# DNS check as a single JSON object to stdout. Backward compatible: keeps
# public_ip/resolved_ip/propagated and ADDS egress_ip, local_ips, and a human note.
# Shared by the dashboard (check-dns) and RPC (rpc-check-dns) phases.
# The domain is normalised and validated first (as the UI helper does), so nothing
# but a hostname reaches dig or getent; an invalid one gives the same object with
# propagated false, the reason in note and error, and exit 1.
do_check_dns_json() {
    local domain why
    domain="$(caddy_norm_host "$1")"
    why="$(caddy_domain_problem "$domain")"
    if [[ -n "$why" ]]; then
        printf '{"domain":"%s","public_ip":"","resolved_ip":"","propagated":false,"egress_ip":"","local_ips":[],"note":"%s","error":"%s"}\n' \
            "$(json_escape "$domain")" "$(json_escape "invalid domain: ${why}")" "$(json_escape "invalid domain: ${why}")"
        return 1
    fi
    caddy_dns_eval "$domain"
    # shellcheck disable=SC2086  # intentional: split local_ips into one arg per IP (all validated dotted-quads)
    printf '{"domain":"%s","public_ip":"%s","resolved_ip":"%s","propagated":%s,"egress_ip":"%s","local_ips":%s,"note":"%s"}\n' \
        "$(json_escape "$domain")" "$(json_escape "$DNS_PUB")" "$(json_escape "$DNS_RESOLVED")" "$DNS_PROPAGATED" \
        "$(json_escape "$DNS_EGRESS")" "$(json_str_array $DNS_LOCAL_IPS)" "$(json_escape "$DNS_NOTE")"
}

# The same DNS check, human-readable (non-JSON --phase=check-dns / rpc-check-dns).
# Returns 0 only when <domain> resolves to an address that reaches this host, so a
# caller (setup-node.sh) can gate on the exit code.
do_check_dns_human() {
    local domain
    domain="$(caddy_norm_host "$1")"
    caddy_require_domain "$domain" "domain"
    caddy_dns_eval "$domain"
    print_info "Domain:              ${domain}"
    print_info "Resolves to:         ${DNS_RESOLVED:-<nothing>}"
    print_info "Effective public IP: ${DNS_PUB:-<unknown>}   (egress: ${DNS_EGRESS:-<unknown>})"
    print_info "Bound local IP(s):   ${DNS_LOCAL_IPS:-<none>}"
    if [[ "$DNS_PROPAGATED" == "true" ]]; then
        print_ok "$DNS_NOTE"
        return 0
    fi
    print_warn "$DNS_NOTE"
    return 1
}

# =============================================================================
# PHASES -- PUBLIC RPC
# =============================================================================

# Record the public endpoint in .node-meta, the keys setup-node.sh writes:
# PUBLIC_RPC_DOMAIN=<domain>, PUBLIC_RPC_URL=https://<domain> and PUBLIC_WS_URL=
# wss://<domain>, or empty when <with_ws> is false (no trailing slash, as the fleet
# records them; node-info.yaml keeps the slash). No <domain> removes all three. The
# UI and check-node read them. Best effort: a failure is a warning, never fatal.
caddy_meta_record() {
    local domain="${1:-}" with_ws="${2:-true}" ws="" key failed=""
    if [[ -z "$(node_meta_path 2>/dev/null || true)" ]]; then
        if [[ -n "$domain" ]]; then
            caddy_say info "No .node-meta found, so the public endpoint is not recorded there (PUBLIC_RPC_DOMAIN, PUBLIC_RPC_URL, PUBLIC_WS_URL)."
        fi
        return 0
    fi
    if ! caddy_meta_ready; then
        caddy_say warn "The update lock or the ownership migration stopped the .node-meta update, so PUBLIC_RPC_DOMAIN, PUBLIC_RPC_URL and PUBLIC_WS_URL were not changed."
        caddy_note ".node-meta not updated"
        return 0
    fi
    if [[ -n "$domain" ]]; then
        if [[ "$with_ws" == "true" ]]; then ws="wss://${domain}"; fi
        meta_set PUBLIC_RPC_DOMAIN "$domain" >/dev/null 2>&1 || failed="${failed} PUBLIC_RPC_DOMAIN"
        meta_set PUBLIC_RPC_URL "https://${domain}" >/dev/null 2>&1 || failed="${failed} PUBLIC_RPC_URL"
        meta_set PUBLIC_WS_URL "$ws" >/dev/null 2>&1 || failed="${failed} PUBLIC_WS_URL"
    else
        for key in PUBLIC_RPC_DOMAIN PUBLIC_RPC_URL PUBLIC_WS_URL; do
            meta_unset "$key" >/dev/null 2>&1 || failed="${failed} ${key}"
        done
    fi
    if [[ -n "$failed" ]]; then
        caddy_say warn "Could not update${failed} in $(node_meta_path 2>/dev/null || echo .node-meta). The UI and check-node may show the previous public endpoint until it is fixed by hand."
    fi
    return 0
}

# caddy_meta_ready -- make .node-meta writable for this run: the update lock (held
# until the operation ends; the EXIT trap releases it) and addon_meta_write_begin,
# which migrates an old ownership layout. rc 0 ready; 1 the lock is held elsewhere or
# the migration refused (message said; nothing written).
caddy_meta_ready() {
    [[ "$CADDY_META_READY" == "true" ]] && return 0
    if [[ "$CADDY_LOCK_HELD" != "true" ]]; then
        TN_EXIT_TRAP_OWNED=1
        if ! tn_acquire_update_lock >/dev/null 2>&1; then
            print_error "Another node operation holds the update lock${TN_UPDATE_LOCK_HOLDER:+ (PID ${TN_UPDATE_LOCK_HOLDER})}." >&2
            return 1
        fi
        CADDY_LOCK_HELD=true
    fi
    addon_meta_write_begin || return 1
    CADDY_META_READY=true
    return 0
}

# Rewrite ONLY the site address of the dashboard block in <file> (in place) to <host>.
# Every other byte -- basic_auth user + hash, the X-TN-Dashboard-Public header_up,
# encode, comments -- is kept: awk does no expansion, and <host> is a validated
# [A-Za-z0-9.-] name (no awk sub() metacharacters).
caddy_retarget_dashboard() {
    local file="$1" host="$2" tmp
    tmp="$(mktemp)"
    caddy_tmp_track "$tmp"
    awk -v h="$host" '!done && /^[A-Za-z0-9].*\{[[:space:]]*$/ {sub(/^[^[:space:]{]+/, h); done=1} {print}' "$file" > "$tmp"
    [[ "$(caddy_block_domain < "$tmp")" == "$host" ]] || die "could not rewrite the dashboard site address -- nothing was changed"
    cat "$tmp" > "$file"
    rm -f "$tmp"
}

# Start of an rpc-enable / rpc-disable: clear what a previous operation in the same
# process (the interactive menu) left behind, so its epoch wait, launch backup and
# notes are not mistaken for this one's.
caddy_operation_reset() {
    CADDY_WINDOW_DONE=false
    CADDY_RESTART_PENDING=false
    CADDY_NI_FILE=""
    CADDY_META_READY=false
    CADDY_RPC_PORT=""
    CADDY_WS_PORT_SET=""
    CADDY_NI_BAK=""
    CADDY_LAUNCH_FILE=""
    CADDY_LAUNCH_BAK=""
    CADDY_LAUNCH_METHOD=""
    CADDY_LOCK_NOTE=""
    CADDY_DONE_NOTES=""
    CADDY_WS_PLAN=""
    CADDY_WS_FLAGS=""
    CADDY_WS_OK=true
    CADDY_DASH_MOVED_TO=""
}

# Refusals for an rpc-enable, checked before anything is written (and, in a --json
# run, before any step is announced): <domain> and <move_to> (both normalised) and the
# one-hostname-per-site rule. Sets CADDY_DASH_FROM (the dashboard's current hostname,
# '' when none) and CADDY_DASH_MOVE (true when the dashboard sits on <domain> and moves
# to <move_to> in the same swap + reload).
CADDY_DASH_FROM=""
CADDY_DASH_MOVE=false
caddy_rpc_enable_precheck() {
    local domain="$1" move_to="${2:-}" clash rc
    caddy_require_domain "$domain" "RPC domain"
    CADDY_DASH_MOVE=false
    CADDY_DASH_FROM="$(caddy_current_dashboard_domain)"
    if [[ -n "$move_to" ]]; then
        caddy_require_domain "$move_to" "--move-dashboard-to hostname"
        if caddy_same_host "$move_to" "$domain"; then
            die "--move-dashboard-to (${move_to}) must differ from --rpc-domain (${domain}) -- the dashboard and the public RPC endpoint need different hostnames. Nothing was changed."
        fi
        if [[ -n "$CADDY_DASH_FROM" ]] && caddy_same_host "$domain" "$CADDY_DASH_FROM"; then
            CADDY_DASH_MOVE=true
        fi
    fi
    if [[ "$CADDY_DASH_MOVE" != "true" ]] && clash="$(caddy_domain_clash rpc "$domain")"; then die "$clash"; fi
    caddy_mainnet_gate
    caddy_node_info_path >/dev/null 2>&1 \
        || die "DATA_DIR is set more than once in .node-meta, so node-info.yaml cannot be located; remove the extra lines and run this again. Nothing was changed."
    rc=0
    CADDY_RPC_PORT="$(caddy_node_port --http.port RPC_PORT 8545)" || rc=$?
    [[ "$rc" -eq 0 ]] || die "no usable reth HTTP port for the public RPC site (see above). Nothing was changed."
    CADDY_WS_PORT_SET="$(caddy_node_port --ws.port WS_PORT 8546)" || rc=$?
    [[ "$rc" -eq 0 ]] || die "no usable reth WebSocket port for the public RPC site (see above). Nothing was changed."
    return 0
}

# The P2-5 exposure summary for a public RPC site on <domain>, one sentence per line.
caddy_rpc_exposure_summary() {
    printf '%s\n' \
        "Public RPC on https://${1}/ answers anyone on the internet, for every JSON-RPC namespace the node serves, with CORS open to every origin." \
        "This edge has no rate limit, per-IP limit or method filter: only the node's own launch limits bound the load." \
        "For production traffic put a rate-limited gateway in front of it, and never enable it on a staked validator."
}

# caddy_rpc_confirm <domain> -- state the exposure summary and get consent. --json:
# a `warn` event (the UI action is the consent). Otherwise --yes, or a yes typed on a
# terminal; without a terminal and without --yes the run stops before any change.
caddy_rpc_confirm() {
    local line ans
    if json_mode; then
        json_event warn "$(caddy_rpc_exposure_summary "$1" | tr '\n' ' ')"
        return 0
    fi
    while IFS= read -r line; do print_warn "$line"; done < <(caddy_rpc_exposure_summary "$1")
    [[ "$CADDY_YES" == "true" ]] && return 0
    [[ -t 0 ]] || die "public RPC needs your consent to the exposure above: run again with --yes (or from a terminal). Nothing was changed."
    read -r -p "  Expose this node's RPC publicly? [y/N]: " ans
    case "$ans" in
        y|Y) return 0 ;;
    esac
    die "public RPC not enabled (not confirmed). Nothing was changed."
}

# Enable the public RPC vhost (preserving any dashboard vhost), open 80/443, then add
# --ws when needed and advertise the endpoint in node-info.yaml, restarting the node
# under the brick guard, and record it in .node-meta. Order:
#   1. refusals (caddy_rpc_enable_precheck), ports, foreign config, Caddy version;
#   2. the node side is decided without changing anything (caddy_ws_plan,
#      caddy_node_info_needs_edit); when a launch edit, a node-info.yaml edit or a
#      restart will follow, the update lock is taken now, so a held lock refuses
#      before the Caddyfile is touched;
#   3. Caddyfile swap + reload (the page mentions wss:// only when it will be served);
#   4. the edits, then the committee guard, the epoch wait and the guarded restart
#      -- only when step 2 found something to change.
# <move_to> (--move-dashboard-to): when <domain> is the hostname the dashboard is
# served on, the dashboard block moves to <move_to> -- only its site address changes
# -- in the SAME swap + reload. Without it that clash dies before anything is written
# (in --json runs the reason is an `error` event, then `done ok:false`). Both names are
# normalised first (caddy_norm_host). Run again with the same domain it rewrites the
# block (a stale v1 block becomes v2) and reloads Caddy; the node is only restarted
# when node-info.yaml or the launch file needs a change.
do_rpc_enable() {
    local domain move_to ws_port want_ws=true node_change=false
    domain="$(caddy_norm_host "$1")"
    move_to="$(caddy_norm_host "${2:-}")"
    caddy_operation_reset
    caddy_rpc_enable_precheck "$domain" "$move_to"
    if [[ -n "$move_to" && "$CADDY_DASH_MOVE" != "true" ]]; then
        caddy_say info "The dashboard is not served on ${domain} (current: ${CADDY_DASH_FROM:-none}) -- --move-dashboard-to ${move_to} is not needed and was ignored."
    fi

    caddy_assert_ports_free
    caddy_assert_not_foreign
    # .node-meta records the endpoint at the end: take the update lock and migrate an
    # old ownership layout now, so a refusal comes before anything changes.
    if [[ -n "$(node_meta_path 2>/dev/null || true)" ]]; then
        caddy_meta_ready || die "the update lock or the ownership migration stopped this run (see above). Nothing was changed."
    fi
    install_caddy_pkg

    # Decide the node side first: WebSocket (may need --ws in the node launch) and
    # whether node-info.yaml needs an edit. Nothing is changed or waited for here.
    ws_port="$(caddy_ws_port)" || die "no usable reth WebSocket port (see above). Nothing was changed."
    caddy_ws_plan "$ws_port"
    if [[ "$CADDY_WS_PLAN" == "http" ]]; then want_ws=false; fi
    if [[ "$CADDY_WS_PLAN" == "inject" ]]; then node_change=true; fi
    if caddy_node_info_needs_edit set "$domain" "$want_ws"; then node_change=true; fi
    if [[ "$node_change" == "true" ]]; then
        CADDY_LOCK_NOTE="Nothing was changed."
        caddy_node_lock
    fi

    local dash_tmp rpc_tmp
    dash_tmp="$(mktemp)"; rpc_tmp="$(mktemp)"
    caddy_tmp_track "$dash_tmp" "$rpc_tmp"
    caddy_current_dashboard_block > "$dash_tmp"       # preserve dashboard verbatim (handles legacy)
    if [[ "$CADDY_DASH_MOVE" == "true" ]]; then
        caddy_retarget_dashboard "$dash_tmp" "$move_to"
        CADDY_DASH_MOVED_TO="$move_to"
        caddy_say info "Moving the dashboard from ${CADDY_DASH_FROM} to ${move_to} (same login; only the hostname changes). Its DNS A record must already point here -- Caddy requests a certificate for it."
    fi
    write_rpc_block "$domain" "$rpc_tmp" "$want_ws"
    caddy_write_managed "$dash_tmp" "$rpc_tmp"
    rm -f "$dash_tmp" "$rpc_tmp"

    caddy_open_ports
    caddy_reload

    # The node side: --ws first (under the update lock), then node-info.yaml and one
    # guarded restart (the committee guard and the epoch wait right before it).
    CADDY_LOCK_NOTE="The Caddy site for ${domain} is configured; the node launch and node-info.yaml were not changed. Run rpc-enable again later (once any update in progress has finished)."
    CADDY_WS_OK="$want_ws"
    if [[ "$CADDY_WS_PLAN" == "inject" ]]; then
        caddy_ws_inject "$ws_port" || CADDY_WS_OK=false
    fi
    if [[ "$CADDY_WS_OK" != "true" ]]; then caddy_note "wss:// not advertised"; fi
    caddy_node_info_advertise set "$domain" "$CADDY_WS_OK"
    if [[ "$CADDY_WS_OK" == "true" ]]; then caddy_ws_verify "$ws_port" "$domain"; fi
    caddy_meta_record "$domain" "$CADDY_WS_OK"
    caddy_node_unlock
}

# Disable the public RPC vhost. The takedown comes first and takes effect at once, even
# on a committee node: remove the RPC block (preserving any dashboard vhost; full
# teardown when no managed vhost remains) with a Caddy reload -- no lock, no epoch
# wait -- and drop the PUBLIC_RPC_* keys from .node-meta. Then un-advertise in
# node-info.yaml: only when worker 0 still advertises something, the update lock,
# the edit, then the committee guard, the epoch wait and a guarded restart (allowed
# on mainnet too; a guard refusal puts node-info.yaml back). A lock held by another
# run refuses that second part (`done ok:false`; the site is already gone).
do_rpc_disable() {
    caddy_operation_reset
    local dash_tmp; dash_tmp="$(mktemp)"
    caddy_tmp_track "$dash_tmp"
    caddy_current_dashboard_block > "$dash_tmp"
    if [[ -s "$dash_tmp" ]]; then
        caddy_write_managed "$dash_tmp" ""
        caddy_reload
    else
        caddy_teardown
    fi
    rm -f "$dash_tmp"
    caddy_say ok "The public RPC site is removed."
    caddy_meta_record ""

    CADDY_LOCK_NOTE="The public RPC site is removed, but node-info.yaml still advertises it; run rpc-disable again later (once any update in progress has finished)."
    CADDY_RPC_PORT="$(caddy_node_port --http.port RPC_PORT 8545)" || die "the public RPC site is removed, but there is no usable reth HTTP port to check the node with (see above), so node-info.yaml was not changed and still advertises it."
    caddy_node_info_advertise clear
    caddy_node_unlock
}

# Echo "<http>|<ws>" that node-info.yaml advertises for worker 0 (current `workers:`
# list or legacy `worker:` map); '' parts when absent, "|" when unreadable.
caddy_node_info_advertised() {
    local ni out h w
    if ! ni="$(caddy_node_info_path 2>/dev/null)" || ! out="$(caddy_node_info_rpc_get "$ni")"; then
        printf '|\n'
        return 0
    fi
    h="${out%% *}"
    w="${out#* }"
    if [[ "$h" == "none" ]]; then h=""; fi
    if [[ "$w" == "none" ]]; then w=""; fi
    printf '%s|%s\n' "$h" "$w"
}

# Print a single JSON status object for the RPC vhost (UI RPC card). The v1.2.0 keys
# come first, unchanged; advertised_http / advertised_ws (node-info.yaml worker 0 rpc,
# '' when absent), ws_listening (reth WS port bound) and block_stale (an enabled block
# written by install-caddy.sh 1.3.0 or older; caddy_rpc_block_stale) are appended.
do_rpc_status() {
    local installed=false running=false enabled=false domain="" block=""
    local adv adv_http adv_ws ws_listening=false block_stale=false
    command -v caddy >/dev/null 2>&1 && installed=true
    systemctl is-active --quiet caddy 2>/dev/null && running=true
    if caddy_block_present "$RPC_BEGIN"; then
        enabled=true
        block="$(caddy_extract_block "$RPC_BEGIN" "$RPC_END")"
        domain=$(printf '%s\n' "$block" | grep -m1 -E '^[A-Za-z0-9].*\{[[:space:]]*$' | sed -E 's/[[:space:]]*\{.*$//' | tr -d ' ' || true)
        caddy_rpc_block_stale && block_stale=true
    fi
    adv="$(caddy_node_info_advertised)"
    adv_http="${adv%%|*}"; adv_ws="${adv#*|}"
    caddy_port_listening "$(caddy_ws_port)" && ws_listening=true
    printf '{"installed":%s,"running":%s,"enabled":%s,"domain":"%s","advertised_http":"%s","advertised_ws":"%s","ws_listening":%s,"block_stale":%s}\n' \
        "$installed" "$running" "$enabled" "$(json_escape "$domain")" \
        "$(json_escape "$adv_http")" "$(json_escape "$adv_ws")" "$ws_listening" "$block_stale"
}

# =============================================================================
# JSON RUNNERS
# =============================================================================
# The --json runners. Refusals (invalid name, hostname clash) are checked before the
# step list is announced; each refusal is an `error` event and `done ok:false`
# (die). A run that succeeded but left something undone (caddy_note) says so in its
# closing message too; the matching `warn` event went out when it happened.
run_json_enable() {
    local domain
    json_setup_fds
    trap json_on_exit EXIT
    check_root
    domain="$(caddy_norm_host "$JSON_DOMAIN")"
    caddy_dashboard_precheck "$domain" "$JSON_USERNAME"
    json_event step "Checking ports 80 and 443 are free"
    json_event step "Installing Caddy (if needed)"
    json_event step "Configuring the dashboard site for ${domain}"
    json_event step "Opening the firewall (80, 443) and reloading Caddy"
    do_enable "$domain" "$JSON_USERNAME"
    json_done "{\"event\":\"done\",\"ok\":true,\"domain\":\"$(json_escape "$domain")\",\"msg\":\"external dashboard access enabled -- certificate will be issued on first request\"}"
}

run_json_disable() {
    json_setup_fds
    trap json_on_exit EXIT
    check_root
    json_event step "Disabling external dashboard access"
    do_disable
    json_done "{\"event\":\"done\",\"ok\":true,\"msg\":\"external dashboard access disabled\"}"
}

run_json_rpc_enable() {
    local domain move_to
    json_setup_fds
    trap json_on_exit EXIT
    check_root
    domain="$(caddy_norm_host "$JSON_RPC_DOMAIN")"
    move_to="$(caddy_norm_host "$JSON_MOVE_DASH")"
    caddy_rpc_enable_precheck "$domain" "$move_to"
    caddy_rpc_confirm "$domain"
    json_event step "Checking ports 80 and 443 are free"
    json_event step "Installing Caddy (if needed)"
    json_event step "Configuring the public RPC endpoint for ${domain}"
    if [[ "$CADDY_DASH_MOVE" == "true" ]]; then
        json_event step "Moving the dashboard to ${move_to}"
    fi
    json_event step "Opening the firewall (80, 443) and reloading Caddy"
    json_event step "Advertising the endpoint in node-info.yaml"
    do_rpc_enable "$domain" "$move_to"
    json_done "{\"event\":\"done\",\"ok\":true,\"domain\":\"$(json_escape "$domain")\",\"msg\":\"$(json_escape "public RPC endpoint enabled -- certificate issues on first request${CADDY_DONE_NOTES:+ (${CADDY_DONE_NOTES})}")\"}"
}

run_json_rpc_disable() {
    json_setup_fds
    trap json_on_exit EXIT
    check_root
    json_event step "Removing the public RPC site"
    json_event step "Clearing the advertisement in node-info.yaml"
    do_rpc_disable
    json_done "{\"event\":\"done\",\"ok\":true,\"msg\":\"$(json_escape "public RPC endpoint disabled${CADDY_DONE_NOTES:+ (${CADDY_DONE_NOTES})}")\"}"
}

# =============================================================================
# INTERACTIVE
# =============================================================================

# Map a listening process name to "service|friendly|purgable". Empty when it's
# not a web server we know how to stop. On Ubuntu the package and systemd unit
# names match (apache2/nginx/lighttpd), so one token serves both.
caddy_known_webserver() {
    case "$1" in
        apache2)  echo "apache2|Apache|true" ;;
        nginx)    echo "nginx|Nginx|false" ;;
        lighttpd) echo "lighttpd|Lighttpd|false" ;;
        *)        echo "" ;;
    esac
}

# Interactive: if Apache (or another known web server) is holding 80/443, offer to
# stop/disable it -- or remove it outright -- so Caddy can bind; else let the user
# quit and handle it themselves. Caddy already running its OWN config is NOT a
# conflict here (caddy_port_holder ignores caddy); a foreign Caddyfile is handled
# separately by caddy_foreign_config.
resolve_port_conflicts() {
    local procs p info svc friendly purgable ans
    procs=$( { caddy_port_holder 80; caddy_port_holder 443; } | grep -v '^$' | sort -u || true)
    [[ -z "$procs" ]] && return 0

    while IFS= read -r p; do
        [[ -z "$p" ]] && continue
        info=$(caddy_known_webserver "$p")
        if [[ -z "$info" ]]; then
            die "ports 80/443 are in use by '${p}', which I do not know how to stop safely. Stop or reconfigure it manually, then re-run."
        fi
        IFS='|' read -r svc friendly purgable <<< "$info"
        echo ""
        print_warn "${friendly} (${svc}) is using a port Caddy needs (80/443) -- they cannot run together."
        while true; do
            if [[ "$purgable" == "true" ]]; then
                read -r -p "  [s] stop & disable ${svc} / [p] stop, disable & remove (purge) / [q] quit: " ans
            else
                read -r -p "  [s] stop & disable ${svc} / [q] quit: " ans
            fi
            case "$ans" in
                s|S) systemctl stop "$svc" 2>/dev/null || true
                     systemctl disable "$svc" 2>/dev/null || true
                     print_ok "Stopped and disabled ${svc}."; break ;;
                p|P) [[ "$purgable" == "true" ]] || { print_warn "Choose s or q."; continue; }
                     systemctl stop "$svc" 2>/dev/null || true
                     systemctl disable "$svc" 2>/dev/null || true
                     run_streamed apt-get purge -y "$svc"
                     print_ok "Removed ${svc}."; break ;;
                q|Q) print_info "Aborted. Free ports 80/443 (remove or reconfigure ${friendly}) and re-run."; exit 0 ;;
                *)   ;;
            esac
        done
    done <<< "$procs"

    sleep 1
    local h80 h443; h80=$(caddy_port_holder 80); h443=$(caddy_port_holder 443)
    [[ -n "$h80" || -n "$h443" ]] && die "ports 80/443 are still in use (80:'${h80:-free}' 443:'${h443:-free}') -- cannot continue."
    return 0
}

# Prompt for / confirm the inbound public IP the A record must point at, and export
# TN_CADDY_PUBLIC_IP for the rest of the flow. Shared by the dashboard + RPC flows.
caddy_prompt_public_ip() {
    local egress local_ips pub pub_default
    egress=$(caddy_egress_ip)
    local_ips=$(caddy_local_ips)
    print_info "This server's egress (outbound) IP: ${egress:-<unknown>}"
    print_info "Bound local IP(s) on this host:     ${local_ips:-<none>}"
    echo ""
    print_info "The DNS A record must point at this server's INBOUND public IP -- the"
    print_info "address where ACME challenges on ports 80/443 arrive. On a multi-IP host"
    print_info "or behind 1:1 NAT this can DIFFER from the egress IP above (inbound traffic,"
    print_info "like your SSH session, may reach a different address than outbound uses)."
    echo ""
    pub_default="${TN_CADDY_PUBLIC_IP:-$egress}"
    while true; do
        read -r -p "  Server's inbound public IP [${pub_default:-enter manually}]: " pub
        pub="${pub:-$pub_default}"
        [[ -n "$pub" ]] && validate_public_ip "$pub" && break
        print_warn "Enter a valid IP address (the public IP your A record points at)."
    done
    export TN_CADDY_PUBLIC_IP="$pub"
}

# Gate on DNS propagation for <domain>: re-check / continue-anyway / abort loop.
caddy_dns_gate() {
    local domain="$1" pub="${TN_CADDY_PUBLIC_IP:-}" local_ips resolved ans
    local_ips=$(caddy_local_ips)
    read -r -p "  Press Enter to check DNS propagation once the record is set..."
    while true; do
        resolved=$(caddy_resolve_domain "$domain")
        if caddy_ip_reaches_host "$resolved" "$pub" "$local_ips"; then
            print_ok "${domain} resolves to ${resolved}, which reaches this server. Proceeding."
            return 0
        fi
        print_warn "${domain} resolves to '${resolved:-<nothing>}', which is not this server's"
        print_warn "inbound public IP (${pub}) or any bound local IP (${local_ips:-none})."
        read -r -p "  [r]echeck / [c]ontinue anyway / [a]bort: " ans
        case "$ans" in
            c|C) print_warn "Continuing despite DNS mismatch -- cert issuance may fail."; return 0 ;;
            a|A) print_info "Aborted."; exit 0 ;;
            *) ;;
        esac
    done
}

# Interactive: enable external dashboard access.
dashboard_enable_interactive() {
    print_header "Dashboard -- External Access (Caddy)  v${SCRIPT_VERSION}"
    print_info "Makes the Node Manager dashboard reachable at https://<your-domain> with a"
    print_info "login, behind Caddy. Public access is READ-ONLY -- management stays on the"
    print_info "SSH tunnel."
    echo ""
    caddy_mainnet_gate
    caddy_prompt_public_ip
    echo ""

    local domain username pw pw2 clash why
    while true; do
        read -r -p "  Dashboard domain (e.g. admin.node1.adiri.telcoin.network): " domain
        domain="$(caddy_norm_host "$domain")"
        why="$(caddy_domain_problem "$domain")"
        [[ -z "$why" ]] || { print_warn "Invalid domain: ${why}."; continue; }
        if clash="$(caddy_domain_clash dashboard "$domain")"; then print_warn "$clash"; continue; fi
        break
    done
    while true; do
        read -r -p "  Dashboard username [admin]: " username
        username="${username:-admin}"
        caddy_validate_username "$username" && break
        print_warn "Invalid username (2-32 chars: letters, digits, . _ -)."
    done
    while true; do
        read -r -s -p "  Dashboard password (min ${CADDY_PASSWORD_MIN} chars; Enter alone generates one): " pw; echo ""
        if [[ -z "$pw" ]]; then
            pw="$(caddy_generate_password)"
            [[ -z "$(caddy_password_problem "$pw")" ]] || { print_warn "Could not generate a password; type one."; continue; }
            print_info "Generated dashboard password (shown once; store it in your password manager):"
            printf '      %s\n' "$pw"
            break
        fi
        read -r -s -p "  Confirm password: " pw2; echo ""
        [[ "$pw" == "$pw2" ]] || { print_warn "Passwords do not match."; continue; }
        why="$(caddy_password_problem "$pw")"
        [[ -z "$why" ]] || { print_warn "Not accepted: ${why}."; continue; }
        break
    done

    echo ""
    print_warn "BEFORE CONTINUING: create a DNS A record:"
    print_info "    ${domain}  ->  ${TN_CADDY_PUBLIC_IP:-this servers public IP}"
    print_warn "If this host is behind NAT, point the record at your routers public IP"
    print_warn "and port-forward to this machine: 443/tcp is REQUIRED, 80/tcp recommended."
    echo ""
    caddy_dns_gate "$domain"

    resolve_port_conflicts
    caddy_confirm_foreign_overwrite

    CADDY_PASSWORD="$pw"
    pw=""
    pw2=""
    do_enable "$domain" "$username"
    CADDY_PASSWORD=""
    echo ""
    print_ok "External dashboard access enabled at https://${domain}"
    print_info "The TLS certificate is issued on the first request -- give it a few seconds."
    print_info "Public access is READ-ONLY. For management, use the SSH tunnel (localhost:8080)."
}

# Interactive: enable the public RPC endpoint.
rpc_enable_interactive() {
    print_header "Public RPC Endpoint (Caddy)  v${SCRIPT_VERSION}"
    print_info "Exposes this node's JSON-RPC publicly at https://<rpc-domain>/ (+ wss://) behind"
    print_info "Caddy with automatic TLS. reth stays loopback-only; the public reach is the TLS"
    print_info "edge. Enabling ALSO advertises the endpoint in node-info.yaml (so peers discover"
    print_info "it) and restarts the node when that, or adding --ws, changes anything."
    echo ""
    caddy_mainnet_gate
    caddy_prompt_public_ip
    echo ""

    local domain move_to="" ans why
    while true; do
        read -r -p "  Public RPC domain (e.g. node1.adiri.telcoin.network): " domain
        domain="$(caddy_norm_host "$domain")"
        why="$(caddy_domain_problem "$domain")"
        [[ -z "$why" ]] || { print_warn "Invalid domain: ${why}."; continue; }
        if caddy_domain_clash rpc "$domain" >/dev/null; then
            # Same-domain guard: offer to move the dashboard (same login) off this hostname.
            print_warn "${domain} currently serves the Node Manager dashboard; the dashboard and the"
            print_warn "public RPC endpoint need DIFFERENT hostnames."
            read -r -p "  Move the dashboard to dashboard.${domain} and use ${domain} for RPC? [y/N]: " ans
            case "$ans" in
                y|Y) move_to="dashboard.${domain}"
                     caddy_validate_domain "$move_to" || { print_warn "${move_to} would exceed the 253-character hostname limit -- choose a shorter RPC domain."; move_to=""; continue; } ;;
                *)   print_info "Choose another RPC domain."; continue ;;
            esac
        fi
        break
    done

    echo ""
    print_warn "BEFORE CONTINUING: create a DNS A record:"
    print_info "    ${domain}  ->  ${TN_CADDY_PUBLIC_IP:-this servers public IP}"
    [[ -n "$move_to" ]] && print_info "    ${move_to}  ->  ${TN_CADDY_PUBLIC_IP:-this servers public IP}   (the moved dashboard)"
    print_warn "If this host is behind NAT, port-forward 443/tcp (required) and 80/tcp (recommended)."
    echo ""
    caddy_dns_gate "$domain"
    [[ -n "$move_to" ]] && caddy_dns_gate "$move_to"

    echo ""
    print_warn "This will expose this node's JSON-RPC publicly at https://${domain}/, open"
    print_warn "ports 80/443, advertise the endpoint to peers (node-info.yaml worker rpc), and"
    print_warn "RESTART the node if node-info.yaml or its launch changes (adding --ws first if"
    print_warn "reth's WebSocket is off)."
    while IFS= read -r ans; do print_warn "$ans"; done < <(caddy_rpc_exposure_summary "$domain")
    [[ -n "$move_to" ]] && print_warn "The dashboard moves to https://${move_to} (same login)."
    read -r -p "  Proceed? [y/N]: " ans
    case "$ans" in
        y|Y) ;;
        *) print_info "Aborted."; return 0 ;;
    esac

    resolve_port_conflicts
    caddy_confirm_foreign_overwrite

    do_rpc_enable "$domain" "$move_to"
    echo ""
    caddy_rpc_enabled_summary "$domain"
}

# Closing lines after a successful rpc-enable (interactive + non-interactive phase).
caddy_rpc_enabled_summary() {
    local domain="$1"
    if [[ "$CADDY_WS_OK" == "true" ]]; then
        print_ok "Public RPC endpoint enabled at https://${domain}/  (wss://${domain}/)"
    else
        print_ok "Public RPC endpoint enabled at https://${domain}/  (wss:// NOT advertised -- see the warning above)"
    fi
    [[ -n "$CADDY_DASH_MOVED_TO" ]] && print_ok "Dashboard moved to https://${CADDY_DASH_MOVED_TO} (same login)."
    print_info "The TLS certificate is issued on the first request -- give it a few seconds."
    caddy_print_notes
}

# Human runs: the closing notes (caddy_note) as one warning line, when there are any.
caddy_print_notes() {
    [[ -n "$CADDY_DONE_NOTES" ]] || return 0
    print_warn "Open items: ${CADDY_DONE_NOTES} (see the warnings above)."
}

# Interactive: don't silently clobber a Caddy config the operator set up by hand.
caddy_confirm_foreign_overwrite() {
    caddy_foreign_config || return 0
    local ans
    echo ""
    print_warn "An existing Caddy configuration was found at ${CADDYFILE} (not created by the Node Manager)."
    print_warn "Enabling will REPLACE it (the original is backed up to ${CADDYFILE_ORIG})."
    read -r -p "  [o] back up and overwrite / [q] quit: " ans
    case "$ans" in
        o|O) CADDY_OVERWRITE_FOREIGN=true ;;
        *)   print_info "Aborted. Re-run after migrating your Caddy config."; exit 0 ;;
    esac
}

# Human-readable Caddy install/run state (first line of every status view).
print_caddy_state_human() {
    local installed="no" running="no"
    command -v caddy >/dev/null 2>&1 && installed="yes"
    systemctl is-active --quiet caddy 2>/dev/null && running="yes"
    echo ""
    print_info "Caddy installed: ${installed}    running: ${running}"
}

# Human-readable status of the public RPC vhost, its node-info.yaml advertisement and
# whether reth's WebSocket port is bound (same fields as the rpc-status JSON).
print_rpc_status_human() {
    local rdom adv ws_port
    if caddy_block_present "$RPC_BEGIN"; then
        rdom="$(caddy_current_rpc_domain)"
        if caddy_port_listening "$(caddy_ws_port)"; then
            print_ok "Public RPC: ENABLED  ->  https://${rdom:-<unknown>}/  (wss://${rdom:-<unknown>}/)"
        else
            print_ok "Public RPC: ENABLED  ->  https://${rdom:-<unknown>}/  (wss:// not served: the reth WebSocket port is not listening)"
        fi
        if caddy_rpc_block_stale; then
            print_warn "The public RPC block in ${CADDYFILE} was written by an older install-caddy.sh: WebSocket upgrades sent with a lowercase 'Connection: upgrade' get 405, request bodies are not capped and browsers get no page. Refresh it by running rpc-enable again with the same hostname (a Caddy reload; the node restarts only if node-info.yaml or its WebSocket flags need a change):"
            print_info "    sudo bash ${SCRIPT_DIR}/install-caddy.sh --phase=rpc-enable --rpc-domain ${rdom:-<rpc-domain>}"
        fi
    else
        print_info "Public RPC: disabled"
    fi
    adv="$(caddy_node_info_advertised)"
    print_info "Advertised in node-info.yaml:  http: ${adv%%|*}   ws: ${adv#*|}"
    ws_port="$(caddy_ws_port)"
    if caddy_port_listening "$ws_port"; then
        print_ok "reth WebSocket: listening on port ${ws_port}"
    else
        print_warn "reth WebSocket: NOT listening on port ${ws_port}"
    fi
}

# Interactive / --phase=status: human-readable status of both vhosts.
print_status_human() {
    print_caddy_state_human
    local dash; dash="$(caddy_current_dashboard_block)"
    if [[ -n "$dash" ]]; then
        local ddom; ddom=$(printf '%s\n' "$dash" | grep -m1 -E '^[A-Za-z0-9].*\{[[:space:]]*$' | sed -E 's/[[:space:]]*\{.*$//' | tr -d ' ' || true)
        print_ok "Dashboard: ENABLED  ->  https://${ddom:-<unknown>}"
    else
        print_info "Dashboard: disabled"
    fi
    print_rpc_status_human
}

# Interactive: dashboard sub-menu.
dashboard_menu() {
    local ans
    while true; do
        echo ""
        print_info "Dashboard (Node Manager UI):"
        echo "    [e] enable / re-configure"
        echo "    [d] disable"
        echo "    [b] back"
        read -r -p "  Choose [e/d/b]: " ans
        case "$ans" in
            e|E) dashboard_enable_interactive; return 0 ;;
            d|D) do_disable; print_ok "Dashboard access disabled."; return 0 ;;
            b|B) return 0 ;;
            *) ;;
        esac
    done
}

# Interactive: RPC sub-menu.
rpc_menu() {
    local ans
    while true; do
        echo ""
        print_info "Public RPC endpoint:"
        echo "    [e] enable / re-configure"
        echo "    [d] disable"
        echo "    [b] back"
        read -r -p "  Choose [e/d/b]: " ans
        case "$ans" in
            e|E) rpc_enable_interactive; return 0 ;;
            d|D) print_warn "Disabling removes the public site at once, then un-advertises the endpoint (node-info.yaml) and restarts the node."
                 read -r -p "  Proceed? [y/N]: " ans
                 case "$ans" in y|Y) do_rpc_disable; print_ok "Public RPC endpoint disabled."; caddy_print_notes ;; *) print_info "Aborted." ;; esac
                 return 0 ;;
            b|B) return 0 ;;
            *) ;;
        esac
    done
}

# Interactive top-level menu.
interactive_menu() {
    check_root
    print_header "Telcoin Node -- External Access (Caddy)  v${SCRIPT_VERSION}"
    while true; do
        echo ""
        print_info "What would you like to manage?"
        echo "    [1] Dashboard (Node Manager UI)   -- public HTTPS access with a login"
        echo "    [2] Public RPC endpoint           -- https/wss JSON-RPC, advertised on-network"
        echo "    [3] Show status"
        echo "    [q] Quit"
        local ans; read -r -p "  Choose [1/2/3/q]: " ans
        case "$ans" in
            1) dashboard_menu ;;
            2) rpc_menu ;;
            3) print_status_human ;;
            q|Q) exit 0 ;;
            *) ;;
        esac
    done
}

# =============================================================================
# NON-INTERACTIVE HUMAN MODE (--phase=<x> without --json)
# =============================================================================
# Run ONE phase with human-readable output and no prompts -- how setup-node.sh drives
# the RPC flow at first install. Same phases and flags as the JSON contract (enable
# reads the password from --password-stdin, else $TN_CADDY_PASSWORD; rpc-enable asks
# for consent on a terminal and needs --yes without one); failures exit non-zero. check-dns and
# rpc-check-dns exit 0 only when the domain resolves to an address that reaches this
# host (1 otherwise), so callers can gate on the exit code.
run_phase_human() {
    local phase="$1"
    case "$phase" in
        status)        print_status_human ;;
        check-dns)     do_check_dns_human "$JSON_DOMAIN" ;;
        enable)
            check_root
            do_enable "$JSON_DOMAIN" "$JSON_USERNAME"
            print_ok "External dashboard access enabled at https://${JSON_DOMAIN} -- the certificate is issued on the first request."
            ;;
        disable)
            check_root
            do_disable
            print_ok "External dashboard access disabled."
            ;;
        rpc-status)    print_caddy_state_human; print_rpc_status_human ;;
        rpc-check-dns) do_check_dns_human "$JSON_RPC_DOMAIN" ;;
        rpc-enable)
            check_root
            caddy_rpc_enable_precheck "$JSON_RPC_DOMAIN" "$JSON_MOVE_DASH"
            caddy_rpc_confirm "$JSON_RPC_DOMAIN"
            do_rpc_enable "$JSON_RPC_DOMAIN" "$JSON_MOVE_DASH"
            caddy_rpc_enabled_summary "$JSON_RPC_DOMAIN"
            ;;
        rpc-disable)
            check_root
            do_rpc_disable
            print_ok "Public RPC endpoint disabled."
            caddy_print_notes
            ;;
        *) die "unknown --phase '${phase}' (status|check-dns|enable|disable|rpc-status|rpc-check-dns|rpc-enable|rpc-disable)" ;;
    esac
}

# =============================================================================
# MAIN
# =============================================================================
# A malformed command line: in --json mode an `error` event and `done ok:false` on
# stdout, otherwise [ERROR] on stderr; exit 2. Checked before any phase starts.
caddy_usage_error() {
    if json_mode; then
        printf '{"event":"error","msg":"%s"}\n{"event":"done","ok":false,"msg":"%s"}\n' "$(json_escape "$1")" "$(json_escape "$1")"
    else
        print_error "$1"
    fi
    exit 2
}

# Die unless lib/common.sh has the helpers this release writes through (it ships with
# this script; an older copy means update-scripts.sh did not finish).
caddy_require_lib() {
    local fn missing=""
    for fn in tn_write_root_file tn_backup_file tn_restore_backup tn_as_service_user \
              addon_meta_get addon_meta_write_begin tn_acquire_update_lock _tn_strip_gw \
              tn_committee_down_guard tn_wait_restart_window tn_local_rpc_url; do
        declare -F "$fn" >/dev/null 2>&1 || missing="${missing:+${missing}, }${fn}"
    done
    [[ -z "$missing" ]] && return 0
    caddy_usage_error "lib/common.sh ${COMMON_VERSION:-unknown} lacks ${missing}; run update-scripts.sh, then this again."
}

main() {
    local arg pw_env="${TN_CADDY_PASSWORD:-}"
    # The password never stays in the environment of anything this run starts.
    unset TN_CADDY_PASSWORD
    # --json first, so a usage error below is reported in the form the caller reads.
    for arg in "$@"; do
        if [[ "$arg" == "--json" ]]; then JSON_MODE=true; fi
    done
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json)         shift ;;
            --password-stdin) CADDY_PASSWORD_STDIN=true; shift ;;
            --yes|-y)       CADDY_YES=true; shift ;;
            --phase|--domain|--username|--rpc-domain|--move-dashboard-to|--public-ip)
                # A value flag given as the last word has no value: a usage error,
                # never a silent exit.
                [[ $# -ge 2 ]] || caddy_usage_error "$1 needs a value (usage: install-caddy.sh [--json] --phase=<phase> [--domain <d>] [--username <u>] [--rpc-domain <d>] [--move-dashboard-to <host>] [--public-ip <ip>])"
                case "$1" in
                    --phase)             JSON_PHASE="$2" ;;
                    --domain)            JSON_DOMAIN="$2" ;;
                    --username)          JSON_USERNAME="$2" ;;
                    --rpc-domain)        JSON_RPC_DOMAIN="$2" ;;
                    # rpc-enable only: move a dashboard that sits on --rpc-domain to this hostname.
                    --move-dashboard-to) JSON_MOVE_DASH="$2" ;;
                    # Operator-supplied INBOUND public IP -- the address the A record points
                    # at, which on multi-IP / NAT hosts differs from the detected egress IP.
                    # Exported so both JSON (check-dns) and interactive paths honour it via
                    # caddy_public_ip().
                    --public-ip)         export TN_CADDY_PUBLIC_IP="$2" ;;
                esac
                shift 2 ;;
            --phase=*)      JSON_PHASE="${1#*=}"; shift ;;
            --domain=*)     JSON_DOMAIN="${1#*=}"; shift ;;
            --username=*)   JSON_USERNAME="${1#*=}"; shift ;;
            --rpc-domain=*) JSON_RPC_DOMAIN="${1#*=}"; shift ;;
            --move-dashboard-to=*) JSON_MOVE_DASH="${1#*=}"; shift ;;
            --public-ip=*)  export TN_CADDY_PUBLIC_IP="${1#*=}"; shift ;;
            *) shift ;;
        esac
    done
    # Hostnames as the UI normalises them (trimmed, lowercase, no trailing dot); the
    # phases validate and use only these.
    JSON_DOMAIN="$(caddy_norm_host "$JSON_DOMAIN")"
    JSON_RPC_DOMAIN="$(caddy_norm_host "$JSON_RPC_DOMAIN")"
    JSON_MOVE_DASH="$(caddy_norm_host "$JSON_MOVE_DASH")"
    caddy_require_lib
    if [[ "$CADDY_PASSWORD_STDIN" == "true" ]]; then
        [[ -z "$pw_env" ]] || caddy_usage_error "the password came both on stdin (--password-stdin) and in TN_CADDY_PASSWORD; give it one way only."
        caddy_read_password_stdin
    else
        CADDY_PASSWORD="$pw_env"
    fi
    pw_env=""

    # A signal exits with the conventional 128+N status, so the EXIT trap below (and
    # json_on_exit, which reports "exited early (rc=...)") sees a non-zero rc instead of
    # the 0 that $? holds when the trap interrupts a successful command. Armed BEFORE the
    # EXIT trap; `exit` still runs it, so temp files are removed on a signal too.
    trap 'exit 143' TERM
    trap 'exit 130' INT
    trap 'exit 129' HUP

    # Temp files are removed and the update lock released on every exit path (the JSON
    # runners swap this for json_on_exit, which does both too).
    trap caddy_exit_cleanup EXIT

    if json_mode; then
        case "$JSON_PHASE" in
            status)        do_status ;;
            check-dns)     do_check_dns_json "$JSON_DOMAIN" ;;
            enable)        run_json_enable ;;
            disable)       run_json_disable ;;
            rpc-status)    do_rpc_status ;;
            rpc-check-dns) do_check_dns_json "$JSON_RPC_DOMAIN" ;;
            rpc-enable)    run_json_rpc_enable ;;
            rpc-disable)   run_json_rpc_disable ;;
            *) echo '{"event":"done","ok":false,"msg":"unknown or missing --phase (status|check-dns|enable|disable|rpc-status|rpc-check-dns|rpc-enable|rpc-disable)"}'; exit 1 ;;
        esac
        exit $?
    fi

    # --phase without --json: run that phase non-interactively, human-readable.
    if [[ -n "$JSON_PHASE" ]]; then
        run_phase_human "$JSON_PHASE"
        exit 0
    fi

    interactive_menu
}

main "$@"
