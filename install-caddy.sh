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
#        edge. Enabling also ADVERTISES the endpoint in node-info.yaml (worker.rpc)
#        so gateways/wallets discover it, then restarts the node (with a brick guard).
#
# IMPORTANT: set the DNS A record (<domain> -> this server's INBOUND public IP)
# BEFORE enabling. Caddy requests the cert on first start; if DNS isn't pointing here
# (and ports 80/443 reachable), ACME fails and Let's Encrypt rate-limits you. On a
# multi-IP host or behind 1:1 NAT the inbound IP differs from the egress (outbound)
# IP ipify reports -- pass the inbound IP with --public-ip (or $TN_CADDY_PUBLIC_IP).
#
# USAGE (interactive menu: dashboard / RPC / status):
#   sudo bash install-caddy.sh
# USAGE (JSON, driven by the Node Manager UI helper):
#   install-caddy.sh --json --phase=status
#   install-caddy.sh --json --phase=check-dns --domain <d> [--public-ip <inbound-ip>]
#   install-caddy.sh --json --phase=enable --domain <d> --username <u>   (password: $TN_CADDY_PASSWORD)
#   install-caddy.sh --json --phase=disable
#   install-caddy.sh --json --phase=rpc-status
#   install-caddy.sh --json --phase=rpc-check-dns --rpc-domain <d> [--public-ip <inbound-ip>]
#   install-caddy.sh --json --phase=rpc-enable --rpc-domain <d>
#   install-caddy.sh --json --phase=rpc-disable
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

# common.sh provides the print_*/check_root helpers but not die(); define our own
# so error paths exit cleanly (print_error goes to stderr, which the UI surfaces).
die() { print_error "$*"; exit 1; }

readonly SCRIPT_VERSION="1.2.0"
readonly CADDYFILE="/etc/caddy/Caddyfile"
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

# =============================================================================
# JSON / NON-INTERACTIVE MODE (mirrors setup-*.sh)
# =============================================================================
JSON_MODE=false
JSON_PHASE=""
JSON_DOMAIN=""
JSON_USERNAME=""
JSON_RPC_DOMAIN=""
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

# Name of the process LISTENING on <port>, or '' when free / it's caddy. Needs
# root to read the process name (the UI helper runs as root).
caddy_port_holder() {
    local port="$1" line proc
    line=$(ss -ltnHp 2>/dev/null | awk -v p=":${port}" '$4 ~ p"$"{print; exit}' || true)
    [[ -z "$line" ]] && { echo ""; return 0; }
    proc=$(printf '%s' "$line" | grep -oE '"[^"]+"' | head -1 | tr -d '"' || true)
    [[ "$proc" == "caddy" ]] && { echo ""; return 0; }
    echo "${proc:-unknown}"
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

caddy_validate_domain() {
    [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)+$ ]]
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

# Compose + write the single managed Caddyfile from two block bodies (each a file
# path; empty/missing -> that vhost omitted), AFTER `caddy validate` on the composed
# result. Never clobbers a working live config: a validation failure dies with the
# live file untouched. Each block's bytes are emitted verbatim (no re-parsing).
caddy_write_managed() {
    local dash="$1" rpc="$2"
    local tmp; tmp="$(mktemp)"
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
    if ! caddy validate --adapter caddyfile --config "$tmp" >/dev/null 2>&1; then
        rm -f "$tmp"
        die "composed Caddyfile failed validation -- live config left unchanged"
    fi
    # Back up the true pre-Telcoin config once (never our own managed file).
    if [[ -f "$CADDYFILE" && ! -f "$CADDYFILE_ORIG" ]] && ! grep -qF "$CADDY_MARKER" "$CADDYFILE" 2>/dev/null; then
        cp -p "$CADDYFILE" "$CADDYFILE_ORIG"
    fi
    chmod 644 "$tmp"
    mv -f "$tmp" "$CADDYFILE"
}

# Enable caddy + reload (validate already happened in caddy_write_managed).
caddy_reload() {
    systemctl enable caddy >/dev/null 2>&1 || true
    systemctl reload caddy 2>/dev/null || systemctl restart caddy
    sleep 1
    systemctl is-active --quiet caddy || die "caddy is not active after reload (check: journalctl -u caddy)"
}

# Full teardown when NO managed vhost remains: restore the pre-Telcoin config (or a
# disabled stub) and close 80/443.
caddy_teardown() {
    if [[ -f "$CADDYFILE_ORIG" ]]; then
        mv -f "$CADDYFILE_ORIG" "$CADDYFILE"
    else
        printf '# Telcoin Node Manager: external access disabled.\n' > "$CADDYFILE"
    fi
    caddy validate --adapter caddyfile --config "$CADDYFILE" >/dev/null 2>&1 || true
    systemctl reload caddy 2>/dev/null || systemctl restart caddy 2>/dev/null || true
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

# Edit ONLY the worker P2pNode's `rpc:` in node-info.yaml via a python3 stdlib line
# editor (PyYAML is not guaranteed on a node). mode=set writes http/ws URLs; mode=clear
# resets to null. Idempotent (a no-op leaves the file byte-identical). primary.rpc and
# execution_address are never touched. Returns the python rc.
caddy_edit_node_info() {
    local ni="$1" mode="$2" http_url="${3:-}" ws_url="${4:-}"
    TN_NI_FILE="$ni" TN_NI_MODE="$mode" TN_NI_HTTP="$http_url" TN_NI_WS="$ws_url" python3 - <<'PYEOF'
import os, sys

path = os.environ["TN_NI_FILE"]
mode = os.environ["TN_NI_MODE"]            # "set" or "clear"
http_url = os.environ.get("TN_NI_HTTP", "")
ws_url = os.environ.get("TN_NI_WS", "")

def indent(s):
    return len(s) - len(s.lstrip(" "))

try:
    with open(path) as f:
        lines = f.readlines()
except OSError as exc:
    sys.stderr.write("cannot read %s: %s\n" % (path, exc))
    sys.exit(2)
n = len(lines)

# Locate the top-level p2p_info: mapping (indent 0).
p = -1
for i in range(n):
    if indent(lines[i]) == 0 and lines[i].strip().startswith("p2p_info:"):
        p = i
        break
if p < 0:
    sys.stderr.write("node-info.yaml: no top-level p2p_info:\n")
    sys.exit(3)

# Locate worker: (indent 2) under p2p_info, before the next indent-0 line. worker is
# the SECOND P2pNode (after primary); we deliberately skip primary and its children.
w = -1
for j in range(p + 1, n):
    s = lines[j].strip()
    if s and indent(lines[j]) == 0:
        break
    if indent(lines[j]) == 2 and s.startswith("worker:"):
        w = j
        break
if w < 0:
    sys.stderr.write("node-info.yaml: no worker: under p2p_info:\n")
    sys.exit(3)

# Extent of the worker block: child lines (indent > 2) until the next shallower line.
wb = w + 1
e = wb
while e < n:
    if lines[e].strip() == "":
        e += 1
        continue
    if indent(lines[e]) <= 2:
        break
    e += 1

# Find worker.rpc (indent 4); track the last indent-4 key for the insert-after fallback.
rpc = -1
last4 = w
for m in range(wb, e):
    s = lines[m].strip()
    if s and indent(lines[m]) == 4:
        last4 = m
        if s.startswith("rpc:"):
            rpc = m
            break

def is_null_scalar(line):
    after = line.strip()[4:].strip()       # text after "rpc:"
    return after in ("", "~", "null", "Null", "NULL")

if mode == "set":
    new_block = ["    rpc:\n",
                 "      http: " + http_url + "\n",
                 "      ws: " + ws_url + "\n"]
else:
    new_block = ["    rpc: ~\n"]

if rpc >= 0:
    # Existing value extent: the rpc: line + any following deeper (indent >= 6) lines.
    r_end = rpc + 1
    while r_end < e and lines[r_end].strip() != "" and indent(lines[r_end]) >= 6:
        r_end += 1
    if mode == "clear" and r_end == rpc + 1 and is_null_scalar(lines[rpc]):
        sys.exit(0)                        # already null -> no change
    out = lines[:rpc] + new_block + lines[r_end:]
else:
    if mode == "clear":
        sys.exit(0)                        # absent == not advertised -> no change
    ins = last4 + 1
    out = lines[:ins] + new_block + lines[ins:]

try:
    with open(path, "w") as f:             # in-place truncate-write: preserves owner+mode
        f.writelines(out)
except OSError as exc:
    sys.stderr.write("cannot write %s: %s\n" % (path, exc))
    sys.exit(2)
sys.exit(0)
PYEOF
}

# Restart the node and verify RPC returns. FAST-FAIL if the unit enters `failed` (an
# invalid worker.rpc crash-loops at startup: Restart=on-failure, StartLimitBurst=5):
# restore node-info.yaml.tn-bak, restart to recover, and die (the Caddy vhost is left
# up, harmlessly 502'ing until retried). A slow DB-replay (neither up nor failed) is
# NON-fatal -- the change is kept and advertises once the node finishes starting.
# Works for binary AND docker installs (the host node-info.yaml is bind-mounted).
caddy_restart_node_guarded() {
    local ni="$1"
    local svc rpc_port i rpc_up=false failed=false
    svc="$(tn_resolve_service 2>/dev/null || true)"
    if [[ -z "$svc" ]]; then
        print_warn "no telcoin service found -- node-info.yaml updated; restart the node manually to advertise."
        rm -f "${ni}.tn-bak"
        return 0
    fi
    rpc_port="$(meta_get RPC_PORT 2>/dev/null || true)"; [[ "$rpc_port" =~ ^[0-9]+$ ]] || rpc_port=8545

    print_info "Restarting ${svc} to apply the node-info.yaml change..."
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
        print_error "${svc} entered the failed state after the node-info.yaml change -- rolling back."
        mv -f "${ni}.tn-bak" "$ni"
        systemctl restart "$svc" 2>/dev/null || true
        die "node-info.yaml change rolled back (an invalid worker.rpc would crash-loop the node). The Caddy vhost is up but will 502 until you retry with a valid domain."
    fi

    if [[ "$rpc_up" == "true" ]]; then
        rm -f "${ni}.tn-bak"
        print_ok "Node restarted; RPC responding on 127.0.0.1:${rpc_port}."
        return 0
    fi

    print_warn "${svc} is still starting (DB replay?) and RPC has not answered yet. The node-info.yaml change is kept and will take effect once the node is up. Backup: ${ni}.tn-bak"
    return 0
}

# Advertise (mode=set) or un-advertise (mode=clear) the worker RPC endpoint in
# node-info.yaml, then restart the node under the brick guard. Best-effort: a missing
# python3 / node-info.yaml is a non-fatal warning (the proxy still works; it just
# won't be discovered on-network).
caddy_node_info_advertise() {
    local mode="$1" domain="${2:-}"
    local ni; ni="$(caddy_node_info_path)"
    if ! command -v python3 >/dev/null 2>&1; then
        print_warn "python3 not found -- cannot edit node-info.yaml. The endpoint works but won't be advertised on-network; install python3 and re-run to advertise."
        return 0
    fi
    if [[ ! -f "$ni" ]]; then
        print_warn "node-info.yaml not found (${ni}) -- skipping on-network advertisement."
        return 0
    fi

    local http_url="" ws_url=""
    if [[ "$mode" == "set" ]]; then
        http_url="https://${domain}/"; ws_url="wss://${domain}/"
        # Validate BEFORE writing -- an invalid worker.rpc crash-loops the node.
        caddy_validate_rpc_url http "$http_url" || die "refusing to write an invalid http URL into node-info.yaml: ${http_url}"
        caddy_validate_rpc_url ws   "$ws_url"   || die "refusing to write an invalid ws URL into node-info.yaml: ${ws_url}"
    fi

    cp -p "$ni" "${ni}.tn-bak"
    if ! caddy_edit_node_info "$ni" "$mode" "$http_url" "$ws_url"; then
        mv -f "${ni}.tn-bak" "$ni"
        die "failed to edit node-info.yaml (worker.rpc) -- node-info restored unchanged"
    fi

    if cmp -s "${ni}.tn-bak" "$ni"; then
        rm -f "${ni}.tn-bak"
        if [[ "$mode" == "set" ]]; then
            print_ok "node-info.yaml already advertises ${http_url} -- no node restart needed."
        else
            print_ok "node-info.yaml worker.rpc already cleared -- no node restart needed."
        fi
        return 0
    fi

    caddy_restart_node_guarded "$ni"
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

# DNS check as a single JSON object to stdout. Backward compatible: keeps
# public_ip/resolved_ip/propagated and ADDS egress_ip, local_ips, and a human note.
# Shared by the dashboard (check-dns) and RPC (rpc-check-dns) phases.
do_check_dns_json() {
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
    # shellcheck disable=SC2086  # intentional: split local_ips into one arg per IP (all validated dotted-quads)
    printf '{"domain":"%s","public_ip":"%s","resolved_ip":"%s","propagated":%s,"egress_ip":"%s","local_ips":%s,"note":"%s"}\n' \
        "$(json_escape "$domain")" "$(json_escape "$pub")" "$(json_escape "$resolved")" "$propagated" \
        "$(json_escape "$egress")" "$(json_str_array $local_ips)" "$(json_escape "$note")"
}

# =============================================================================
# PHASES -- PUBLIC RPC
# =============================================================================

# Enable the public RPC vhost (preserving any dashboard vhost), open 80/443, then
# advertise the endpoint in node-info.yaml and restart the node under the brick guard.
do_rpc_enable() {
    local domain="$1"
    caddy_validate_domain "$domain" || die "invalid RPC domain: ${domain:-<empty>}"

    caddy_assert_ports_free
    caddy_assert_not_foreign
    install_caddy_pkg

    local dash_tmp rpc_tmp
    dash_tmp="$(mktemp)"; rpc_tmp="$(mktemp)"
    caddy_current_dashboard_block > "$dash_tmp"       # preserve dashboard verbatim (handles legacy)
    write_rpc_block "$domain" "$rpc_tmp"
    caddy_write_managed "$dash_tmp" "$rpc_tmp"
    rm -f "$dash_tmp" "$rpc_tmp"

    caddy_open_ports
    caddy_reload

    # Advertise on-network (worker.rpc) + restart the node. Brick-guarded.
    caddy_node_info_advertise set "$domain"
}

# Disable the public RPC vhost: un-advertise in node-info.yaml (best-effort, restart
# guarded), then remove the RPC block (preserving any dashboard vhost). Full teardown
# only when no managed vhost remains.
do_rpc_disable() {
    caddy_node_info_advertise clear

    local dash_tmp; dash_tmp="$(mktemp)"
    caddy_current_dashboard_block > "$dash_tmp"
    if [[ -s "$dash_tmp" ]]; then
        caddy_write_managed "$dash_tmp" ""
        caddy_reload
    else
        caddy_teardown
    fi
    rm -f "$dash_tmp"
}

# Print a single JSON status object for the RPC vhost (UI RPC card).
do_rpc_status() {
    local installed=false running=false enabled=false domain="" block=""
    command -v caddy >/dev/null 2>&1 && installed=true
    systemctl is-active --quiet caddy 2>/dev/null && running=true
    if caddy_block_present "$RPC_BEGIN"; then
        enabled=true
        block="$(caddy_extract_block "$RPC_BEGIN" "$RPC_END")"
        domain=$(printf '%s\n' "$block" | grep -m1 -E '^[A-Za-z0-9].*\{[[:space:]]*$' | sed -E 's/[[:space:]]*\{.*$//' | tr -d ' ' || true)
    fi
    printf '{"installed":%s,"running":%s,"enabled":%s,"domain":"%s"}\n' \
        "$installed" "$running" "$enabled" "$(json_escape "$domain")"
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
    json_event step "Opening the firewall (80, 443) and reloading Caddy"
    json_event step "Advertising the endpoint in node-info.yaml and restarting the node"
    do_rpc_enable "$JSON_RPC_DOMAIN"
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

    local domain username pw pw2
    while true; do
        read -r -p "  Dashboard domain (e.g. dashboard.example.com): " domain
        caddy_validate_domain "$domain" && break
        print_warn "Invalid domain."
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

    local domain
    while true; do
        read -r -p "  Public RPC domain (e.g. rpc.node1.adiri.telcoin.network): " domain
        caddy_validate_domain "$domain" && break
        print_warn "Invalid domain."
    done

    echo ""
    print_warn "BEFORE CONTINUING: create a DNS A record:"
    print_info "    ${domain}  ->  ${TN_CADDY_PUBLIC_IP:-this servers public IP}"
    print_warn "If this host is behind NAT, port-forward 443/tcp (required) and 80/tcp (recommended)."
    echo ""
    caddy_dns_gate "$domain"

    echo ""
    print_warn "This will expose this node's JSON-RPC publicly at https://${domain}/, open"
    print_warn "ports 80/443, advertise the endpoint to peers (node-info.yaml worker.rpc), and"
    print_warn "RESTART the node."
    local ans
    read -r -p "  Proceed? [y/N]: " ans
    case "$ans" in
        y|Y) ;;
        *) print_info "Aborted."; return 0 ;;
    esac

    resolve_port_conflicts
    caddy_confirm_foreign_overwrite

    do_rpc_enable "$domain"
    echo ""
    print_ok "Public RPC endpoint enabled at https://${domain}/  (wss://${domain}/)"
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

# Interactive: human-readable status of both vhosts.
print_status_human() {
    local installed="no" running="no"
    command -v caddy >/dev/null 2>&1 && installed="yes"
    systemctl is-active --quiet caddy 2>/dev/null && running="yes"
    echo ""
    print_info "Caddy installed: ${installed}    running: ${running}"
    local dash; dash="$(caddy_current_dashboard_block)"
    if [[ -n "$dash" ]]; then
        local ddom; ddom=$(printf '%s\n' "$dash" | grep -m1 -E '^[A-Za-z0-9].*\{[[:space:]]*$' | sed -E 's/[[:space:]]*\{.*$//' | tr -d ' ' || true)
        print_ok "Dashboard: ENABLED  ->  https://${ddom:-<unknown>}"
    else
        print_info "Dashboard: disabled"
    fi
    if caddy_block_present "$RPC_BEGIN"; then
        local rdom; rdom=$(caddy_extract_block "$RPC_BEGIN" "$RPC_END" | grep -m1 -E '^[A-Za-z0-9].*\{[[:space:]]*$' | sed -E 's/[[:space:]]*\{.*$//' | tr -d ' ' || true)
        print_ok "Public RPC: ENABLED  ->  https://${rdom:-<unknown>}/  (wss://${rdom:-<unknown>}/)"
    else
        print_info "Public RPC: disabled"
    fi
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
            # Operator-supplied INBOUND public IP -- the address the A record points at,
            # which on multi-IP / NAT hosts differs from the detected egress IP. Exported
            # so both JSON (check-dns) and interactive paths honour it via caddy_public_ip().
            --public-ip)    export TN_CADDY_PUBLIC_IP="${2:-}"; shift 2 ;;
            --public-ip=*)  export TN_CADDY_PUBLIC_IP="${1#*=}"; shift ;;
            *) shift ;;
        esac
    done

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

    interactive_menu
}

main "$@"
