#!/usr/bin/env bash
# =============================================================================
# setup-vpn.sh -- Telcoin testnet add-on: WireGuard admin SSH overlay
#
# Opt-in, testnet-only, reversible. Joins this node to the Telcoin Association's
# private WireGuard overlay and lets the core team SSH in as a 'tnadmin' user ONLY
# from the maintainer overlay range (TN_OVERLAY_ADMIN_CIDR in
# lib/testnet-addons.env), e.g. to help recover a stuck node. tnadmin may run a
# short list of node recovery commands with sudo (status, start, stop and restart
# of the node unit, its journal, and check-node.sh when the scripts directory is
# root-owned); full root needs a second, explicit flag (--grant-maintainer-root).
# Your own SSH/login configuration is never touched (a scoped drop-in is added
# instead), the host nftables table is installed DORMANT (ufw stays your only
# active firewall), and wg0 uses Table=off so your default route and consensus
# path are untouched.
#
# Maintainer keys come from lib/wgvpn/peers/ssh/KEYS ("<name> <fingerprint>" per
# line, plus "# revoked: <fingerprint>" lines). A key you want blocked on this
# host goes into /etc/wgvpn/tnadmin.revoked (one fingerprint per line).
#
# Because the overlay can reach a box that may hold your validator BLS keys,
# consent is EXPLICIT and the whole thing is reversible: setup-vpn.sh --disable.
#
# USAGE:
#   sudo bash setup-vpn.sh                          # interactive enable
#   sudo bash setup-vpn.sh --overlay-ip 10.100.20.7 # non-interactive IP
#   sudo bash setup-vpn.sh --accept-vpn-consent     # skip the consent prompt (UI)
#   sudo bash setup-vpn.sh --status                 # diagnose tunnel + keys + firewall (any network)
#   sudo bash setup-vpn.sh --sync-keys              # re-apply the maintainer SSH key set
#   sudo bash setup-vpn.sh --apply-firewall         # (re)add the overlay->SSH ufw rule
#   sudo bash setup-vpn.sh --selfheal               # re-assert tunnel + drop-in + keys; migrates old units
#   sudo bash setup-vpn.sh --disable                # tear everything down (any network)
#   --grant-maintainer-root    with enable or --sync-keys: give tnadmin full root (testnet only)
#   --revoke-maintainer-root   with enable or --sync-keys: back to the recovery command list
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

readonly SCRIPT_VERSION="2.0.0"
readonly WGVPN_DIR="${SCRIPT_DIR}/lib/wgvpn"
# The maintainer key directory (KEYS + <name>.pub files). Not readonly: the fixture
# tests point it at a scratch copy.
VPN_KEYS_DIR="${WGVPN_DIR}/peers/ssh"
readonly SCOPED_SSHD_DROPIN="/etc/ssh/sshd_config.d/15-tnadmin-overlay.conf"
# Self-heal units (H3): a boot-time oneshot + an on-change path watcher that run the
# root-owned helper below, which re-asserts the overlay tunnel + scoped drop-in +
# maintainer keys, so an openssh upgrade, reboot, or cloud-init reset can never
# silently relock an external node out of maintainer SSH. The helper is generated
# by this script, runs no other file, and lives outside the scripts directory.
readonly SELFHEAL_SERVICE="/etc/systemd/system/tn-vpn-selfheal.service"
readonly SELFHEAL_PATH_UNIT="/etc/systemd/system/tn-vpn-selfheal.path"
readonly SELFHEAL_BIN="/usr/local/sbin/tn-vpn-selfheal"
# Root-owned key state: the verified KEYS set (the helper reads it), the operator's
# local deny list, and the file sshd reads for overlay tnadmin logins.
readonly VPN_STATE_DIR="/etc/wgvpn"
readonly VPN_KEYS_FILE="/etc/wgvpn/tnadmin.keys"
readonly VPN_REVOKED_FILE="/etc/wgvpn/tnadmin.revoked"
readonly VPN_AUTH_FILE="/etc/wgvpn/tnadmin.authorized_keys"
readonly TNADMIN_SUDOERS="/etc/sudoers.d/90-tnadmin"
# The ops user the maintainer keys authorize, and the hub's fixed overlay IP. Both
# mirror wg-node-bootstrap.sh (WG_TNADMIN_USER default) and the hub's wg0 address.
readonly TNADMIN_USER="tnadmin"
readonly HUB_OVERLAY_IP="10.100.0.1"

MODE="enable"
ACCEPT_CONSENT=false
OVERLAY_IP=""
ROOT_GRANT=""       # grant | revoke | "" (keep VPN_MAINTAINER_ROOT from .node-meta)
NETWORK=""          # read from .node-meta; consumed by require_testnet (is_testnet)
VPN_META=""         # the .node-meta path ("" when no node is installed)
WG_NODE_PUBKEY=""
PRE_PWAUTH=""
PRE_ROOT=""
TNADMIN_PUBKEYS=""  # the KEYS-verified maintainer set (recorded in tnadmin.keys)
TNADMIN_INSTALL=""  # that set minus the local deny list (what sshd will accept)

# Paths the shared vpn_* functions below use. vpn_init_paths sets them; the
# generated self-heal helper carries the same names with fixed values.
R=""
TNV_USER="$TNADMIN_USER"
TNV_CIDR=""
TNV_PROBE_ADDR=""
TNV_AUTH_PATH="$VPN_AUTH_FILE"
TNV_DROPIN=""
TNV_SSHD_CONFIG=""
TNV_KEYS=""
TNV_REVOKED=""
TNV_AUTH=""
TNV_SERVICE_UNIT=""
TNV_PATH_UNIT=""
TNV_SELF=""

# vpn_say MESSAGE -- progress line (the helper defines its own).
vpn_say() { print_info "$*"; }

# vpn_probe_addr CIDR -- the first host address of an IPv4 CIDR (10.100.9.0/24
# -> 10.100.9.1): the source address used to ask sshd which settings apply to an
# overlay maintainer login.
vpn_probe_addr() {
    local ip last
    ip="${1%/*}"
    last="${ip##*.}"
    if [[ "$last" =~ ^[0-9]+$ ]] && [[ "$last" -lt 255 ]]; then
        printf '%s.%s\n' "${ip%.*}" "$((last + 1))"
    else
        printf '%s\n' "$ip"
    fi
}

# vpn_init_paths -- set the TNV_* paths. TN_ROOT_PREFIX points them at a fixture
# tree (tests only; unset on a node).
vpn_init_paths() {
    R="${TN_ROOT_PREFIX:-}"
    TNV_CIDR="${TN_OVERLAY_ADMIN_CIDR:-}"
    if ! validate_health_src "$TNV_CIDR" || [[ "$TNV_CIDR" != */* ]]; then
        print_error "TN_OVERLAY_ADMIN_CIDR ('${TNV_CIDR}') in lib/testnet-addons.env is not a CIDR."
        exit 1
    fi
    TNV_PROBE_ADDR="$(vpn_probe_addr "$TNV_CIDR")"
    TNV_DROPIN="${R}${SCOPED_SSHD_DROPIN}"
    TNV_SSHD_CONFIG="${R}/etc/ssh/sshd_config"
    TNV_KEYS="${R}${VPN_KEYS_FILE}"
    TNV_REVOKED="${R}${VPN_REVOKED_FILE}"
    TNV_AUTH="${R}${VPN_AUTH_FILE}"
    TNV_SERVICE_UNIT="${R}${SELFHEAL_SERVICE}"
    TNV_PATH_UNIT="${R}${SELFHEAL_PATH_UNIT}"
    TNV_SELF="${R}${SELFHEAL_BIN}"
}

# =============================================================================
# Shared functions. The self-heal helper is written from these exact bodies
# (declare -f in vpn_selfheal_script), so they use only print_warn (stderr),
# vpn_say, tn_root_dir_ok, tn_write_root_file, each other and system tools.
# =============================================================================

# vpn_key_fp LINE -- the SHA256 fingerprint of one authorized_keys line, as
# `ssh-keygen -lf` prints it (SHA256:<43 base64 chars>); rc 1 when ssh-keygen
# cannot read the line.
vpn_key_fp() {
    local fp re='^SHA256:[A-Za-z0-9+/]{43}$'
    fp="$(printf '%s\n' "${1:-}" | ssh-keygen -lf - -E sha256 2>/dev/null | awk 'NR == 1 { print $2 }')" || fp=""
    [[ "$fp" =~ $re ]] || return 1
    printf '%s\n' "$fp"
}

# vpn_root_file_ok FILE -- rc 0 when FILE is a regular file (not a symlink) owned
# by uid 0, not group- or other-writable, in a directory that passes
# tn_root_dir_ok.
vpn_root_file_ok() {
    local f="${1:-}" st
    [[ "$f" == /* && -f "$f" && ! -L "$f" ]] || return 1
    st="$(stat -c '%u %a' -- "$f" 2>/dev/null)" || return 1
    [[ "${st%% *}" == 0 ]] || return 1
    case "${st##* }" in
        *[2367]?|*[2367]) return 1 ;;
    esac
    tn_root_dir_ok "${f%/*}"
}

# vpn_filter_keys REVOKED_FILE -- copy authorized_keys lines from stdin to stdout,
# dropping blank and comment lines, lines ssh-keygen cannot fingerprint, and keys
# whose fingerprint is listed in REVOKED_FILE (first word of each line;
# "#" starts a comment). A missing REVOKED_FILE blocks nothing; one that exists
# but is not a root-owned regular file stops the filter (rc 1, no output), and so
# does input none of whose lines could be fingerprinted (a missing or broken
# ssh-keygen must not empty the key file).
vpn_filter_keys() {
    local revoked="${1:-}" deny=" " line fp rest cr out="" seen=0 read_ok=0
    local re_fp='^SHA256:[A-Za-z0-9+/]{43}$' re_blank='^[[:space:]]*(#.*)?$'
    cr=$'\r'
    if ! command -v ssh-keygen >/dev/null 2>&1; then
        print_warn "ssh-keygen is not installed; the maintainer keys were left as they are." >&2
        return 1
    fi
    if [[ -n "$revoked" ]] && [[ -e "$revoked" || -L "$revoked" ]]; then
        if ! vpn_root_file_ok "$revoked"; then
            print_warn "${revoked} is not a root-owned regular file; no maintainer key was written." >&2
            return 1
        fi
        while IFS= read -r line || [[ -n "$line" ]]; do
            line="${line%%#*}"
            read -r fp rest <<<"$line" || true
            if [[ "$fp" =~ $re_fp ]]; then
                deny="${deny}${fp} "
            fi
        done < "$revoked"
    fi
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%"$cr"}"
        [[ "$line" =~ $re_blank ]] && continue
        seen=$((seen + 1))
        if ! fp="$(vpn_key_fp "$line")"; then
            print_warn "Skipped a key line that ssh-keygen cannot read." >&2
            continue
        fi
        read_ok=$((read_ok + 1))
        case "$deny" in
            *" ${fp} "*)
                print_warn "Skipped revoked key ${fp}." >&2
                continue ;;
        esac
        out="${out}${line}"$'\n'
    done
    if [[ "$seen" -gt 0 && "$read_ok" -eq 0 ]]; then
        print_warn "ssh-keygen could not read any maintainer key; the key file was left as it is." >&2
        return 1
    fi
    printf '%s' "$out"
    return 0
}

# vpn_login_fix USER -- keep USER password-less (no hash) yet able to accept key
# logins. Ubuntu sshd is UsePAM=yes, so AFTER the key matches it runs PAM account
# management; a '!'-locked or aging-flagged account is refused there. Shadow field
# '*' can never authenticate but is not the '!' lock; aging and expiry are off.
# (usermod -U / passwd -u on a no-hash account would yield an EMPTY field, which
# is a passwordless login, so the field is set to '*' explicitly.)
vpn_login_fix() {
    local u="${1:-}"
    if ! getent passwd "$u" >/dev/null 2>&1; then
        print_warn "User ${u} does not exist yet; skipped the key-only login fix." >&2
        return 0
    fi
    usermod -p '*' "$u" >/dev/null 2>&1 \
        || print_warn "Could not set the ${u} password field to '*'." >&2
    if command -v chage >/dev/null 2>&1; then
        chage -d "$(date +%Y-%m-%d)" -m 0 -M -1 -I -1 -E -1 "$u" >/dev/null 2>&1 \
            || print_warn "Could not turn off password aging for ${u}." >&2
    fi
    vpn_say "${u}: no password, login enabled for key-only SSH."
    return 0
}

# vpn_dropin_text CIDR AUTHFILE -- the scoped sshd drop-in. sshd keeps the FIRST
# value it finds for each keyword, so the overlay blocks come before the deny block.
vpn_dropin_text() {
    local cidr="${1:-}" auth="${2:-}"
    cat <<EOF
# Telcoin VPN admin access (testnet add-on), written by setup-vpn.sh. Scoped to
# the tnadmin user and the maintainer overlay range ${cidr}; your own SSH
# configuration is untouched.
#   1) from ${cidr} only tnadmin may log in;
#   2) tnadmin from ${cidr}: publickey with the maintainer keys in ${auth}
#      (root-owned; written from the KEYS list minus /etc/wgvpn/tnadmin.revoked);
#   3) tnadmin from anywhere else: publickey with no keys (/dev/null), so no login.
Match Address ${cidr}
    AllowUsers tnadmin
Match User tnadmin Address ${cidr}
    AuthenticationMethods publickey
    PubkeyAuthentication yes
    PasswordAuthentication no
    AuthorizedKeysFile ${auth}
Match User tnadmin
    AuthenticationMethods publickey
    PubkeyAuthentication no
    PasswordAuthentication no
    AuthorizedKeysFile /dev/null
EOF
}

# vpn_sshd_include -- make TNV_SSHD_CONFIG read /etc/ssh/sshd_config.d/*.conf. An
# openssh upgrade or a cloud-init reset can drop the Include line, leaving the
# drop-in on disk but ignored. No-op when an Include is present; otherwise append
# it, check with sshd -t and put the file back on failure.
vpn_sshd_include() {
    local f="$TNV_SSHD_CONFIG" old text nl=$'\n'
    if [[ ! -f "$f" || -L "$f" ]]; then
        print_warn "No regular ${f}; cannot add the Include line." >&2
        return 1
    fi
    if grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/' "$f"; then
        return 0
    fi
    old="$(cat -- "$f")" || return 1
    text="${old}${nl}${nl}# Added by the Telcoin VPN add-on: read the sshd_config.d drop-ins."
    text="${text}${nl}Include /etc/ssh/sshd_config.d/*.conf"
    # A here-string, not a here-document: this function is copied into the
    # self-heal helper with declare -f, which cannot reproduce a here-document
    # inside an if condition.
    if ! tn_write_root_file "$f" 0644 <<< "$text"; then
        return 1
    fi
    if sshd -t >/dev/null 2>&1; then
        systemctl reload ssh >/dev/null 2>&1 || systemctl reload sshd >/dev/null 2>&1 || true
        vpn_say "Added the missing Include line to ${f}; the drop-ins are read again."
        return 0
    fi
    tn_write_root_file "$f" 0644 <<< "$old" || true
    print_warn "sshd -t rejected the Include line; ${f} is back as it was." >&2
    return 1
}

# vpn_sshd_honored -- ask sshd which AuthorizedKeysFile applies to an overlay
# tnadmin login; when it is not the maintainer key file, repair the Include line
# and ask again. rc 1 when the drop-in is still not applied.
vpn_sshd_honored() {
    local eff=""
    command -v sshd >/dev/null 2>&1 || return 0
    eff="$(sshd -T -C "user=${TNV_USER},addr=${TNV_PROBE_ADDR}" 2>/dev/null)" || eff=""
    if [[ -z "$eff" ]]; then
        vpn_say "sshd -T -C is not available here; skipped the drop-in check."
        return 0
    fi
    if grep -qiF "$TNV_AUTH_PATH" <<<"$eff"; then
        vpn_say "Verified: sshd applies the drop-in to ${TNV_USER} logins from ${TNV_PROBE_ADDR}."
        return 0
    fi
    print_warn "sshd is not applying the drop-in to ${TNV_USER} logins from the overlay; checking the Include line." >&2
    vpn_sshd_include || true
    eff="$(sshd -T -C "user=${TNV_USER},addr=${TNV_PROBE_ADDR}" 2>/dev/null)" || eff=""
    if grep -qiF "$TNV_AUTH_PATH" <<<"$eff"; then
        vpn_say "Verified after the repair: sshd applies the drop-in."
        return 0
    fi
    print_warn "The drop-in is still not applied. Check: sshd -T -C user=${TNV_USER},addr=${TNV_PROBE_ADDR} | grep -i authorizedkeysfile" >&2
    return 1
}

# vpn_sshd_apply -- write the scoped drop-in (TNV_DROPIN) when it differs, check
# with sshd -t, put the previous drop-in back (or remove the new one) on failure,
# reload sshd, then confirm sshd applies it. rc 1 when sshd rejected it.
vpn_sshd_apply() {
    local desired cur="" had=0 d="${TNV_DROPIN%/*}"
    desired="$(vpn_dropin_text "$TNV_CIDR" "$TNV_AUTH_PATH")"
    if [[ -f "$TNV_DROPIN" && ! -L "$TNV_DROPIN" ]]; then
        cur="$(cat -- "$TNV_DROPIN" 2>/dev/null)" || cur=""
        had=1
    fi
    if [[ "$had" == 1 && "$cur" == "$desired" ]]; then
        vpn_say "Scoped sshd drop-in already current."
    else
        if [[ ! -d "$d" ]]; then
            install -d -m 0755 -- "$d" || return 1
        fi
        if ! tn_write_root_file "$TNV_DROPIN" 0644 <<< "$desired"; then
            print_warn "Could not write ${TNV_DROPIN}; SSH is unchanged." >&2
            return 1
        fi
        if ! sshd -t >/dev/null 2>&1; then
            if [[ "$had" == 1 ]]; then
                tn_write_root_file "$TNV_DROPIN" 0644 <<< "$cur" || rm -f -- "$TNV_DROPIN"
            else
                rm -f -- "$TNV_DROPIN"
            fi
            print_warn "sshd -t rejected the drop-in; the previous state is back and SSH is unchanged." >&2
            return 1
        fi
        systemctl reload ssh >/dev/null 2>&1 || systemctl reload sshd >/dev/null 2>&1 || true
        vpn_say "Scoped sshd drop-in installed and checked (${TNV_USER}: ${TNV_CIDR} only, key only)."
    fi
    vpn_sshd_honored || true
    return 0
}

# vpn_drop_user_keyfile -- remove the per-user key file that older releases (and
# the vendored bootstrap) wrote in tnadmin's home, once the drop-in reads the
# root-owned file instead. Unlinks one fixed name; never follows a link: it does
# nothing when the home or its .ssh is a symlink or not a directory.
vpn_drop_user_keyfile() {
    local home
    grep -qF "$TNV_AUTH_PATH" "$TNV_DROPIN" 2>/dev/null || return 0
    home="$(getent passwd "$TNV_USER" 2>/dev/null | cut -d: -f6)" || home=""
    [[ "$home" == /* ]] || return 0
    if [[ -L "$home" || ! -d "$home" || -L "${home}/.ssh" || ! -d "${home}/.ssh" ]]; then
        return 0
    fi
    rm -f -- "${home}/.ssh/authorized_keys.tnvpn" 2>/dev/null || true
    return 0
}

# vpn_remove_selfheal -- disable and delete the two self-heal units and the
# helper. The service is disabled without --now: the helper may be the caller.
vpn_remove_selfheal() {
    if command -v systemctl >/dev/null 2>&1; then
        systemctl disable --now tn-vpn-selfheal.path >/dev/null 2>&1 || true
        systemctl disable tn-vpn-selfheal.service >/dev/null 2>&1 || true
    fi
    rm -f -- "$TNV_SERVICE_UNIT" "$TNV_PATH_UNIT" "$TNV_SELF"
    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi
    return 0
}

# vpn_reassert all|keys|sshd -- the idempotent re-assert behind enable,
# --sync-keys, --selfheal and the helper:
#   keys: TNV_KEYS (root-owned) minus TNV_REVOKED -> TNV_AUTH (root 0644), only
#         when the content changed; a key no longer in KEYS disappears here;
#   sshd: the scoped drop-in (sshd -t checked) and the Include repair;
#   all:  wg-quick@wg0 enabled, keys, sshd, the key-only tnadmin login.
# Keys go first so the drop-in never points at a missing file. rc 1 when a step
# failed (the others still ran).
vpn_reassert() {
    local what="${1:-all}" rc=0 keys cur n
    case "$what" in
        all|keys|sshd) ;;
        *) print_warn "vpn_reassert: unknown step '${what}'" >&2; return 2 ;;
    esac
    if [[ "$what" == all ]] && command -v systemctl >/dev/null 2>&1; then
        if systemctl is-enabled wg-quick@wg0 >/dev/null 2>&1; then
            vpn_say "wg-quick@wg0 is enabled (the tunnel returns after a reboot)."
        elif systemctl enable wg-quick@wg0 >/dev/null 2>&1; then
            vpn_say "Re-enabled wg-quick@wg0 (it was not enabled)."
        else
            print_warn "Could not enable wg-quick@wg0; the tunnel may not return after a reboot." >&2
            rc=1
        fi
    fi
    if [[ "$what" != sshd ]]; then
        if ! vpn_root_file_ok "$TNV_KEYS"; then
            print_warn "${TNV_KEYS} is missing or not a root-owned file; the maintainer keys were left as they are." >&2
            rc=1
        elif ! keys="$(vpn_filter_keys "$TNV_REVOKED" < "$TNV_KEYS")"; then
            rc=1
        else
            n=0
            if [[ -n "$keys" ]]; then
                n="$(printf '%s\n' "$keys" | grep -c .)" || n=0
            fi
            cur=""
            if [[ -f "$TNV_AUTH" && ! -L "$TNV_AUTH" ]]; then
                cur="$(cat -- "$TNV_AUTH" 2>/dev/null)" || cur=""
            fi
            if [[ -f "$TNV_AUTH" && ! -L "$TNV_AUTH" && "$cur" == "$keys" ]]; then
                vpn_say "Maintainer keys already current (${n} key(s) in ${TNV_AUTH})."
            elif if [[ -n "$keys" ]]; then tn_write_root_file "$TNV_AUTH" 0644 <<< "$keys"; else tn_write_root_file "$TNV_AUTH" 0644 < /dev/null; fi; then
                vpn_say "Wrote ${n} maintainer key(s) to ${TNV_AUTH} (root, 0644)."
            else
                print_warn "Could not write ${TNV_AUTH}; the maintainer keys were left as they are." >&2
                rc=1
            fi
        fi
    fi
    if [[ "$what" != keys ]]; then
        vpn_sshd_apply || rc=1
    fi
    if [[ "$what" == all ]]; then
        vpn_login_fix "$TNV_USER" || rc=1
    fi
    vpn_drop_user_keyfile
    return "$rc"
}

# =============================================================================
# Self-heal helper and units
# =============================================================================

# vpn_selfheal_script -- print the root-owned self-heal helper: the TNV_* values
# of this run, the shared functions above (declare -f) and a short main. It runs
# no other file and holds no path under the scripts directory.
vpn_selfheal_script() {
    local v meta="${VPN_META:-${R}/etc/telcoin/.node-meta}"
    printf '%s\n' '#!/bin/bash'
    cat <<'EOF'
# tn-vpn-selfheal -- written by setup-vpn.sh (Telcoin testnet VPN add-on); do not
# edit, setup-vpn.sh --sync-keys or --selfheal writes it again. Root-owned and
# self-contained: it runs no other file. tn-vpn-selfheal.service (boot) and
# tn-vpn-selfheal.path (sshd config changes) run it. It re-asserts wg-quick@wg0,
# the maintainer keys (/etc/wgvpn/tnadmin.keys minus /etc/wgvpn/tnadmin.revoked
# into /etc/wgvpn/tnadmin.authorized_keys), the tnadmin sshd drop-in (checked with
# sshd -t) and the key-only tnadmin login. When .node-meta does not say testnet
# or devnet it removes its units and itself.
#   tn-vpn-selfheal           everything
#   tn-vpn-selfheal --keys    the maintainer keys only
#   tn-vpn-selfheal --sshd    the drop-in and the Include line only
set -u
umask 022
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
EOF
    printf 'TNV_META=%q\n' "$meta"
    for v in TNV_USER TNV_CIDR TNV_PROBE_ADDR TNV_AUTH_PATH TNV_DROPIN TNV_SSHD_CONFIG \
             TNV_KEYS TNV_REVOKED TNV_AUTH TNV_SERVICE_UNIT TNV_PATH_UNIT TNV_SELF; do
        printf '%s=%q\n' "$v" "${!v}"
    done
    printf '\n'
    declare -f tn_root_dir_ok tn_write_root_file vpn_key_fp vpn_root_file_ok \
        vpn_filter_keys vpn_login_fix vpn_dropin_text vpn_sshd_include vpn_sshd_honored \
        vpn_sshd_apply vpn_drop_user_keyfile vpn_remove_selfheal vpn_reassert
    cat <<'EOF'

print_warn() { printf 'tn-vpn-selfheal: %s\n' "$*" >&2; }
vpn_say() { printf 'tn-vpn-selfheal: %s\n' "$*"; }

# tnv_network -- NETWORK from .node-meta; rc 1 when absent, rc 2 when the key is
# set more than once.
tnv_network() {
    local n
    [[ -f "$TNV_META" && ! -L "$TNV_META" ]] || return 1
    n="$(grep -c '^NETWORK=' "$TNV_META" 2>/dev/null)" || n=0
    [[ "$n" -gt 1 ]] && return 2
    [[ "$n" -eq 1 ]] || return 1
    sed -n 's/^NETWORK=//p' "$TNV_META" | tr -d '\r'
}

tnv_main() {
    local what net rc=0
    case "${1:-}" in
        ""|--all) what=all ;;
        --keys) what=keys ;;
        --sshd) what=sshd ;;
        *) print_warn "usage: tn-vpn-selfheal [--keys|--sshd]"; return 2 ;;
    esac
    net="$(tnv_network)" || rc=$?
    if [[ "$rc" -eq 2 ]]; then
        print_warn "NETWORK is set more than once in ${TNV_META}; nothing was changed."
        return 1
    fi
    case "$net" in
        testnet|devnet) ;;
        *)
            vpn_say "NETWORK is '${net:-unset}': the VPN add-on is testnet-only; removing the self-heal units and this helper."
            vpn_remove_selfheal
            return 0 ;;
    esac
    vpn_reassert "$what"
}

tnv_main "$@"
EOF
}

# vpn_selfheal_service_unit / vpn_selfheal_path_unit -- the two unit files.
vpn_selfheal_service_unit() {
    cat <<EOF
[Unit]
Description=Telcoin VPN admin-SSH self-heal (tunnel, maintainer keys, scoped sshd drop-in)
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
# Root-owned helper; it runs no file from the scripts directory.
ExecStart=${SELFHEAL_BIN}
[Install]
WantedBy=multi-user.target
EOF
}

vpn_selfheal_path_unit() {
    cat <<EOF
[Unit]
Description=Watch sshd config + the tnadmin overlay drop-in; re-assert on change (covers openssh upgrades with no reboot)
[Path]
PathChanged=/etc/ssh/sshd_config
PathChanged=${SCOPED_SSHD_DROPIN}
Unit=tn-vpn-selfheal.service
[Install]
WantedBy=multi-user.target
EOF
}

# install_selfheal_helper -- write the helper root:root 0755 through
# tn_write_root_file after checking it parses.
install_selfheal_helper() {
    local text
    text="$(vpn_selfheal_script)" || return 1
    if ! printf '%s\n' "$text" | bash -n 2>/dev/null; then
        print_warn "The generated self-heal helper does not parse; it was not installed."
        return 1
    fi
    if [[ ! -d "${TNV_SELF%/*}" ]]; then
        install -d -m 0755 -- "${TNV_SELF%/*}" || return 1
    fi
    tn_write_root_file "$TNV_SELF" 0755 <<< "$text"
}

# install_selfheal_units (H3) -- install the helper and the two units, then enable
# them: tn-vpn-selfheal.service (oneshot, WantedBy=multi-user.target) at every
# boot, tn-vpn-selfheal.path whenever /etc/ssh/sshd_config or the scoped drop-in
# changes (the no-reboot openssh-upgrade case). Rewrites an older unit that ran
# setup-vpn.sh from the scripts directory. A host without systemd keeps the
# manual `setup-vpn.sh --selfheal`.
install_selfheal_units() {
    print_step "Installing the VPN self-heal helper and units (boot + on-change re-assert)"
    if ! command -v systemctl >/dev/null 2>&1; then
        print_warn "systemd not present; skipping the self-heal units (manual 'setup-vpn.sh --selfheal' still works)."
        return 0
    fi
    if ! install_selfheal_helper \
        || ! tn_write_root_file "$TNV_SERVICE_UNIT" 0644 <<< "$(vpn_selfheal_service_unit)" \
        || ! tn_write_root_file "$TNV_PATH_UNIT" 0644 <<< "$(vpn_selfheal_path_unit)"; then
        print_warn "Could not install the self-heal helper or units."
        return 1
    fi
    systemctl daemon-reload >/dev/null 2>&1 || true
    # Enable the oneshot for boot; enable+start the watcher now so it is armed before
    # the next upgrade. (No --now on the service: the caller just re-asserted.)
    systemctl enable tn-vpn-selfheal.service >/dev/null 2>&1 || print_warn "Could not enable tn-vpn-selfheal.service."
    systemctl enable --now tn-vpn-selfheal.path >/dev/null 2>&1 || print_warn "Could not enable tn-vpn-selfheal.path."
    print_ok "Self-heal installed: ${SELFHEAL_BIN} (root-owned) run at boot and on sshd config changes."
}

# =============================================================================
# Preconditions
# =============================================================================

require_apt() {
    if ! command -v apt-get >/dev/null 2>&1; then
        print_error "setup-vpn.sh needs an apt-based distro (Debian/Ubuntu)."
        print_info  "The WireGuard bootstrap installs wireguard-tools + nftables via apt-get."
        exit 1
    fi
}

# load_node_context -- VPN_META and NETWORK. --status and --disable work with no
# node and on any network; the other verbs stop without a node, and a duplicated
# NETWORK line stops every verb that acts on it.
load_node_context() {
    local rc=0
    VPN_META="$(node_meta_path 2>/dev/null || true)"
    if [[ -z "$VPN_META" ]]; then
        case "$MODE" in
            status|disable)
                print_warn "No Telcoin node detected (no .node-meta); continuing with --${MODE}."
                return 0 ;;
        esac
        print_error "No Telcoin node detected (no /etc/telcoin/{validator,observer}/.node-meta)."
        print_info  "Run setup-validator.sh or setup-observer.sh first."
        exit 1
    fi
    # shellcheck disable=SC2034  # consumed cross-file by require_testnet (is_testnet)
    NETWORK="$(addon_meta_get NETWORK)" || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        NETWORK=""
        case "$MODE" in
            status|disable) print_warn "Continuing with --${MODE}, which works on any network." ;;
            *) exit 1 ;;
        esac
    fi
}

# vpn_root_grant_wanted -- prints true when tnadmin should have full root: the
# --grant-maintainer-root / --revoke-maintainer-root flag of this run, else
# VPN_MAINTAINER_ROOT in .node-meta (default false). rc 1 on a duplicated key.
vpn_root_grant_wanted() {
    local v
    case "$ROOT_GRANT" in
        grant) printf 'true\n'; return 0 ;;
        revoke) printf 'false\n'; return 0 ;;
    esac
    v="$(addon_meta_get VPN_MAINTAINER_ROOT false)" || return 1
    if [[ "$v" == true ]]; then printf 'true\n'; else printf 'false\n'; fi
}

# =============================================================================
# Maintainer keys
# =============================================================================

# vpn_keys_from_list DIR -- print the verified maintainer keys: DIR/KEYS holds one
# "<name> <SHA256:fingerprint>" line per maintainer; only DIR/<name>.pub files
# named there are read, each must hold exactly one key whose `ssh-keygen -lf`
# fingerprint matches, and fingerprints on "# revoked: <fingerprint> ..." lines
# are never printed. A listed key that is missing or does not match is skipped
# with a warning. rc 1 (nothing printed) when KEYS is missing, has a malformed
# line or a duplicated name, or no key is left.
vpn_keys_from_list() {
    local dir="${1:-}" list line name fp keyline got revoked=" " seen=" " out="" n=0 lineno=0 cr nl
    local re_rev='^#[[:space:]]*revoked:[[:space:]]*(SHA256:[A-Za-z0-9+/]{43})([[:space:]]|$)'
    local re_key='^([A-Za-z0-9][A-Za-z0-9._-]*)[[:space:]]+(SHA256:[A-Za-z0-9+/]{43})[[:space:]]*$'
    local re_skip='^[[:space:]]*(#.*)?$'
    cr=$'\r'
    nl=$'\n'
    list="${dir}/KEYS"
    if [[ ! -f "$list" || -L "$list" ]]; then
        print_warn "No maintainer key list at ${list}." >&2
        return 1
    fi
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%"$cr"}"
        if [[ "$line" =~ $re_rev ]]; then
            revoked="${revoked}${BASH_REMATCH[1]} "
        fi
    done < "$list"
    while IFS= read -r line || [[ -n "$line" ]]; do
        lineno=$((lineno + 1))
        line="${line%"$cr"}"
        [[ "$line" =~ $re_skip ]] && continue
        if [[ ! "$line" =~ $re_key ]]; then
            print_warn "${list} line ${lineno} is not '<name> SHA256:<fingerprint>'; no maintainer key was used." >&2
            return 1
        fi
        name="${BASH_REMATCH[1]}"
        fp="${BASH_REMATCH[2]}"
        case "$seen" in
            *" ${name} "*)
                print_warn "${list} names ${name} twice; no maintainer key was used." >&2
                return 1 ;;
        esac
        seen="${seen}${name} "
        case "$revoked" in
            *" ${fp} "*)
                print_warn "Skipping ${name}: ${fp} is on the revoked list in KEYS." >&2
                continue ;;
        esac
        if [[ -L "${dir}/${name}.pub" || ! -f "${dir}/${name}.pub" ]]; then
            print_warn "Skipping ${name}: ${dir}/${name}.pub is missing or not a regular file." >&2
            continue
        fi
        keyline="$(grep -vE "$re_skip" "${dir}/${name}.pub" 2>/dev/null | tr -d '\r')" || keyline=""
        if [[ -z "$keyline" || "$keyline" == *"$nl"* ]]; then
            print_warn "Skipping ${name}: ${name}.pub must hold exactly one key." >&2
            continue
        fi
        got="$(vpn_key_fp "$keyline")" || got=""
        if [[ "$got" != "$fp" ]]; then
            print_warn "Skipping ${name}: ${name}.pub has fingerprint ${got:-unreadable}, KEYS lists ${fp}." >&2
            continue
        fi
        case "$out" in
            *"${keyline}"*) continue ;;
        esac
        out="${out}${keyline}${nl}"
        n=$((n + 1))
    done < "$list"
    if [[ "$n" -eq 0 ]]; then
        print_warn "No usable maintainer key in ${list}." >&2
        return 1
    fi
    printf '%s' "$out"
}

# assemble_pubkeys -- TNADMIN_PUBKEYS from KEYS (vpn_keys_from_list) and
# TNADMIN_INSTALL = that set minus the local deny list. Exits when KEYS gives no
# key; TNADMIN_INSTALL may be empty when the operator revoked every key.
assemble_pubkeys() {
    local out
    if ! out="$(vpn_keys_from_list "$VPN_KEYS_DIR")" || [[ -z "$out" ]]; then
        print_error "No usable maintainer SSH key in ${VPN_KEYS_DIR}/KEYS. Re-install the scripts and retry."
        exit 1
    fi
    TNADMIN_PUBKEYS="${out}"$'\n'
    if ! TNADMIN_INSTALL="$(printf '%s' "$TNADMIN_PUBKEYS" | vpn_filter_keys "$TNV_REVOKED")"; then
        exit 1
    fi
}

# install_keys_file -- record TNADMIN_PUBKEYS in /etc/wgvpn/tnadmin.keys (root
# 0644), the copy the self-heal helper reads. Skips an unchanged file.
install_keys_file() {
    local d="${TNV_KEYS%/*}" cur="" nl=$'\n'
    if [[ ! -d "$d" ]]; then
        install -d -m 0755 -o root -g root -- "$d" || return 1
    fi
    if [[ -f "$TNV_KEYS" && ! -L "$TNV_KEYS" ]]; then
        cur="$(cat -- "$TNV_KEYS" 2>/dev/null)" || cur=""
        if [[ "$cur" == "$(printf '%s' "$TNADMIN_PUBKEYS")" ]]; then
            return 0
        fi
    fi
    if [[ -z "$TNADMIN_PUBKEYS" ]]; then
        tn_write_root_file "$TNV_KEYS" 0644 < /dev/null
    else
        # TNADMIN_PUBKEYS ends with its newline; the here-string adds it back.
        tn_write_root_file "$TNV_KEYS" 0644 <<< "${TNADMIN_PUBKEYS%"$nl"}"
    fi
}

# write_tnadmin_keys -- record the verified set (install_keys_file) and install it
# minus the local deny list /etc/wgvpn/tnadmin.revoked into the root-owned file
# sshd reads (vpn_reassert keys). A key no longer listed in KEYS is gone after this.
# assemble_pubkeys MUST have run first.
write_tnadmin_keys() {
    if ! install_keys_file; then
        print_error "Could not write ${VPN_KEYS_FILE}; the maintainer keys are unchanged."
        exit 1
    fi
    if ! vpn_reassert keys; then
        print_error "Could not install the maintainer keys (see above)."
        exit 1
    fi
}

# =============================================================================
# tnadmin sudo scope
# =============================================================================

# vpn_abs_cmd NAME -- the absolute path of a command, limited to characters that
# need no quoting in sudoers.
vpn_abs_cmd() {
    local p
    p="$(command -v "${1:-}" 2>/dev/null)" || return 1
    [[ "$p" =~ ^/[A-Za-z0-9/._-]+$ ]] || return 1
    printf '%s\n' "$p"
}

# vpn_check_node_cmd -- "<bash> <SCRIPT_DIR>/check-node.sh" when the scripts
# directory, its lib/ and their files are root-owned and not group- or
# other-writable (so tnadmin running it as root cannot run code another account
# controls); rc 1 otherwise.
vpn_check_node_cmd() {
    local d="$SCRIPT_DIR" b bad
    [[ "$d" =~ ^/[A-Za-z0-9/._-]+$ ]] || return 1
    tn_root_dir_ok "$d" || return 1
    tn_root_dir_ok "${d}/lib" || return 1
    vpn_root_file_ok "${d}/check-node.sh" || return 1
    bad="$(find "${d}/lib" -maxdepth 1 \( ! -uid 0 -o -perm /022 \) -print 2>/dev/null | head -n 1)" || return 1
    [[ -z "$bad" ]] || return 1
    b="$(vpn_abs_cmd bash)" || return 1
    printf '%s %s\n' "$b" "${d}/check-node.sh"
}

# vpn_sudoers_text true|false -- the 90-tnadmin text: full root (true) or the node
# recovery commands, each allowed with exactly the arguments written here.
vpn_sudoers_text() {
    local svc sc jc cn list
    if [[ "${1:-false}" == true ]]; then
        printf '%s\n' \
            "# Written by setup-vpn.sh (Telcoin testnet VPN add-on). The operator granted the" \
            "# maintainers full root with --grant-maintainer-root; --revoke-maintainer-root" \
            "# goes back to the recovery command list." \
            "${TNADMIN_USER} ALL=(ALL) NOPASSWD:ALL"
        return 0
    fi
    svc="$(tn_resolve_service 2>/dev/null)" || svc=""
    [[ "$svc" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || svc="telcoin"
    sc="$(vpn_abs_cmd systemctl)" || return 1
    jc="$(vpn_abs_cmd journalctl)" || return 1
    list="${sc} status --no-pager ${svc}, ${sc} start ${svc}, ${sc} stop ${svc}, ${sc} restart ${svc}, ${jc} --no-pager -u ${svc} -n 200, ${jc} --no-pager -u ${svc} -n 2000"
    if cn="$(vpn_check_node_cmd)"; then
        list="${list}, ${cn}"
    fi
    printf '%s\n' \
        "# Written by setup-vpn.sh (Telcoin testnet VPN add-on). tnadmin (the maintainers," \
        "# over the VPN overlay) may run these node recovery commands as root, with exactly" \
        "# these arguments, and nothing else. Full root needs the operator's explicit" \
        "#   sudo bash setup-vpn.sh --sync-keys --grant-maintainer-root" \
        "Cmnd_Alias TN_RECOVERY = ${list}" \
        "${TNADMIN_USER} ALL=(root) NOPASSWD: TN_RECOVERY"
}

# write_tnadmin_sudoers true|false -- replace /etc/sudoers.d/90-tnadmin (the
# vendored bootstrap writes NOPASSWD:ALL there) with vpn_sudoers_text, checked
# with visudo -cf first. When the text cannot be built, checked or installed the
# file is removed, so tnadmin is left with no sudo rather than full root.
write_tnadmin_sudoers() {
    local root="${1:-false}" f="${R}${TNADMIN_SUDOERS}" text tmpd="" rc=0
    [[ -d "${f%/*}" ]] || return 0
    text="$(vpn_sudoers_text "$root")" || rc=1
    if [[ "$rc" -eq 0 ]]; then
        tmpd="$(mktemp -d 2>/dev/null)" || tmpd=""
        if [[ -z "$tmpd" ]]; then
            rc=1
        elif ! printf '%s\n' "$text" > "${tmpd}/90-tnadmin" \
            || ! visudo -cf "${tmpd}/90-tnadmin" >/dev/null 2>&1 \
            || ! tn_write_root_file "$f" 0440 < "${tmpd}/90-tnadmin"; then
            rc=1
        fi
        [[ -z "$tmpd" ]] || rm -rf -- "$tmpd"
    fi
    if [[ "$rc" -ne 0 ]]; then
        rm -f -- "$f"
        print_warn "Could not install the tnadmin sudo rules; removed ${TNADMIN_SUDOERS}, so tnadmin has no sudo."
        return 1
    fi
    if [[ "$root" == true ]]; then
        print_warn "tnadmin has FULL root (NOPASSWD:ALL), as granted with --grant-maintainer-root."
    else
        print_ok "tnadmin sudo limited to the node recovery commands (${TNADMIN_SUDOERS})."
        if ! vpn_check_node_cmd >/dev/null; then
            print_info "check-node.sh is not in that list: ${SCRIPT_DIR} is not a root-owned, root-only-writable directory."
        fi
    fi
    return 0
}

# vpn_tnadmin_home_safe -- the vendored bootstrap writes and chowns
# ~tnadmin/.ssh/authorized_keys.tnvpn as root; refuse to run it while that path
# or a parent is a symlink.
vpn_tnadmin_home_safe() {
    local home p
    getent passwd "$TNADMIN_USER" >/dev/null 2>&1 || return 0
    home="$(getent passwd "$TNADMIN_USER" | cut -d: -f6)" || home=""
    [[ -n "$home" ]] || return 0
    for p in "$home" "${home}/.ssh" "${home}/.ssh/authorized_keys.tnvpn"; do
        if [[ -L "$p" ]]; then
            print_error "${p} is a symlink. The WireGuard bootstrap writes there as root; remove the link (and find out how it got there) before enabling again."
            return 1
        fi
    done
    return 0
}

# =============================================================================
# Enable
# =============================================================================

consent_gate() {
    [[ "$ACCEPT_CONSENT" == "true" ]] && return 0
    print_header "VPN admin SSH -- consent required"
    print_warn "This lets the Telcoin Association SSH into THIS node as a 'tnadmin' user over"
    print_warn "a private WireGuard overlay. This box may hold your validator BLS keys."
    print_warn "It is reversible at any time: setup-vpn.sh --disable."
    echo ""
    print_info "What it does and does NOT touch:"
    print_info "  * adds a 'tnadmin' user reachable ONLY from the maintainer range (${TN_OVERLAY_ADMIN_CIDR})"
    print_info "  * tnadmin may run node recovery commands with sudo (status/start/stop/restart"
    print_info "    of the node unit, its journal); full root only with --grant-maintainer-root"
    print_info "  * does NOT change your own SSH/login config (scoped drop-in only)"
    print_info "  * installs a host firewall table DORMANT (ufw stays your active firewall)"
    print_info "  * wg0 uses Table=off: your default route + consensus path are untouched"
    print_info "Full trust model: docs/testnet-addons.md"
    echo ""
    local ans
    read -r -p "  Type 'I CONSENT' to proceed (anything else aborts): " ans
    if [[ "$ans" != "I CONSENT" ]]; then
        print_info "Consent not given -- aborting. No changes made."
        exit 0
    fi
}

# detect_existing_install — best-effort read of the overlay IP a prior run already
# assigned this node, so a re-run can confirm-and-reuse instead of re-prompting for an
# address that is already on the box. Sets DETECTED_OVERLAY_IP / DETECTED_OVERLAY_SRC;
# returns non-zero when nothing is found. Reads .node-meta's VPN_OVERLAY_IP first (the
# same key persist_state writes and the UI helper reads), then falls back to the wg0.conf
# `Address =` line as the on-disk-of-record.
detect_existing_install() {
    DETECTED_OVERLAY_IP=""; DETECTED_OVERLAY_SRC=""
    local ip=""
    [[ -n "$VPN_META" ]] && ip="$(meta_get VPN_OVERLAY_IP "$VPN_META" 2>/dev/null || true)"
    [[ -n "$ip" ]] && DETECTED_OVERLAY_SRC=".node-meta"
    if [[ -z "$ip" && -r /etc/wireguard/wg0.conf ]]; then
        # `|| ip=""` guards set -e: with pipefail, grep finding no Address line makes the
        # pipeline non-zero, which would otherwise abort the whole script (a half-written
        # wg0.conf is exactly the kind of node a re-run should still handle gracefully).
        ip="$(grep -E '^[[:space:]]*Address[[:space:]]*=' /etc/wireguard/wg0.conf 2>/dev/null \
              | head -1 | awk -F= '{print $2}' | tr -d ' ')" || ip=""
        ip="${ip%%/*}"
        [[ -n "$ip" ]] && DETECTED_OVERLAY_SRC="/etc/wireguard/wg0.conf"
    fi
    [[ -n "$ip" ]] || return 1
    DETECTED_OVERLAY_IP="$ip"; return 0
}

prompt_overlay_ip() {
    if [[ -n "$OVERLAY_IP" ]]; then
        validate_overlay_ip "$OVERLAY_IP" || { print_error "Invalid overlay IP: ${OVERLAY_IP}"; exit 1; }
        return 0
    fi
    # Re-run on a node that already has WireGuard + an assigned IP: confirm reuse instead of
    # walking the full assignment spiel for an address that is already on the box.
    if detect_existing_install && validate_overlay_ip "$DETECTED_OVERLAY_IP"; then
        print_header "Existing VPN install detected"
        command -v wg >/dev/null 2>&1 && print_ok "WireGuard is installed (wg present)."
        print_ok "This node is already assigned overlay IP ${DETECTED_OVERLAY_IP} (from ${DETECTED_OVERLAY_SRC})."
        if wg show wg0 >/dev/null 2>&1; then print_info "Tunnel wg0 is currently up."; fi
        if confirm "Reuse overlay IP ${DETECTED_OVERLAY_IP}?"; then
            OVERLAY_IP="$DETECTED_OVERLAY_IP"
            return 0
        fi
        print_info "OK — enter a different overlay IP below."
    fi
    print_header "Overlay IP assignment"
    print_info "The Telcoin Association assigns each external node a unique overlay IP in the"
    print_info "external band (${TN_OVERLAY_EXTERNAL_BAND_HINT}+). Request one before continuing."
    print_info "Reserved nets you cannot use: ${TN_OVERLAY_RESERVED_NETS} (of 10.100.0.0/16)."
    echo ""
    while true; do
        read -r -p "  Assigned overlay IP (e.g. 10.100.20.7): " OVERLAY_IP
        validate_overlay_ip "$OVERLAY_IP" && break
        print_warn "Not a valid external overlay IP (10.100.0.0/16, not a reserved net, host 1-254)."
    done
}

# ensure_tnadmin_passwordless_login — tnadmin key-only with NO usable password, but
# not '!'-locked (see vpn_login_fix).
ensure_tnadmin_passwordless_login() {
    vpn_login_fix "$TNADMIN_USER"
}

capture_sshd_posture() {
    PRE_PWAUTH="$(sshd -T 2>/dev/null | awk '/^passwordauthentication /{print $2}' || true)"
    PRE_ROOT="$(sshd -T 2>/dev/null | awk '/^permitrootlogin /{print $2}' || true)"
}

# run_bootstrap ROOT -- run the vendored WireGuard bootstrap with the maintainer keys
# that pass KEYS and the local deny list, then replace the NOPASSWD:ALL sudoers file
# it writes (write_tnadmin_sudoers ROOT), also when it failed half-way.
run_bootstrap() {
    local root="${1:-false}" logf
    # Hub coordinates (public) from the vendored env file.
    # shellcheck source=/dev/null
    source "${WGVPN_DIR}/hub-coordinates.env"
    print_step "Running WireGuard node bootstrap (additive; dormant firewall)"
    logf="$(mktemp)"
    # All bootstrap inputs supplied via env so it never falls back to GCP metadata.
    # WG_NODE_ENFORCE=0  -> firewall installed but dormant (ufw stays active)
    # WG_NODE_PUBLIC_SSH=1 -> don't drop public :22 (operator keeps their access)
    # WG_NODE_SSHD_HARDEN=0 -> DON'T touch global sshd (we add a scoped drop-in)
    WG_HUB_ENDPOINT="$WG_HUB_ENDPOINT" \
    WG_HUB_PUBKEY="$WG_HUB_PUBKEY" \
    WG_OVERLAY_IP="$OVERLAY_IP" \
    TNADMIN_PUBKEYS="$TNADMIN_INSTALL" \
    PRIMARY_UDP_PORT="${DEFAULT_P2P_PORT}" \
    WORKER_UDP_PORT="${DEFAULT_WORKER_PORT}" \
    HEALTHCHECK_TCP_PORT="${TN_KUMA_PORT}" \
    HEALTHCHECK_MONITOR_SRC="${TN_KUMA_SRC}" \
    WG_NODE_ENFORCE=0 \
    WG_NODE_PUBLIC_SSH=1 \
    WG_NODE_SSHD_HARDEN=0 \
    bash "${WGVPN_DIR}/wg-node-bootstrap.sh" 2>&1 | tee "$logf" || true
    # The bootstrap grants tnadmin NOPASSWD:ALL; narrow it before anything else.
    if [[ -e "${R}${TNADMIN_SUDOERS}" ]]; then
        write_tnadmin_sudoers "$root" || true
    fi
    # The bootstrap's success signal is the WG_NODE_PUBKEY line it prints at the end;
    # `|| true` keeps a non-zero pipeline from aborting us before this check.
    WG_NODE_PUBKEY="$(sed -n 's/^WG_NODE_PUBKEY=//p' "$logf" | tail -1)"
    rm -f "$logf"
    if [[ -z "$WG_NODE_PUBKEY" ]]; then
        print_error "Bootstrap did not report a WG_NODE_PUBKEY -- it likely failed (see output above)."
        exit 1
    fi
    print_ok "WireGuard peer configured. Node pubkey: ${WG_NODE_PUBKEY}"
    ensure_tnadmin_passwordless_login
}

# write_scoped_sshd -- the tnadmin drop-in (vpn_sshd_apply): overlay maintainer
# range only, key only, checked with sshd -t and rolled back on failure.
write_scoped_sshd() {
    print_step "Adding scoped sshd drop-in (tnadmin only)"
    if ! vpn_reassert sshd; then
        print_error "sshd rejected the drop-in; your SSH is unchanged and the VPN is not enabled."
        exit 1
    fi
}

verify_sshd_unchanged() {
    local post_pw post_root
    post_pw="$(sshd -T 2>/dev/null | awk '/^passwordauthentication /{print $2}' || true)"
    post_root="$(sshd -T 2>/dev/null | awk '/^permitrootlogin /{print $2}' || true)"
    if [[ "$post_pw" == "$PRE_PWAUTH" && "$post_root" == "$PRE_ROOT" ]]; then
        print_ok "Verified: your global SSH posture is unchanged (passwordauth=${post_pw:-?}, permitrootlogin=${post_root:-?})."
    else
        print_warn "Global SSH posture changed (passwordauth ${PRE_PWAUTH:-?}->${post_pw:-?}, permitrootlogin ${PRE_ROOT:-?}->${post_root:-?})."
        print_warn "Review /etc/ssh/sshd_config.d/ -- the overlay drop-in should be scoped to tnadmin only."
    fi
}

# do_apply_firewall — idempotently admit SSH from the maintainer overlay range on the
# operator's ACTIVE firewall (ufw). Runs inside do_enable AND standalone
# (--apply-firewall) for operators who enable or tighten ufw AFTER enrollment, which is
# the common Cause-2 banner-timeout: ufw was inactive at enable time so no allow rule was
# ever added. Reuses allow_overlay_ssh (lib/common.sh), which dedups and drops the
# older whole-overlay rule, so re-running is safe.
do_apply_firewall() {
    print_step "Overlay SSH firewall rule (ufw)"
    local port; port="$(get_ssh_port)"; [[ -n "$port" ]] || port=22
    if ufw_installed && ufw_active; then
        if allow_overlay_ssh; then
            print_ok "ufw: SSH allowed from the maintainer range (${TN_OVERLAY_ADMIN_CIDR} -> :${port})."
        else
            print_warn "Could not add the overlay-SSH ufw rule; add it via firewall-setup.sh."
        fi
    elif ufw_installed; then
        print_warn "ufw is installed but INACTIVE — no inbound rule is enforced right now."
        print_info  "Nothing to do until you enable ufw. The moment you do, re-run:"
        print_info  "  sudo bash setup-vpn.sh --apply-firewall"
        print_info  "(equivalently: ufw allow from ${TN_OVERLAY_ADMIN_CIDR} to any port ${port} proto tcp)."
    else
        print_info "ufw is not installed — your active firewall is something else (or none)."
        print_info "Ensure it admits TCP ${TN_OVERLAY_ADMIN_CIDR} -> :${port} (overlay SSH). The node's"
        print_info "dormant nftables table already permits overlay SSH if you ever enforce it."
    fi
}

persist_state() {
    local root="${1:-false}"
    [[ -n "$VPN_META" ]] || return 0
    meta_set ENABLE_VPN true "$VPN_META"
    meta_set VPN_OVERLAY_IP "$OVERLAY_IP" "$VPN_META"
    meta_set VPN_NODE_PUBKEY "$WG_NODE_PUBKEY" "$VPN_META"
    meta_set VPN_MAINTAINER_ROOT "$root" "$VPN_META"
}

print_enrollment() {
    local node_name today
    node_name="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo node)"
    today="$(date +%Y-%m-%d 2>/dev/null || echo YYYY-MM-DD)"
    print_header "VPN enrollment -- send these to the Telcoin Association"
    cat <<EOF

  node_name:  ${node_name}
  overlay_ip: ${OVERLAY_IP}
  wg_pubkey:  ${WG_NODE_PUBKEY}

EOF
    print_info "Email/Slack these to the Association (or your enrollment channel). They add"
    print_info "you to the overlay registry + redeploy the hub. Until then your tunnel is up"
    print_info "but the hub won't accept your peer yet."
    echo ""
    print_info "For the Association admin -- ONE command registers this node (run from the"
    print_info "adiri-genesis checkout; it stamps the enrollment date and pushes the hub):"
    cat <<EOF

  ./common/wgvpn/add-node.sh ${node_name} ${OVERLAY_IP} ${WG_NODE_PUBKEY} "external <fill: e.g. Mobicom VPS>"

EOF
    print_info "Illustrative registry row (reference only -- the command above is authoritative"
    print_info "and writes the row itself with the real run-date):"
    cat <<EOF

  node,${node_name},${OVERLAY_IP},${WG_NODE_PUBKEY},${today},external <fill>

EOF
    print_info "After they confirm, verify the handshake:"
    print_info "  sudo wg show wg0        (peer ${TN_WG_HUB_ENDPOINT}, nonzero transfer)"
    print_info "Disable any time:  sudo bash setup-vpn.sh --disable"
}

do_enable() {
    local root
    print_header "Telcoin Network -- VPN admin SSH  v${SCRIPT_VERSION}"
    consent_gate
    addon_meta_write_begin || exit 1
    root="$(vpn_root_grant_wanted)" || exit 1
    prompt_overlay_ip
    assemble_pubkeys
    if [[ -z "$TNADMIN_INSTALL" ]]; then
        print_error "Every maintainer key is blocked in ${VPN_REVOKED_FILE}; there is nothing to enable."
        exit 1
    fi
    vpn_tnadmin_home_safe || exit 1
    capture_sshd_posture
    run_bootstrap "$root"
    write_tnadmin_keys
    write_scoped_sshd
    verify_sshd_unchanged
    do_apply_firewall
    persist_state "$root"
    install_selfheal_units || true
    nudge_handshake
    print_enrollment
}

# =============================================================================
# Self-service: --sync-keys / --status / --apply-firewall / --selfheal
# The operator analog of the admin's sync-access.sh: verify and repair the tunnel +
# firewall, or re-apply the maintainer key set after an update, with NO admin needed.
# =============================================================================

# nudge_handshake — force an immediate hub handshake instead of waiting up to one
# keepalive interval (25s). Best-effort and safe: wg0 is Table=off, so a ping to the
# hub touches only the overlay, never the default route / consensus path.
nudge_handshake() {
    if command -v wg >/dev/null 2>&1 && wg show wg0 >/dev/null 2>&1; then
        print_step "Nudging the hub handshake (ping ${HUB_OVERLAY_IP})"
        if ping -c1 -W2 "$HUB_OVERLAY_IP" >/dev/null 2>&1; then
            print_ok "Hub ${HUB_OVERLAY_IP} answered over the overlay — tunnel is carrying traffic."
        else
            print_info "No reply from ${HUB_OVERLAY_IP} yet. Either the tunnel is still converging,"
            print_info "or the Association has not added your peer to the hub yet. Re-check with:"
            print_info "  sudo wg show wg0   (look for a recent handshake + nonzero transfer)"
        fi
    else
        print_warn "wg0 is not up — skipping the handshake nudge."
        print_info  "Bring it up:  sudo wg-quick up wg0   (then: sudo bash setup-vpn.sh --status)"
    fi
}

# do_sync_keys — re-apply the maintainer key set from KEYS (minus the local deny list),
# re-write the tnadmin sudo scope and the self-heal helper (migrating an old unit).
# Reads ONLY local files, so it works before overlay connectivity is fixed.
# Idempotent: the key file is byte-stable across repeat runs.
do_sync_keys() {
    local root
    print_header "Telcoin Network -- refresh maintainer SSH keys  v${SCRIPT_VERSION}"
    if ! getent passwd "$TNADMIN_USER" >/dev/null 2>&1; then
        print_error "User '${TNADMIN_USER}' does not exist on this node."
        print_info  "Run the enable flow first:  sudo bash setup-vpn.sh"
        exit 1
    fi
    if [[ -n "$ROOT_GRANT" ]]; then
        addon_meta_write_begin || exit 1
    fi
    root="$(vpn_root_grant_wanted)" || exit 1
    assemble_pubkeys
    write_tnadmin_keys
    write_tnadmin_sudoers "$root" || true
    if [[ -n "$ROOT_GRANT" && -n "$VPN_META" ]]; then
        meta_set VPN_MAINTAINER_ROOT "$root" "$VPN_META"
    fi
    install_selfheal_units || true
    nudge_handshake
    print_info "Done. Confirm the full picture with:  sudo bash setup-vpn.sh --status"
}

# do_status — PASS/FAIL triage, one check per ranked banner-timeout cause, each failure
# printing the exact fix command. Read-only; never changes node state. Any network.
do_status() {
    print_header "Telcoin Network -- VPN admin SSH status  v${SCRIPT_VERSION}"
    local issues=0
    local port; port="$(get_ssh_port)"; [[ -n "$port" ]] || port=22

    # 1) wg0 up + hub handshake freshness (Cause 1: tunnel not converged) ----------
    print_step "1) WireGuard tunnel + hub handshake"
    if command -v wg >/dev/null 2>&1 && wg show wg0 >/dev/null 2>&1; then
        print_ok "wg0 interface is up."
        local hs now age
        # Max timestamp across peers (a node has exactly one peer: the hub). awk reads
        # all input so head/SIGPIPE never trips pipefail; prints 0 when there are none.
        hs="$(wg show wg0 latest-handshakes 2>/dev/null | awk 'BEGIN{m=0}{if($2>m)m=$2}END{print m+0}')" || hs=0
        now="$(date +%s)"; age=$(( now - hs ))
        if [[ "$hs" -eq 0 ]]; then
            print_warn "No handshake with the hub yet (never)."
            print_info  "Fix: make sure the Association added your peer, then nudge it:"
            print_info  "     ping -c1 ${HUB_OVERLAY_IP}    (re-check: sudo wg show wg0)"
            (( ++issues ))
        elif [[ "$age" -lt 180 ]]; then
            print_ok "Recent hub handshake (${age}s ago)."
        else
            print_warn "Stale hub handshake (${age}s ago; a live tunnel re-handshakes well under 180s)."
            print_info  "Fix: ping -c1 ${HUB_OVERLAY_IP} to force one. If it stays stale, the hub may"
            print_info  "     not have your CURRENT pubkey — re-send wg_pubkey (sudo wg show wg0) to the Association."
            (( ++issues ))
        fi
    else
        print_warn "wg0 is not up (the WireGuard tunnel is down)."
        print_info  "Fix: sudo wg-quick up wg0    (then re-run --status)"
        (( ++issues ))
    fi

    # 2) wg-quick@wg0 enabled — survives a reboot (Cause 3) ------------------------
    print_step "2) Tunnel persistence across reboot"
    if systemctl is-enabled wg-quick@wg0 >/dev/null 2>&1; then
        print_ok "wg-quick@wg0 is enabled (the tunnel returns after a reboot)."
    else
        print_warn "wg-quick@wg0 is NOT enabled — the tunnel will be gone after a reboot."
        print_info  "Fix: sudo systemctl enable wg-quick@wg0"
        (( ++issues ))
    fi

    # 3) maintainer key set present and current (Cause 4 / completeness) ------------
    print_step "3) Maintainer SSH keys (tnadmin)"
    local n expected cur
    if [[ -f "$TNV_AUTH" && ! -L "$TNV_AUTH" ]]; then
        n="$(grep -c '[^[:space:]]' "$TNV_AUTH" 2>/dev/null)" || n=0
        expected="$(vpn_keys_from_list "$VPN_KEYS_DIR" 2>/dev/null | vpn_filter_keys "$TNV_REVOKED" 2>/dev/null)" || expected=""
        cur="$(cat -- "$TNV_AUTH" 2>/dev/null)" || cur=""
        if [[ "$n" -eq 0 ]]; then
            print_warn "${VPN_AUTH_FILE} is empty — no maintainer can log in."
            print_info  "Fix: sudo bash setup-vpn.sh --sync-keys   (or check ${VPN_REVOKED_FILE})"
            (( ++issues ))
        else
            print_ok "${n} maintainer key(s) installed for ${TNADMIN_USER} (${VPN_AUTH_FILE})."
        fi
        if [[ -n "$expected" && "$cur" != "$expected" ]]; then
            print_warn "The installed keys differ from KEYS minus ${VPN_REVOKED_FILE}."
            print_info  "Fix: sudo bash setup-vpn.sh --sync-keys"
            (( ++issues ))
        fi
    else
        print_warn "No ${VPN_AUTH_FILE} — is the VPN enabled on this node (or not yet migrated)?"
        print_info  "Fix: sudo bash setup-vpn.sh --sync-keys   (or enable: sudo bash setup-vpn.sh)"
        (( ++issues ))
    fi

    # 3b) tnadmin account login-enabled — the '!'-lock regression (Part 1). Reads the shadow
    #     field directly (status runs as root) so it tells the desired '*' from a broken '!'.
    print_step "3b) tnadmin account login-enabled (key-only)"
    local pwf; pwf="$(getent shadow "$TNADMIN_USER" 2>/dev/null | cut -d: -f2)" || pwf=""
    case "$pwf" in
        '!'*) print_warn "${TNADMIN_USER} password is '!'-LOCKED — PAM can refuse the key login on some nodes."
              print_info  "Fix: sudo bash setup-vpn.sh --selfheal   (sets it password-less but login-enabled)"
              (( ++issues )) ;;
        '')   print_warn "${TNADMIN_USER} shadow password field is EMPTY (passwordless login risk / no entry)."
              print_info  "Fix: sudo bash setup-vpn.sh --selfheal"
              (( ++issues )) ;;
        '*')  print_ok "${TNADMIN_USER} is password-less ('*') and login-enabled." ;;
        *)    print_ok "${TNADMIN_USER} login-enabled (has a password set)." ;;
    esac

    # 4) scoped sshd drop-in present, current and config valid -----------------------
    print_step "4) Scoped sshd drop-in"
    if [[ -f "$TNV_DROPIN" ]]; then
        if sshd -t 2>/dev/null; then
            print_ok "Drop-in present and 'sshd -t' validates."
        else
            print_warn "Drop-in present but 'sshd -t' reports an error — sshd may refuse to reload."
            print_info  "Fix: sudo sshd -t    (read the error); the drop-in is ${SCOPED_SSHD_DROPIN}"
            (( ++issues ))
        fi
        if [[ "$(cat -- "$TNV_DROPIN" 2>/dev/null)" != "$(vpn_dropin_text "$TNV_CIDR" "$TNV_AUTH_PATH")" ]]; then
            print_warn "The drop-in is not the current version (maintainer range ${TN_OVERLAY_ADMIN_CIDR}, root-owned key file)."
            print_info  "Fix: sudo bash setup-vpn.sh --selfheal"
            (( ++issues ))
        fi
    else
        print_warn "Scoped sshd drop-in is missing (${SCOPED_SSHD_DROPIN})."
        print_info  "Fix: sudo bash setup-vpn.sh    (re-enable reinstalls it)"
        (( ++issues ))
    fi

    # 5) ACTIVE firewall admits the maintainer range -> :ssh (Cause 2) ---------------
    print_step "5) Firewall: maintainer range -> SSH (:${port})"
    local ufw_out=""
    if ufw_installed && ufw_active; then
        ufw_out="$(ufw status 2>/dev/null)" || ufw_out=""
        if grep -F "$TN_OVERLAY_ADMIN_CIDR" <<<"$ufw_out" | grep -q ALLOW; then
            print_ok "ufw allows ${TN_OVERLAY_ADMIN_CIDR} -> :${port}."
        else
            print_warn "ufw is ACTIVE but has no allow rule for ${TN_OVERLAY_ADMIN_CIDR} — inbound SSH is dropped."
            print_info  "Fix: sudo bash setup-vpn.sh --apply-firewall"
            (( ++issues ))
        fi
        if [[ "$TN_OVERLAY_CIDR" != "$TN_OVERLAY_ADMIN_CIDR" ]] \
            && grep -F "$TN_OVERLAY_CIDR" <<<"$ufw_out" | grep -q ALLOW; then
            print_warn "ufw still admits the whole overlay (${TN_OVERLAY_CIDR}); only the maintainer range is needed."
            print_info  "Fix: sudo bash setup-vpn.sh --apply-firewall   (it removes the older rule)"
            (( ++issues ))
        fi
    elif ufw_installed; then
        print_info "ufw is installed but inactive — its rules are not enforced (nftables table is dormant)."
        print_info "If you enable ufw later, run: sudo bash setup-vpn.sh --apply-firewall"
    else
        print_info "ufw is not installed — overlay SSH relies on whatever firewall is active (or none)."
        print_info "Ensure TCP ${TN_OVERLAY_ADMIN_CIDR} -> :${port} is admitted there."
    fi

    # 6) self-heal helper + tnadmin sudo scope -----------------------------------------
    print_step "6) Self-heal helper and tnadmin sudo scope"
    if [[ -f "$TNV_SERVICE_UNIT" ]]; then
        if grep -qxF "ExecStart=${SELFHEAL_BIN}" "$TNV_SERVICE_UNIT" && vpn_root_file_ok "$TNV_SELF"; then
            print_ok "Self-heal runs the root-owned ${SELFHEAL_BIN}."
        else
            print_warn "The self-heal unit does not run the root-owned ${SELFHEAL_BIN} (an older unit, or the helper is missing)."
            print_info  "Fix: sudo bash setup-vpn.sh --selfheal"
            (( ++issues ))
        fi
    else
        print_warn "The self-heal units are not installed."
        print_info  "Fix: sudo bash setup-vpn.sh --sync-keys"
        (( ++issues ))
    fi
    local sudo_f="${R}${TNADMIN_SUDOERS}" granted
    granted="$(addon_meta_get VPN_MAINTAINER_ROOT false 2>/dev/null)" || granted="false"
    if [[ -f "$sudo_f" ]] && grep -qE 'NOPASSWD:[[:space:]]*ALL' "$sudo_f" 2>/dev/null; then
        if [[ "$granted" == true ]]; then
            print_info "tnadmin has full root (granted with --grant-maintainer-root)."
        else
            print_warn "tnadmin has full root (NOPASSWD:ALL) that was never granted with --grant-maintainer-root."
            print_info  "Fix: sudo bash setup-vpn.sh --sync-keys   (writes the recovery command list)"
            (( ++issues ))
        fi
    elif [[ -f "$sudo_f" ]]; then
        print_ok "tnadmin sudo is limited to the node recovery commands."
    else
        print_info "No ${TNADMIN_SUDOERS}: tnadmin has no sudo."
    fi

    # Summary ---------------------------------------------------------------------
    echo ""
    if [[ "$issues" -eq 0 ]]; then
        print_ok "All checks passed — a maintainer should be able to tn_ssh this node."
    else
        print_warn "${issues} check(s) need attention — apply the Fix line under each above."
    fi
}

# do_selfheal (H3) — the manual (and older-unit) re-assert. On a host that is not
# testnet or devnet it removes the self-heal units and helper and stops. Otherwise it
# records the KEYS set, narrows the tnadmin sudo scope, installs the root-owned helper
# and units (an older unit ran this script from the scripts directory; this rewrites
# it), then re-asserts everything in this process (vpn_reassert all). Self-writes are
# content-conditional, so a steady-state heal touches no watched file and never
# re-triggers tn-vpn-selfheal.path. Reads only local files — needs no overlay.
do_selfheal() {
    local root
    print_header "Telcoin Network -- VPN admin SSH self-heal  v${SCRIPT_VERSION}"
    if ! is_testnet_like; then
        print_warn "NETWORK is '${NETWORK:-unset}': the VPN add-on is testnet-only."
        print_info "Removing the self-heal units and helper; run 'sudo bash setup-vpn.sh --disable' to remove the rest."
        vpn_remove_selfheal
        return 0
    fi
    root="$(vpn_root_grant_wanted)" || exit 1
    assemble_pubkeys
    if ! install_keys_file; then
        print_error "Could not write ${VPN_KEYS_FILE}."
        exit 1
    fi
    if [[ -e "${R}${TNADMIN_SUDOERS}" ]]; then
        write_tnadmin_sudoers "$root" || true
    fi
    install_selfheal_units || true
    if ! vpn_reassert all; then
        print_warn "Self-heal finished with problems (see above)."
        exit 1
    fi
    print_ok "Self-heal pass complete."
}

# =============================================================================
# Disable / teardown (any network)
# =============================================================================

do_disable() {
    print_header "Disable VPN admin SSH"
    if ! confirm "Tear down the WireGuard overlay + tnadmin access on this node?"; then
        print_info "Cancelled -- no changes made."
        exit 0
    fi
    # The lock only: a teardown never runs the ownership migration, so it works on a
    # host laid out by an older release (where the migration may refuse).
    if [[ -n "$VPN_META" ]]; then
        addon_meta_lock || exit 1
    fi

    # Remove the self-heal units FIRST, so the path watcher can't re-assert the drop-in /
    # tunnel while we tear them down below.
    print_step "Removing the VPN self-heal units and helper"
    vpn_remove_selfheal

    print_step "Bringing down wg0"
    wg-quick down wg0 2>/dev/null || true
    systemctl disable wg-quick@wg0.service >/dev/null 2>&1 || true
    rm -f "${R}/etc/wireguard/wg0.conf" "${R}/etc/wireguard/wg0-private.key"

    print_step "Removing scoped sshd drop-in and maintainer keys"
    rm -f "$TNV_DROPIN" "$TNV_KEYS" "$TNV_AUTH"
    if sshd -t 2>/dev/null; then
        systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
    fi
    if [[ -f "$TNV_REVOKED" ]]; then
        print_info "Kept your local deny list ${VPN_REVOKED_FILE}."
    fi

    print_step "Removing the dormant host firewall table + helpers"
    systemctl disable --now tn-nftables.service >/dev/null 2>&1 || true
    rm -f "${R}/etc/systemd/system/tn-nftables.service" "${R}/etc/wgvpn/nftables-node.nft" "${R}/usr/local/sbin/tn-node-ssh-lockdown"
    rmdir "${R}${VPN_STATE_DIR}" 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true

    if ufw_installed; then
        local port cidr; port="$(get_ssh_port)"; [[ -n "$port" ]] || port=22
        for cidr in "$TN_OVERLAY_ADMIN_CIDR" "$TN_OVERLAY_CIDR"; do
            ufw delete allow from "$cidr" to any port "${port}" proto tcp >/dev/null 2>&1 || true
        done
        print_ok "Removed the overlay-SSH ufw rules."
    fi

    if confirm "Also remove the 'tnadmin' user and its sudo access?"; then
        userdel -r tnadmin 2>/dev/null || true
        rm -f "${R}${TNADMIN_SUDOERS}"
        print_ok "tnadmin user removed."
    else
        print_info "Left the tnadmin user in place (its overlay reachability is already gone)."
    fi

    if [[ -n "$VPN_META" ]] && ! meta_set ENABLE_VPN false "$VPN_META"; then
        print_warn "ENABLE_VPN=false could not be written to ${VPN_META} (a host laid out by an older release refuses the write until its ownership is migrated); the VPN itself is torn down."
    fi
    print_ok "VPN admin SSH disabled. Your own SSH is unchanged."
    print_info "Ask the Telcoin Association to remove your peer from the overlay registry."
}

# =============================================================================
# Args + main
# =============================================================================

usage() {
    awk 'NR > 1 && /^# =+$/ { n++; if (n == 2) exit; next } NR > 1 && /^#/ { sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --disable)                   MODE="disable";        shift ;;
            --sync-keys|--refresh-keys)  MODE="sync-keys";      shift ;;
            --status|--verify)           MODE="status";         shift ;;
            --apply-firewall)            MODE="apply-firewall"; shift ;;
            --selfheal)                  MODE="selfheal";       shift ;;
            --accept-vpn-consent)        ACCEPT_CONSENT=true;   shift ;;
            --grant-maintainer-root)     ROOT_GRANT="grant";    shift ;;
            --revoke-maintainer-root)    ROOT_GRANT="revoke";   shift ;;
            --overlay-ip)                OVERLAY_IP="${2:-}";   shift 2 ;;
            --overlay-ip=*)              OVERLAY_IP="${1#*=}";  shift ;;
            -h|--help)                   usage; exit 0 ;;
            *) print_warn "Ignoring unknown argument: $1"; shift ;;
        esac
    done
    if [[ -n "$ROOT_GRANT" && "$MODE" != enable && "$MODE" != sync-keys ]]; then
        print_error "--grant-maintainer-root / --revoke-maintainer-root go with the enable flow or --sync-keys."
        exit 1
    fi
}

# vpn_require_lib -- exit 2 before anything else when lib/common.sh lacks a helper
# this script calls (scripts updated without the library); the message names
# update-scripts.sh.
vpn_require_lib() {
    local fn missing=""
    for fn in addon_meta_get addon_meta_lock addon_meta_write_begin tn_write_root_file \
              tn_root_dir_ok tn_acquire_update_lock validate_health_src allow_overlay_ssh \
              is_testnet_like require_testnet; do
        declare -F "$fn" >/dev/null 2>&1 || missing="${missing:+${missing}, }${fn}"
    done
    [[ -z "$missing" ]] && return 0
    print_error "lib/common.sh is older than this script (it lacks ${missing}): run update-scripts.sh, then this again. Nothing was changed."
    exit 2
}

main() {
    parse_args "$@"
    vpn_require_lib
    check_root
    detect_distro
    require_apt
    vpn_init_paths
    load_node_context
    # Only the verbs that add access are testnet-only; --status and --disable work on
    # any network, and --selfheal removes its own units off testnet.
    case "$MODE" in
        enable|sync-keys|apply-firewall) require_testnet ;;
    esac

    case "$MODE" in
        enable)         do_enable ;;
        disable)        do_disable ;;
        sync-keys)      do_sync_keys ;;
        status)         do_status ;;
        apply-firewall) do_apply_firewall ;;
        selfheal)       do_selfheal ;;
    esac
}

main "$@"
