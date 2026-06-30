#!/bin/bash
#
# =============================================================================
# VENDORED from adiri-genesis: common/wgvpn/node/wg-node-bootstrap.sh
#   upstream sha256: b2928a23c0e2209b55a7cca19a3e240b0f3b612ce3635dc08e1c7c816cb20d0b
#   vendored:        2026-06-30
#
# Verbatim copy of the core team's node bootstrap, carrying ONE upstream-pushed
# change already present in the source: the WG_NODE_SSHD_HARDEN guard (default 1 =
# upstream behavior). setup-vpn.sh invokes this with WG_NODE_SSHD_HARDEN=0 so an
# external operator's existing password/root SSH is never disabled — a scoped
# `Match User tnadmin` drop-in is added by setup-vpn.sh instead. Keep this file
# byte-identical to upstream below this header; re-vendor + diff procedure is in
# docs/testnet-addons.md.
# =============================================================================
#
# wg-node-bootstrap.sh — THE cloud-agnostic core. Turns a host into a WireGuard peer of
# the wheel and installs the tnadmin ops user + host firewall. Pure bash, zero hard GCP
# dependency: every input is read from the environment FIRST, then GCP instance metadata
# as a fallback (so it runs identically when piped over SSH by migrate-nodes.sh and when
# executed by startup.sh on a fresh GCP node — and on a non-GCP box it just uses env).
#
# Runs as root (startup.sh) or via sudo (migrate over SSH); $SUDO bridges both.
#
# LIVE-VALIDATOR SAFETY (the node runs --network=host, so this shares the consensus
# netns — these are correctness-critical, not cosmetic):
#   * wg0 uses Table=off + a single explicit /24 route → the default route and consensus
#     QUIC path are provably untouched. AllowedIPs is 10.100.0.0/16 only, never 0.0.0.0/0.
#   * MTU 1380 applies to wg0 only.
#   * The host firewall is a dedicated `table inet tn_filter` (never a global flush), so
#     Docker's iptables-nft chains are untouched. It is INSTALLED-but-DORMANT by default
#     (WG_NODE_ENFORCE=0) so migration is purely additive; lockdown enables it.
#   * sshd keeps its public bind (IAP break-glass forwards to the internal NIC); only
#     the firewall restricts who can reach :22.
#
# Inputs (env overrides metadata overrides default):
#   WG_HUB_ENDPOINT      required  ip:port of the hub
#   WG_HUB_PUBKEY        required  hub WireGuard public key
#   WG_OVERLAY_IP        required  this node's overlay IP (e.g. 10.100.1.3)
#   TNADMIN_PUBKEYS      maintainer SSH authorized_keys (newline-separated; may be empty)
#   PRIMARY_UDP_PORT/WORKER_UDP_PORT/HEALTHCHECK_TCP_PORT   consensus + health ports
#   WG_OVERLAY (10.100.0.0/16) WG_MTU (1380) WG_IAP_RANGE WG_TNADMIN_USER (tnadmin)
#   HC_RANGES            Google LB health-check source ranges (nft set body)
#   HEALTHCHECK_MONITOR_SRC  external uptime-monitor sources (nft set body) allowed to
#                            TCP-probe the health port — mirrors the cloud rule
#                            allow-validator-healthcheck-from-kuma; empty = no such rule
#   WG_NODE_FIREWALL     1 = install the policy-drop host firewall machinery (the nft
#                        table + tn-nftables service + lockdown helper) (DEFAULT; today's
#                        behavior — adiri byte-identical, honors WG_NODE_ENFORCE below).
#                        0 = overlay ONLY: bring wg0 up but lay down NO policy-drop table.
#                        DEVNET uses 0 because UFW is the single authoritative host
#                        firewall there; a second policy-drop table would create an
#                        intersection trap. Mirrors tn-node-deployment's setup-vpn.sh
#                        (overlay only, no enforcement). Gates the whole §5 block below.
#   WG_NODE_ENFORCE      0 = install firewall but don't activate (default; additive)
#                        1 = activate it now (lockdown / new node born locked)
#                        (only meaningful when WG_NODE_FIREWALL=1)
#   WG_NODE_PUBLIC_SSH   1 = keep public tcp:22 in the firewall (default) / 0 = drop it
#   WG_NODE_SSHD_HARDEN  1 = install the GLOBAL sshd drop-in disabling password/root SSH
#                        (default; upstream GCP behavior) / 0 = leave sshd untouched so
#                        the caller can add its own scoped drop-in (off-GCP lockout-safe)

set -uo pipefail

SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO="sudo"

meta() { curl -sf -H "Metadata-Flavor: Google" \
    "http://metadata.google.internal/computeMetadata/v1/instance/attributes/$1" 2>/dev/null; }

WG_HUB_ENDPOINT="${WG_HUB_ENDPOINT:-$(meta WG_HUB_ENDPOINT)}"
WG_HUB_PUBKEY="${WG_HUB_PUBKEY:-$(meta WG_HUB_PUBKEY)}"
WG_OVERLAY_IP="${WG_OVERLAY_IP:-$(meta WG_OVERLAY_IP)}"
# Maintainer authorized_keys: direct env, else base64 env (so migrate can pass a
# multi-line blob over `bash -s` as a single token), else GCP metadata.
TNADMIN_PUBKEYS="${TNADMIN_PUBKEYS:-}"
if [ -z "${TNADMIN_PUBKEYS}" ] && [ -n "${TNADMIN_PUBKEYS_B64:-}" ]; then
    TNADMIN_PUBKEYS="$(printf '%s' "${TNADMIN_PUBKEYS_B64}" | base64 -d 2>/dev/null)"
fi
TNADMIN_PUBKEYS="${TNADMIN_PUBKEYS:-$(meta TNADMIN_PUBKEYS)}"
PRIMARY_UDP_PORT="${PRIMARY_UDP_PORT:-$(meta PRIMARY_UDP_PORT)}"; PRIMARY_UDP_PORT="${PRIMARY_UDP_PORT:-49590}"
WORKER_UDP_PORT="${WORKER_UDP_PORT:-$(meta WORKER_UDP_PORT)}"; WORKER_UDP_PORT="${WORKER_UDP_PORT:-49594}"
HEALTH_TCP_PORT="${HEALTHCHECK_TCP_PORT:-$(meta HEALTHCHECK_TCP_PORT)}"; HEALTH_TCP_PORT="${HEALTH_TCP_PORT:-43174}"
WG_OVERLAY="${WG_OVERLAY:-10.100.0.0/16}"   # /16: overlay spans 10.100.<net>.x (maintainers=9, nodes), not just 10.100.0.x
WG_MTU="${WG_MTU:-1380}"
WG_IAP_RANGE="${WG_IAP_RANGE:-35.235.240.0/20}"
WG_TNADMIN_USER="${WG_TNADMIN_USER:-tnadmin}"
# WG_NODE_FIREWALL gates the whole §5 policy-drop host-firewall block. Default 1 keeps
# today's behavior (adiri byte-identical). Read defensively (unset -> 1). Devnet sets 0:
# overlay only, no policy-drop table (UFW is the single authoritative firewall there).
WG_NODE_FIREWALL="${WG_NODE_FIREWALL:-1}"
WG_NODE_ENFORCE="${WG_NODE_ENFORCE:-0}"
WG_NODE_PUBLIC_SSH="${WG_NODE_PUBLIC_SSH:-1}"
WG_NODE_SSHD_HARDEN="${WG_NODE_SSHD_HARDEN:-1}"
HC_RANGES="${HC_RANGES:-130.211.0.0/22, 35.191.0.0/16, 209.85.152.0/22, 209.85.204.0/22}"
# External uptime monitor(s) allowed to TCP-probe the health port (nft set body). Empty
# default = no such rule (preserves the pre-lockdown posture where the cloud rule alone
# admitted the monitor and there was no host firewall).
HEALTHCHECK_MONITOR_SRC="${HEALTHCHECK_MONITOR_SRC:-$(meta HEALTHCHECK_MONITOR_SRC)}"

for v in WG_HUB_ENDPOINT WG_HUB_PUBKEY WG_OVERLAY_IP; do
    [ -n "${!v}" ] || { echo "wg-node-bootstrap: missing required ${v}" >&2; exit 1; }
done
[ -n "${TNADMIN_PUBKEYS}" ] || echo "wg-node-bootstrap: WARNING — TNADMIN_PUBKEYS empty; no overlay SSH until sync-access.sh runs." >&2

echo "[wg-node] $(hostname) overlay=${WG_OVERLAY_IP} hub=${WG_HUB_ENDPOINT} firewall=${WG_NODE_FIREWALL} enforce=${WG_NODE_ENFORCE} public_ssh=${WG_NODE_PUBLIC_SSH}"

# --- 1. packages ---------------------------------------------------------------
if ! command -v wg >/dev/null 2>&1 || ! command -v nft >/dev/null 2>&1; then
    echo "[wg-node] installing wireguard-tools + nftables"
    $SUDO apt-get update
    $SUDO apt-get install -y wireguard-tools nftables
fi

# --- 2. tnadmin ops user -------------------------------------------------------
echo "[wg-node] ensuring ${WG_TNADMIN_USER}"
id -u "${WG_TNADMIN_USER}" >/dev/null 2>&1 || $SUDO useradd -m -s /bin/bash "${WG_TNADMIN_USER}"
echo "${WG_TNADMIN_USER} ALL=(ALL) NOPASSWD:ALL" | $SUDO tee "/etc/sudoers.d/90-${WG_TNADMIN_USER}" >/dev/null
$SUDO chmod 440 "/etc/sudoers.d/90-${WG_TNADMIN_USER}"
$SUDO visudo -cf "/etc/sudoers.d/90-${WG_TNADMIN_USER}" >/dev/null
TN_HOME="$(getent passwd "${WG_TNADMIN_USER}" | cut -d: -f6)"
$SUDO install -d -m 700 -o "${WG_TNADMIN_USER}" -g "${WG_TNADMIN_USER}" "${TN_HOME}/.ssh"
# We own authorized_keys.tnvpn (registry maintainer keys); the guest agent owns the
# plain authorized_keys (operator IAP break-glass key).
printf '%s\n' "${TNADMIN_PUBKEYS}" | $SUDO tee "${TN_HOME}/.ssh/authorized_keys.tnvpn" >/dev/null
$SUDO chmod 600 "${TN_HOME}/.ssh/authorized_keys.tnvpn"
$SUDO chown "${WG_TNADMIN_USER}:${WG_TNADMIN_USER}" "${TN_HOME}/.ssh/authorized_keys.tnvpn"

# --- 3. node WireGuard key (generated on-node, never leaves it) -----------------
$SUDO install -d -m 700 /etc/wireguard
if ! $SUDO test -f /etc/wireguard/wg0-private.key; then
    echo "[wg-node] generating node WireGuard key"
    $SUDO sh -c 'umask 077; wg genkey > /etc/wireguard/wg0-private.key'
fi
NODE_PRIV="$($SUDO cat /etc/wireguard/wg0-private.key)"
NODE_PUB="$(printf '%s' "${NODE_PRIV}" | wg pubkey)"
[ -n "${NODE_PUB}" ] || { echo "wg-node-bootstrap: failed to derive node pubkey" >&2; exit 1; }

# --- 4. wg0.conf + bring up (Table=off + single /24 route) ----------------------
echo "[wg-node] writing /etc/wireguard/wg0.conf"
$SUDO tee /etc/wireguard/wg0.conf >/dev/null <<EOF
[Interface]
PrivateKey = ${NODE_PRIV}
Address = ${WG_OVERLAY_IP}/32
MTU = ${WG_MTU}
# Table=off: wg-quick adds NO routes, so the default route + consensus QUIC path are
# provably untouched. The one overlay route is added explicitly below.
Table = off
PostUp = ip -4 route replace ${WG_OVERLAY} dev wg0
PostDown = ip -4 route del ${WG_OVERLAY} dev wg0 || true

[Peer]
PublicKey = ${WG_HUB_PUBKEY}
Endpoint = ${WG_HUB_ENDPOINT}
AllowedIPs = ${WG_OVERLAY}
PersistentKeepalive = 25
EOF
$SUDO chmod 600 /etc/wireguard/wg0.conf
if ip link show wg0 >/dev/null 2>&1; then
    echo "[wg-node] wg0 up — syncconf (no tunnel drop) + re-assert route"
    $SUDO bash -c 'wg syncconf wg0 <(wg-quick strip wg0)'
    $SUDO ip -4 route replace "${WG_OVERLAY}" dev wg0
else
    echo "[wg-node] bringing wg0 up"
    $SUDO wg-quick up wg0
fi
# Enable-then-verify: a silently-swallowed enable failure means the tunnel never returns
# after a reboot. Confirm with is-enabled and warn loudly so it's caught at bootstrap time
# rather than discovered as a lockout after the next reboot.
if $SUDO systemctl enable wg-quick@wg0.service >/dev/null 2>&1 && \
   $SUDO systemctl is-enabled wg-quick@wg0.service >/dev/null 2>&1; then
    echo "[wg-node] wg-quick@wg0 enabled (tunnel returns after a reboot)"
else
    echo "[wg-node] WARNING: could not enable wg-quick@wg0 — the WireGuard tunnel will NOT return after a reboot. Fix: systemctl enable wg-quick@wg0" >&2
fi

# --- 5. host firewall (dedicated table; install dormant unless enforcing) -------
# Gated on WG_NODE_FIREWALL (default 1). When 0 (devnet), we install NO policy-drop
# table at all: UFW is the single authoritative host firewall there, so a second
# default-drop table would create an intersection trap. The overlay (§4) is already up
# above this block unconditionally, and with no policy-drop table present overlay SSH
# needs no explicit nft allow — it simply works (nothing drops it). This mirrors
# tn-node-deployment's setup-vpn.sh: overlay only, no enforcement.
if [ "${WG_NODE_FIREWALL}" = "1" ]; then
echo "[wg-node] installing host firewall (inet tn_filter)"
if [ "${WG_NODE_PUBLIC_SSH}" = "1" ]; then
    PUBLIC_SSH_LINE='        tcp dport 22 accept comment "TN-PUBLIC-SSH removed at lockdown"'
else
    PUBLIC_SSH_LINE=''
fi
# External uptime monitor on the health port (Kuma VM). Empty -> harmless blank line,
# exactly like PUBLIC_SSH_LINE above.
if [ -n "${HEALTHCHECK_MONITOR_SRC}" ]; then
    MONITOR_HC_LINE="        ip saddr { ${HEALTHCHECK_MONITOR_SRC} } tcp dport ${HEALTH_TCP_PORT} accept comment \"external uptime monitor\""
else
    MONITOR_HC_LINE=""
fi
$SUDO install -d -m 755 /etc/wgvpn
# Canonical reviewable source: common/wgvpn/node/nftables-node.conf.tmpl (kept in sync).
$SUDO tee /etc/wgvpn/nftables-node.nft >/dev/null <<EOF
#!/usr/sbin/nft -f
# Generated by wg-node-bootstrap.sh. Dedicated table; NO global flush (must not clobber
# Docker). Idempotent reload via declare -> delete -> redefine.
table inet tn_filter
delete table inet tn_filter
table inet tn_filter {
    chain input {
        type filter hook input priority 0; policy drop;
        ct state established,related accept
        ct state invalid drop
        iif "lo" accept
        ip protocol icmp accept
        ip6 nexthdr ipv6-icmp accept
        udp dport ${PRIMARY_UDP_PORT} accept
        udp dport ${WORKER_UDP_PORT} accept
        tcp dport 8545 accept
        tcp dport 443 accept
        tcp dport 80 accept
        ip saddr { ${HC_RANGES} } tcp dport ${HEALTH_TCP_PORT} accept
        ip saddr ${WG_OVERLAY} tcp dport ${HEALTH_TCP_PORT} accept
${MONITOR_HC_LINE}
        ip saddr ${WG_OVERLAY} tcp dport 22 accept
        ip saddr ${WG_IAP_RANGE} tcp dport 22 accept
${PUBLIC_SSH_LINE}
    }
}
EOF

# systemd unit that loads ONLY our table (no flush-on-stop, unlike the stock service).
$SUDO tee /etc/systemd/system/tn-nftables.service >/dev/null <<'EOF'
[Unit]
Description=Telcoin node host firewall (inet tn_filter)
After=network-pre.target
Wants=network-pre.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/nft -f /etc/wgvpn/nftables-node.nft
ExecReload=/usr/sbin/nft -f /etc/wgvpn/nftables-node.nft
ExecStop=/usr/sbin/nft delete table inet tn_filter
[Install]
WantedBy=multi-user.target
EOF
$SUDO systemctl daemon-reload

# Idempotent host-side lockdown helper (removes public tcp:22, reloads). Called by
# lockdown-firewall-gcp.sh; portable enough for a non-GCP node to run directly.
$SUDO tee /usr/local/sbin/tn-node-ssh-lockdown >/dev/null <<'EOF'
#!/bin/bash
set -e
F=/etc/wgvpn/nftables-node.nft
sed -i '/TN-PUBLIC-SSH/d' "$F"
if systemctl is-active --quiet tn-nftables.service; then
    systemctl reload tn-nftables.service
else
    nft -f "$F"
fi
echo "host nft: public tcp:22 removed on $(hostname)"
EOF
$SUDO chmod 755 /usr/local/sbin/tn-node-ssh-lockdown

if [ "${WG_NODE_ENFORCE}" = "1" ]; then
    echo "[wg-node] enforcing host firewall now"
    $SUDO systemctl enable --now tn-nftables.service
    [ "${WG_NODE_PUBLIC_SSH}" = "1" ] || $SUDO /usr/local/sbin/tn-node-ssh-lockdown
else
    echo "[wg-node] host firewall installed but DORMANT (additive migration mode)"
fi
else
    # WG_NODE_FIREWALL=0: overlay only. No policy-drop table, no tn-nftables service, no
    # lockdown helper. UFW (devnet) stays the single authoritative host firewall; overlay
    # SSH works without an explicit allow because nothing drops it.
    echo "[wg-node] WG_NODE_FIREWALL=0 — overlay only; NOT installing policy-drop nft table (UFW authoritative)"
fi

# --- 6. sshd hardening (additive; safe on a live node) --------------------------
# WG_NODE_SSHD_HARDEN=0 skips the GLOBAL drop-in below (which disables password + root
# SSH for EVERY user). Off-GCP callers (e.g. external operators via setup-vpn.sh) set 0
# and add their own scoped `Match User tnadmin` drop-in instead, so the operator's
# existing SSH posture is never touched. Default 1 keeps the upstream (GCP) behavior.
if [ "${WG_NODE_SSHD_HARDEN}" = "1" ]; then
echo "[wg-node] installing sshd hardening drop-in"
$SUDO install -d -m 755 /etc/ssh/sshd_config.d
# Canonical reviewable source: common/wgvpn/node/sshd-node.conf (kept in sync).
$SUDO tee /etc/ssh/sshd_config.d/10-tnvpn.conf >/dev/null <<'EOF'
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys .ssh/authorized_keys.tnvpn
MaxAuthTries 3
LoginGraceTime 20
X11Forwarding no
EOF
if $SUDO sshd -t; then
    $SUDO systemctl reload ssh 2>/dev/null || $SUDO systemctl reload sshd 2>/dev/null || true
    echo "[wg-node] sshd drop-in valid + reloaded"
else
    echo "[wg-node] ERROR: sshd -t failed; reverting drop-in (node SSH unchanged)" >&2
    $SUDO rm -f /etc/ssh/sshd_config.d/10-tnvpn.conf
fi
else
echo "[wg-node] WG_NODE_SSHD_HARDEN=0 — leaving global sshd config untouched (caller adds a scoped drop-in)"
fi

# --- 7. report -----------------------------------------------------------------
echo "WG_NODE_PUBKEY=${NODE_PUB}"
echo "WG_OVERLAY_IP=${WG_OVERLAY_IP}"
echo "[wg-node] done."
