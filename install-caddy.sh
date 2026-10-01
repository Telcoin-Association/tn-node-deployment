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
#   2) Public RPC (# >>> tn-rpc >>> ... # <<< tn-rpc <<<)
#        https://<rpc-domain>/  -> 127.0.0.1:${RPC_PORT}  (JSON-RPC; CORS + OPTIONS)
#        wss://<rpc-domain>/    -> 127.0.0.1:${WS_PORT}   (WebSocket upgrade)
#        reth stays loopback-only; the public reach is exclusively the Caddy TLS
#        edge. Enabling also ADVERTISES the endpoint in node-info.yaml (the rpc of
#        every `workers:` entry; legacy `worker:` map too) so gateways/wallets
#        discover it, then restarts the node (with a brick guard).
#
# SAFETY RULES (every Caddyfile change, enable/disable/teardown alike):
#   - The new file is rendered to a temp file inside /etc/caddy and checked with
#     `caddy validate`, whose output is shown (bcrypt / base64 hashes redacted). A
#     failure leaves the live Caddyfile untouched and exits non-zero.
#   - The live file is backed up to /etc/caddy/Caddyfile.bak.<YYYYmmdd_HHMMSS> (cp -p,
#     path printed), then replaced by an atomic rename keeping its owner + mode.
#   - Caddy running -> `systemctl reload` only, never a blind restart. A rejected reload
#     restores that backup over the live file and exits non-zero (rpc-enable then stops:
#     nothing is advertised, the node is not restarted); a reload that succeeds but leaves
#     Caddy down exits non-zero with the new file kept. Caddy stopped -> first start.
#     One exception: taking over a hand-made Caddyfile with `admin off` (no admin API, so
#     no reload is possible) restarts Caddy once, saying why.
#   - Same-domain rule: the dashboard and the public RPC endpoint need DIFFERENT
#     hostnames. The node's public name (e.g. nodeN.adiri.telcoin.network) carries RPC;
#     the dashboard goes on another name (e.g. dashboard.nodeN.adiri.telcoin.network).
#     A clash dies before anything is written; the dashboard block is never dropped.
#     rpc-enable --move-dashboard-to <host> moves a dashboard sitting on the RPC
#     hostname (site address only; same login) in the same swap + reload.
#   - WebSocket preflight (rpc-enable): wss:// is advertised only when reth's WS
#     endpoint will exist -- the node itself listens on WS_PORT, or the node launch
#     already carries --ws; otherwise `--ws --ws.addr 127.0.0.1 --ws.port <WS_PORT>` is
#     added to the node's launch line. When that is not possible (or another process
#     holds WS_PORT) only https:// is advertised, with a warning.
#   - Node-restart brick guard (rpc-enable, rpc-disable): after restarting the node it
#     checks up to 30 times, about 2 s apart (~60 s), for RPC to answer. Only a unit that
#     reaches systemd's `failed` state inside that window (a crash loop that used up its
#     start limit) gets node-info.yaml and the launch edit rolled back and the node
#     restarted on the previous config. A node still auto-restarting (RestartSec) or
#     replaying its DB when the window ends is NOT rolled back -- the change is kept,
#     with a warning.
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
#   install-caddy.sh --json --phase=enable --domain <d> --username <u>   (password: $TN_CADDY_PASSWORD)
#   install-caddy.sh --json --phase=disable
#   install-caddy.sh --json --phase=rpc-status
#   install-caddy.sh --json --phase=rpc-check-dns --rpc-domain <d> [--public-ip <inbound-ip>]
#   install-caddy.sh --json --phase=rpc-enable --rpc-domain <d> [--move-dashboard-to <host>]
#   install-caddy.sh --json --phase=rpc-disable
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

# common.sh provides the print_*/check_root helpers but not die(); define our own
# so error paths exit cleanly (print_error goes to stderr, which the UI surfaces).
die() { print_error "$*"; exit 1; }

readonly SCRIPT_VERSION="1.3.0"
readonly CADDYFILE="/etc/caddy/Caddyfile"
readonly CADDY_DIR="${CADDYFILE%/*}"
readonly CADDYFILE_ORIG="/etc/caddy/Caddyfile.tn-orig"
readonly UI_UPSTREAM="127.0.0.1:8080"
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
# Set by caddy_ws_preflight when it injected --ws into the node launch file: the file,
# its pre-edit backup and the install method. The node-restart brick guard rolls the
# launch edit back with node-info.yaml, and the node restarts even when node-info.yaml
# itself is unchanged (otherwise the new flag would never take effect).
CADDY_LAUNCH_FILE=""
CADDY_LAUNCH_BAK=""
CADDY_LAUNCH_METHOD=""
# Outcome flags of do_rpc_enable for the final messages: whether wss:// was advertised
# (false when caddy_ws_preflight fell back to http only) and where the dashboard moved.
CADDY_WS_OK=true
CADDY_DASH_MOVED_TO=""

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

json_mode() { [[ "$JSON_MODE" == "true" ]]; }

json_setup_fds() { exec 3>&1; exec 1>&2; }   # fd3 = JSON; stdout -> stderr (noise)

json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/\\n}"; s="${s//$'\r'/ }"; s="${s//$'\t'/ }"
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
    caddy_cleanup_tmp
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
# EXIT-trap body: remove every registered temp file. Idempotent, never fails.
caddy_cleanup_tmp() {
    local f
    for f in $CADDY_TMP_FILES; do rm -f "$f" 2>/dev/null || true; done
    CADDY_TMP_FILES=""
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

# caddy_say <ok|warn|info> <msg> -- print_* for the terminal; in --json mode ALSO a
# `log` event, because there stdout is redirected to stderr (server logs only) and the
# operator should still see backups, WebSocket changes and warnings in the UI.
caddy_say() {
    local level="$1" msg
    shift
    msg="$*"
    case "$level" in
        ok)   print_ok "$msg" ;;
        warn) print_warn "$msg"; msg="WARNING: ${msg}" ;;
        *)    print_info "$msg" ;;
    esac
    if json_mode; then
        json_emit "{\"event\":\"log\",\"msg\":\"$(json_escape "$msg")\"}" 2>/dev/null || true
    fi
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

# 0 (true) for a multi-label DNS hostname within the RFC 1035 limits: at most 253
# characters overall, each label 1-63 characters of letters, digits and inner hyphens.
# Used for --domain, --rpc-domain and --move-dashboard-to (and the interactive prompts).
caddy_validate_domain() {
    [[ "${#1}" -le 253 ]] || return 1
    [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+$ ]]
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

# Install Caddy from the official (cloudsmith) apt repo if missing.
install_caddy_pkg() {
    if command -v caddy >/dev/null 2>&1; then
        print_ok "Caddy already installed: $(caddy version 2>/dev/null | head -1)"
        return 0
    fi
    print_info "Installing Caddy from the official repository..."
    run_streamed apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
        | gpg --batch --yes --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
        > /etc/apt/sources.list.d/caddy-stable.list
    run_streamed apt-get update
    run_streamed apt-get install -y caddy
    command -v caddy >/dev/null 2>&1 || die "Caddy installation failed"
}

caddy_open_ports() {
    command -v ufw >/dev/null 2>&1 || return 0
    ufw status 2>/dev/null | grep -q "Status: active" || return 0
    ufw allow 80/tcp  >/dev/null 2>&1 || true
    ufw allow 443/tcp >/dev/null 2>&1 || true
}
caddy_close_ports() {
    command -v ufw >/dev/null 2>&1 || return 0
    ufw status 2>/dev/null | grep -q "Status: active" || return 0
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
#   2. keep the true pre-Telcoin config once (Caddyfile.tn-orig, never our own file);
#   3. back up the live file to Caddyfile.bak.<YYYYmmdd_HHMMSS> (cp -p; never clobbers
#      an existing backup) and record it in CADDY_LAST_BACKUP for caddy_apply_live;
#   4. give <tmp> the live file's owner+mode (root:root 0644 when none), then mv -f.
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
        cp -p "$CADDYFILE" "$CADDYFILE_ORIG"
    fi
    if [[ -f "$CADDYFILE" ]]; then
        bak="${CADDYFILE}.bak.$(date +%Y%m%d_%H%M%S)"
        while [[ -e "$bak" ]]; do
            sleep 1
            bak="${CADDYFILE}.bak.$(date +%Y%m%d_%H%M%S)"
        done
        cp -p "$CADDYFILE" "$bak"
        CADDY_LAST_BACKUP="$bak"
        caddy_say info "Backed up the live Caddyfile to ${bak}"
        chown --reference="$CADDYFILE" "$tmp"
        chmod --reference="$CADDYFILE" "$tmp"
    else
        chown root:root "$tmp"
        chmod 0644 "$tmp"
    fi
    mv -f "$tmp" "$CADDYFILE"
    CADDY_SWAPPED=true
}

# Put CADDY_LAST_BACKUP back as the live Caddyfile (byte-identical, same owner+mode via
# cp -p, then an atomic rename). 1 when this run swapped nothing / there is no backup.
caddy_restore_backup() {
    local bak="$CADDY_LAST_BACKUP" rtmp
    [[ "$CADDY_SWAPPED" == "true" && -n "$bak" && -f "$bak" ]] || return 1
    rtmp="$(mktemp "${CADDYFILE}.tn-restore.XXXXXX")" || return 1
    caddy_tmp_track "$rtmp"
    cp -p "$bak" "$rtmp" || return 1
    mv -f "$rtmp" "$CADDYFILE" || return 1
}

# 0 (true) when the Caddyfile this run replaced (CADDY_LAST_BACKUP) turns Caddy's admin
# API off (`admin off` in its global options). `systemctl reload caddy` goes through
# that API, so a Caddy started from such a file can never be reloaded.
caddy_backup_admin_off() {
    [[ "$CADDY_SWAPPED" == "true" && -n "$CADDY_LAST_BACKUP" && -f "$CADDY_LAST_BACKUP" ]] || return 1
    awk '{sub(/(^|[[:space:]])#.*$/, "")} /(^|[[:space:]{])admin[[:space:]]+off([[:space:]}]|$)/ {f=1} END {exit !f}' "$CADDY_LAST_BACKUP" 2>/dev/null
}

# Put the freshly swapped-in Caddyfile into effect. Caddy ACTIVE -> `systemctl reload`
# (graceful: Caddy keeps serving its old config when it rejects the new one). Only a
# FAILED reload command restores the backup over the live file, so disk matches what
# Caddy still runs, and dies non-zero naming the backup -- NEVER a fallback restart,
# which would take every vhost down on a bad config. A reload that succeeds but leaves
# Caddy inactive a second later dies saying exactly that (the new config stays on
# disk). One exception to reload-only: when the file just replaced had `admin off`
# (an operator Caddyfile taken over after confirmation) no reload can work, so that
# apply is a `systemctl restart`, with the reason printed. Caddy NOT active ->
# `systemctl restart` (first start) and die if it does not come up. Every caller stops
# on that die, so e.g. rpc-enable never advertises an endpoint whose vhost failed to load.
caddy_apply_live() {
    if systemctl is-active --quiet caddy 2>/dev/null; then
        if caddy_backup_admin_off; then
            caddy_say info "The Caddyfile being replaced (${CADDY_LAST_BACKUP}) sets 'admin off', and 'systemctl reload' needs Caddy's admin API -- restarting Caddy once to apply the new config (the managed file keeps the admin API on, so later changes reload)."
            systemctl restart caddy || die "caddy failed to restart with the new config and is DOWN (check: journalctl -u caddy). To go back: sudo cp -p ${CADDY_LAST_BACKUP} ${CADDYFILE} && sudo systemctl restart caddy"
            sleep 1
            systemctl is-active --quiet caddy || die "caddy is not active after the restart with the new config (check: journalctl -u caddy). To go back: sudo cp -p ${CADDY_LAST_BACKUP} ${CADDYFILE} && sudo systemctl restart caddy"
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

# Enable caddy at boot, then apply the new config (reload if running, else first start).
caddy_reload() {
    systemctl enable caddy >/dev/null 2>&1 || true
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
        caddy_apply_live
    else
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
write_dashboard_block() {
    local domain="$1" username="$2" hash="$3" outfile="$4"
    {
        printf '# Node Manager dashboard. Public access is READ-ONLY (X-TN-Dashboard-Public);\n'
        printf '# management stays on the SSH tunnel.\n'
        printf '%s {\n' "$domain"
        printf '\tencode zstd gzip\n'
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

# Write the RPC vhost block (content only, no fences) to <outfile>. Self-contained
# (no `import`): OPTIONS preflight -> empty 200 + CORS; WebSocket Upgrade -> reth WS
# port; everything else -> reth HTTP port + CORS. 127.0.0.1 (not localhost) matches
# reth's IPv4 loopback bind (http_addr/ws_addr default to Ipv4Addr::LOCALHOST). Tabs
# keep the file `caddy fmt`-clean. Ports come from .node-meta (meta_get), default
# 8545/8546 -- so a node that pinned non-default ports is proxied correctly too.
write_rpc_block() {
    local domain="$1" outfile="$2"
    local rpc_port ws_port
    rpc_port="$(meta_get RPC_PORT 2>/dev/null || true)"; [[ "$rpc_port" =~ ^[0-9]+$ ]] || rpc_port=8545
    ws_port="$(meta_get WS_PORT 2>/dev/null || true)";   [[ "$ws_port"  =~ ^[0-9]+$ ]] || ws_port=8546
    {
        printf '# Public JSON-RPC + WebSocket endpoint. READ-ONLY reverse proxy to reth on\n'
        printf '# loopback; CORS + OPTIONS preflight answered at the TLS edge.\n'
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
        printf '\t\theader Connection *Upgrade*\n'
        printf '\t\theader Upgrade websocket\n'
        printf '\t}\n'
        printf '\thandle @websocket {\n'
        printf '\t\treverse_proxy 127.0.0.1:%s\n' "$ws_port"
        printf '\t}\n'
        printf '\thandle {\n'
        printf '\t\theader Access-Control-Allow-Origin "*"\n'
        printf '\t\theader Access-Control-Allow-Methods "POST, GET, OPTIONS"\n'
        printf '\t\theader Access-Control-Allow-Headers "X-Requested-With, Content-Type"\n'
        printf '\t\treverse_proxy 127.0.0.1:%s\n' "$rpc_port"
        printf '\t}\n'
        printf '}\n'
    } > "$outfile"
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
# /var/lib/telcoin/<role>). May not exist; the caller checks -f.
caddy_node_info_path() {
    local dd
    dd="$(tn_resolve_data_dir 2>/dev/null || echo /var/lib/telcoin)"
    printf '%s/node-info.yaml\n' "$dd"
}

# Read or edit ONLY the worker P2pNode(s)' `rpc:` in node-info.yaml via a python3 stdlib
# line editor (PyYAML is not guaranteed on a node). Handles BOTH on-disk shapes:
#   current (telcoin-network >= v0.15 keytool):  p2p_info: {primary, workers: [ {..}, .. ]}
#     -> set/clear `rpc` on EVERY workers entry (each worker's kad record advertises the
#        same public endpoint);
#   legacy:                                       p2p_info: {primary, worker: {..}}
#     -> set/clear worker.rpc.
# mode=set writes http (+ ws when non-empty); mode=clear resets to `~`; mode=get prints
# "<http>|<ws>" of the FIRST worker ('' parts when absent) and never writes. Idempotent:
# a semantic no-op (same URLs, even if quoted differently) leaves the file byte-identical
# and unwritten. Key order and every other line are kept; primary and execution_address
# are never touched. Returns the python rc (0 ok, 2 read/write error, 3 unexpected shape).
caddy_edit_node_info() {
    local ni="$1" mode="$2" http_url="${3:-}" ws_url="${4:-}"
    TN_NI_FILE="$ni" TN_NI_MODE="$mode" TN_NI_HTTP="$http_url" TN_NI_WS="$ws_url" python3 - <<'PYEOF'
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
for t in targets:
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

try:
    with open(path, "w") as f:             # in-place truncate-write: preserves owner+mode
        f.writelines(out)
except OSError as exc:
    sys.stderr.write("cannot write %s: %s\n" % (path, exc))
    sys.exit(2)
sys.exit(0)
PYEOF
}

# Undo / keep a launch-file --ws edit made by caddy_ws_preflight (no-op when none).
caddy_launch_rollback() {
    [[ -n "$CADDY_LAUNCH_BAK" && -f "$CADDY_LAUNCH_BAK" ]] || return 0
    mv -f "$CADDY_LAUNCH_BAK" "$CADDY_LAUNCH_FILE"
    if [[ "$CADDY_LAUNCH_METHOD" == "docker" ]]; then systemctl daemon-reload 2>/dev/null || true; fi
    print_warn "Restored the node launch file ${CADDY_LAUNCH_FILE} (the --ws change was undone)."
    CADDY_LAUNCH_BAK=""
}
caddy_launch_commit() {
    [[ -n "$CADDY_LAUNCH_BAK" ]] && rm -f "$CADDY_LAUNCH_BAK"
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

# Restart the node and verify RPC returns. FAST-FAIL if the unit enters `failed` (an
# invalid worker.rpc crash-loops at startup: Restart=on-failure, StartLimitBurst=5):
# restore node-info.yaml.tn-bak AND any launch-file --ws edit, restart to recover, and
# die (the Caddy vhost is left up, harmlessly 502'ing until retried). A slow DB-replay
# (neither up nor failed) is NON-fatal -- the change is kept and advertises once the
# node finishes starting. <ni> is '' when only the launch file changed. Works for
# binary AND docker installs (the host node-info.yaml is bind-mounted).
caddy_restart_node_guarded() {
    local ni="${1:-}"
    local svc rpc_port i rpc_up=false failed=false
    svc="$(tn_resolve_service 2>/dev/null || true)"
    if [[ -z "$svc" ]]; then
        print_warn "no telcoin service found -- node-info.yaml updated; restart the node manually to advertise."
        [[ -n "$ni" ]] && rm -f "${ni}.tn-bak"
        caddy_launch_commit
        return 0
    fi
    rpc_port="$(meta_get RPC_PORT 2>/dev/null || true)"; [[ "$rpc_port" =~ ^[0-9]+$ ]] || rpc_port=8545

    print_info "Restarting ${svc} to apply the change..."
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
        print_error "${svc} entered the failed state after the change -- rolling back."
        [[ -n "$ni" ]] && mv -f "${ni}.tn-bak" "$ni"
        caddy_launch_rollback
        # A unit that crash-looped into `failed` has also used up its start-rate limit
        # (Restart=on-failure + StartLimitBurst), and systemd refuses a manual restart
        # until that is cleared. Docker installs run under the same unit (its wrapper
        # execs `docker run`; ExecStartPre removes a stale container), so this covers both.
        systemctl reset-failed "$svc" 2>/dev/null || true
        systemctl restart "$svc" 2>/dev/null || true
        local node_state
        if caddy_node_stays_active "$svc"; then
            node_state="${svc} is back up on the previous config."
        else
            node_state="${svc} is STILL DOWN -- start it by hand: sudo systemctl start ${svc}  (logs: journalctl -u ${svc})"
        fi
        die "node-info.yaml / launch change rolled back (an invalid worker rpc or launch flag would crash-loop the node). ${node_state} The Caddy vhost is up but will 502 until you retry with a valid domain."
    fi

    if [[ "$rpc_up" == "true" ]]; then
        [[ -n "$ni" ]] && rm -f "${ni}.tn-bak"
        caddy_launch_commit
        print_ok "Node restarted; RPC responding on 127.0.0.1:${rpc_port}."
        return 0
    fi

    print_warn "${svc} is still starting (DB replay?) and RPC has not answered yet. The change is kept and will take effect once the node is up. Backup(s): ${ni:+${ni}.tn-bak }${CADDY_LAUNCH_BAK}"
    return 0
}

# Restart the node only because caddy_ws_preflight edited its launch file (no-op otherwise).
caddy_restart_for_launch() {
    [[ -n "$CADDY_LAUNCH_BAK" ]] || return 0
    caddy_restart_node_guarded ""
}

# Advertise (mode=set) or un-advertise (mode=clear) the worker RPC endpoint in
# node-info.yaml, then restart the node under the brick guard. <with_ws> (set only,
# default true) also advertises wss://<domain>/; false writes http only (decided by
# caddy_ws_preflight). Best-effort: a missing python3 / node-info.yaml is a non-fatal
# warning (the proxy still works; it just won't be discovered on-network). A launch file
# edited by caddy_ws_preflight gets its node restart on every path.
caddy_node_info_advertise() {
    local mode="$1" domain="${2:-}" with_ws="${3:-true}"
    local ni; ni="$(caddy_node_info_path)"
    if ! command -v python3 >/dev/null 2>&1; then
        print_warn "python3 not found -- cannot edit node-info.yaml. The endpoint works but won't be advertised on-network; install python3 and re-run to advertise."
        caddy_restart_for_launch
        return 0
    fi
    if [[ ! -f "$ni" ]]; then
        print_warn "node-info.yaml not found (${ni}) -- skipping on-network advertisement."
        caddy_restart_for_launch
        return 0
    fi

    local http_url="" ws_url=""
    if [[ "$mode" == "set" ]]; then
        http_url="https://${domain}/"
        if [[ "$with_ws" == "true" ]]; then ws_url="wss://${domain}/"; fi
        # Validate BEFORE writing -- an invalid worker rpc crash-loops the node.
        caddy_validate_rpc_url http "$http_url" || { caddy_launch_rollback; die "refusing to write an invalid http URL into node-info.yaml: ${http_url}"; }
        if [[ -n "$ws_url" ]]; then
            caddy_validate_rpc_url ws "$ws_url" || { caddy_launch_rollback; die "refusing to write an invalid ws URL into node-info.yaml: ${ws_url}"; }
        fi
    fi

    cp -p "$ni" "${ni}.tn-bak"
    if ! caddy_edit_node_info "$ni" "$mode" "$http_url" "$ws_url"; then
        mv -f "${ni}.tn-bak" "$ni"
        if [[ "$mode" == "clear" ]]; then
            # rpc-disable must always be able to take the public endpoint down: a
            # node-info.yaml this editor cannot parse is a warning, and do_rpc_disable
            # goes on to remove the RPC vhost.
            caddy_say warn "Could not clear the worker rpc in ${ni} (unexpected layout or read/write error) -- the file is unchanged and may still advertise the public endpoint. Clear it by hand: set 'rpc: ~' on every entry under p2p_info.workers (legacy layout: p2p_info.worker.rpc), then restart the node (sudo systemctl restart $(tn_resolve_service 2>/dev/null || echo telcoin)). The public RPC vhost is removed anyway."
            caddy_restart_for_launch
            return 0
        fi
        caddy_launch_rollback
        die "failed to edit node-info.yaml (worker rpc) -- node-info restored unchanged"
    fi

    if cmp -s "${ni}.tn-bak" "$ni"; then
        rm -f "${ni}.tn-bak"
        if [[ "$mode" == "set" ]]; then
            print_ok "node-info.yaml already advertises ${http_url}${ws_url:+ and ${ws_url}}."
        else
            print_ok "node-info.yaml worker rpc already cleared."
        fi
        if [[ -n "$CADDY_LAUNCH_BAK" ]]; then
            caddy_restart_node_guarded ""
        else
            print_ok "No node restart needed."
        fi
        return 0
    fi

    caddy_restart_node_guarded "$ni"
}

# reth WebSocket port: .node-meta WS_PORT, default 8546 (same source as write_rpc_block).
caddy_ws_port() {
    local p; p="$(meta_get WS_PORT 2>/dev/null || true)"
    [[ "$p" =~ ^[0-9]+$ ]] || p=8546
    printf '%s\n' "$p"
}

# 0 (true) when <file> carries launch flag <flag-regex> as a whole word (`--f`, `--f v`,
# `--f=v`, also quoted "--f" / '--f') on a non-comment line. `--ws` alone turns reth's WS
# server on; --ws.addr / --ws.port without it do not.
caddy_launch_has_flag() {
    awk -v f="$2" '/^[[:space:]]*#/ {next} $0 ~ ("(^|[[:space:]])[\"\047]?" f "([\"\047[:space:]=]|$)") {x=1} END {exit !x}' "$1" 2>/dev/null
}

# Echo "<line-no> <verdict>" for the line tn_node_inject_flags (lib/common.sh) appends
# to -- its selection rule, replicated: the FIRST line holding a whole-word --http,
# comment lines included. <verdict> is `ok` only for a real launch line: not a comment,
# no trailing `#` comment, not continued onto the next line, and part of a command that
# invokes the node -- a `node` word on that line or on the lines it continues, as in the
# launch files setup-node.sh writes (`exec <binary> node \`, `<image> telcoin node \`).
# Otherwise comment | trailing-comment | continued | no-node; "0 none" when no line
# matches (the helper then changes nothing).
caddy_launch_inject_target() {
    awk '
        { iscomment = ($0 ~ /^[[:space:]]*#/)
          if (!cont) cmd = ""
          if (!iscomment) cmd = cmd " " $0 }
        $0 ~ /(^|[[:space:]])--http([[:space:]]|$)/ {
            if (iscomment) v = "comment"
            else if ($0 ~ /\\[[:space:]]*$/) v = "continued"
            else if ($0 ~ /[[:space:]]#/) v = "trailing-comment"
            else if (cmd !~ /(^|[[:space:]])node([[:space:]]|$)/) v = "no-node"
            else v = "ok"
            print NR, v; found = 1; exit
        }
        { cont = (!iscomment && $0 ~ /\\[[:space:]]*$/) }
        END { if (!found) print 0, "none" }
    ' "$1" 2>/dev/null
}

# 0 (true) when <file> differs from its pre-edit copy <bak> ONLY by " <flags>" appended
# to line <n>, and that line is not a comment -- i.e. the flags reached the launch line.
caddy_launch_verify_inject() {
    awk -v n="$3" -v f="$4" '
        NR == FNR { b[FNR] = $0; nb = FNR; next }
        { nl = FNR
          if (FNR == n + 0) { if ($0 != b[FNR] " " f || $0 ~ /^[[:space:]]*#/) bad = 1 }
          else if ($0 != b[FNR]) bad = 1 }
        END { exit (bad || nl != nb || n + 0 < 1) }
    ' "$2" "$1" 2>/dev/null
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

# WebSocket preflight, run by rpc-enable BEFORE advertising wss://. reth's WS endpoint
# will exist when (a) the NODE already LISTENS on TCP <ws_port> (ss -ltnp; a port held by
# any other process means public wss:// would reach that process, so it is reported and
# only https:// is advertised), or (b) the node launch file -- resolved by
# tn_node_launch_target (lib/common.sh), the resolver setup-observability.sh uses: the
# start wrapper, or the unit for legacy inline-docker installs -- already carries --ws
# (the node restart that follows picks it up). Otherwise inject the missing parts of
# `--ws --ws.addr 127.0.0.1 --ws.port <ws_port>` onto the launch --http line with
# tn_node_inject_flags -- only when the line that helper edits is the real launch line
# (caddy_launch_inject_target), and the result is re-read to confirm the flags landed
# there (else the backup is restored); the file is backed up first and the brick guard
# restores it if the node then fails to start.
# 0 = advertise ws; 1 = advertise http only (the warning says why).
caddy_ws_preflight() {
    local ws_port="$1" target="" svc="" method="" file="" flags holder tline tstat why
    target="$(tn_node_launch_target 2>/dev/null || true)"
    [[ -n "$target" ]] && read -r svc method file <<< "$target"
    holder="$(caddy_port_proc "$ws_port")"
    if [[ -n "$holder" ]]; then
        if caddy_ws_holder_is_node "$holder" "$file"; then
            print_ok "reth WebSocket already listening on port ${ws_port}."
            return 0
        fi
        caddy_say warn "The reth WebSocket port ${ws_port} is held by '${holder}', not the node, so public wss:// traffic would reach that process. Advertising https:// only (no wss://) and leaving the node launch unchanged; free port ${ws_port} (or give the node another WS_PORT) and re-run rpc-enable to advertise wss:// too."
        return 1
    fi
    if [[ -z "$target" ]]; then
        caddy_say warn "Nothing listens on the reth WebSocket port ${ws_port} and no telcoin node service was found, so --ws cannot be checked or enabled. Advertising https:// only (no wss://); re-run rpc-enable once the node runs with --ws to advertise wss:// too."
        return 1
    fi
    if [[ ! -f "$file" ]]; then
        caddy_say warn "Nothing listens on the reth WebSocket port ${ws_port} and the node launch file (${file}) was not found, so --ws cannot be checked or enabled. Advertising https:// only (no wss://); add --ws --ws.addr 127.0.0.1 --ws.port ${ws_port} to the ${svc} launch and re-run rpc-enable to advertise wss:// too."
        return 1
    fi
    if caddy_launch_has_flag "$file" '--ws'; then
        print_ok "The node launch (${file}) already enables --ws; the WebSocket binds on port ${ws_port} once ${svc} (re)starts."
        return 0
    fi
    read -r tline tstat <<< "$(caddy_launch_inject_target "$file")"
    case "$tstat" in
        ok|none) ;;   # none: the helper finds no line; the warning below says so
        continued)
            caddy_say warn "The node launch (${file}) lacks --ws, but its --http line continues onto the next line, so it is not edited automatically. Advertising https:// only (no wss://); add --ws --ws.addr 127.0.0.1 --ws.port ${ws_port} to the launch by hand and re-run rpc-enable to advertise wss:// too."
            return 1 ;;
        *)
            case "$tstat" in
                comment)          why="it is a comment" ;;
                trailing-comment) why="it ends in a # comment" ;;
                *)                why="it is not part of the node command" ;;
            esac
            caddy_say warn "The node launch (${file}) lacks --ws, but the first line carrying --http (line ${tline}) is not the node launch line (${why}), so it is not edited automatically. Advertising https:// only (no wss://); add --ws --ws.addr 127.0.0.1 --ws.port ${ws_port} to the launch by hand and re-run rpc-enable to advertise wss:// too."
            return 1 ;;
    esac
    flags="--ws"
    caddy_launch_has_flag "$file" '--ws[.]addr' || flags="${flags} --ws.addr 127.0.0.1"
    caddy_launch_has_flag "$file" '--ws[.]port' || flags="${flags} --ws.port ${ws_port}"
    if ! cp -p "$file" "${file}.tn-bak"; then
        caddy_say warn "Could not back up the node launch (${file}), so --ws is not added. Advertising https:// only (no wss://)."
        return 1
    fi
    # Marker = the flags anchored at end of line: absent before (no whole-word --ws), and
    # exactly what the helper appends to the --http line.
    if tn_node_inject_flags "$file" "${flags}\$" "$flags"; then
        if ! caddy_launch_verify_inject "$file" "${file}.tn-bak" "$tline" "$flags"; then
            mv -f "${file}.tn-bak" "$file"
            caddy_say warn "Adding --ws to the node launch (${file}) did not land on its launch line ${tline}, so the edit was undone. Advertising https:// only (no wss://); add --ws --ws.addr 127.0.0.1 --ws.port ${ws_port} to the launch by hand and re-run rpc-enable to advertise wss:// too."
            return 1
        fi
        if [[ "$method" == "docker" ]]; then systemctl daemon-reload || print_warn "systemctl daemon-reload failed"; fi
        CADDY_LAUNCH_FILE="$file"
        CADDY_LAUNCH_BAK="${file}.tn-bak"
        CADDY_LAUNCH_METHOD="$method"
        caddy_say ok "Enabled the reth WebSocket: added '${flags}' to the node launch (${file}); it takes effect on the ${svc} restart below."
        return 0
    fi
    rm -f "${file}.tn-bak"
    caddy_say warn "Could not add --ws to the node launch (${file}): no --http launch line found. Advertising https:// only (no wss://); add --ws --ws.addr 127.0.0.1 --ws.port ${ws_port} to the launch and re-run rpc-enable to advertise wss:// too."
    return 1
}

# After the node restart: warn (never fail) while reth's WebSocket is still not listening.
caddy_ws_verify() {
    local ws_port="$1" domain="$2" i
    for i in 1 2 3 4 5; do
        if caddy_port_listening "$ws_port"; then
            print_ok "reth WebSocket listening on port ${ws_port} -- wss://${domain}/ is served."
            return 0
        fi
        sleep 2
    done
    caddy_say warn "Nothing listens on the reth WebSocket port ${ws_port} yet, so wss://${domain}/ returns 502 until it does. If the node is still starting (DB replay) this clears on its own; otherwise confirm the node launch carries --ws and check journalctl for the node service."
}

# =============================================================================
# PHASES -- DASHBOARD
# =============================================================================

# Enable the dashboard vhost: install + configure + start, preserving any RPC vhost
# verbatim. Password arrives via TN_CADDY_PASSWORD (env only -- never argv/logs).
do_enable() {
    local domain="$1" username="$2"
    caddy_validate_domain "$domain"     || die "invalid domain: ${domain:-<empty>}"
    caddy_validate_username "$username" || die "invalid username (2-32 chars: letters, digits, . _ -)"
    local pw="${TN_CADDY_PASSWORD:-}"
    [[ "${#pw}" -ge 8 ]] || die "password too short (minimum 8 characters)"
    local clash
    if clash="$(caddy_domain_clash dashboard "$domain")"; then die "$clash"; fi

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
do_check_dns_json() {
    local domain="$1"
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
    local domain="$1"
    caddy_validate_domain "$domain" || die "invalid domain: ${domain:-<empty>}"
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

# Enable the public RPC vhost (preserving any dashboard vhost), open 80/443, then run the
# WebSocket preflight and advertise the endpoint in node-info.yaml, restarting the node
# under the brick guard. <move_to> (--move-dashboard-to): when <domain> is the hostname
# the dashboard is served on, the dashboard block moves to <move_to> -- only its site
# address changes -- in the SAME swap + reload. Without it that clash dies before
# anything is written (caddy_domain_clash).
do_rpc_enable() {
    local domain="$1" move_to="${2:-}"
    caddy_validate_domain "$domain" || die "invalid RPC domain: ${domain:-<empty>}"
    local dash_dom move=false clash
    dash_dom="$(caddy_current_dashboard_domain)"
    if [[ -n "$move_to" ]]; then
        caddy_validate_domain "$move_to" || die "invalid --move-dashboard-to hostname: ${move_to}"
        if caddy_same_host "$move_to" "$domain"; then
            die "--move-dashboard-to (${move_to}) must differ from --rpc-domain (${domain}) -- the dashboard and the public RPC endpoint need different hostnames. Nothing was changed."
        fi
        if [[ -n "$dash_dom" ]] && caddy_same_host "$domain" "$dash_dom"; then
            move=true
        else
            print_info "The dashboard is not served on ${domain} (current: ${dash_dom:-none}) -- --move-dashboard-to ${move_to} is not needed and was ignored."
        fi
    fi
    if [[ "$move" != "true" ]] && clash="$(caddy_domain_clash rpc "$domain")"; then die "$clash"; fi

    caddy_assert_ports_free
    caddy_assert_not_foreign
    install_caddy_pkg

    local dash_tmp rpc_tmp
    dash_tmp="$(mktemp)"; rpc_tmp="$(mktemp)"
    caddy_tmp_track "$dash_tmp" "$rpc_tmp"
    caddy_current_dashboard_block > "$dash_tmp"       # preserve dashboard verbatim (handles legacy)
    if [[ "$move" == "true" ]]; then
        caddy_retarget_dashboard "$dash_tmp" "$move_to"
        CADDY_DASH_MOVED_TO="$move_to"
        caddy_say info "Moving the dashboard from ${dash_dom} to ${move_to} (same login; only the hostname changes). Its DNS A record must already point here -- Caddy requests a certificate for it."
    fi
    write_rpc_block "$domain" "$rpc_tmp"
    caddy_write_managed "$dash_tmp" "$rpc_tmp"
    rm -f "$dash_tmp" "$rpc_tmp"

    caddy_open_ports
    caddy_reload

    # WebSocket preflight: advertise wss:// only when reth's WS endpoint will exist
    # (may add --ws to the node launch; the guarded restart below applies it).
    local ws_port
    ws_port="$(caddy_ws_port)"
    CADDY_WS_OK=true
    caddy_ws_preflight "$ws_port" || CADDY_WS_OK=false

    # Advertise on-network (worker rpc) + restart the node. Brick-guarded.
    caddy_node_info_advertise set "$domain" "$CADDY_WS_OK"
    if [[ "$CADDY_WS_OK" == "true" ]]; then caddy_ws_verify "$ws_port" "$domain"; fi
}

# Disable the public RPC vhost: un-advertise in node-info.yaml (best-effort, restart
# guarded), then remove the RPC block (preserving any dashboard vhost). Full teardown
# only when no managed vhost remains.
do_rpc_disable() {
    caddy_node_info_advertise clear

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
}

# Echo "<http>|<ws>" that node-info.yaml advertises for the FIRST worker (current
# `workers:` list or legacy `worker:` map); "|" when absent, unreadable or no python3.
caddy_node_info_advertised() {
    local ni out=""
    ni="$(caddy_node_info_path)"
    if [[ -r "$ni" ]] && command -v python3 >/dev/null 2>&1; then
        out="$(caddy_edit_node_info "$ni" get 2>/dev/null || true)"
    fi
    [[ "$out" == *"|"* ]] || out="|"
    printf '%s\n' "$out"
}

# Print a single JSON status object for the RPC vhost (UI RPC card). The v1.2.0 keys
# come first, unchanged; advertised_http / advertised_ws (node-info.yaml worker rpc, ''
# when absent) and ws_listening (reth WS port bound) are appended.
do_rpc_status() {
    local installed=false running=false enabled=false domain="" block=""
    local adv adv_http adv_ws ws_listening=false
    command -v caddy >/dev/null 2>&1 && installed=true
    systemctl is-active --quiet caddy 2>/dev/null && running=true
    if caddy_block_present "$RPC_BEGIN"; then
        enabled=true
        block="$(caddy_extract_block "$RPC_BEGIN" "$RPC_END")"
        domain=$(printf '%s\n' "$block" | grep -m1 -E '^[A-Za-z0-9].*\{[[:space:]]*$' | sed -E 's/[[:space:]]*\{.*$//' | tr -d ' ' || true)
    fi
    adv="$(caddy_node_info_advertised)"
    adv_http="${adv%%|*}"; adv_ws="${adv#*|}"
    caddy_port_listening "$(caddy_ws_port)" && ws_listening=true
    printf '{"installed":%s,"running":%s,"enabled":%s,"domain":"%s","advertised_http":"%s","advertised_ws":"%s","ws_listening":%s}\n' \
        "$installed" "$running" "$enabled" "$(json_escape "$domain")" \
        "$(json_escape "$adv_http")" "$(json_escape "$adv_ws")" "$ws_listening"
}

# =============================================================================
# JSON RUNNERS
# =============================================================================
run_json_enable() {
    json_setup_fds
    trap json_on_exit EXIT
    check_root
    json_event step "Checking ports 80 and 443 are free"
    json_event step "Installing Caddy (if needed)"
    json_event step "Configuring the dashboard site for ${JSON_DOMAIN}"
    json_event step "Opening the firewall (80, 443) and reloading Caddy"
    do_enable "$JSON_DOMAIN" "$JSON_USERNAME"
    json_done "{\"event\":\"done\",\"ok\":true,\"domain\":\"$(json_escape "$JSON_DOMAIN")\",\"msg\":\"external dashboard access enabled -- certificate will be issued on first request\"}"
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
    json_setup_fds
    trap json_on_exit EXIT
    check_root
    json_event step "Checking ports 80 and 443 are free"
    json_event step "Installing Caddy (if needed)"
    json_event step "Configuring the public RPC endpoint for ${JSON_RPC_DOMAIN}"
    if [[ -n "$JSON_MOVE_DASH" ]] && caddy_same_host "$JSON_RPC_DOMAIN" "$(caddy_current_dashboard_domain)"; then
        json_event step "Moving the dashboard to ${JSON_MOVE_DASH}"
    fi
    json_event step "Opening the firewall (80, 443) and reloading Caddy"
    json_event step "Advertising the endpoint in node-info.yaml and restarting the node"
    do_rpc_enable "$JSON_RPC_DOMAIN" "$JSON_MOVE_DASH"
    json_done "{\"event\":\"done\",\"ok\":true,\"domain\":\"$(json_escape "$JSON_RPC_DOMAIN")\",\"msg\":\"public RPC endpoint enabled -- certificate issues on first request\"}"
}

run_json_rpc_disable() {
    json_setup_fds
    trap json_on_exit EXIT
    check_root
    json_event step "Un-advertising the RPC endpoint in node-info.yaml"
    json_event step "Removing the public RPC vhost"
    do_rpc_disable
    json_done "{\"event\":\"done\",\"ok\":true,\"msg\":\"public RPC endpoint disabled\"}"
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
    caddy_prompt_public_ip
    echo ""

    local domain username pw pw2 clash
    while true; do
        read -r -p "  Dashboard domain (e.g. admin.node1.adiri.telcoin.network): " domain
        caddy_validate_domain "$domain" || { print_warn "Invalid domain."; continue; }
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
        read -r -s -p "  Dashboard password (min 8 chars): " pw; echo ""
        read -r -s -p "  Confirm password: " pw2; echo ""
        [[ "$pw" == "$pw2" ]] || { print_warn "Passwords do not match."; continue; }
        [[ "${#pw}" -ge 8 ]]  || { print_warn "Too short (min 8)."; continue; }
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

    export TN_CADDY_PASSWORD="$pw"
    do_enable "$domain" "$username"
    unset TN_CADDY_PASSWORD
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
    print_info "it) and RESTARTS the node."
    echo ""
    caddy_prompt_public_ip
    echo ""

    local domain move_to="" ans
    while true; do
        read -r -p "  Public RPC domain (e.g. node1.adiri.telcoin.network): " domain
        caddy_validate_domain "$domain" || { print_warn "Invalid domain."; continue; }
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
    print_warn "RESTART the node (adding --ws to its launch first if reth's WebSocket is off)."
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
        print_ok "Public RPC: ENABLED  ->  https://${rdom:-<unknown>}/  (wss://${rdom:-<unknown>}/)"
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
            d|D) print_warn "Disabling un-advertises the endpoint (node-info.yaml) and restarts the node."
                 read -r -p "  Proceed? [y/N]: " ans
                 case "$ans" in y|Y) do_rpc_disable; print_ok "Public RPC endpoint disabled." ;; *) print_info "Aborted." ;; esac
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
# reads the password from $TN_CADDY_PASSWORD); failures exit non-zero. check-dns and
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
            do_rpc_enable "$JSON_RPC_DOMAIN" "$JSON_MOVE_DASH"
            caddy_rpc_enabled_summary "$JSON_RPC_DOMAIN"
            ;;
        rpc-disable)
            check_root
            do_rpc_disable
            print_ok "Public RPC endpoint disabled."
            ;;
        *) die "unknown --phase '${phase}' (status|check-dns|enable|disable|rpc-status|rpc-check-dns|rpc-enable|rpc-disable)" ;;
    esac
}

# =============================================================================
# MAIN
# =============================================================================
main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json)         JSON_MODE=true; shift ;;
            --phase)        JSON_PHASE="${2:-}"; shift 2 ;;
            --phase=*)      JSON_PHASE="${1#*=}"; shift ;;
            --domain)       JSON_DOMAIN="${2:-}"; shift 2 ;;
            --domain=*)     JSON_DOMAIN="${1#*=}"; shift ;;
            --username)     JSON_USERNAME="${2:-}"; shift 2 ;;
            --username=*)   JSON_USERNAME="${1#*=}"; shift ;;
            --rpc-domain)   JSON_RPC_DOMAIN="${2:-}"; shift 2 ;;
            --rpc-domain=*) JSON_RPC_DOMAIN="${1#*=}"; shift ;;
            # rpc-enable only: move a dashboard that sits on --rpc-domain to this hostname.
            --move-dashboard-to)   JSON_MOVE_DASH="${2:-}"; shift 2 ;;
            --move-dashboard-to=*) JSON_MOVE_DASH="${1#*=}"; shift ;;
            # Operator-supplied INBOUND public IP -- the address the A record points at,
            # which on multi-IP / NAT hosts differs from the detected egress IP. Exported
            # so both JSON (check-dns) and interactive paths honour it via caddy_public_ip().
            --public-ip)    export TN_CADDY_PUBLIC_IP="${2:-}"; shift 2 ;;
            --public-ip=*)  export TN_CADDY_PUBLIC_IP="${1#*=}"; shift ;;
            *) shift ;;
        esac
    done

    # A signal exits with the conventional 128+N status, so the EXIT trap below (and
    # json_on_exit, which reports "exited early (rc=...)") sees a non-zero rc instead of
    # the 0 that $? holds when the trap interrupts a successful command. Armed BEFORE the
    # EXIT trap; `exit` still runs it, so temp files are removed on a signal too.
    trap 'exit 143' TERM
    trap 'exit 130' INT
    trap 'exit 129' HUP

    # Temp files are removed on every exit path (the JSON runners swap this for
    # json_on_exit, which cleans up too).
    trap caddy_cleanup_tmp EXIT

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
