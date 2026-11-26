#!/usr/bin/env bash
# =============================================================================
# tools/tests/check_node_gateway_edge_test.sh -- check-node.sh's check of a
# worker gateway's public edge (check_gateway_edge) on a host where Caddy fronts
# it: /ready, the DNS answer of install-caddy.sh --phase=gateway-check-dns, GET
# https://<domain>/health through Caddy on loopback, the certificate's expiry and
# the ufw rules for 80/tcp and 443/tcp, as a normal user.
#
#   bash tools/tests/run.sh tools/tests/check_node_gateway_edge_test.sh
#   docker run --rm --network none -v "$PWD:/w:ro" -w /w bash:3.2 \
#       bash tools/tests/run.sh tools/tests/check_node_gateway_edge_test.sh
#
# The function is cut out of check-node.sh (its HARDENING CHECKS section and
# have_fns) and run over the real lib/common.sh with the GW_ST_* values that
# gw_status leaves. curl, openssl, ufw and id are PATH stubs, install-caddy.sh a
# stub in a fixture SCRIPT_DIR; curl, ufw and install-caddy.sh log their calls.
# Maintainer tooling (not updater-tracked). bash 3.2 safe.
# =============================================================================
# shellcheck disable=SC2034  # the GW_ST_* values, CN_GATEWAY_ONLY and the colours are read by the cut-out function
set -u
# shellcheck source=tools/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
T="$TN_TEST_TMP"
CN="$TN_TEST_REPO/check-node.sh"
export TN_ROOT_PREFIX="$T/fx"
export CALLS="$T/calls"
REAL_ID="$(command -v id)"
export REAL_ID
mkdir -p "$T/bin" "$T/sd" "$T/fx"
: > "$CALLS"

# --- stubs -------------------------------------------------------------------
# id: `id -u` is FAKE_UID when set; anything else is the real id.
cat > "$T/bin/id" <<'STUB'
#!/usr/bin/env bash
if [ "$*" = "-u" ] && [ -n "${FAKE_UID:-}" ]; then echo "$FAKE_UID"; exit 0; fi
exec "$REAL_ID" "$@"
STUB
# curl: https://<name>/health prints EDGE_CODE and exits EDGE_RC.
cat > "$T/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >> "${CALLS:?}"
u=""
for a in "$@"; do u="$a"; done
case "$u" in
    https://*/health) printf '%s' "${EDGE_CODE:-200}"; exit "${EDGE_RC:-0}" ;;
esac
exit 22
STUB
# openssl: s_client prints a certificate unless CERT_READ=0; x509 -enddate
# prints CERT_END for it; x509 -checkend exits CERT_CHECKEND_RC.
cat > "$T/bin/openssl" <<'STUB'
#!/usr/bin/env bash
case "$1" in
    s_client)
        [ "${CERT_READ:-1}" = 1 ] || exit 1
        printf '%s\n' "-----BEGIN CERTIFICATE-----" "fixture" "-----END CERTIFICATE-----" ;;
    x509)
        grep -q 'BEGIN CERTIFICATE' || exit 1
        case "$*" in
            *-enddate*) printf 'notAfter=%s\n' "${CERT_END:-Feb 24 12:00:00 2027 GMT}" ;;
            *-checkend*) exit "${CERT_CHECKEND_RC:-0}" ;;
        esac ;;
esac
exit 0
STUB
# ufw: `ufw status` prints UFW_OUT.
cat > "$T/bin/ufw" <<'STUB'
#!/usr/bin/env bash
printf 'ufw %s\n' "$*" >> "${CALLS:?}"
[ "${1:-}" = status ] && printf '%b' "${UFW_OUT:-Status: inactive\n}"
exit 0
STUB
# install-caddy.sh: prints DNS_JSON as its last line.
cat > "$T/sd/install-caddy.sh" <<'STUB'
#!/usr/bin/env bash
printf 'install-caddy.sh %s\n' "$*" >> "${CALLS:?}"
printf 'a log line first\n%s\n' "${DNS_JSON:-}"
STUB
chmod +x "$T/bin/"* "$T/sd/install-caddy.sh"
PATH="$T/bin:$PATH"
export PATH
hash -r

# --- check-node.sh functions over the real library -------------------------------
{
    sed -n '/^have_fns() {/,/^}/p' "$CN"
    awk '/^# HARDENING CHECKS/ { f = 1 } /^# REPORT HEADER/ { f = 0 } f' "$CN"
} > "$T/fns.sh"
eval "$(tn_test_source_common)"
# The lines are matched with their [OK], [WARN] and [ERROR] tags, so no colour
# codes even when the test runs on a terminal.
RED='' GREEN='' YELLOW='' BLUE='' CYAN='' BOLD='' RESET=''
# shellcheck source=/dev/null
. "$T/fns.sh"
check "check_gateway_edge cut out of check-node.sh" yes "$(declare -F check_gateway_edge >/dev/null && echo yes)"
check "the report runs it right after check_gateway" "check_gateway check_gateway_edge" \
    "$(grep -A1 -x 'check_gateway' "$CN" | tr '\n' ' ' | sed 's/ $//')"
SCRIPT_DIR="$T/sd"   # where check_gateway_edge finds install-caddy.sh

DNS_OK='{"domain":"gw.example.org","public_ip":"203.0.113.7","resolved_ip":"203.0.113.7","propagated":true,"egress_ip":"203.0.113.7","local_ips":["10.0.0.9"],"note":"gw.example.org resolves to 203.0.113.7, an address that reaches this host."}'
DNS_NONE='{"domain":"gw.example.org","public_ip":"203.0.113.7","resolved_ip":"","propagated":false,"egress_ip":"203.0.113.7","local_ips":["10.0.0.9"],"note":"gw.example.org does not resolve yet"}'
DNS_ELSE='{"domain":"gw.example.org","public_ip":"203.0.113.7","resolved_ip":"198.51.100.4","propagated":false,"egress_ip":"203.0.113.7","local_ips":["10.0.0.9"],"note":"elsewhere"}'
UFW_WEB="Status: active\nDefault: deny (incoming), allow (outgoing), disabled (routed)\n\nTo                         Action      From\n--                         ------      ----\n22/tcp                     ALLOW       Anywhere\n80/tcp                     ALLOW       Anywhere\n443/tcp                    ALLOW       Anywhere\n80/tcp (v6)                ALLOW       Anywhere (v6)\n443/tcp (v6)               ALLOW       Anywhere (v6)\n"

has() { if grep -qF -- "$1" <<< "$2"; then echo yes; else echo no; fi; }
runc() {  # runc -> OUT (check_gateway_edge's output and a last line issues=<HEALTH_ISSUES>)
    HEALTH_ISSUES=0
    : > "$CALLS"
    OUT="$(check_gateway_edge 2>&1; printf '\nissues=%s' "$HEALTH_ISSUES")"
}
fresh() {  # a healthy gateway-only host whose gateway Caddy fronts at gw.example.org
    GW_ST_INSTALLED=true GW_ST_FRONT=caddy GW_ST_DOMAIN=gw.example.org GW_ST_ACTIVE=true
    GW_ST_HEALTH=true GW_ST_READY=true GW_ST_UPSTREAM_READINESS=http://10.0.0.5:43174/health/workers
    CN_GATEWAY_ONLY=true
    export DNS_JSON="$DNS_OK" EDGE_CODE=200 EDGE_RC=0 CERT_READ=1 CERT_CHECKEND_RC=0 UFW_OUT="$UFW_WEB" FAKE_UID=0
    unset CERT_END
}

# =============================================================================
# a healthy edge
# =============================================================================
fresh; runc
check_has "healthy edge: no issue" "issues=0" "$OUT"
check "healthy: the section heading" yes "$(has "Checking the worker gateway's public edge (Caddy)..." "$OUT")"
check "healthy: DNS ok" yes "$(has '[OK]  DNS: gw.example.org resolves to 203.0.113.7, an address that reaches this host' "$OUT")"
check "healthy: https through Caddy ok" yes \
    "$(has '[OK]  GET https://gw.example.org/health through Caddy on this host answered 200 over a verified certificate' "$OUT")"
check "healthy: certificate expiry ok" yes "$(has '[OK]  The certificate for gw.example.org is valid until Feb 24 12:00:00 2027 GMT' "$OUT")"
check "healthy: ufw ok" yes "$(has '[OK]  ufw is active and allows 80/tcp and 443/tcp for Caddy' "$OUT")"
check "healthy: the cloud firewall line" yes \
    "$(has 'Cloud firewall rules (security groups, firewall rules, NSGs) cannot be seen from this host: check that they let TCP 80 and 443 in from anywhere' "$OUT")"
check_lacks "healthy: /ready not reported" "/ready" "$OUT"
check_lacks "healthy: no warning" "[WARN]" "$OUT"
check "DNS asked of install-caddy.sh in JSON for the gateway's name" yes \
    "$(has 'install-caddy.sh --json --phase=gateway-check-dns --gateway-domain gw.example.org' "$(cat "$CALLS")")"
check "one curl, through Caddy on loopback" \
    "curl -q -sS -o /dev/null -w %{http_code} --proto =https --max-redirs 0 --connect-timeout 3 --max-time 5 --resolve gw.example.org:443:127.0.0.1 https://gw.example.org/health" \
    "$(grep '^curl ' "$CALLS")"

# =============================================================================
# /ready
# =============================================================================
fresh; GW_ST_READY=false; runc
check_has "gateway-only host, /ready not 200: one issue" "issues=1" "$OUT"
check "gateway-only /ready: an error naming the validator's readiness URL" yes \
    "$(has "[ERROR] The gateway's /ready is not 200, so it refuses transactions (503): the validator at http://10.0.0.5:43174/health/workers is down" "$OUT")"
fresh; GW_ST_READY=false; CN_GATEWAY_ONLY=false; runc
check_has "host with a node, /ready not 200: no issue" "issues=0" "$OUT"
check "host with a node, /ready: a warning" yes "$(has "[WARN] The gateway's /ready is not 200" "$OUT")"
fresh; GW_ST_READY=false; GW_ST_HEALTH=false; runc
check_has "gateway not healthy (gw_status counts it): /ready not counted again" "issues=0" "$OUT"
check_lacks "gateway not healthy: no /ready line" "/ready" "$OUT"

# =============================================================================
# DNS
# =============================================================================
fresh; DNS_JSON="$DNS_NONE"; runc
check_has "name does not resolve: one issue" "issues=1" "$OUT"
check "name does not resolve: names the A record and this host's IP" yes \
    "$(has "[ERROR] DNS: gw.example.org does not resolve, so nobody reaches the gateway by its name; its A record must point at this host's static public IP (203.0.113.7 as seen from here)" "$OUT")"
fresh; DNS_JSON="$DNS_ELSE"; runc
check_has "name resolves elsewhere: no issue" "issues=0" "$OUT"
check "name resolves elsewhere: a warning" yes \
    "$(has "[WARN] DNS: gw.example.org resolves to 198.51.100.4, which is neither this host's public IP (203.0.113.7 as seen from here) nor a local address" "$OUT")"
fresh; DNS_JSON=""; runc
check_has "install-caddy.sh gives no answer: no issue" "issues=0" "$OUT"
check "no answer: not checked" yes \
    "$(has 'DNS of gw.example.org: not checked (install-caddy.sh --json --phase=gateway-check-dns gave no answer)' "$OUT")"
fresh; DNS_JSON='{"domain":"gw..org","public_ip":"","resolved_ip":"","propagated":false,"egress_ip":"","local_ips":[],"note":"invalid domain: x","error":"invalid domain: x"}'; runc
check_has "install-caddy.sh refuses the name: not counted here" "issues=0" "$OUT"
check "refused name: not checked" yes "$(has 'DNS of gw.example.org: not checked' "$OUT")"
fresh; mv "$T/sd/install-caddy.sh" "$T/sd/ic.off"; runc; mv "$T/sd/ic.off" "$T/sd/install-caddy.sh"
check "install-caddy.sh missing: not checked" yes "$(has 'DNS of gw.example.org: not checked' "$OUT")"

# =============================================================================
# https through Caddy, and the certificate
# =============================================================================
fresh; EDGE_RC=60 EDGE_CODE=000; runc
check_has "certificate not verified: one issue" "issues=1" "$OUT"
check "certificate not verified: said" yes \
    "$(has "[ERROR] GET https://gw.example.org/health through Caddy on this host got a TLS or certificate error (curl exit 60), so Caddy has no valid certificate for gw.example.org instead of 200" "$OUT")"
check "certificate not verified: the A record and the ports" yes \
    "$(has "Caddy gets one once the A record of gw.example.org points at this host and TCP 80 and 443 reach it from anywhere; see journalctl -u caddy" "$OUT")"
check_lacks "certificate not verified: no expiry line" "Certificate expiry" "$OUT"
check_lacks "certificate not verified: no validity line" "is valid until" "$OUT"
fresh; EDGE_CODE=502; runc
check_has "HTTP 502: one issue" "issues=1" "$OUT"
check "HTTP 502: said" yes "$(has 'through Caddy on this host got HTTP 502 instead of 200' "$OUT")"
fresh; EDGE_CODE=502; GW_ST_HEALTH=false; GW_ST_ACTIVE=false; runc
check_has "HTTP 502 while the gateway is down (gw_status counts it): not counted again" "issues=0" "$OUT"
check "gateway down: the 502 is information" yes \
    "$(has 'through Caddy on this host got HTTP 502: the gateway behind Caddy does not answer (see above)' "$OUT")"
fresh; EDGE_RC=60 EDGE_CODE=000; GW_ST_HEALTH=false; runc
check_has "TLS error while the gateway is down: still an issue" "issues=1" "$OUT"
fresh; EDGE_RC=7 EDGE_CODE=000; runc
check "connection refused: said" yes "$(has 'got the connection was refused instead of 200' "$OUT")"
check "connection refused: asks whether Caddy runs" yes "$(has 'fix: check that Caddy runs: systemctl status caddy' "$OUT")"
fresh; CERT_CHECKEND_RC=1; CERT_END="Dec  1 12:00:00 2026 GMT"; export CERT_END; runc
check_has "certificate expires within 14 days: no issue" "issues=0" "$OUT"
check "expiring certificate: a warning with the date" yes \
    "$(has '[WARN] The certificate for gw.example.org expires Dec  1 12:00:00 2026 GMT, within 14 days.' "$OUT")"
fresh; CERT_READ=0; runc
check_has "openssl cannot read the certificate: no issue" "issues=0" "$OUT"
check "certificate unreadable: not checked" yes \
    "$(has 'Certificate expiry: not checked (openssl could not read the certificate Caddy serves for gw.example.org)' "$OUT")"
fresh
OUT="$(command() { if [ "${1:-}" = -v ] && [ "${2:-}" = openssl ]; then return 1; fi; builtin command "$@"; }
       HEALTH_ISSUES=0; check_gateway_edge 2>&1; printf '\nissues=%s' "$HEALTH_ISSUES")"
check_has "no openssl: no issue" "issues=0" "$OUT"
check "no openssl: the expiry is not checked, said once" yes "$(has 'Certificate expiry: not checked (openssl not found)' "$OUT")"

# =============================================================================
# ufw
# =============================================================================
fresh; UFW_OUT="Status: inactive\n"; runc
check_has "ufw inactive: one issue" "issues=1" "$OUT"
check "ufw inactive: names firewall-setup.sh --enable" yes \
    "$(has '[ERROR] ufw is not active, so this host has no firewall rules in force; run: sudo bash firewall-setup.sh --enable' "$OUT")"
fresh; UFW_OUT="${UFW_WEB//443\/tcp/8443\/tcp}"; runc
check_has "no 443/tcp rule: one issue" "issues=1" "$OUT"
check "no 443/tcp rule: names the port" yes \
    "$(has '[ERROR] ufw does not allow 443/tcp from anywhere; Caddy needs TCP 80 and 443 open from anywhere to serve https://gw.example.org/ and renew its certificate; run: sudo bash firewall-setup.sh --enable' "$OUT")"
fresh; UFW_OUT="Status: active\n\nTo   Action   From\n22/tcp   ALLOW   Anywhere\n"; runc
check "no web rules: names both ports" yes "$(has 'ufw does not allow 80/tcp and 443/tcp from anywhere' "$OUT")"
# A rule for some sources only keeps the public and the certificate authority out.
fresh; UFW_OUT="${UFW_WEB//443\/tcp                    ALLOW       Anywhere/443/tcp                    ALLOW       10.0.0.0/8}"; runc
check_has "443/tcp from 10.0.0.0/8 only: one issue" "issues=1" "$OUT"
check "443/tcp from 10.0.0.0/8 only: names the port" yes "$(has '[ERROR] ufw does not allow 443/tcp from anywhere;' "$OUT")"
check_lacks "443/tcp from 10.0.0.0/8 only: not ok" "[OK]  ufw is active" "$OUT"
fresh; UFW_OUT="Status: active\n\nTo   Action   From\n80/tcp   ALLOW   203.0.113.0/24\n443/tcp   ALLOW   Anywhere   # caddy\n80/tcp (v6)   ALLOW   Anywhere (v6)\n"; runc
check "80/tcp from one range, open on IPv6 only: names 80/tcp alone" yes \
    "$(has '[ERROR] ufw does not allow 80/tcp from anywhere;' "$OUT")"
fresh; UFW_OUT="Status: active\n\nTo   Action   From\n80/tcp   ALLOW   Anywhere   # caddy\n443/tcp   ALLOW   Anywhere\n"; runc
check_has "rules from anywhere, one with a comment: no issue" "issues=0" "$OUT"
fresh; FAKE_UID=1000; runc
check_has "not root: no false issue" "issues=0" "$OUT"
check "not root: ufw not checked, said" yes "$(has 'Gateway firewall (ufw): not checked (reading ufw needs sudo)' "$OUT")"
check_lacks "not root: ufw not run" "ufw " "$(cat "$CALLS")"
check "not root: the cloud firewall line still printed" yes "$(has 'Cloud firewall rules' "$OUT")"

# =============================================================================
# when the section does not apply
# =============================================================================
fresh; GW_ST_FRONT=none; runc
check "front none: silent" "issues=0" "$(sed '/^$/d' <<< "$OUT")"
fresh; GW_ST_INSTALLED=false; runc
check "no gateway (or gw_status did not run): silent" "issues=0" "$(sed '/^$/d' <<< "$OUT")"
fresh; GW_ST_DOMAIN=""; FAKE_UID=1000; runc
check "no name without root: says gateway.meta needs sudo" yes \
    "$(has 'Gateway name, DNS and certificate: not checked (the name is in gateway.meta, which needs sudo to read)' "$OUT")"
check_lacks "no name: no curl" "curl " "$(cat "$CALLS")"

finish
