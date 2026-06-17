#!/usr/bin/env bash
# =============================================================================
# setup-vpn.sh -- Telcoin testnet add-on: WireGuard admin SSH overlay
#
# Opt-in, testnet-only, reversible. Joins this node to the Telcoin Association's
# private WireGuard overlay and grants the core team SSH (via a sudo-capable
# 'tnadmin' user) ONLY over that overlay -- e.g. to help recover a stuck node.
# It is ADDITIVE: your own SSH/login configuration is never touched (the global
# sshd hardening in the bootstrap is skipped; a scoped `Match User tnadmin`
# drop-in is added instead), the host nftables table is installed DORMANT (ufw
# stays your only active firewall), and wg0 uses Table=off so your default route
# and consensus path are untouched.
#
# Because the overlay can reach a box that may hold your validator BLS keys,
# consent is EXPLICIT and the whole thing is reversible: setup-vpn.sh --disable.
#
# USAGE:
#   sudo bash setup-vpn.sh                          # interactive enable
#   sudo bash setup-vpn.sh --overlay-ip 10.100.20.7 # non-interactive IP
#   sudo bash setup-vpn.sh --accept-vpn-consent     # skip the consent prompt (UI)
#   sudo bash setup-vpn.sh --disable                # tear everything down
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

readonly SCRIPT_VERSION="1.0.0"
readonly WGVPN_DIR="${SCRIPT_DIR}/lib/wgvpn"
readonly SCOPED_SSHD_DROPIN="/etc/ssh/sshd_config.d/15-tnadmin-overlay.conf"

MODE="enable"
ACCEPT_CONSENT=false
OVERLAY_IP=""
NETWORK=""          # read from .node-meta; consumed by require_testnet (is_testnet)
WG_NODE_PUBKEY=""
PRE_PWAUTH=""
PRE_ROOT=""

# -----------------------------------------------------------------------------
# Preconditions
# -----------------------------------------------------------------------------

require_apt() {
    if ! command -v apt-get >/dev/null 2>&1; then
        print_error "setup-vpn.sh needs an apt-based distro (Debian/Ubuntu)."
        print_info  "The WireGuard bootstrap installs wireguard-tools + nftables via apt-get."
        exit 1
    fi
}

load_node_context() {
    local meta
    meta="$(node_meta_path || true)"
    if [[ -z "$meta" ]]; then
        print_error "No Telcoin node detected (no /etc/telcoin/{validator,observer}/.node-meta)."
        print_info  "Run setup-validator.sh or setup-observer.sh first."
        exit 1
    fi
    # shellcheck disable=SC2034  # consumed cross-file by require_testnet (is_testnet)
    NETWORK="$(meta_get NETWORK "$meta" 2>/dev/null || true)"
}

# -----------------------------------------------------------------------------
# Enable
# -----------------------------------------------------------------------------

consent_gate() {
    [[ "$ACCEPT_CONSENT" == "true" ]] && return 0
    print_header "VPN admin SSH -- consent required"
    print_warn "This grants the Telcoin Association root-capable SSH (a sudo 'tnadmin' user)"
    print_warn "to THIS node over a private WireGuard overlay. This box may hold your"
    print_warn "validator BLS keys. It is reversible at any time: setup-vpn.sh --disable."
    echo ""
    print_info "What it does and does NOT touch:"
    print_info "  * adds a 'tnadmin' user reachable ONLY from the overlay (10.100.0.0/16)"
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

prompt_overlay_ip() {
    if [[ -n "$OVERLAY_IP" ]]; then
        validate_overlay_ip "$OVERLAY_IP" || { print_error "Invalid overlay IP: ${OVERLAY_IP}"; exit 1; }
        return 0
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

assemble_pubkeys() {
    local d="${WGVPN_DIR}/peers/ssh" f
    TNADMIN_PUBKEYS=""
    for f in "$d"/*.pub; do
        [[ -e "$f" ]] || continue
        TNADMIN_PUBKEYS+="$(cat "$f")"$'\n'
    done
    if [[ -z "$TNADMIN_PUBKEYS" ]]; then
        print_error "No maintainer SSH keys found in ${d}. Re-install scripts and retry."
        exit 1
    fi
    export TNADMIN_PUBKEYS
}

capture_sshd_posture() {
    PRE_PWAUTH="$(sshd -T 2>/dev/null | awk '/^passwordauthentication /{print $2}' || true)"
    PRE_ROOT="$(sshd -T 2>/dev/null | awk '/^permitrootlogin /{print $2}' || true)"
}

run_bootstrap() {
    # Hub coordinates (public) from the vendored env file.
    # shellcheck source=/dev/null
    source "${WGVPN_DIR}/hub-coordinates.env"
    print_step "Running WireGuard node bootstrap (additive; dormant firewall)"
    local logf; logf="$(mktemp)"
    # All bootstrap inputs supplied via env so it never falls back to GCP metadata.
    # WG_NODE_ENFORCE=0  -> firewall installed but dormant (ufw stays active)
    # WG_NODE_PUBLIC_SSH=1 -> don't drop public :22 (operator keeps their access)
    # WG_NODE_SSHD_HARDEN=0 -> DON'T touch global sshd (we add a scoped drop-in)
    WG_HUB_ENDPOINT="$WG_HUB_ENDPOINT" \
    WG_HUB_PUBKEY="$WG_HUB_PUBKEY" \
    WG_OVERLAY_IP="$OVERLAY_IP" \
    TNADMIN_PUBKEYS="$TNADMIN_PUBKEYS" \
    PRIMARY_UDP_PORT="${DEFAULT_P2P_PORT}" \
    WORKER_UDP_PORT="${DEFAULT_WORKER_PORT}" \
    HEALTHCHECK_TCP_PORT="${TN_KUMA_PORT}" \
    HEALTHCHECK_MONITOR_SRC="${TN_KUMA_SRC}" \
    WG_NODE_ENFORCE=0 \
    WG_NODE_PUBLIC_SSH=1 \
    WG_NODE_SSHD_HARDEN=0 \
    bash "${WGVPN_DIR}/wg-node-bootstrap.sh" 2>&1 | tee "$logf" || true
    # The bootstrap's success signal is the WG_NODE_PUBKEY line it prints at the end;
    # `|| true` keeps a non-zero pipeline from aborting us before this check.
    WG_NODE_PUBKEY="$(sed -n 's/^WG_NODE_PUBKEY=//p' "$logf" | tail -1)"
    rm -f "$logf"
    if [[ -z "$WG_NODE_PUBKEY" ]]; then
        print_error "Bootstrap did not report a WG_NODE_PUBKEY -- it likely failed (see output above)."
        exit 1
    fi
    print_ok "WireGuard peer configured. Node pubkey: ${WG_NODE_PUBKEY}"
    # Belt-and-suspenders: ensure the tnadmin account is explicitly key-only (no usable
    # password), independent of the distro's useradd defaults.
    passwd -l tnadmin >/dev/null 2>&1 || true
}

write_scoped_sshd() {
    print_step "Adding scoped sshd drop-in (tnadmin only)"
    install -d -m 755 /etc/ssh/sshd_config.d
    # The trust model (and the consent text) promise tnadmin is reachable ONLY over the
    # overlay. Enforce that at the sshd layer so it holds regardless of the operator's
    # firewall state (ufw inactive, nftables dormant, public :22 left open, etc.).
    local overlay_cidr="${TN_OVERLAY_CIDR:-10.100.0.0/16}"
    cat > "$SCOPED_SSHD_DROPIN" <<EOF
# Telcoin VPN admin access (testnet add-on). SCOPED to the tnadmin user ONLY, so your
# own SSH configuration is untouched. tnadmin may authenticate with the maintainer keys
# in authorized_keys.tnvpn (written by wg-node-bootstrap.sh) and ONLY over the WireGuard
# overlay (${overlay_cidr}); from any other source address it has no usable auth method.
#
# sshd uses FIRST-MATCH-WINS, so the specific overlay-allow block MUST come BEFORE the
# general deny block:
#   1) from the overlay  -> publickey auth with the maintainer keys (this block wins);
#   2) from anywhere else -> publickey-only but with NO keys (/dev/null) => cannot log in.
# (AuthenticationMethods=publickey also forces pubkey-only, so password / keyboard-
# interactive are off without version-specific keywords like KbdInteractiveAuthentication.)
Match User tnadmin Address ${overlay_cidr}
    AuthenticationMethods publickey
    PubkeyAuthentication yes
    PasswordAuthentication no
    AuthorizedKeysFile .ssh/authorized_keys .ssh/authorized_keys.tnvpn
Match User tnadmin
    AuthenticationMethods publickey
    PubkeyAuthentication no
    PasswordAuthentication no
    AuthorizedKeysFile /dev/null
EOF
    if sshd -t 2>/dev/null; then
        systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
        print_ok "Scoped sshd drop-in installed + validated (tnadmin: overlay-only, key-only)."
    else
        rm -f "$SCOPED_SSHD_DROPIN"
        print_error "sshd -t failed; reverted the drop-in. Your SSH is unchanged; VPN not enabled."
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

apply_overlay_firewall() {
    if ufw_installed && ufw_active; then
        if allow_overlay_ssh; then
            print_ok "ufw: SSH allowed from the overlay (${TN_OVERLAY_CIDR})."
        else
            print_warn "Could not add the overlay-SSH ufw rule; add it via firewall-setup.sh."
        fi
    else
        print_info "ufw not active. When you enable it, allow SSH from ${TN_OVERLAY_CIDR}"
        print_info "(firewall-setup.sh -> 'Manage testnet add-on rules')."
    fi
}

persist_state() {
    local meta; meta="$(node_meta_path || true)"
    if [[ -n "$meta" ]]; then
        meta_set ENABLE_VPN true "$meta"
        meta_set VPN_OVERLAY_IP "$OVERLAY_IP" "$meta"
        meta_set VPN_NODE_PUBKEY "$WG_NODE_PUBKEY" "$meta"
    fi
}

print_enrollment() {
    local node_name; node_name="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo node)"
    print_header "VPN enrollment -- send these 3 values to the Telcoin Association"
    cat <<EOF

  node_name:  ${node_name}
  overlay_ip: ${OVERLAY_IP}
  wg_pubkey:  ${WG_NODE_PUBKEY}

EOF
    print_info "Email/Slack these to the Association (or your enrollment channel). They add"
    print_info "you to the overlay registry + redeploy the hub. Until then your tunnel is up"
    print_info "but the hub won't accept your peer yet."
    print_info "After they confirm, verify the handshake:"
    print_info "  sudo wg show wg0        (peer ${TN_WG_HUB_ENDPOINT}, nonzero transfer)"
    print_info "Disable any time:  sudo bash setup-vpn.sh --disable"
}

do_enable() {
    print_header "Telcoin Network -- VPN admin SSH  v${SCRIPT_VERSION}"
    consent_gate
    prompt_overlay_ip
    assemble_pubkeys
    capture_sshd_posture
    run_bootstrap
    write_scoped_sshd
    verify_sshd_unchanged
    apply_overlay_firewall
    persist_state
    print_enrollment
}

# -----------------------------------------------------------------------------
# Disable / teardown
# -----------------------------------------------------------------------------

do_disable() {
    print_header "Disable VPN admin SSH"
    if ! confirm "Tear down the WireGuard overlay + tnadmin access on this node?"; then
        print_info "Cancelled -- no changes made."
        exit 0
    fi

    print_step "Bringing down wg0"
    wg-quick down wg0 2>/dev/null || true
    systemctl disable wg-quick@wg0.service >/dev/null 2>&1 || true
    rm -f /etc/wireguard/wg0.conf /etc/wireguard/wg0-private.key

    print_step "Removing scoped sshd drop-in"
    rm -f "$SCOPED_SSHD_DROPIN"
    if sshd -t 2>/dev/null; then
        systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
    fi

    print_step "Removing the dormant host firewall table + helpers"
    systemctl disable --now tn-nftables.service >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/tn-nftables.service /etc/wgvpn/nftables-node.nft /usr/local/sbin/tn-node-ssh-lockdown
    rmdir /etc/wgvpn 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true

    if ufw_installed && ufw_active; then
        local port; port="$(get_ssh_port)"; [[ -n "$port" ]] || port=22
        ufw delete allow from "${TN_OVERLAY_CIDR}" to any port "${port}" proto tcp &>/dev/null || true
        print_ok "Removed the overlay-SSH ufw rule."
    fi

    if confirm "Also remove the 'tnadmin' user and its sudo access?"; then
        userdel -r tnadmin 2>/dev/null || true
        rm -f /etc/sudoers.d/90-tnadmin
        print_ok "tnadmin user removed."
    else
        print_info "Left the tnadmin user in place (its overlay reachability is already gone)."
    fi

    local meta; meta="$(node_meta_path || true)"; [[ -n "$meta" ]] && meta_set ENABLE_VPN false "$meta"
    print_ok "VPN admin SSH disabled. Your own SSH is unchanged."
    print_info "Ask the Telcoin Association to remove your peer from the overlay registry."
}

# -----------------------------------------------------------------------------
# Args + main
# -----------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
    case "$1" in
        --disable)             MODE="disable"; shift ;;
        --accept-vpn-consent)  ACCEPT_CONSENT=true; shift ;;
        --overlay-ip)          OVERLAY_IP="${2:-}"; shift 2 ;;
        --overlay-ip=*)        OVERLAY_IP="${1#*=}"; shift ;;
        -h|--help)
            grep -E '^#( |$)' "$0" | sed -E 's/^# ?//'; exit 0 ;;
        *) print_warn "Ignoring unknown argument: $1"; shift ;;
    esac
done

check_root
detect_distro
require_apt
load_node_context
require_testnet

case "$MODE" in
    enable)  do_enable ;;
    disable) do_disable ;;
esac
