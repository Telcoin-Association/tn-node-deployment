#!/usr/bin/env bash
# =============================================================================
# terraform/first-boot/first-boot-gateway.sh -- first boot of the worker-gateway
# host a Terraform root under terraform/ creates
#
# cloud-init runs this once, as root, from /usr/local/libexec/telcoin-first-boot.
# It sets up the worker gateway in front of the validator's private address
# (setup-gateway.sh --mode standalone, behind this host's Caddy) and this
# host's firewall, unattended. The host holds no node and no key.
#
# Steps, in order (first-boot-lib.sh has the env file, the log and the markers):
#   env             check /etc/telcoin-first-boot/first-boot.env
#   apt-lock        apt waits up to 15 minutes for the dpkg lock
#   cve-2026-31431  the algif_aead modprobe line; unload the module if loaded
#   swap            swap off
#   node-scripts    the published installer, as TN_FB_LOGIN_USER, three tries
#   scripts-release the installed release is TN_FB_MIN_RELEASE or newer; first,
#                   so an older one stops the boot before Docker is installed
#   docker          Docker Engine from Docker's apt repository, its signing key
#                   checked against TN_DOCKER_APT_FINGERPRINT first
#   docker-service  systemctl enable --now docker; wait for docker info
#   dns             wait up to 30 minutes for TN_FB_DOMAIN to reach this host
#                   (install-caddy.sh --phase=gateway-check-dns); never fails
#                   the boot, because Caddy keeps asking for the certificate
#   gateway         setup-gateway.sh --enable --json: exit 0 with "ok":true; up
#                   to three tries, 60 s apart, while it exits 1 (refused or put
#                   back, such as a failed image pull); exit 3 stops the boot
#   firewall        firewall-setup.sh --enable --ssh-from TN_FB_SSH_FROM; the
#                   network comes from the gateway's gateway.meta
#   check-node      check-node.sh, its output into the log
#
# USAGE:
#   sudo bash /usr/local/libexec/telcoin-first-boot/first-boot-gateway.sh
#   Run it again after a fix: every step it repeats is a no-op when current.
#
# Exit status: 0 the gateway is set up (/var/lib/telcoin-first-boot/done); 1 a
# step failed (/var/lib/telcoin-first-boot/failed names it and says why).
# =============================================================================

set -euo pipefail

FB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=terraform/first-boot/first-boot-lib.sh
. "${FB_DIR}/first-boot-lib.sh"

# Docker's apt signing key (download.docker.com/linux/<distro>/gpg): its primary
# key fingerprint, the same value as TN_DOCKER_APT_FINGERPRINT in setup-node.sh
# (tools/tests/terraform_static_test.sh keeps the two equal). The repository is
# added only when the downloaded key has exactly this fingerprint.
readonly TN_DOCKER_APT_FINGERPRINT="9DC858229FC7DD38854AE2D88D81803C0EBFCD88"

# fbg_upstream_ok V -- V is a private IPv4 address of another host.
fbg_upstream_ok() {
    local a b
    fb_ipv4_ok "$1" || return 1
    IFS=. read -r a b _ <<< "$1"
    case "$a" in
        10) return 0 ;;
        172) [ "$b" -ge 16 ] && [ "$b" -le 31 ] ;;
        192) [ "$b" = 168 ] ;;
        100) [ "$b" -ge 64 ] && [ "$b" -le 127 ] ;;
        169) [ "$b" = 254 ] ;;
        *) return 1 ;;
    esac
}

# fbg_src_ok V -- V is an SSH source: IPv4, or IPv6 in hex groups, with a mask
# of /8 or narrower; never 0.0.0.0 or ::, which mean anywhere.
fbg_src_ok() {
    local ip="${1%%/*}" max=32 g='[0-9A-Fa-f]{1,4}' re
    case "$ip" in 0.0.0.0|::|*:::*|*::*::*|:[!:]*|*[!:]:) return 1 ;; esac
    if ! fb_ipv4_ok "$ip"; then
        max=128
        re="^${g}(:${g}){7}\$"
        case "$ip" in
            *::*) ip="${ip/::/:}"; ip="${ip#:}"; ip="${ip%:}"; re="^${g}(:${g}){0,6}\$" ;;
        esac
        [[ "$ip" =~ $re ]] || return 1
    fi
    re='^[1-9][0-9]{0,2}$'
    case "$1" in
        */*) [[ "${1#*/}" =~ $re ]] && [ "${1#*/}" -ge 8 ] && [ "${1#*/}" -le "$max" ] ;;
    esac
}

# fbg_redirect_loops URL UPSTREAM -- URL names UPSTREAM's RPC or readiness port,
# or this gateway's ports on a loopback name.
fbg_redirect_loops() {
    local h p=80
    h="${1#*://}"
    h="${h%%/*}"
    case "$1" in https:*) p=443 ;; esac
    case "$h" in *:*) p="${h##*:}" ;; esac
    h="$(printf '%s' "${h%%:*}" | tr '[:upper:]' '[:lower:]')"
    case "$h" in localhost|127.0.0.1|0.0.0.0) h=lo ;; esac
    case "${h}:${p}" in
        "${2}:8545"|"${2}:43174"|lo:8655|lo:8656|lo:9655) return 0 ;;
    esac
    return 1
}

# -----------------------------------------------------------------------------
# JSON lines of the node scripts, read the way lib/gateway.sh reads them (no jq)
# -----------------------------------------------------------------------------

# fbg_done_line TEXT -- the last {"event":"done",...} line of TEXT.
fbg_done_line() {
    local line last="" re='"event"[[:space:]]*:[[:space:]]*"done"'
    while IFS= read -r line; do
        if [[ "$line" =~ $re ]]; then
            last="$line"
        fi
    done <<< "$1"
    printf '%s' "$last"
}

# fbg_json_true KEY LINE -- LINE holds "KEY": true.
fbg_json_true() {
    local re="\"${1}\"[[:space:]]*:[[:space:]]*true"
    [[ "$2" =~ $re ]]
}

# fbg_json_str KEY LINE -- the string value of KEY in LINE, or nothing.
fbg_json_str() {
    printf '%s\n' "$2" | sed -nE 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)".*/\1/p' \
        | sed -e 's/\\"/"/g' || true
}

# -----------------------------------------------------------------------------
# Steps
# -----------------------------------------------------------------------------

# fbg_docker -- Docker Engine from Docker's apt repository, the flow of
# _setup_docker_apt in setup-node.sh: the signing key is downloaded over https
# and compared with TN_DOCKER_APT_FINGERPRINT before it is installed
# (/etc/apt/keyrings/docker.gpg) and the repository listed with signed-by=
# (/etc/apt/sources.list.d/docker.list), both 0644.
fbg_docker() {
    local os codename arch tmp fpr keyring list re='^[a-z0-9]+$'
    fb_step docker "Docker Engine from Docker's apt repository"
    export DEBIAN_FRONTEND=noninteractive
    # shellcheck source=/dev/null  # the host's own release file
    os="$( . "${FB_ROOT}/etc/os-release" 2>/dev/null; printf '%s' "${ID:-}" )"
    # shellcheck source=/dev/null  # the host's own release file
    codename="$( . "${FB_ROOT}/etc/os-release" 2>/dev/null; printf '%s' "${VERSION_CODENAME:-}" )"
    arch="$(dpkg --print-architecture 2>/dev/null)" || arch=""
    case "$os" in
        ubuntu|debian) ;;
        *) fb_fail "This host runs ${os:-an unknown system}, not Ubuntu or Debian; Docker's apt repository serves those two." ;;
    esac
    if ! [[ "$codename" =~ $re ]] || ! [[ "$arch" =~ $re ]]; then
        fb_fail "Could not read the release name and architecture of this host (found '${codename}', '${arch}')."
    fi
    if ! command -v gpg >/dev/null 2>&1; then
        fb_try 3 30 apt-get -q update || fb_fail "apt-get update failed."
        fb_try 3 30 apt-get -y -q install gnupg \
            || fb_fail "Could not install gnupg, which checks Docker's signing key."
    fi
    tmp="$(mktemp -d "${FB_STATE}/docker-apt.XXXXXX")" || fb_fail "Could not create a temporary directory in ${FB_STATE#"$FB_ROOT"}."
    if ! ( umask 077; mkdir -p -- "${tmp}/gnupg" ); then
        fbg_cleanup "$tmp"
        fb_fail "Could not create a temporary directory in ${FB_STATE#"$FB_ROOT"}."
    fi
    if ! curl --proto '=https' --tlsv1.2 -fsSL --max-time 60 --max-filesize 1048576 \
        -o "${tmp}/key" --url "https://download.docker.com/linux/${os}/gpg"; then
        fbg_cleanup "$tmp"
        fb_fail "Could not download Docker's apt signing key."
    fi
    fpr="$(GNUPGHOME="${tmp}/gnupg" gpg --batch --no-tty --with-colons --import-options show-only --import < "${tmp}/key" 2>/dev/null \
        | awk -F: '$1 == "pub" { want = 1; next } $1 == "fpr" && want { print $10; want = 0 }')" || fpr=""
    if [ "$fpr" != "$TN_DOCKER_APT_FINGERPRINT" ]; then
        fbg_cleanup "$tmp"
        fb_fail "Docker's apt signing key has the fingerprint ${fpr:-(none)}, not the pinned ${TN_DOCKER_APT_FINGERPRINT}; no apt source was written. Check https://docs.docker.com/engine/install/${os}/ for a key change."
    fi
    keyring="${FB_ROOT}/etc/apt/keyrings/docker.gpg"
    list="${FB_ROOT}/etc/apt/sources.list.d/docker.list"
    if ! { mkdir -p "${keyring%/*}" "${list%/*}" \
        && GNUPGHOME="${tmp}/gnupg" gpg --batch --no-tty --dearmor < "${tmp}/key" > "${tmp}/docker.gpg" 2>/dev/null \
        && cp -- "${tmp}/docker.gpg" "$keyring" && chmod 0644 "$keyring"; }; then
        fbg_cleanup "$tmp"
        fb_fail "Could not write /etc/apt/keyrings/docker.gpg."
    fi
    fbg_cleanup "$tmp"
    if ! { printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/%s %s stable\n' \
            "$arch" "$os" "$codename" > "$list" && chmod 0644 "$list"; }; then
        fb_fail "Could not write /etc/apt/sources.list.d/docker.list."
    fi
    fb_try 3 30 apt-get -q update || fb_fail "apt-get update failed."
    fb_try 3 30 apt-get -y -q install docker-ce docker-ce-cli containerd.io \
        || fb_fail "Could not install docker-ce, docker-ce-cli and containerd.io from Docker's repository."
}

# fbg_cleanup DIR -- remove a temporary directory and any gpg agent in it.
fbg_cleanup() {
    if [ -d "$1/gnupg" ] && command -v gpgconf >/dev/null 2>&1; then
        GNUPGHOME="$1/gnupg" gpgconf --kill all >/dev/null 2>&1 || true
    fi
    rm -rf -- "$1"
}

# fbg_docker_running -- setup-gateway.sh needs a running Docker daemon.
fbg_docker_running() {
    local n=1
    fb_step docker-service "the Docker daemon, enabled and running"
    fb_try 1 0 systemctl enable --now docker || fb_fail "systemctl enable --now docker failed."
    until docker info >/dev/null 2>&1; do
        [ "$n" -lt 24 ] || fb_fail "docker info still fails 2 minutes after the daemon started; see journalctl -u docker."
        fb_sleep 5
        n=$((n + 1))
    done
}

# fbg_wait_dns -- the gateway's name should reach this host before Caddy asks
# for its certificate, but waiting longer helps nothing: Caddy retries with
# backoff by itself, so a name that is still missing only goes to the log. The
# wait ends on the clock: a check can itself take a while when DNS or the
# outbound HTTPS it uses is slow.
fbg_wait_dns() {
    local limit end out="" note re='"propagated"[[:space:]]*:[[:space:]]*true'
    fb_step dns "${TN_FB_DOMAIN} resolving to ${TN_FB_PUBLIC_IP}"
    limit="${TN_FB_DNS_TIMEOUT:-1800}"
    end=$((SECONDS + limit))
    while :; do
        out="$(bash "${FB_SCRIPTS_DIR}/install-caddy.sh" --json --phase=gateway-check-dns \
            --gateway-domain "$TN_FB_DOMAIN" --public-ip "$TN_FB_PUBLIC_IP" 2>>"$FB_LOG" </dev/null)" || out=""
        if [[ "$out" =~ $re ]]; then
            fb_log "${TN_FB_DOMAIN} reaches this host."
            return 0
        fi
        [ "$SECONDS" -lt "$end" ] || break
        fb_sleep 30
    done
    note="$(fbg_json_str note "$out")"
    fb_log "Warning: ${TN_FB_DOMAIN} did not reach ${TN_FB_PUBLIC_IP} within ${limit} s${note:+ (${note})}. The gateway is set up anyway; Caddy gets the certificate once the A record resolves, and sudo systemctl reload caddy starts a new attempt at once."
}

# fbg_setup_gateway -- setup-gateway.sh --enable, unattended (--json never asks).
fbg_setup_gateway() {
    local n=1 rc out done_line msg sg="${FB_SCRIPTS_DIR}/setup-gateway.sh"
    fb_step gateway "setup-gateway.sh --enable --mode standalone --upstream ${TN_FB_UPSTREAM} --domain ${TN_FB_DOMAIN}"
    while :; do
        rc=0
        out="$(bash "$sg" --enable --mode standalone --network "$TN_FB_NETWORK" \
            --upstream "$TN_FB_UPSTREAM" --front caddy --domain "$TN_FB_DOMAIN" \
            --redirect-queries "$TN_FB_REDIRECT_QUERIES" \
            --rate-limit-submissions "$TN_FB_RATE_LIMIT_SUBMISSIONS" --json 2>>"$FB_LOG" </dev/null)" || rc=$?
        if [ -n "$out" ]; then
            printf '%s\n' "$out" >> "$FB_LOG" 2>/dev/null || true
        fi
        done_line="$(fbg_done_line "$out")"
        msg="$(fbg_json_str msg "$done_line")"
        if [ "$rc" -eq 0 ] && fbg_json_true ok "$done_line"; then
            fb_log "setup-gateway.sh: ${msg:-done}"
            return 0
        fi
        case "$rc" in
            0)
                fb_fail "setup-gateway.sh exited 0 without an \"ok\":true result${msg:+: ${msg}}." ;;
            1)
                if [ "$n" -lt 3 ]; then
                    fb_log "setup-gateway.sh refused or put everything back (exit 1)${msg:+: ${msg}}. Trying again in 60 s (attempt ${n} of 3)."
                    fb_sleep 60
                    n=$((n + 1))
                    continue
                fi
                fb_fail "setup-gateway.sh refused or put everything back three times (exit 1)${msg:+: ${msg}}." ;;
            3)
                fb_fail "setup-gateway.sh stopped after a partial change (exit 3)${msg:+: ${msg}}. The firewall step did not run; see sudo bash ${FB_SCRIPTS_DIR#"$FB_ROOT"}/setup-gateway.sh --status first." ;;
            *)
                fb_fail "setup-gateway.sh failed (exit ${rc})${msg:+: ${msg}}." ;;
        esac
    done
}

# fbg_firewall -- this host's firewall. On mainnet firewall-setup.sh needs an
# SSH source; TN_FB_SSH_FROM always holds the network's own range.
fbg_firewall() {
    fb_step firewall "firewall-setup.sh --enable --ssh-from ${TN_FB_SSH_FROM}"
    fb_try 1 0 bash "${FB_SCRIPTS_DIR}/firewall-setup.sh" --enable --ssh-from "$TN_FB_SSH_FROM" </dev/null \
        || fb_fail "firewall-setup.sh --enable failed; the lines above in ${FB_LOG_PATH} say why."
}

# fbg_check_node -- a diagnostic: its output goes to the log and never fails the boot.
fbg_check_node() {
    fb_step check-node "check-node.sh, its output into ${FB_LOG_PATH}"
    if ! bash "${FB_SCRIPTS_DIR}/check-node.sh" >> "$FB_LOG" 2>&1 </dev/null; then
        fb_log "Warning: check-node.sh did not finish; its output is in ${FB_LOG_PATH}."
    fi
}

main() {
    fb_init gateway
    fb_apt_lock_timeout
    fb_cve_2026_31431
    fb_swap_off
    fb_install_node_scripts setup-gateway.sh install-caddy.sh firewall-setup.sh check-node.sh
    fbg_docker
    fbg_docker_running
    fbg_wait_dns
    fbg_setup_gateway
    fbg_firewall
    fbg_check_node
    fb_done "The worker gateway is set up: https://${TN_FB_DOMAIN}/ in front of ${TN_FB_UPSTREAM}. Next: the steps that terraform output next_steps prints for once the gateway is up, run on the validator."
}

main "$@"
