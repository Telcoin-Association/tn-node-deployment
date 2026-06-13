#!/usr/bin/env bash
# =============================================================================
# install-caddy.sh -- External (public) dashboard access via Caddy
#
# Puts Caddy in front of the Node Manager UI (127.0.0.1:8080) so it's reachable
# at https://<domain> with automatic Let's Encrypt TLS and Caddy's built-in
# basic_auth. The public path is READ-ONLY: Caddy stamps an X-TN-Dashboard-Public
# header that the UI server enforces (every write -> 403). Management stays on the
# SSH tunnel (localhost, no such header).
#
# IMPORTANT: set the DNS A record (<domain> -> this server's public IP) BEFORE
# enabling. Caddy requests the cert on first start; if DNS isn't pointing here
# (and ports 80/443 reachable), ACME fails and Let's Encrypt rate-limits you.
#
# USAGE (interactive):
#   sudo bash install-caddy.sh
# USAGE (JSON, driven by the Node Manager UI helper):
#   install-caddy.sh --json --phase=status
#   install-caddy.sh --json --phase=check-dns --domain <d>
#   install-caddy.sh --json --phase=enable --domain <d> --username <u>   (password: $TN_CADDY_PASSWORD)
#   install-caddy.sh --json --phase=disable
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

# common.sh provides the print_*/check_root helpers but not die(); define our own
# so error paths exit cleanly (print_error goes to stderr, which the UI surfaces).
die() { print_error "$*"; exit 1; }

readonly SCRIPT_VERSION="1.1.1"
readonly CADDYFILE="/etc/caddy/Caddyfile"
readonly CADDYFILE_ORIG="/etc/caddy/Caddyfile.tn-orig"
readonly UI_UPSTREAM="127.0.0.1:8080"
readonly PUBLIC_HEADER="X-TN-Dashboard-Public"
# First line of every Caddyfile we generate -- lets us tell our own managed
# config apart from one the operator (or another tool) set up by hand.
readonly CADDY_MARKER="# Managed by the Telcoin Node Manager"

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
JSON_DONE_EMITTED=false

json_mode() { [[ "$JSON_MODE" == "true" ]]; }

json_setup_fds() { exec 3>&1; exec 1>&2; }   # fd3 = JSON; stdout -> stderr (noise)

json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/\\n}"; s="${s//$'\r'/ }"; s="${s//$'\t'/ }"
    printf '%s' "$s"
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

# Public IP of this host (best-effort, mirrors the setup scripts). '' on failure.
caddy_public_ip() {
    local ip
    ip=$(curl -s --max-time 8 https://api.ipify.org 2>/dev/null || true)
    [[ "$ip" =~ ^[0-9a-fA-F.:]+$ ]] && echo "$ip" || echo ""
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

# Write our managed Caddyfile site. printf (not heredoc) so the bcrypt hash --
# which contains $ and / -- is inserted verbatim with no shell re-expansion.
write_caddy_site() {
    local domain="$1" username="$2" hash="$3"
    {
        printf '# Managed by the Telcoin Node Manager (install-caddy.sh).\n'
        printf '# Public dashboard access is READ-ONLY (X-TN-Dashboard-Public).\n'
        printf '%s {\n' "$domain"
        printf '    encode zstd gzip\n'
        printf '    reverse_proxy %s {\n' "$UI_UPSTREAM"
        printf '        header_up -%s\n' "$PUBLIC_HEADER"
        printf '        header_up %s "1"\n' "$PUBLIC_HEADER"
        printf '        flush_interval -1\n'
        printf '    }\n'
        printf '    basic_auth {\n'
        printf '        %s %s\n' "$username" "$hash"
        printf '    }\n'
        printf '}\n'
    } > "$CADDYFILE"
    chmod 644 "$CADDYFILE"
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
# PHASES
# =============================================================================

# Enable: install + configure + start. Password arrives via TN_CADDY_PASSWORD
# (env only -- never argv/logs). Caller must have validated domain/username.
do_enable() {
    local domain="$1" username="$2"
    caddy_validate_domain "$domain"     || die "invalid domain: ${domain:-<empty>}"
    caddy_validate_username "$username" || die "invalid username (2-32 chars: letters, digits, . _ -)"
    local pw="${TN_CADDY_PASSWORD:-}"
    [[ "${#pw}" -ge 8 ]] || die "password too short (minimum 8 characters)"

    local h80 h443
    h80=$(caddy_port_holder 80); h443=$(caddy_port_holder 443)
    [[ -n "$h80" ]]  && die "port 80 is in use by '${h80}' -- Caddy needs it and cannot share with another web server. Stop/remove it first (Apache: 'sudo systemctl disable --now apache2'), or run 'sudo bash install-caddy.sh' on the server to be guided through removing it."
    [[ -n "$h443" ]] && die "port 443 is in use by '${h443}' -- Caddy needs it and cannot share with another web server. Stop/remove it first (Apache: 'sudo systemctl disable --now apache2'), or run 'sudo bash install-caddy.sh' on the server to be guided through removing it."

    # Never overwrite a Caddy config we did not create unless explicitly told to.
    if caddy_foreign_config && [[ "$CADDY_OVERWRITE_FOREIGN" != "true" ]]; then
        die "an existing Caddy configuration at ${CADDYFILE} was not created by the Node Manager -- refusing to overwrite it. Run 'sudo bash install-caddy.sh' on the server to review and confirm, or back up and remove the existing config first."
    fi

    install_caddy_pkg

    # caddy hash-password reads a newline-terminated line from stdin -- without the
    # trailing \n it errors "EOF" and emits nothing. --algorithm bcrypt pins the
    # output to a $2 hash (matching basic_auth's default; newer Caddy can default
    # to argon2id). The password stays on stdin, never in argv/logs.
    local hash
    hash=$(printf '%s\n' "$pw" | caddy hash-password --algorithm bcrypt 2>/dev/null || true)
    [[ "$hash" == \$2* ]] || die "failed to hash the password (caddy hash-password produced no bcrypt hash)"

    [[ -f "$CADDYFILE" && ! -f "$CADDYFILE_ORIG" ]] && cp -p "$CADDYFILE" "$CADDYFILE_ORIG"
    write_caddy_site "$domain" "$username" "$hash"

    caddy validate --adapter caddyfile --config "$CADDYFILE" >/dev/null 2>&1 \
        || die "generated Caddyfile failed validation"

    caddy_open_ports
    systemctl enable caddy >/dev/null 2>&1 || true
    systemctl reload caddy 2>/dev/null || systemctl restart caddy

    sleep 2
    systemctl is-active --quiet caddy || die "caddy is not active after reload (check: journalctl -u caddy)"
}

do_disable() {
    if [[ -f "$CADDYFILE_ORIG" ]]; then
        mv -f "$CADDYFILE_ORIG" "$CADDYFILE"
    else
        printf '# Telcoin Node Manager: external dashboard access disabled.\n' > "$CADDYFILE"
    fi
    caddy validate --adapter caddyfile --config "$CADDYFILE" >/dev/null 2>&1 || true
    systemctl reload caddy 2>/dev/null || systemctl restart caddy 2>/dev/null || true
    caddy_close_ports
}

# Print a single JSON status object to stdout (consumed by the UI helper/server).
do_status() {
    local installed=false running=false enabled=false domain="" username=""
    command -v caddy >/dev/null 2>&1 && installed=true
    systemctl is-active --quiet caddy 2>/dev/null && running=true
    if [[ -f "$CADDYFILE" ]] && grep -q "reverse_proxy ${UI_UPSTREAM}" "$CADDYFILE" 2>/dev/null; then
        enabled=true
        domain=$(grep -m1 -E '^[A-Za-z0-9].*\{[[:space:]]*$' "$CADDYFILE" 2>/dev/null | sed -E 's/[[:space:]]*\{.*$//' | tr -d ' ' || true)
        username=$(awk '/basic_auth[[:space:]]*\{/{f=1;next} f&&/\}/{f=0} f{print $1; exit}' "$CADDYFILE" 2>/dev/null || true)
    fi
    printf '{"installed":%s,"running":%s,"enabled":%s,"domain":"%s","username":"%s"}\n' \
        "$installed" "$running" "$enabled" "$(json_escape "$domain")" "$(json_escape "$username")"
}

# DNS check as a single JSON object to stdout.
do_check_dns_json() {
    local domain="$1" pub resolved propagated=false
    pub=$(caddy_public_ip)
    resolved=$(caddy_resolve_domain "$domain")
    [[ -n "$resolved" && "$resolved" == "$pub" ]] && propagated=true
    printf '{"domain":"%s","public_ip":"%s","resolved_ip":"%s","propagated":%s}\n' \
        "$(json_escape "$domain")" "$(json_escape "$pub")" "$(json_escape "$resolved")" "$propagated"
}

run_json_enable() {
    json_setup_fds
    trap json_on_exit EXIT
    check_root
    json_event step "Checking ports 80 and 443 are free"
    json_event step "Installing Caddy (if needed)"
    json_event step "Configuring the dashboard site for ${JSON_DOMAIN}"
    json_event step "Opening the firewall (80, 443) and starting Caddy"
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

interactive_flow() {
    check_root
    print_header "External Dashboard Access (Caddy)  v${SCRIPT_VERSION}"
    print_info "This makes the Node Manager dashboard reachable at https://<your-domain>"
    print_info "with a login, behind Caddy. Public access is READ-ONLY -- management"
    print_info "stays on the SSH tunnel."
    echo ""

    local pub; pub=$(caddy_public_ip)
    print_info "This server's public IP: ${pub:-<unknown>}"
    echo ""

    local domain username
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
    local pw pw2
    while true; do
        read -r -s -p "  Dashboard password (min 8 chars): " pw; echo ""
        read -r -s -p "  Confirm password: " pw2; echo ""
        [[ "$pw" == "$pw2" ]] || { print_warn "Passwords do not match."; continue; }
        [[ "${#pw}" -ge 8 ]]  || { print_warn "Too short (min 8)."; continue; }
        break
    done

    echo ""
    print_warn "BEFORE CONTINUING: create a DNS A record:"
    print_info "    ${domain}  ->  ${pub:-this servers public IP}"
    print_warn "If this host is behind NAT, point the record at your routers public IP"
    print_warn "and port-forward to this machine: 443/tcp is REQUIRED, 80/tcp recommended."
    print_info "Caddy gets the certificate over 443 (TLS-ALPN). Forwarding 80 too adds the"
    print_info "http->https redirect and a fallback path for certificate issuance/renewal."
    echo ""
    read -r -p "  Press Enter to check DNS propagation once the record is set..."

    while true; do
        local resolved; resolved=$(caddy_resolve_domain "$domain")
        if [[ -n "$resolved" && "$resolved" == "$pub" ]]; then
            print_ok "${domain} resolves to ${resolved} (this server). Proceeding."
            break
        fi
        print_warn "${domain} resolves to '${resolved:-<nothing>}', expected '${pub}'."
        local ans
        read -r -p "  [r]echeck / [c]ontinue anyway / [a]bort: " ans
        case "$ans" in
            c|C) print_warn "Continuing despite DNS mismatch -- cert issuance may fail."; break ;;
            a|A) print_info "Aborted."; exit 0 ;;
            *) ;;
        esac
    done

    # Free ports 80/443 (offer to stop/remove Apache et al.) before binding Caddy.
    resolve_port_conflicts

    # Don't silently clobber a Caddy config the operator already set up by hand.
    if caddy_foreign_config; then
        echo ""
        print_warn "An existing Caddy configuration was found at ${CADDYFILE} (not created by the Node Manager)."
        print_warn "Enabling external access will REPLACE it (the original is backed up to ${CADDYFILE_ORIG})."
        read -r -p "  [o] back up and overwrite / [q] quit: " ans
        case "$ans" in
            o|O) CADDY_OVERWRITE_FOREIGN=true ;;
            *)   print_info "Aborted. Re-run after migrating your Caddy config."; exit 0 ;;
        esac
    fi

    export TN_CADDY_PASSWORD="$pw"
    do_enable "$domain" "$username"
    unset TN_CADDY_PASSWORD
    echo ""
    print_ok "External dashboard access enabled at https://${domain}"
    print_info "The TLS certificate is issued on the first request -- give it a few seconds."
    print_info "Public access is READ-ONLY. For management, use the SSH tunnel (localhost:8080)."
}

# =============================================================================
# MAIN
# =============================================================================
main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json)        JSON_MODE=true; shift ;;
            --phase)       JSON_PHASE="${2:-}"; shift 2 ;;
            --phase=*)     JSON_PHASE="${1#*=}"; shift ;;
            --domain)      JSON_DOMAIN="${2:-}"; shift 2 ;;
            --domain=*)    JSON_DOMAIN="${1#*=}"; shift ;;
            --username)    JSON_USERNAME="${2:-}"; shift 2 ;;
            --username=*)  JSON_USERNAME="${1#*=}"; shift ;;
            *) shift ;;
        esac
    done

    if json_mode; then
        case "$JSON_PHASE" in
            status)    do_status ;;
            check-dns) do_check_dns_json "$JSON_DOMAIN" ;;
            enable)    run_json_enable ;;
            disable)   run_json_disable ;;
            *) echo '{"event":"done","ok":false,"msg":"unknown or missing --phase (status|check-dns|enable|disable)"}'; exit 1 ;;
        esac
        exit $?
    fi

    interactive_flow
}

main "$@"
