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
#   sudo bash setup-vpn.sh --status                 # diagnose tunnel + keys + firewall
#   sudo bash setup-vpn.sh --sync-keys              # re-apply the maintainer SSH key set
#   sudo bash setup-vpn.sh --apply-firewall         # (re)add the overlay->SSH ufw rule
#   sudo bash setup-vpn.sh --selfheal               # re-assert tunnel + drop-in + keys (run by the self-heal units)
#   sudo bash setup-vpn.sh --disable                # tear everything down
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

readonly SCRIPT_VERSION="1.2.0"
readonly WGVPN_DIR="${SCRIPT_DIR}/lib/wgvpn"
readonly SCOPED_SSHD_DROPIN="/etc/ssh/sshd_config.d/15-tnadmin-overlay.conf"
# Self-heal units (H3): a boot-time oneshot + an on-change path watcher that re-assert
# the overlay tunnel + scoped drop-in + maintainer keys, so an openssh upgrade, reboot,
# or cloud-init reset can never silently relock an external node out of maintainer SSH.
readonly SELFHEAL_SERVICE="/etc/systemd/system/tn-vpn-selfheal.service"
readonly SELFHEAL_PATH_UNIT="/etc/systemd/system/tn-vpn-selfheal.path"
# The ops user the maintainer keys authorize, and the hub's fixed overlay IP. Both
# mirror wg-node-bootstrap.sh (WG_TNADMIN_USER default) and the hub's wg0 address —
# the self-service verbs below read them, never re-derive them.
readonly TNADMIN_USER="tnadmin"
readonly HUB_OVERLAY_IP="10.100.0.1"

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

# write_tnadmin_keys — install the already-assembled $TNADMIN_PUBKEYS into tnadmin's
# authorized_keys.tnvpn. Mirrors wg-node-bootstrap.sh's own writer (same path, owner,
# mode) so an enable and a later --sync-keys converge on the same file. assemble_pubkeys
# MUST have run first (it refuses an empty key dir, so this can never blank the file).
write_tnadmin_keys() {
    local home
    home="$(getent passwd "$TNADMIN_USER" | cut -d: -f6 2>/dev/null || true)"
    if [[ -z "$home" ]]; then
        print_error "User '${TNADMIN_USER}' does not exist on this node."
        print_info  "Run the enable flow first:  sudo bash setup-vpn.sh"
        exit 1
    fi
    install -d -m 700 -o "$TNADMIN_USER" -g "$TNADMIN_USER" "${home}/.ssh"
    local akf="${home}/.ssh/authorized_keys.tnvpn"
    # $TNADMIN_PUBKEYS already ends in a newline (assemble_pubkeys trails each key with
    # one), so write it verbatim — no extra '\n' that would drift the file vs a re-run.
    local desired; desired="$(mktemp)"
    printf '%s' "$TNADMIN_PUBKEYS" > "$desired"
    # Idempotent: skip the rewrite when the on-disk set already matches byte-for-byte, so a
    # boot/self-heal pass is a quiet no-op rather than churning the file (and its mtime).
    if [[ -f "$akf" ]] && cmp -s "$desired" "$akf"; then
        rm -f "$desired"
        local n; n="$(grep -cE '\S' "$akf" 2>/dev/null)" || n=0
        print_ok "Maintainer keys already current (${n} key(s)) in ${akf}."
        return 0
    fi
    cat "$desired" > "$akf"; rm -f "$desired"
    chmod 600 "$akf"
    chown "${TNADMIN_USER}:${TNADMIN_USER}" "$akf"
    local n; n="$(grep -cE '\S' "$akf" 2>/dev/null)" || n=0
    print_ok "Wrote ${n} maintainer key(s) -> ${akf} (mode 600, owner ${TNADMIN_USER})."
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
    local desired; desired="$(mktemp)"
    cat > "$desired" <<EOF
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
    # Idempotent: when the on-disk drop-in already matches, don't rewrite it. That keeps a
    # boot/self-heal pass from bumping the file mtime (which would re-trigger the
    # tn-vpn-selfheal.path watcher) and skips a needless sshd reload. The honored-check
    # below still runs every time — the file can be intact yet IGNORED if sshd_config lost
    # its Include (the node-6 lockout), which a content compare alone would never catch.
    if [[ -f "$SCOPED_SSHD_DROPIN" ]] && cmp -s "$desired" "$SCOPED_SSHD_DROPIN"; then
        rm -f "$desired"
        print_ok "Scoped sshd drop-in already current (no change)."
        verify_dropin_honored || true
        return 0
    fi
    # Content differs (or first install): stash the prior version so a failed validation
    # rolls back to it, then install + validate the new drop-in.
    local backup=""
    if [[ -f "$SCOPED_SSHD_DROPIN" ]]; then
        backup="$(mktemp)"; cp -p "$SCOPED_SSHD_DROPIN" "$backup"
    fi
    cat "$desired" > "$SCOPED_SSHD_DROPIN"; rm -f "$desired"
    chmod 644 "$SCOPED_SSHD_DROPIN"
    if sshd -t 2>/dev/null; then
        systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
        if [[ -n "$backup" ]]; then rm -f "$backup"; fi
        print_ok "Scoped sshd drop-in installed + validated (tnadmin: overlay-only, key-only)."
    else
        if [[ -n "$backup" ]]; then
            cp -p "$backup" "$SCOPED_SSHD_DROPIN"; rm -f "$backup"
            print_error "sshd -t failed; reverted to the prior drop-in. Your SSH is unchanged."
        else
            rm -f "$SCOPED_SSHD_DROPIN"
            print_error "sshd -t failed; reverted the drop-in. Your SSH is unchanged; VPN not enabled."
        fi
        exit 1
    fi
    verify_dropin_honored || true
}

# verify_dropin_honored (H2) — prove the scoped drop-in is actually IN FORCE, not merely
# present on disk. sshd reads sshd_config.d/*.conf only if the main config Includes that
# dir; an openssh-server upgrade or a cloud-init reset can rewrite /etc/ssh/sshd_config and
# drop the `Include` line, leaving the drop-in file intact but IGNORED — every maintainer
# key then silently refused (the node-6 `Permission denied (publickey)`). Ask sshd itself
# for the effective AuthorizedKeysFile on a hypothetical overlay tnadmin login; if our
# .tnvpn file isn't there, repair the Include and re-check. Advisory: always returns 0 so a
# non-fatal warning never aborts an otherwise-good enable.
verify_dropin_honored() {
    command -v sshd >/dev/null 2>&1 || return 0
    local eff=""
    eff="$(sshd -T -C "user=${TNADMIN_USER},addr=${HUB_OVERLAY_IP}" 2>/dev/null)" || eff=""
    if [[ -z "$eff" ]]; then
        print_info "Could not compute the effective sshd config for an overlay ${TNADMIN_USER} login"
        print_info "(sshd -T -C unsupported here) — skipping the drop-in honored-check."
        return 0
    fi
    if grep -qi 'authorized_keys\.tnvpn' <<<"$eff"; then
        print_ok "Verified: sshd honors the drop-in (overlay ${TNADMIN_USER} resolves authorized_keys.tnvpn)."
        return 0
    fi
    print_warn "Drop-in present but sshd is NOT honoring it — an overlay ${TNADMIN_USER} login would ignore the maintainer keys."
    print_info "Most likely /etc/ssh/sshd_config lost its 'Include /etc/ssh/sshd_config.d/*.conf' (openssh upgrade / cloud-init reset)."
    ensure_sshd_includes_dropins || true
    eff="$(sshd -T -C "user=${TNADMIN_USER},addr=${HUB_OVERLAY_IP}" 2>/dev/null)" || eff=""
    if grep -qi 'authorized_keys\.tnvpn' <<<"$eff"; then
        print_ok "Verified after repair: sshd now honors the drop-in."
    else
        print_warn "Drop-in STILL not honored after the Include repair. Inspect manually:"
        print_info  "  sudo sshd -T -C user=${TNADMIN_USER},addr=${HUB_OVERLAY_IP} | grep -i authorizedkeysfile"
        print_info  "  (expect: .ssh/authorized_keys .ssh/authorized_keys.tnvpn)"
    fi
    return 0
}

# ensure_sshd_includes_dropins (H2) — guarantee /etc/ssh/sshd_config actually pulls in
# /etc/ssh/sshd_config.d/*.conf so the scoped tnadmin block is read. No-op when an active
# Include is already present (idempotent). Otherwise append it (the manual repair the
# runbook documents), re-validate with sshd -t, and roll back on failure so a bad edit can
# never break the operator's SSH. Our drop-in is Match-scoped, so appending the Include at
# the end is safe — it only ever runs when no Include exists at all (so we are RESTORING
# drop-in reads, not reordering live ones).
ensure_sshd_includes_dropins() {
    local main=/etc/ssh/sshd_config
    if [[ ! -f "$main" ]]; then
        print_warn "No ${main} — cannot ensure the drop-in directory is included."
        return 1
    fi
    if grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/' "$main"; then
        return 0
    fi
    print_warn "${main} has no active 'Include /etc/ssh/sshd_config.d/*.conf' — adding it so the scoped drop-in is read."
    local backup; backup="$(mktemp)"
    cp -p "$main" "$backup"
    {
        echo ""
        echo "# Added by setup-vpn.sh (Telcoin VPN add-on): pull in the sshd_config.d drop-ins"
        echo "# so the scoped tnadmin overlay file (${SCOPED_SSHD_DROPIN##*/}) is honored. An"
        echo "# openssh upgrade or cloud-init reset can drop this line; without it maintainer SSH breaks."
        echo "Include /etc/ssh/sshd_config.d/*.conf"
    } >> "$main"
    if sshd -t 2>/dev/null; then
        systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
        rm -f "$backup"
        print_ok "Added the missing Include to ${main} (drop-ins are honored again)."
        return 0
    fi
    cp -p "$backup" "$main"; rm -f "$backup"
    print_error "Adding the Include broke 'sshd -t' — reverted ${main}; your SSH is unchanged."
    return 1
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

# do_apply_firewall — idempotently admit overlay->SSH on the operator's ACTIVE firewall
# (ufw). Runs inside do_enable AND standalone (--apply-firewall) for operators who enable
# or tighten ufw AFTER enrollment, which is the common Cause-2 banner-timeout: ufw was
# inactive at enable time so no allow rule was ever added. Reuses allow_overlay_ssh
# (lib/common.sh), which dedups, so re-running is safe.
do_apply_firewall() {
    print_step "Overlay SSH firewall rule (ufw)"
    local port; port="$(get_ssh_port)"; [[ -n "$port" ]] || port=22
    if ufw_installed && ufw_active; then
        if allow_overlay_ssh; then
            print_ok "ufw: SSH allowed from the overlay (${TN_OVERLAY_CIDR} -> :${port})."
        else
            print_warn "Could not add the overlay-SSH ufw rule; add it via firewall-setup.sh."
        fi
    elif ufw_installed; then
        print_warn "ufw is installed but INACTIVE — no inbound rule is enforced right now."
        print_info  "Nothing to do until you enable ufw. The moment you do, re-run:"
        print_info  "  sudo bash setup-vpn.sh --apply-firewall"
        print_info  "(equivalently: ufw allow from ${TN_OVERLAY_CIDR} to any port ${port} proto tcp)."
    else
        print_info "ufw is not installed — your active firewall is something else (or none)."
        print_info "Ensure it admits TCP ${TN_OVERLAY_CIDR} -> :${port} (overlay SSH). The node's"
        print_info "dormant nftables table already permits this if you ever enforce it."
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

# install_selfheal_units (H3) — install + enable a boot oneshot and an on-change path
# watcher that keep this node reachable to maintainers without anyone logging in:
#   * tn-vpn-selfheal.service (oneshot, WantedBy=multi-user.target) runs `--selfheal` at
#     every boot — covers reboot + cloud-init reset.
#   * tn-vpn-selfheal.path triggers that service whenever /etc/ssh/sshd_config or the
#     scoped drop-in changes — covers the no-reboot openssh-upgrade case (the node-6 one).
# Both invoke this very script's idempotent `--selfheal`; the units reference its absolute
# path, so the tn-node-deployment checkout must stay put (the runbook's `git pull` lives
# there anyway). Best-effort: a missing systemd just means manual `--selfheal` still works.
install_selfheal_units() {
    print_step "Installing the VPN self-heal units (boot + on-change re-assert)"
    if ! command -v systemctl >/dev/null 2>&1; then
        print_warn "systemd not present — skipping self-heal units (manual 'setup-vpn.sh --selfheal' still works)."
        return 0
    fi
    local self="${SCRIPT_DIR}/setup-vpn.sh"
    if [[ ! -f "$self" ]]; then
        print_warn "Cannot resolve this script's path (${self}) — skipping the self-heal units."
        return 0
    fi
    cat > "$SELFHEAL_SERVICE" <<EOF
[Unit]
Description=Telcoin VPN admin-SSH self-heal (re-assert overlay tunnel + scoped sshd drop-in + maintainer keys)
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
# Reuses setup-vpn.sh's idempotent verbs: assemble_pubkeys refuses an empty key set (so the
# key file can never be blanked) and every sshd edit is sshd -t-guarded with revert-on-fail.
ExecStart=/bin/bash ${self} --selfheal
[Install]
WantedBy=multi-user.target
EOF
    cat > "$SELFHEAL_PATH_UNIT" <<EOF
[Unit]
Description=Watch sshd config + the tnadmin overlay drop-in; re-assert on change (covers openssh upgrades with no reboot)
[Path]
PathChanged=/etc/ssh/sshd_config
PathChanged=${SCOPED_SSHD_DROPIN}
Unit=tn-vpn-selfheal.service
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload 2>/dev/null || true
    # Enable the oneshot for boot; enable+start the watcher now so it's armed before the
    # next upgrade. (No --now on the service: enable just ran everything fresh.)
    systemctl enable tn-vpn-selfheal.service >/dev/null 2>&1 || print_warn "Could not enable tn-vpn-selfheal.service."
    systemctl enable --now tn-vpn-selfheal.path >/dev/null 2>&1 || print_warn "Could not enable tn-vpn-selfheal.path."
    print_ok "Self-heal installed: boot oneshot + path-watch on sshd_config and the scoped drop-in."
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
    do_apply_firewall
    persist_state
    install_selfheal_units
    nudge_handshake
    print_enrollment
}

# -----------------------------------------------------------------------------
# Self-service: --sync-keys / --status / --apply-firewall
# The operator analog of the admin's sync-access.sh: verify and repair the tunnel +
# firewall, or re-apply the maintainer key set after a git pull, with NO admin needed.
# -----------------------------------------------------------------------------

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

# do_sync_keys — re-apply the vendored maintainer key set to tnadmin. Reads ONLY local
# files, so it works even before overlay connectivity is fixed (e.g. right after a git
# pull that added a maintainer). Idempotent: the file is byte-stable across repeat runs.
do_sync_keys() {
    print_header "Telcoin Network -- refresh maintainer SSH keys  v${SCRIPT_VERSION}"
    assemble_pubkeys
    write_tnadmin_keys
    nudge_handshake
    print_info "Done. Confirm the full picture with:  sudo bash setup-vpn.sh --status"
}

# do_status — PASS/FAIL triage, one check per ranked banner-timeout cause, each failure
# printing the exact fix command. Read-only; never changes node state.
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

    # 3) maintainer key set present (Cause 4 / completeness) -----------------------
    print_step "3) Maintainer SSH keys (tnadmin)"
    local home akf n vendored
    home="$(getent passwd "$TNADMIN_USER" | cut -d: -f6 2>/dev/null || true)"
    akf="${home:+${home}/.ssh/authorized_keys.tnvpn}"
    if [[ -n "$akf" && -f "$akf" ]]; then
        n="$(grep -cE '\S' "$akf" 2>/dev/null)" || n=0
        vendored="$(find "${WGVPN_DIR}/peers/ssh" -maxdepth 1 -name '*.pub' 2>/dev/null | wc -l | tr -d ' ')" || vendored=0
        if [[ "$n" -gt 0 ]]; then
            print_ok "${n} maintainer key(s) installed for ${TNADMIN_USER}."
            if [[ "$vendored" -gt "$n" ]]; then
                print_warn "Vendored set has ${vendored} keys but only ${n} are installed — keys drifted."
                print_info  "Fix: git pull && sudo bash setup-vpn.sh --sync-keys"
                (( ++issues ))
            fi
        else
            print_warn "authorized_keys.tnvpn exists but is empty — no maintainer can log in."
            print_info  "Fix: sudo bash setup-vpn.sh --sync-keys"
            (( ++issues ))
        fi
    else
        print_warn "No tnadmin authorized_keys.tnvpn found — is the VPN enabled on this node?"
        print_info  "Fix: sudo bash setup-vpn.sh    (enable), or --sync-keys if tnadmin already exists."
        (( ++issues ))
    fi

    # 4) scoped sshd drop-in present + config valid --------------------------------
    print_step "4) Scoped sshd drop-in"
    if [[ -f "$SCOPED_SSHD_DROPIN" ]]; then
        if sshd -t 2>/dev/null; then
            print_ok "Drop-in present and 'sshd -t' validates."
        else
            print_warn "Drop-in present but 'sshd -t' reports an error — sshd may refuse to reload."
            print_info  "Fix: sudo sshd -t    (read the error); the drop-in is ${SCOPED_SSHD_DROPIN}"
            (( ++issues ))
        fi
    else
        print_warn "Scoped sshd drop-in is missing (${SCOPED_SSHD_DROPIN})."
        print_info  "Fix: sudo bash setup-vpn.sh    (re-enable reinstalls it)"
        (( ++issues ))
    fi

    # 5) ACTIVE firewall admits overlay -> :ssh (Cause 2) --------------------------
    print_step "5) Firewall: overlay -> SSH (:${port})"
    if ufw_installed && ufw_active; then
        if ufw status 2>/dev/null | grep -F "$TN_OVERLAY_CIDR" | grep -q ALLOW; then
            print_ok "ufw allows ${TN_OVERLAY_CIDR} -> :${port}."
        else
            print_warn "ufw is ACTIVE but has no allow rule for ${TN_OVERLAY_CIDR} — inbound SSH is dropped."
            print_info  "Fix: sudo bash setup-vpn.sh --apply-firewall"
            (( ++issues ))
        fi
    elif ufw_installed; then
        print_info "ufw is installed but inactive — its rules are not enforced (nftables table is dormant)."
        print_info "If you enable ufw later, run: sudo bash setup-vpn.sh --apply-firewall"
    else
        print_info "ufw is not installed — overlay SSH relies on whatever firewall is active (or none)."
        print_info "Ensure TCP ${TN_OVERLAY_CIDR} -> :${port} is admitted there."
    fi

    # Summary ---------------------------------------------------------------------
    echo ""
    if [[ "$issues" -eq 0 ]]; then
        print_ok "All checks passed — a maintainer should be able to tn_ssh this node."
    else
        print_warn "${issues} check(s) need attention — apply the Fix line under each above."
    fi
}

# do_selfheal (H3) — the unit-invoked, non-interactive re-assert. Reuses the SAME tested,
# idempotent functions as enable, in the order most-likely-cause-first, so it can never
# blank the key file or break SSH:
#   1) wg-quick@wg0 stays enabled (defense-in-depth; persists the tunnel across reboots).
#   2) write_scoped_sshd re-asserts the drop-in AND, via verify_dropin_honored, repairs a
#      dropped sshd_config Include — the node-6 lockout. sshd -t-guarded, revert-on-fail.
#   3) assemble_pubkeys (aborts on an empty vendored set) + write_tnadmin_keys re-install
#      the maintainer keys.
# Self-writes are content-conditional, so a steady-state heal touches no watched file and
# never re-triggers tn-vpn-selfheal.path. Reads only local files — needs no overlay.
do_selfheal() {
    print_header "Telcoin Network -- VPN admin SSH self-heal  v${SCRIPT_VERSION}"
    # 1) tunnel persistence across reboot (the H1 defense-in-depth, re-asserted on-node).
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl is-enabled wg-quick@wg0 >/dev/null 2>&1; then
            print_ok "wg-quick@wg0 already enabled (tunnel returns after a reboot)."
        elif systemctl enable wg-quick@wg0 >/dev/null 2>&1; then
            print_ok "Re-enabled wg-quick@wg0 (it was not enabled)."
        else
            print_warn "Could not enable wg-quick@wg0 — the tunnel may not return after a reboot."
        fi
    fi
    # 2) scoped drop-in present + actually honored (repairs a missing Include).
    write_scoped_sshd
    # 3) maintainer key set (refuses an empty set; rewrites only on change).
    assemble_pubkeys
    write_tnadmin_keys
    print_ok "Self-heal pass complete."
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

    # Remove the self-heal units FIRST, so the path watcher can't re-assert the drop-in /
    # tunnel while we tear them down below.
    print_step "Removing the VPN self-heal units"
    systemctl disable --now tn-vpn-selfheal.path >/dev/null 2>&1 || true
    systemctl disable tn-vpn-selfheal.service >/dev/null 2>&1 || true
    rm -f "$SELFHEAL_SERVICE" "$SELFHEAL_PATH_UNIT"
    systemctl daemon-reload 2>/dev/null || true

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
        --sync-keys|--refresh-keys)  MODE="sync-keys";      shift ;;
        --status|--verify)           MODE="status";         shift ;;
        --apply-firewall)            MODE="apply-firewall"; shift ;;
        --selfheal)                  MODE="selfheal";       shift ;;
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
    enable)         do_enable ;;
    disable)        do_disable ;;
    sync-keys)      do_sync_keys ;;
    status)         do_status ;;
    apply-firewall) do_apply_firewall ;;
    selfheal)       do_selfheal ;;
esac
