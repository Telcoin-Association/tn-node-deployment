#!/usr/bin/env bash
# =============================================================================
# tools/tests/gateway_check_remove_test.sh -- the worker-gateway sections of
# check-node.sh (check_gateway, check_gateway_upstream, the gateway-only host)
# and of remove-node.sh (remove_gateway and its callers) on fixture trees, as a
# normal user, over the REAL lib/common.sh and lib/gateway.sh (gw_status and its
# GW_ST_* values, gw_unit_text for the fixture unit).
#
#   bash tools/tests/run.sh tools/tests/gateway_check_remove_test.sh
#   docker run --rm --network none -v "$PWD:/w:ro" -w /w bash:3.2 \
#       bash tools/tests/run.sh tools/tests/gateway_check_remove_test.sh
#
# The check-node.sh functions are cut out of it (its HARDENING CHECKS section,
# have_fns, detect_data_dir and the advertised-RPC readers); the gateway-only
# host runs the whole script. remove-node.sh is sourced from a copy without its
# common.sh source line (common is already loaded) and its `main "$@"` line.
# systemctl, docker, curl, ss, ufw and id are PATH stubs; systemctl, docker and
# ufw log their calls. TN_ROOT_PREFIX points every path at the fixture tree.
# Maintainer tooling (not updater-tracked). bash 3.2 safe.
# =============================================================================
set -u
# shellcheck source=tools/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
T="$TN_TEST_TMP"
R="$T/fx"
CN="$TN_TEST_REPO/check-node.sh"
export TN_ROOT_PREFIX="$R"
export CALLS="$T/calls"
REAL_ID="$(command -v id)"
export REAL_ID
mkdir -p "$T/bin" "$T/rn" "$R"
: > "$CALLS"

# --- stubs -------------------------------------------------------------------
# id: `id -u` is FAKE_UID when set; anything else is the real id.
cat > "$T/bin/id" <<'STUB'
#!/usr/bin/env bash
if [ "$*" = "-u" ] && [ -n "${FAKE_UID:-}" ]; then echo "$FAKE_UID"; exit 0; fi
exec "$REAL_ID" "$@"
STUB
# systemctl: the gateway unit is enabled / active per GW_ENABLED / GW_ACTIVE;
# every other unit is unknown.
cat > "$T/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >> "${CALLS:?}"
case "$1" in
    is-enabled|is-active)
        case "$*" in *telcoin-gateway*) ;; *) exit 3 ;; esac
        v=GW_ACTIVE
        [ "$1" = is-enabled ] && v=GW_ENABLED
        eval "[ \"\${$v:-1}\" = 1 ]" && exit 0
        exit 3 ;;
esac
exit 0
STUB
# docker: holds the image asked for when GW_HELD=1; `ps -a` prints DOCKER_PS.
cat > "$T/bin/docker" <<'STUB'
#!/usr/bin/env bash
printf 'docker %s\n' "$*" >> "${CALLS:?}"
last=""
for a in "$@"; do last="$a"; done
case "$1 ${2:-}" in
    "image inspect") [ "${GW_HELD:-1}" = 1 ] || exit 1; printf '%s\n' "$last" ;;
    "ps -a") printf '%b' "${DOCKER_PS:-}" ;;
esac
exit 0
STUB
# curl: the probe listener's /health and /ready answer per GW_HEALTH / GW_READY.
cat > "$T/bin/curl" <<'STUB'
#!/usr/bin/env bash
u=""
for a in "$@"; do u="$a"; done
case "$u" in
    */health)    [ "${GW_HEALTH:-1}" = 1 ] && exit 0 ;;
    */ready)     [ "${GW_READY:-1}" = 1 ] && exit 0 ;;
    */ready/any) [ "${GW_READY:-1}" = 1 ] && exit 0 ;;
esac
exit 22
STUB
# ss: `ss -ltn` with SS_LINES under the header.
cat > "$T/bin/ss" <<'STUB'
#!/usr/bin/env bash
printf 'State  Recv-Q Send-Q Local Address:Port Peer Address:Port Process\n'
printf '%b' "${SS_LINES:-}"
STUB
# ufw: `ufw status` prints UFW_OUT.
cat > "$T/bin/ufw" <<'STUB'
#!/usr/bin/env bash
printf 'ufw %s\n' "$*" >> "${CALLS:?}"
[ "${1:-}" = status ] && printf '%b' "${UFW_OUT:-Status: inactive\n}"
exit 0
STUB
chmod +x "$T/bin/"*
PATH="$T/bin:$PATH"
export PATH
hash -r
export GW_ENABLED=1 GW_ACTIVE=1 GW_HELD=1 GW_HEALTH=1 GW_READY=1
SS_OK="LISTEN 0 4096 127.0.0.1:8655 0.0.0.0:*\nLISTEN 0 4096 127.0.0.1:8656 0.0.0.0:*\nLISTEN 0 4096 127.0.0.1:9655 0.0.0.0:*\n"
export SS_LINES="$SS_OK" UFW_OUT="" DOCKER_PS=""

# --- check-node.sh functions over the real libraries ----------------------------
{
    for f in have_fns detect_data_dir read_advertised_rpc advertised_rpc; do
        sed -n "/^${f}() {/,/^}/p" "$CN"
    done
    awk '/^# HARDENING CHECKS/ { f = 1 } /^# REPORT HEADER/ { f = 0 } f' "$CN"
} > "$T/fns.sh"
eval "$(tn_test_source_common)"
# shellcheck source=/dev/null
. "$T/fns.sh"
check "functions cut out of check-node.sh, real gw_status loaded" "yes" \
    "$(declare -F check_gateway check_gateway_upstream _cn_gw_listener advertised_rpc gw_status >/dev/null && echo yes)"
LAUNCH="$R/usr/local/libexec/telcoin/tn-start"
tn_node_launch_target() { printf 'telcoin source %s\n' "$LAUNCH"; }
detect_data_dir() { printf '%s\n' "$R/var/lib/telcoin"; }
SERVICE_NAME=telcoin
HP="$TN_KUMA_PORT"
GWIMG="us-docker.pkg.dev/telcoin-network/tn-public/worker-gateway@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
GWUNIT="$R/etc/systemd/system/telcoin-gateway.service"
GWMETA="$R/etc/telcoin/gateway/gateway.meta"

has() { if grep -qF -- "$1" <<< "$2"; then echo yes; else echo no; fi; }
cnt() { grep -cF -- "$1" <<< "$2"; }
runc() {  # runc FN -> OUT (its output and a last line issues=<HEALTH_ISSUES>)
    HEALTH_ISSUES=0
    OUT="$("$@" 2>&1; printf '\nissues=%s' "$HEALTH_ISSUES")"
}
fresh() {
    rm -rf "$R"
    mkdir -p "$R/etc/telcoin" "$R/etc/systemd/system" "$R/usr/local/libexec/telcoin" "$R/etc/caddy" \
             "$R/var/lib/telcoin"
    : > "$CALLS"
    GW_ENABLED=1 GW_ACTIVE=1 GW_HELD=1 GW_HEALTH=1 GW_READY=1 SS_LINES="$SS_OK" UFW_OUT="" DOCKER_PS=""
    unset FAKE_UID
}
mknode() {  # mknode [META_LINE...] -- .node-meta and a source start script with NODE_FLAGS
    printf '%s\n' NETWORK=devnet INSTALL_METHOD=source "$@" > "$R/etc/telcoin/.node-meta"
    _tn_start_script_text source /opt/telcoin/telcoin-network "--datadir /var/lib/telcoin --http ${NODE_FLAGS}" > "$LAUNCH"
}
mkgw() {  # mkgw MODE FRONT -- gateway.meta, the unit gw_unit_text renders from it, the Caddy block
    local up=127.0.0.1 dom=gw.example.org
    [[ "$1" != standalone ]] || up=10.0.0.5
    [[ "$2" != none ]] || dom=""
    mkdir -p "${GWMETA%/*}"
    printf '%s\n' GATEWAY_META_VERSION=1 NETWORK=devnet "MODE=$1" "FRONT=$2" "DOMAIN=$dom" "IMAGE=$GWIMG" \
        "UPSTREAM_HOST=$up" RPC_PORT=8545 "HEALTH_PORT=$HP" LISTEN_PORT=8655 PROBE_PORT=8656 \
        METRICS_PORT=9655 REDIRECT_QUERIES=https://rpc.example.org TRUSTED_PROXIES= > "$GWMETA"
    _gw_load_meta || printf 'fixture gateway.meta refused: %s\n' "$GW_ERR"
    gw_unit_text > "$GWUNIT"
    if [[ "$2" == caddy ]]; then
        printf '%s\n' "node.example.org {" "}" "# >>> tn-gateway >>>" "gw.example.org {" \
            "    reverse_proxy 127.0.0.1:8655" "}" "# <<< tn-gateway <<<" > "$R/etc/caddy/Caddyfile"
    fi
}
gwonly() {  # what a host with only a gateway lacks: the node's .node-meta, data dir and start script
    rm -rf "$R/etc/telcoin/.node-meta" "$R/var/lib/telcoin" "$R/usr/local/libexec/telcoin"
}
snap() { (cd "$R" && find . -print | LC_ALL=C sort && find . -type f -exec cksum {} + | LC_ALL=C sort); }

# =============================================================================
# check_gateway
# =============================================================================
NODE_FLAGS="--http.addr 127.0.0.1 --healthcheck ${HP}"
fresh; mknode; mkgw same-host caddy
runc check_gateway
check_has "healthy same-host gateway: no issue" "issues=0" "$OUT"
check "healthy: gw_status's ok line" yes "$(has 'Worker gateway: same-host, front caddy, ready' "$OUT")"
check "healthy: three listeners ok" 3 "$(cnt 'listener on 127.0.0.1:' "$OUT")"
check "healthy: node --healthcheck ok" yes "$(has "Node launch line has --healthcheck 127.0.0.1:${HP}" "$OUT")"
check_lacks "healthy: /ready not repeated by check-node" "Gateway /ready" "$OUT"
check_lacks "healthy: no error line" "[ERROR]" "$OUT"

fresh; mknode; mkgw same-host caddy
GW_ACTIVE=0 GW_HEALTH=0 GW_READY=0 runc check_gateway
check_has "unit stopped: one issue" "issues=1" "$OUT"
check "unit stopped: says not running" yes "$(has 'telcoin-gateway.service is not running' "$OUT")"
check "unit stopped: listeners not checked" yes "$(has 'Gateway listeners: not checked (the gateway is not running)' "$OUT")"

fresh; mknode; mkgw same-host caddy
GW_HELD=0 runc check_gateway
check_has "image not held: one issue" "issues=1" "$OUT"
check "image not held: said" yes "$(has "docker does not hold the gateway image ${GWIMG}" "$OUT")"

fresh; mknode; mkgw same-host caddy
SS_LINES="LISTEN 0 4096 127.0.0.1:8655 0.0.0.0:*\nLISTEN 0 4096 127.0.0.1:8656 0.0.0.0:*\n" runc check_gateway
check_has "metrics listener missing: one issue" "issues=1" "$OUT"
check "metrics listener missing: said" yes "$(has 'Gateway metrics listener: nothing listens on 127.0.0.1:9655' "$OUT")"
SS_LINES="LISTEN 0 4096 127.0.0.1:8655 0.0.0.0:*\nLISTEN 0 4096 0.0.0.0:8656 0.0.0.0:*\nLISTEN 0 4096 127.0.0.1:9655 0.0.0.0:*\n" \
    runc check_gateway
check_has "probe listener on 0.0.0.0, not loopback: one issue" "issues=1" "$OUT"
check "probe listener misbound: names the bind" yes "$(has 'Gateway probe listener is bound at 0.0.0.0:8656, not at 127.0.0.1:8656' "$OUT")"

fresh; mknode; mkgw same-host none
SS_LINES="LISTEN 0 4096 [::]:8655 [::]:*\nLISTEN 0 4096 127.0.0.1:8656 0.0.0.0:*\nLISTEN 0 4096 127.0.0.1:9655 0.0.0.0:*\n" \
    runc check_gateway
check_has "front none, listener on [::]: no issue" "issues=0" "$OUT"
check "front none: [::]:8655 is the wildcard listener" yes "$(has 'Gateway listen listener on 0.0.0.0:8655' "$OUT")"
SS_LINES="LISTEN 0 4096 *:8655 *:*\nLISTEN 0 4096 127.0.0.1:8656 0.0.0.0:*\nLISTEN 0 4096 127.0.0.1:9655 0.0.0.0:*\n" \
    runc check_gateway
check_has "front none, listener on *: no issue" "issues=0" "$OUT"

fresh; mknode; mkgw same-host caddy
GW_READY=0 runc check_gateway
check_has "/ready 503: not an issue" "issues=0" "$OUT"
check "/ready 503: reported once (by gw_status)" 1 "$(cnt '/ready' "$OUT")"
check "/ready 503: the line says submissions get 503" yes "$(has 'submissions get 503' "$OUT")"

fresh; mknode; mkgw same-host caddy
sed 's/@sha256:0123/@sha256:9123/' "$GWUNIT" > "$T/unit" && cp "$T/unit" "$GWUNIT"
runc check_gateway
check_has "unit image differs from gateway.meta: one issue" "issues=1" "$OUT"
check "unit image differs: gw_status's drift line" yes "$(has 'The unit differs from /etc/telcoin/gateway/gateway.meta' "$OUT")"
check_lacks "unit image differs: not counted twice" "ExecStart image" "$OUT"

NODE_FLAGS="--http.addr 127.0.0.1"
fresh; mknode; mkgw same-host caddy
runc check_gateway
check_has "same-host node without --healthcheck: one issue" "issues=1" "$OUT"
check "no --healthcheck: said" yes "$(has "the node's launch line has no --healthcheck ${HP}" "$OUT")"
fresh; mknode; mkgw standalone caddy
runc check_gateway
check_has "standalone gateway: the node's --healthcheck is not asked" "issues=0" "$OUT"
NODE_FLAGS="--http.addr 127.0.0.1 --healthcheck ${HP}"

fresh; mknode; mkgw same-host caddy
printf '%s\n' "node.example.org {" "}" > "$R/etc/caddy/Caddyfile"
runc check_gateway
check_has "front caddy, Caddy block missing: one issue" "issues=1" "$OUT"
check "Caddy block missing: said" yes "$(has 'The Caddyfile has no tn-gateway block' "$OUT")"

fresh; mknode; mkgw same-host caddy
if [[ "$("$REAL_ID" -u)" == "0" ]]; then
    skip "not root: gateway.meta unreadable" "running as root, chmod 000 does not hide the file"
else
    chmod 000 "$GWMETA"
    runc check_gateway
    chmod 600 "$GWMETA"
    check_has "not root: no issue" "issues=0" "$OUT"
    check "not root: gw_status reads the unit file" yes "$(has 'Not root: /etc/telcoin/gateway/gateway.meta cannot be read' "$OUT")"
    check "not root: listeners still checked" 3 "$(cnt 'listener on 127.0.0.1:' "$OUT")"
    check "not root: --healthcheck still checked" yes "$(has 'Node launch line has --healthcheck' "$OUT")"
fi

OUT="$(unset -f gw_status; HEALTH_ISSUES=0; check_gateway 2>&1; printf '\nissues=%s\nrc=%s' "$HEALTH_ISSUES" "$?")"
check_has "older lib/gateway.sh: no issue" "issues=0" "$OUT"
check_has "older lib/gateway.sh: rc 0" "rc=0" "$OUT"
check "older lib/gateway.sh: one skip line" 1 "$(grep -c . <<< "$(sed '/^issues=/d;/^rc=/d' <<< "$OUT")")"
check "older lib/gateway.sh: it says update" yes "$(has 'the gateway checks were skipped. Run update-scripts.sh.' "$OUT")"
rm -rf "${GWMETA%/*}" "$GWUNIT"
OUT="$(unset -f gw_status; check_gateway 2>&1)"
check "older lib/gateway.sh, no gateway here: silent" "" "$OUT"
echo "status: check_gateway group done" >&2

# =============================================================================
# a host with a worker gateway and no node: the whole script
# =============================================================================
fresh; mkgw standalone none; gwonly
SS_LINES="LISTEN 0 4096 0.0.0.0:8655 0.0.0.0:*\nLISTEN 0 4096 127.0.0.1:8656 0.0.0.0:*\nLISTEN 0 4096 127.0.0.1:9655 0.0.0.0:*\n"
TO=""
if command -v timeout >/dev/null 2>&1; then TO="timeout 120"; fi
# shellcheck disable=SC2086
(cd "$T" && $TO bash "$CN" --no-network) > "$T/full.out" 2>&1
rc=$?
OUT="$(cat "$T/full.out")"
check_rc "gateway-only host: exit status 0" 0 "$rc"
check "gateway-only host: the one-line notice" 1 "$(cnt 'only a worker gateway: the node sections are skipped' "$OUT")"
check "gateway-only host: gateway section ran" yes "$(has 'Checking the worker gateway...' "$OUT")"
check "gateway-only host: gw_status ran" yes "$(has 'Worker gateway: standalone, front none, ready' "$OUT")"
check_lacks "gateway-only host: service section skipped" "Checking systemd service" "$OUT"
check_lacks "gateway-only host: no 'no node detected' warning" "No Telcoin node detected" "$OUT"
check_lacks "gateway-only host: no error line" "[ERROR]" "$OUT"
check_lacks "gateway-only host: no validator-side section" "gateway upstream (validator side)" "$OUT"
echo "status: gateway-only group done" >&2

# =============================================================================
# check_gateway_upstream (the validator side)
# =============================================================================
ufw_rules() {  # ufw_rules "SRC PORT"... -- an active ufw (default deny incoming) with these allow rules
    local r out="Status: active\nDefault: deny (incoming), allow (outgoing), disabled (routed)\n\nTo                         Action      From\n--                         ------      ----\n"
    for r in "$@"; do
        out="${out}${r##* }/tcp                   ALLOW       ${r%% *}\n"
    done
    UFW_OUT="$out"
}
nodeinfo() {  # nodeinfo HTTP [WS] -- node-info.yaml with worker 0's rpc
    {
        printf '%s\n' "name: v1" "p2p_info:" "  workers:" "    - rpc:" "        http: $1"
        [[ -z "${2:-}" ]] || printf '        ws: %s\n' "$2"
    } > "$R/var/lib/telcoin/node-info.yaml"
}
ALL4="10.0.0.5 8545|10.0.0.5 ${HP}|10.0.0.6 8545|10.0.0.6 ${HP}"
# shellcheck disable=SC2086  # $1 is split on | on purpose
setrules() { local IFS='|'; set -- $1; ufw_rules "$@"; }
FROM=GATEWAY_ALLOW_FROM=10.0.0.5,10.0.0.6
UP=GATEWAY_UPSTREAM=10.0.0.5,10.0.0.6

NODE_FLAGS="--http.addr 0.0.0.0 --healthcheck 0.0.0.0:${HP}"
fresh; mknode "$FROM" "$UP"; nodeinfo https://gw.example.org; setrules "$ALL4"
FAKE_UID=0 runc check_gateway_upstream
check_has "validator, rules and binds in place: no issue" "issues=0" "$OUT"
check "validator: ufw rules ok" yes "$(has "ufw lets 10.0.0.5,10.0.0.6 reach the RPC port 8545 and the health port ${HP}" "$OUT")"
check "validator: binds ok with GATEWAY_UPSTREAM" yes "$(has 'RPC and --healthcheck listen on 0.0.0.0 for the gateway' "$OUT")"
check "validator: https and no ws is ok" yes "$(has 'node-info.yaml advertises https://gw.example.org and no ws URL' "$OUT")"

setrules "10.0.0.5 8545|10.0.0.5 ${HP}|10.0.0.6 8545"
FAKE_UID=0 runc check_gateway_upstream
check_has "validator, one rule missing: one issue" "issues=1" "$OUT"
check "one rule missing: names the rule" yes "$(has "ufw has no rule 'allow from 10.0.0.6 to any port ${HP} proto tcp'" "$OUT")"
check "one rule missing: names --gateway-from with the whole list" yes \
    "$(has 'firewall-setup.sh --enable --gateway-from 10.0.0.5,10.0.0.6' "$OUT")"

fresh; mknode "$FROM"; nodeinfo https://gw.example.org; setrules "$ALL4"
FAKE_UID=0 runc check_gateway_upstream
check_has "wildcard binds without GATEWAY_UPSTREAM: two issues" "issues=2" "$OUT"
check "wildcard RPC: the hint names edit-config.sh's RPC access item" yes \
    "$(has "run sudo bash edit-config.sh, choose 'RPC access', then '1) Private'" "$OUT")"
check "wildcard --healthcheck: the hint names the launch file" yes \
    "$(has "set --healthcheck 127.0.0.1:${HP} on the node command in ${LAUNCH}" "$OUT")"
check_lacks "wildcard binds: no gateway_upstream=off hint" "gateway_upstream=off" "$OUT"

NODE_FLAGS="--http.addr 0.0.0.0 --healthcheck ${HP}"
fresh; mknode "$FROM"; nodeinfo https://gw.example.org; setrules "$ALL4"
printf '%s\n' "# >>> tn-rpc >>>" "rpc.example.org {" "}" "# <<< tn-rpc <<<" > "$R/etc/caddy/Caddyfile"
FAKE_UID=0 runc check_gateway_upstream
check_has "wildcard RPC behind the public-RPC Caddy block: no issue" "issues=0" "$OUT"
check "public-RPC block: said" yes "$(has 'the public-RPC Caddy block fronts it' "$OUT")"

NODE_FLAGS="--http.addr 0.0.0.0 --healthcheck 0.0.0.0:${HP}"
fresh; mknode "$FROM" "$UP"; nodeinfo https://gw.example.org wss://gw.example.org; setrules "$ALL4"
FAKE_UID=0 runc check_gateway_upstream
check_has "advertised ws URL: information, no issue" "issues=0" "$OUT"
check "advertised ws URL: names rpc-advertise" yes "$(has 'install-caddy.sh --phase rpc-advertise' "$OUT")"

fresh; mknode "$FROM" "$UP"; nodeinfo https://gw.example.org; setrules "$ALL4"
FAKE_UID=1000 runc check_gateway_upstream
check_has "validator, not root: no false issue" "issues=0" "$OUT"
check "not root: one information line for ufw" 1 "$(cnt 'Gateway firewall rules: not checked (reading ufw needs sudo)' "$OUT")"
check_lacks "not root: ufw not run" "ufw " "$(cat "$CALLS")"

fresh; mknode; nodeinfo https://gw.example.org
runc check_gateway_upstream
check "no gateway settings in .node-meta: silent" "issues=0" "$(sed '/^$/d' <<< "$OUT")"

# Nobody but the gateways gets in (tn_gateway_ports_private), with GATEWAY_UPSTREAM set.
NODE_FLAGS="--http.addr 0.0.0.0 --healthcheck 0.0.0.0:${HP}"
fresh; mknode "$FROM" "$UP"; nodeinfo https://gw.example.org; setrules "$ALL4"
UFW_OUT="${UFW_OUT}8545/tcp (v6)              ALLOW       Anywhere (v6)\n"
FAKE_UID=0 runc check_gateway_upstream
check_has "upstream set, RPC port open to Anywhere: one issue" "issues=1" "$OUT"
check "open to Anywhere: named" yes "$(has "ufw has a rule letting any address (Anywhere) in to port 8545" "$OUT")"
fresh; mknode "$FROM" "$UP"; nodeinfo https://gw.example.org; setrules "$ALL4"
UFW_OUT="${UFW_OUT//deny (incoming)/allow (incoming)}"
FAKE_UID=0 runc check_gateway_upstream
check_has "upstream set, default allow incoming: one issue" "issues=1" "$OUT"
check "default allow: named" yes "$(has "default policy for incoming traffic is allow" "$OUT")"
NODE_FLAGS="--http.addr 127.0.0.1 --healthcheck ${HP}"
fresh; mknode "$FROM"; nodeinfo https://gw.example.org; setrules "$ALL4"
UFW_OUT="${UFW_OUT}8545/tcp                   ALLOW       Anywhere\n"
FAKE_UID=0 runc check_gateway_upstream
check_has "no GATEWAY_UPSTREAM: an open port is not this section's issue" "issues=0" "$OUT"

# The RPC port as edit-config.sh and firewall-setup.sh read it (tn_local_rpc_url).
NODE_FLAGS="--http.addr 0.0.0.0 --healthcheck 0.0.0.0:${HP}"
fresh; mknode "$FROM" "$UP" RPC_PORT=08545; nodeinfo https://gw.example.org; setrules "$ALL4"
FAKE_UID=0 runc check_gateway_upstream
check_has "RPC_PORT=08545: no false issue" "issues=0" "$OUT"
check "RPC_PORT=08545: read as 8545" yes "$(has "reach the RPC port 8545 and" "$OUT")"
fresh; mknode "$FROM" "$UP"; nodeinfo https://gw.example.org
setrules "10.0.0.5 9545|10.0.0.5 ${HP}|10.0.0.6 9545|10.0.0.6 ${HP}"
RPC_PORT=9545 FAKE_UID=0 runc check_gateway_upstream
check_has "RPC_PORT from the environment: no false issue" "issues=0" "$OUT"

# A hand-edited GATEWAY_UPSTREAM is split without globbing.
mkdir -p "$T/globdir" && : > "$T/globdir/10.0.0.9"
fresh; mknode "$FROM" "GATEWAY_UPSTREAM=10.0.0.*"; nodeinfo https://gw.example.org; setrules "$ALL4"
cd "$T/globdir" || exit 1
FAKE_UID=0 runc check_gateway_upstream
cd "$OLDPWD" || exit 1
check "glob in GATEWAY_UPSTREAM: the value as written" yes "$(has "allow from 10.0.0.* to any port 8545" "$OUT")"
check_lacks "glob in GATEWAY_UPSTREAM: not expanded to a file name" "10.0.0.9" "$OUT"
echo "status: validator group done" >&2

# =============================================================================
# remove-node.sh
# =============================================================================
sed -e '/^main "\$@"$/d' -e 's|^source "\${SCRIPT_DIR}/lib/common.sh"$|: lib/common.sh is already sourced|' \
    "$TN_TEST_REPO/remove-node.sh" > "$T/rn/remove-node.sh"
ln -s "$TN_TEST_REPO/lib" "$T/rn/lib"
check "remove-node.sh copy: common.sh source line dropped" 1 "$(cnt ': lib/common.sh is already sourced' "$(cat "$T/rn/remove-node.sh")")"
# shellcheck source=/dev/null
source "$T/rn/remove-node.sh"
set +e
CONFIRM_ANSWER=no
confirm() { [[ "$CONFIRM_ANSWER" == "yes" ]]; }
calls() { grep -E '^(systemctl|docker) ' "$CALLS"; }
NODE_FLAGS="--http.addr 127.0.0.1 --healthcheck ${HP}"

fresh; mknode; mkgw same-host caddy
RM_JSON=false
OUT="$(remove_gateway 2>&1)"
check "remove_gateway: the call sequence" "systemctl disable --now telcoin-gateway.service
systemctl stop telcoin-gateway.service
docker rm -f telcoin-gateway
systemctl daemon-reload
systemctl reset-failed telcoin-gateway.service" "$(calls)"
check "remove_gateway: unit gone" no "$([[ -e "$GWUNIT" ]] && echo yes || echo no)"
check "remove_gateway: /etc/telcoin/gateway gone" no "$([[ -e "${GWMETA%/*}" ]] && echo yes || echo no)"
check "remove_gateway: the node's .node-meta kept" yes "$([[ -f "$R/etc/telcoin/.node-meta" ]] && echo yes || echo no)"
check "remove_gateway: image kept, named" yes "$(has "The worker gateway image is kept: ${GWIMG} (remove it with: docker image rm ${GWIMG})" "$OUT")"
check "remove_gateway: Caddy fence present, hint given" yes "$(has 'install-caddy.sh --phase gateway-disable' "$OUT")"

fresh; mknode; mkgw same-host none
OUT="$(remove_gateway 2>&1)"
check_lacks "remove_gateway: no Caddy fence, no hint" "gateway-disable" "$OUT"

fresh; mknode
OUT="$(remove_gateway 2>&1)"
check "remove_gateway without a gateway: no output" "" "$OUT"
check "remove_gateway without a gateway: no call" "" "$(calls)"

fresh; mknode; mkgw same-host caddy
mkdir -p "$T/nodock"
for d in /usr/local/bin /usr/bin /bin /usr/sbin /sbin; do
    [[ -d "$d" ]] || continue
    for f in "$d"/*; do
        n="${f##*/}"
        [[ "$n" != docker && ! -e "$T/nodock/$n" ]] || continue
        ln -s "$f" "$T/nodock/$n" 2>/dev/null
    done
done
for n in systemctl id curl ss ufw; do ln -sf "$T/bin/$n" "$T/nodock/$n"; done
# shellcheck disable=SC2123  # PATH without docker, in this subshell only
OUT="$(PATH="$T/nodock"; hash -r; command -v docker >/dev/null 2>&1 && echo DOCKER-ON-PATH; remove_gateway 2>&1)"
hash -r
check_lacks "no docker: precondition, docker not on PATH" "DOCKER-ON-PATH" "$OUT"
check_lacks "no docker: no docker call" "docker rm" "$(calls)"
check "no docker: unit and directory gone" "no no" \
    "$([[ -e "$GWUNIT" ]] && echo yes || echo no) $([[ -e "${GWMETA%/*}" ]] && echo yes || echo no)"
check "no docker: image line still given" yes "$(has 'The worker gateway image is kept' "$OUT")"

fresh; mknode; mkgw same-host caddy
RM_JSON=true
remove_gateway 3> "$T/j" > "$T/o" 2> "$T/e"
RM_JSON=false
check "--json: nothing on stdout" "" "$(cat "$T/o")"
check "--json: every fd-3 line is an event" "0" \
    "$(grep -cvE '^\{"event":"(step|log|warn)","msg":"[^"]*"\}$' "$T/j")"
check "--json: step, image and Caddy events" "3" "$(grep -cE 'Removing the worker gateway|image is kept|gateway-disable' "$T/j")"
check "--json: unit gone" no "$([[ -e "$GWUNIT" ]] && echo yes || echo no)"

# A host with a gateway and no node: the pointer, nothing removed.
fresh; mkgw standalone caddy; gwonly
before="$(snap)"
(INSTALLED_UNITS=(); show_detected) < /dev/null > "$T/o" 2>&1
rc=$?
OUT="$(cat "$T/o")"
check_rc "gateway-only host, menu: exit 0" 0 "$rc"
check "gateway-only host, menu: the pointer" yes "$(has 'remove it with: sudo bash setup-gateway.sh --remove' "$OUT")"
check "gateway-only host, menu: nothing removed" "$before" "$(snap)"
check "gateway-only host, menu: no systemctl or docker change" "" "$(calls | grep -vE ' is-| list-')"
fresh; gwonly
(INSTALLED_UNITS=(); show_detected) < /dev/null > "$T/o" 2>&1
check_rc "no gateway, no node, menu: exit 0 as well" 0 "$?"
check_lacks "no gateway, no node, menu: no pointer" "setup-gateway.sh --remove" "$(cat "$T/o")"

fresh; mkgw standalone caddy; gwonly
before="$(snap)"
# shellcheck disable=SC2034  # read by the sourced remove-node.sh
(RM_JSON=true; json_remove validator keys) 3> "$T/j" > "$T/o" 2> "$T/e"
rc=$?
check_rc "gateway-only host, --json: rc 1 (no node)" 1 "$rc"
check "gateway-only host, --json: the pointer as an event" 1 "$(grep -c '"event":"log".*setup-gateway.sh --remove' "$T/j")"
check "gateway-only host, --json: no node installed" 1 "$(grep -c '"event":"error","msg":"no node installed"' "$T/j")"
check "gateway-only host, --json: nothing on stdout" "" "$(cat "$T/o")"
check "gateway-only host, --json: nothing removed" "$before" "$(snap)"

# The custom-install scan: the gateway's unit name and container are managed.
custom_is_managed_name telcoin-gateway
check_rc "custom scan: telcoin-gateway is a managed name" 0 "$?"
fresh
DOCKER_PS="telcoin-gateway\t${GWIMG}\tUp 2 hours\nmytn\tghcr.io/telcoin-association/tn-dev:latest\tUp 3 hours\n"
export DOCKER_PS
OUT="$(scan_custom_installs < /dev/null 2>&1)"
DOCKER_PS=""
check "custom scan: another node container is offered" yes "$(has '[CUSTOM] Docker container: mytn' "$OUT")"
check_lacks "custom scan: the gateway container is not offered" "telcoin-gateway" "$OUT"
check_lacks "custom scan: nothing removed (declined)" "docker rm" "$(calls)"

# A node host with a gateway, the operator declines: everything kept.
fresh; mknode; mkgw same-host caddy
cp "$LAUNCH" "$R/etc/systemd/system/telcoin.service"
before="$(snap)"
OUT="$(INSTALLED_UNITS=(telcoin); remove_all_nodes < /dev/null 2>&1)"
check "node host, declined: cancelled" yes "$(has 'Cancelled -- no changes made.' "$OUT")"
check "node host, declined: everything kept" "$before" "$(snap)"
check "node host, declined: no systemctl or docker call" "" "$(calls)"
rm -f "$R/etc/systemd/system/telcoin.service"
before="$(snap)"
# shellcheck disable=SC2034  # read by the sourced remove-node.sh
OUT="$(INSTALLED_UNITS=(); remove_leftovers < /dev/null 2>&1)"
check "node leftovers and a gateway: the gateway is listed" yes "$(has 'telcoin-gateway.service, its container and /etc/telcoin/gateway' "$OUT")"
check "node leftovers, declined: kept" yes "$(has 'Leftover files kept.' "$OUT")"
check "node leftovers, declined: everything kept" "$before" "$(snap)"
echo "status: remove group done" >&2

finish
