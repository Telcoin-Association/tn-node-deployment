#!/usr/bin/env bash
# =============================================================================
# tools/tests/gateway_setup_test.sh -- lib/gateway.sh and setup-gateway.sh, the
# worker gateway's installer:
#
#   library   the argument line and the unit text, literally, for same-host +
#             caddy, same-host + none and standalone + caddy; every refusal of
#             --enable leaves the tree byte-identical and runs neither systemctl
#             nor docker run; the image trust rule (tags, the devnet allow-list,
#             the testnet/mainnet pins, an image whose --help lacks a flag); a
#             second enable with the same inputs writes and restarts nothing but
#             still runs the Caddy phase; a failed first enable leaves nothing, a
#             failed change over an installation puts the unit and meta back byte
#             for byte, a failed put-back is rc 2; refresh; remove; status, also
#             without root; the node's unit never reaches systemctl;
#   script    --help, no action, two actions, an unknown argument, a missing
#             value, a flag outside its action (one done line each with --json);
#             the done line's field names and JSON types; exit 1, 2, 3 and 143;
#             consent with --yes and without a terminal; --network on a node host
#             and on a host without a node.
#
#   bash tools/tests/run.sh tools/tests/gateway_setup_test.sh
#   docker run --rm --network none -v "$PWD:/w:ro" -w /w bash:3.2 bash tools/tests/run.sh tools/tests/gateway_setup_test.sh
#
# docker, systemctl, curl and sleep are PATH stubs that log to $T and keep the
# unit's state in $T/sd/<tree>; install-caddy.sh is a stand-in that writes a
# tn-gateway block and answers one done event on fd 3. The root primitives
# (tn_write_root_file, _tn_root_layout_dir, tn_backup_file, tn_restore_backup),
# the update lock and the host baseline are stand-ins, the same in this shell and
# in the setup-gateway.sh copy (its lib/common.sh sources the real one, then
# them). An `id` stand-in answers SGT_UID (default 0) for the script.
# Maintainer tooling (not updater-tracked). bash 3.2 safe.
# =============================================================================
set -u
umask 022
# shellcheck source=tools/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
T="$TN_TEST_TMP"
NODE="$T/node"   # a devnet node host (launch file with --healthcheck)
SA="$T/sa"       # a host without a node
export TN_ROOT_PREFIX="$NODE"
export TN_UPDATE_LOCK_FILE="$T/update.lock"
export TN_EXIT_TRAP_OWNED=1
export GW_HEALTH_WAIT=1
export GWT_DIR="$T"
mkdir -p "$T/bin" "$T/sgbin" "$T/sd" "$T/backups" "$T/sg/lib" \
    "$NODE/etc/telcoin" "$NODE/etc/systemd/system" "$NODE/usr/local/libexec/telcoin" \
    "$SA/etc/systemd/system"

# --- stubs ----------------------------------------------------------------------
cat > "$T/bin/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GWT_DIR/docker.log"
d="$GWT_DIR/sd/${TN_ROOT_PREFIX##*/}"
last=""
for a in "$@"; do last="$a"; done
case "${1:-}" in
    info) [ -f "$GWT_DIR/docker-down" ] && exit 1; exit 0 ;;
    image) grep -qxF -- "$last" "$GWT_DIR/held" 2>/dev/null && printf '%s\n' "$last"; exit 0 ;;
    pull) printf '%s\n' "$2" >> "$GWT_DIR/held"; exit 0 ;;
    run)
        lacks="$(cat "$GWT_DIR/help-lacks" 2>/dev/null)"
        printf 'Usage: worker-gateway [OPTIONS]\n'
        for f in --listen-addr --probe-addr --metrics --upstream-rpc-url --upstream-readiness-url \
                 --worker-id --redirect-queries --trusted-proxies; do
            [ "$f" = "$lacks" ] && continue
            printf '      %s <VALUE>\n' "$f"
        done
        exit 0 ;;
    container) [ -f "$d/active" ]; exit $? ;;
    *) exit 0 ;;
esac
STUB
cat > "$T/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GWT_DIR/systemctl.log"
printf '%s\n' "$*" >> "$GWT_DIR/systemctl.all"
d="$GWT_DIR/sd/${TN_ROOT_PREFIX##*/}"
mkdir -p "$d"
case "${1:-}" in
    is-enabled) [ -f "$d/enabled" ]; exit $? ;;
    is-active) [ -f "$d/active" ]; exit $? ;;
    enable) : > "$d/enabled"; exit 0 ;;
    disable) rm -f "$d/enabled"; [ "${2:-}" = --now ] && rm -f "$d/active"; exit 0 ;;
    restart|start)
        [ -f "$GWT_DIR/selfkill" ] && kill -TERM "$PPID"
        : > "$d/active"; exit 0 ;;
    stop) rm -f "$d/active"; exit 0 ;;
    *) exit 0 ;;
esac
STUB
cat > "$T/bin/curl" <<'STUB'
#!/usr/bin/env bash
u=""
for a in "$@"; do u="$a"; done
printf '%s\n' "$u" >> "$GWT_DIR/curl.log"
printf '%s\n' "$*" >> "$GWT_DIR/curl.args"
# The upstream's eth_chainId (lib/gateway.sh _gw_chain_ask): the id in chain-id.
case "$u" in
    http://*:*/)
        if [ -f "$GWT_DIR/chain-id" ]; then
            printf '{"jsonrpc":"2.0","id":1,"result":"%s"}\n' "$(cat "$GWT_DIR/chain-id")"
            exit 0
        fi ;;
esac
[ -f "$GWT_DIR/sd/${TN_ROOT_PREFIX##*/}/active" ] || exit 7
[ -f "$GWT_DIR/health-fails" ] && exit 22
case "$u" in */ready|*/ready/any) [ -f "$GWT_DIR/not-ready" ] && exit 22 ;; esac
exit 0
STUB
# timeout: logs its arguments; help-hangs makes it end as a timeout would (124).
cat > "$T/bin/timeout" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GWT_DIR/timeout.log"
[ -f "$GWT_DIR/help-hangs" ] && exit 124
shift
exec "$@"
STUB
printf '#!/bin/sh\nexit 0\n' > "$T/bin/sleep"
printf '#!/bin/sh\nif [ "${1:-}" = -u ]; then echo "${SGT_UID:-0}"; exit 0; fi\nexec /usr/bin/id "$@"\n' > "$T/sgbin/id"
# install-caddy.sh stand-in: the gateway phases only, one done event on fd 3.
cat > "$T/install-caddy.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GWT_DIR/caddy.log"
if [ -f "$GWT_DIR/caddy-fails" ]; then printf '{"event":"done","ok":false,"msg":"stand-in refusal"}\n' >&3; exit 1; fi
cf="${TN_ROOT_PREFIX}/etc/caddy/Caddyfile"
phase=""
prev=""
for a in "$@"; do [ "$prev" = --phase ] && phase="$a"; prev="$a"; done
mkdir -p "${cf%/*}"
case "$phase" in
    gateway-enable)
        want="$(printf '# >>> tn-gateway >>>\n# %s\n# <<< tn-gateway <<<' "$*")"
        if [ "$(cat "$cf" 2>/dev/null)" != "$want" ]; then printf '%s\n' "$want" > "$cf"; m="block written"; else m="block current"; fi ;;
    gateway-disable) : > "$cf"; m="block removed" ;;
    *) m="phase ${phase}" ;;
esac
echo "human text on stderr" >&2
printf '{"event":"done","ok":true,"msg":"%s"}\n' "$m" >&3
STUB
chmod 0755 "$T/bin/"* "$T/sgbin/id" "$T/install-caddy.sh"
export PATH="$T/bin:$PATH"

# Root primitives, lock and baseline: the same stand-ins here and in the script.
cat > "$T/standins.sh" <<'STUB'
# shellcheck shell=bash
tn_write_root_file() {
    local tmp
    printf '%s %s\n' "${1#"$TN_ROOT_PREFIX"}" "${2:-}" >> "$GWT_DIR/writes"
    tmp="$(mktemp "${1%/*}/.tn.XXXXXX")" || return 2
    if ! cat > "$tmp" || ! chmod "$2" "$tmp" || ! mv -f "$tmp" "$1"; then
        rm -f "$tmp"
        return 2
    fi
}
_tn_root_layout_dir() { mkdir -p "$1" && chmod "$3" "$1"; }
tn_root_dir_ok() { [[ -d "$1" && ! -L "$1" ]]; }
_tn_root_file_ok() { [[ ! -L "$1" ]]; }
tn_backup_file() {
    local b
    [[ -f "$1" && ! -L "$1" ]] || return 1
    b="$GWT_DIR/backups/${2:-${1##*/}}.$$.$RANDOM"
    cp -- "$1" "$b" || return 1
    printf '%s %s\n' "$b" "$(cksum < "$b" | cut -d' ' -f1)"
}
tn_restore_backup() {
    [[ ! -f "$GWT_DIR/restore-fails" ]] || return 1
    cp -- "$1" "$3" && chmod "$4" "$3"
}
addon_meta_lock() { printf 'lock\n' >> "$GWT_DIR/lock.log"; TN_UPDATE_LOCK_KIND=test; return 0; }
tn_release_update_lock() {
    if [[ -n "${TN_UPDATE_LOCK_KIND:-}" ]]; then printf 'release\n' >> "$GWT_DIR/lock.log"; fi
    TN_UPDATE_LOCK_KIND=""
    return 0
}
tn_host_baseline_refresh() { printf 'baseline\n' >> "$GWT_DIR/baseline.log"; return 0; }
_gw_is_root() { [[ "${SGT_UID:-0}" == 0 ]]; }
STUB

# --- the fixture node (devnet, --http.port 8544, --healthcheck 127.0.0.1:43180) ----
NMETA="$NODE/etc/telcoin/.node-meta"
START="$NODE/usr/local/libexec/telcoin/tn-start"
FLAGS_STD="--http --http.addr 0.0.0.0 --http.port 8544 --healthcheck 127.0.0.1:43180"
node_meta() {
    printf 'NETWORK=%s\nOWNERSHIP_LAYOUT=2\nINSTALL_METHOD=binary\nDATA_DIR=/var/lib/telcoin\n' "$1" > "$NMETA"
    chmod 0600 "$NMETA"
}
start_script() {
    printf '#!/bin/bash\nset -euo pipefail\nexec /opt/telcoin/telcoin-network node --datadir /var/lib/telcoin %s\n' "$1" > "$START"
    chmod 0755 "$START"
}
node_meta devnet
start_script "$FLAGS_STD"
printf '[Service]\nExecStart=/usr/local/libexec/telcoin/tn-start\n' > "$NODE/etc/systemd/system/telcoin.service"

eval "$(tn_test_source_common)"
if ! declare -F gw_enable >/dev/null 2>&1; then
    echo "lib/gateway.sh was not sourced by lib/common.sh" >&2
    exit 1
fi
# shellcheck source=/dev/null
. "$T/standins.sh"

# --- helpers --------------------------------------------------------------------
IMG="us-docker.pkg.dev/telcoin-network/tn-public/worker-gateway@sha256:$(printf '%064d' 0 | tr 0 a)"
IMG2="us-docker.pkg.dev/telcoin-network/tn-public/worker-gateway@sha256:$(printf '%064d' 0 | tr 0 b)"
OTHER="us-docker.pkg.dev/telcoin-network/tn-public/adiri@sha256:$(printf '%064d' 0 | tr 0 a)"
RQ="https://rpc.example.org/"
D="$T/bin/docker"
# shellcheck disable=SC2034  # read by lib/gateway.sh
GW_CADDY_SCRIPT="$T/install-caddy.sh"
has() {
    case "$1" in
        *"$2"*) echo yes ;;
        *) echo no ;;
    esac
}
exists() { if [[ -e "$1" || -L "$1" ]]; then echo yes; else echo no; fi; }
quiet() { printf '%s %s\n' "$1" "$2" >> "$T/say.log"; }
host() { export TN_ROOT_PREFIX="$1"; }
sd() { printf '%s\n' "$T/sd/${TN_ROOT_PREFIX##*/}"; }
# gin K=V... -- every GW_IN_* empty but IMAGE ($IMG) and REDIRECT ($RQ), then K=V.
# shellcheck disable=SC2034  # GW_IN_* are read by lib/gateway.sh
gin() {
    local kv
    GW_IN_MODE="" GW_IN_NETWORK="" GW_IN_IMAGE="$IMG" GW_IN_DOMAIN="" GW_IN_FRONT=""
    GW_IN_UPSTREAM="" GW_IN_RPC_PORT="" GW_IN_HEALTH_PORT="" GW_IN_REDIRECT="$RQ"
    GW_IN_LISTEN_PORT="" GW_IN_PROBE_PORT="" GW_IN_METRICS_PORT="" GW_IN_TRUSTED_PROXIES=""
    for kv in "$@"; do
        printf -v "GW_IN_${kv%%=*}" '%s' "${kv#*=}"
    done
}
logs_reset() {
    : > "$T/systemctl.log"
    : > "$T/docker.log"
    : > "$T/caddy.log"
    : > "$T/curl.log"
    : > "$T/lock.log"
}
# snap -- one checksum over the tree: every path, every file's bytes and modes.
snap() {
    (
        cd "$TN_ROOT_PREFIX" || exit 1
        find . | LC_ALL=C sort
        find . -type f -exec cksum {} + | LC_ALL=C sort
        find . -exec ls -ld {} + | awk '{ print $1, $NF }' | LC_ALL=C sort
    ) 2>&1 | cksum
}
fsum() { if [[ -f "$1" ]]; then cksum < "$1"; else echo absent; fi; }
mode_of() { ls -ld -- "$1" 2>/dev/null | cut -c1-10; }
# The systemctl calls that change something, and the docker run calls.
sys_changes() { grep -E '^(daemon-reload|enable|disable|start|stop|restart|reset-failed)( |$)' "$T/systemctl.log" | tr '\n' ';'; }
docker_runs() { grep -c '^run ' "$T/docker.log"; }
UNIT_P() { printf '%s\n' "$TN_ROOT_PREFIX/etc/systemd/system/telcoin-gateway.service"; }
META_P() { printf '%s\n' "$TN_ROOT_PREFIX/etc/telcoin/gateway/gateway.meta"; }
# want_unit MODE FRONT IMAGE ARGS -- the unit contract 3.3 describes.
want_unit() {
    printf '%s\n' \
        "# Written by setup-gateway.sh. Change it with setup-gateway.sh, not by hand." \
        "[Unit]" \
        "Description=Telcoin worker gateway ($1, front $2)" \
        "After=network-online.target docker.service" \
        "Wants=network-online.target" \
        "Requires=docker.service" \
        "" \
        "[Service]" \
        "Type=simple" \
        "ExecStartPre=-${D} rm -f telcoin-gateway" \
        "ExecStart=${D} run --rm --name telcoin-gateway --network=host --user 1101:1101 --read-only --cap-drop ALL --security-opt no-new-privileges --pull=never --stop-timeout 60 $3 $4" \
        "ExecStop=${D} stop -t 60 telcoin-gateway" \
        "Restart=on-failure" \
        "RestartSec=5" \
        "TimeoutStopSec=75" \
        "" \
        "[Install]" \
        "WantedBy=multi-user.target"
}
# refuse NAME NEEDLE K=V... -- gw_enable with these inputs: rc 1, GW_ERR names
# NEEDLE, the tree byte-identical, no systemctl call, no docker run.
refuse() {
    local name="$1" needle="$2" before rc=0
    shift 2
    gin "$@"
    before="$(snap)"
    logs_reset
    gw_enable quiet || rc=$?
    check_rc "refusal, ${name}: rc 1" 1 "$rc"
    check "refusal, ${name}: GW_ERR says why" yes "$(has "$GW_ERR" "$needle")"
    check "refusal, ${name}: the tree is byte-identical" "$before" "$(snap)"
    check "refusal, ${name}: no systemctl call" "" "$(cat "$T/systemctl.log")"
    check "refusal, ${name}: no docker run" 0 "$(docker_runs)"
}

ARGS_SH_CADDY="--listen-addr 127.0.0.1:8655 --probe-addr 127.0.0.1:8656 --metrics 127.0.0.1:9655 --upstream-rpc-url http://127.0.0.1:8544 --upstream-readiness-url http://127.0.0.1:43180/health/workers --worker-id 0 --redirect-queries ${RQ} --trusted-proxies 127.0.0.1/32"
ARGS_SH_NONE="--listen-addr 0.0.0.0:8655 --probe-addr 127.0.0.1:8656 --metrics 127.0.0.1:9655 --upstream-rpc-url http://127.0.0.1:8544 --upstream-readiness-url http://127.0.0.1:43180/health/workers --worker-id 0 --redirect-queries ${RQ}"
ARGS_SA_CADDY="--listen-addr 127.0.0.1:8655 --probe-addr 127.0.0.1:8656 --metrics 127.0.0.1:9655 --upstream-rpc-url http://10.0.0.12:8545 --upstream-readiness-url http://10.0.0.12:43174/health/workers --worker-id 0 --redirect-queries ${RQ} --trusted-proxies 127.0.0.1/32"

# =============================================================================
# library: the argument line and the unit text
# =============================================================================
host "$NODE"
gin MODE=same-host DOMAIN=gw.example.org
rc=0; gw_validate_inputs quiet || rc=$?
check_rc "library: same-host + caddy validates" 0 "$rc"
check "library: same-host + caddy renders the contract's argument line" "$ARGS_SH_CADDY" "$(gw_render_args)"
check "library: same-host + caddy renders the contract's unit" \
    "$(want_unit same-host caddy "$IMG" "$ARGS_SH_CADDY")" "$(gw_unit_text)"
check_has "library: the unit runs docker with the contract's options in order" \
    "ExecStart=${D} run --rm --name telcoin-gateway --network=host --user 1101:1101 --read-only --cap-drop ALL --security-opt no-new-privileges --pull=never --stop-timeout 60 ${IMG} ${ARGS_SH_CADDY}" \
    "$(gw_unit_text)"
check_has "library: the unit gives docker 75 s to stop" "TimeoutStopSec=75" "$(gw_unit_text)"
check_has "library: the unit restarts on failure" "Restart=on-failure" "$(gw_unit_text)"

gin MODE=same-host FRONT=none
rc=0; gw_validate_inputs quiet || rc=$?
check_rc "library: same-host + none validates" 0 "$rc"
check "library: same-host + none listens on 0.0.0.0 and passes no --trusted-proxies" "$ARGS_SH_NONE" "$(gw_render_args)"
check_lacks "library: same-host + none has no --trusted-proxies in the unit" "--trusted-proxies" "$(gw_unit_text)"
check "library: same-host + none renders the contract's unit" \
    "$(want_unit same-host none "$IMG" "$ARGS_SH_NONE")" "$(gw_unit_text)"
# --rpc-port on a node host: the launch file's --http.port, else .node-meta RPC_PORT,
# else 8545; given, it wins.
gin MODE=same-host FRONT=none RPC_PORT=8600
gw_validate_inputs quiet
check "library: same-host takes a given --rpc-port over the launch file" "8600" "$GW_V_RPC_PORT"
start_script "--http --http.addr 0.0.0.0 --healthcheck 127.0.0.1:43180"
printf 'RPC_PORT=8547\n' >> "$NMETA"
gin MODE=same-host FRONT=none
gw_validate_inputs quiet
check "library: same-host without --http.port takes .node-meta RPC_PORT" "8547" "$GW_V_RPC_PORT"
node_meta devnet
gin MODE=same-host FRONT=none
gw_validate_inputs quiet
check "library: same-host without --http.port or RPC_PORT takes 8545" "8545" "$GW_V_RPC_PORT"
start_script "$FLAGS_STD"

host "$SA"
gin MODE=standalone NETWORK=devnet UPSTREAM=10.0.0.12 DOMAIN=gw.example.org
rc=0; gw_validate_inputs quiet || rc=$?
check_rc "library: standalone + caddy validates on a host without a node" 0 "$rc"
check "library: standalone + caddy renders the contract's argument line" "$ARGS_SA_CADDY" "$(gw_render_args)"
check "library: standalone + caddy renders the contract's unit" \
    "$(want_unit standalone caddy "$IMG" "$ARGS_SA_CADDY")" "$(gw_unit_text)"

# =============================================================================
# library: every refusal of --enable (contract 3.1, amendment A-1(b))
# =============================================================================
host "$NODE"
refuse "standalone on a node host" "this host runs one" MODE=standalone UPSTREAM=10.0.0.12 DOMAIN=gw.example.org
refuse "no mode" "give --mode" DOMAIN=gw.example.org
refuse "a network other than the node's" "is not this node's network" MODE=same-host NETWORK=testnet DOMAIN=gw.example.org
refuse "--upstream with same-host" "--upstream is for --mode standalone" MODE=same-host UPSTREAM=10.0.0.12 DOMAIN=gw.example.org
refuse "front caddy without a domain" "--front caddy needs --domain" MODE=same-host
refuse "a domain with front none" "--domain is for --front caddy" MODE=same-host FRONT=none DOMAIN=gw.example.org
refuse "a domain that is not a hostname" "is not a hostname" MODE=same-host DOMAIN=gw_example
refuse "listen port 0" "is not a port" MODE=same-host DOMAIN=gw.example.org LISTEN_PORT=0
refuse "listen port 65536" "is not a port" MODE=same-host DOMAIN=gw.example.org LISTEN_PORT=65536
refuse "a port with a leading zero" "is not a port" MODE=same-host DOMAIN=gw.example.org PROBE_PORT=08656
refuse "listen port equal to the probe port" "three different ports" MODE=same-host DOMAIN=gw.example.org LISTEN_PORT=8656
refuse "metrics port equal to the probe port" "three different ports" MODE=same-host DOMAIN=gw.example.org METRICS_PORT=8656
refuse "listen port on the node's RPC port" "the node's RPC or health port" MODE=same-host DOMAIN=gw.example.org LISTEN_PORT=8544
refuse "probe port on the node's health port" "the node's RPC or health port" MODE=same-host DOMAIN=gw.example.org PROBE_PORT=43180
refuse "no redirect URL" "give --redirect-queries" MODE=same-host DOMAIN=gw.example.org REDIRECT=
refuse "a redirect URL that is not http(s)" "must be http(s)" MODE=same-host DOMAIN=gw.example.org REDIRECT=ftp://rpc.example.org/
refuse "a redirect URL with a query string" "must be http(s)" MODE=same-host DOMAIN=gw.example.org "REDIRECT=https://rpc.example.org/?a=1"
refuse "a trusted-proxies list with a stray character" "comma list" MODE=same-host DOMAIN=gw.example.org "TRUSTED_PROXIES=10.0.0.0/8;x"
refuse "an image tag" "tags are refused" MODE=same-host DOMAIN=gw.example.org IMAGE=us-docker.pkg.dev/telcoin-network/tn-public/worker-gateway:latest
refuse "no image on devnet" "give the worker-gateway image" MODE=same-host DOMAIN=gw.example.org IMAGE=
: > "$T/docker-down"
refuse "a docker daemon that does not answer" "docker daemon does not answer" MODE=same-host DOMAIN=gw.example.org
rm -f "$T/docker-down"
start_script "--http --http.addr 0.0.0.0 --http.port 8544"
refuse "same-host with a node launched without --healthcheck" "--healthcheck" MODE=same-host DOMAIN=gw.example.org
start_script "$FLAGS_STD"
node_meta mainnet
refuse "same-host on mainnet" "on mainnet the gateway runs on its own host" MODE=same-host DOMAIN=gw.example.org
printf 'NETWORK=devnet\nNETWORK=testnet\nINSTALL_METHOD=binary\n' > "$NMETA"
refuse "a .node-meta with NETWORK twice" "more than once" MODE=same-host DOMAIN=gw.example.org
node_meta devnet
SGT_UID=1000
refuse "not root" "needs root" MODE=same-host DOMAIN=gw.example.org
SGT_UID=0

host "$SA"
refuse "same-host on a host without a node" "needs the node on this host" MODE=same-host NETWORK=devnet DOMAIN=gw.example.org
refuse "standalone without --upstream" "needs --upstream" MODE=standalone NETWORK=devnet DOMAIN=gw.example.org
refuse "a public upstream" "is not a private IPv4" MODE=standalone NETWORK=devnet UPSTREAM=8.8.8.8 DOMAIN=gw.example.org
refuse "a loopback upstream" "is not a private IPv4" MODE=standalone NETWORK=devnet UPSTREAM=127.0.0.1 DOMAIN=gw.example.org
refuse "an upstream with a leading zero" "is not a private IPv4" MODE=standalone NETWORK=devnet UPSTREAM=10.0.0.012 DOMAIN=gw.example.org
refuse "no network on a host without a node" "give --network" MODE=standalone UPSTREAM=10.0.0.12 DOMAIN=gw.example.org
refuse "testnet while its pin is empty" "pins no worker-gateway image for testnet" MODE=standalone NETWORK=testnet UPSTREAM=10.0.0.12 DOMAIN=gw.example.org
refuse "mainnet while its pin is empty" "pins no worker-gateway image for mainnet" MODE=standalone NETWORK=mainnet UPSTREAM=10.0.0.12 DOMAIN=gw.example.org IMAGE=

# =============================================================================
# image trust (contract 3.4)
# =============================================================================
rc=0; gw_image_allowed "${IMG%@*}:latest" devnet || rc=$?
check_rc "image trust: a tag reference is refused" 1 "$rc"
rc=0; gw_image_allowed "$OTHER" devnet || rc=$?
check_rc "image trust: a devnet repository outside the allow-list is refused" 1 "$rc"
rc=0; gw_image_allowed "$IMG" devnet || rc=$?
check_rc "image trust: the allow-listed devnet repository by digest is taken" 0 "$rc"
rc=0; gw_image_allowed "$IMG" testnet || rc=$?
check_rc "image trust: testnet is refused while its pin is empty" 1 "$rc"
check "image trust: the testnet refusal names the empty pin" "this scripts release pins no worker-gateway image for testnet" "$GW_ERR"
rc=0; gw_image_allowed "$IMG" mainnet || rc=$?
check_rc "image trust: mainnet is refused while its pin is empty" 1 "$rc"
GW_TESTNET_IMAGE_PIN="$IMG"
GW_MAINNET_IMAGE_PIN="$IMG2"
rc=0; gw_image_allowed "$IMG" testnet || rc=$?
check_rc "image trust: with a testnet pin the pinned reference is taken" 0 "$rc"
rc=0; gw_image_allowed "$IMG2" testnet || rc=$?
check_rc "image trust: with a testnet pin another digest is refused" 1 "$rc"
rc=0; gw_image_allowed "$IMG2" mainnet || rc=$?
check_rc "image trust: with a mainnet pin the pinned reference is taken" 0 "$rc"
rc=0; gw_image_allowed "$IMG" mainnet || rc=$?
check_rc "image trust: with a mainnet pin another digest is refused" 1 "$rc"
gin MODE=standalone NETWORK=testnet UPSTREAM=10.0.0.12 FRONT=none IMAGE=
rc=0; gw_validate_inputs quiet || rc=$?
check_rc "image trust: testnet without --image validates once a pin is set" 0 "$rc"
check "image trust: testnet without --image takes the pin" "$IMG" "$GW_V_IMAGE"
# shellcheck disable=SC2034  # read by lib/gateway.sh
GW_TESTNET_IMAGE_PIN=""
# shellcheck disable=SC2034  # read by lib/gateway.sh
GW_MAINNET_IMAGE_PIN=""

: > "$T/help-lacks"
printf '%s' "--trusted-proxies" > "$T/help-lacks"
gin MODE=standalone NETWORK=devnet UPSTREAM=10.0.0.12 DOMAIN=gw.example.org
before="$(snap)"
logs_reset
rc=0; gw_enable quiet || rc=$?
check_rc "image trust: an image whose --help lacks one flag is refused" 1 "$rc"
check "image trust: the refusal names the missing flag" yes "$(has "$GW_ERR" "lacks --trusted-proxies")"
check "image trust: the --help refusal leaves the tree byte-identical" "$before" "$(snap)"
check "image trust: the --help refusal calls no systemctl" "" "$(cat "$T/systemctl.log")"
check "image trust: the only docker run is the offline --help probe" \
    "run --rm --network=none --read-only --cap-drop ALL --user 1101:1101 --pull=never ${IMG} --help" \
    "$(grep '^run ' "$T/docker.log")"
check "image trust: the image was pulled by digest before the probe" "pull ${IMG}" "$(grep '^pull ' "$T/docker.log")"
rm -f "$T/help-lacks"

# =============================================================================
# library: not installed; enable; idempotence; status
# =============================================================================
host "$NODE"
rc=0; gw_status quiet || rc=$?
check_rc "status: not installed is rc 0" 0 "$rc"
check "status: not installed says installed false" "false/0/" "${GW_ST_INSTALLED}/${GW_ST_ISSUES}/${GW_ST_MODE}${GW_ST_IMAGE}${GW_ST_LISTEN}${GW_ST_CADDY_BLOCK}"

NMETA_SUM="$(fsum "$NMETA")"
gin MODE=same-host DOMAIN=gw.example.org
logs_reset
rc=0; gw_enable quiet || rc=$?
check_rc "enable: same-host + caddy on a node host" 0 "$rc"
check "enable: applied enabled and caddy" "enabled caddy" "$GW_APPLIED"
check "enable: the unit file is the rendered unit" "$(want_unit same-host caddy "$IMG" "$ARGS_SH_CADDY")" "$(cat "$(UNIT_P)")"
check "enable: gateway.meta holds the contract's keys" "GATEWAY_META_VERSION=1
NETWORK=devnet
MODE=same-host
FRONT=caddy
DOMAIN=gw.example.org
IMAGE=${IMG}
UPSTREAM_HOST=127.0.0.1
RPC_PORT=8544
HEALTH_PORT=43180
LISTEN_PORT=8655
PROBE_PORT=8656
METRICS_PORT=9655
REDIRECT_QUERIES=${RQ}
TRUSTED_PROXIES=127.0.0.1/32" "$(cat "$(META_P)")"
check "enable: gateway.meta is 0600" "-rw-------" "$(mode_of "$(META_P)")"
check "enable: the unit is 0644" "-rw-r--r--" "$(mode_of "$(UNIT_P)")"
check "enable: systemctl reloads, enables and restarts the gateway only" \
    "daemon-reload;enable telcoin-gateway.service;restart telcoin-gateway.service;" "$(sys_changes)"
check "enable: the Caddy phase gets the domain and both ports" \
    "--json --phase gateway-enable --gateway-domain gw.example.org --gateway-port 8655 --gateway-probe-port 8656" \
    "$(cat "$T/caddy.log")"
check "enable: the update lock is taken and released" "lock release" "$(tr '\n' ' ' < "$T/lock.log" | sed 's/ $//')"
check "enable: .node-meta untouched" "$NMETA_SUM" "$(fsum "$NMETA")"

before="$(snap)"
logs_reset
rc=0; gw_enable quiet || rc=$?
check_rc "idempotence: a second enable with the same inputs is rc 0" 0 "$rc"
check "idempotence: a second enable applies nothing" "" "$GW_APPLIED"
check "idempotence: a second enable writes nothing" "$before" "$(snap)"
check "idempotence: a second enable restarts nothing" "" "$(sys_changes)"
check "idempotence: a second enable pulls nothing" "" "$(grep '^pull ' "$T/docker.log")"
check "idempotence: the Caddy phase still runs once" "1" "$(grep -c -- '--phase gateway-enable' "$T/caddy.log")"

rc=0; gw_status quiet || rc=$?
check_rc "status: installed and healthy is rc 0" 0 "$rc"
check "status: installed and healthy, the booleans" \
    "installed=true enabled=true active=true held=true health=true ready=true ready_any=true caddy=true issues=0" \
    "installed=${GW_ST_INSTALLED} enabled=${GW_ST_ENABLED} active=${GW_ST_ACTIVE} held=${GW_ST_IMAGE_HELD} health=${GW_ST_HEALTH} ready=${GW_ST_READY} ready_any=${GW_ST_READY_ANY} caddy=${GW_ST_CADDY_BLOCK} issues=${GW_ST_ISSUES}"
check "status: installed and healthy, the strings" \
    "same-host|caddy|gw.example.org|${IMG}|127.0.0.1:8655|127.0.0.1:8656|127.0.0.1:9655|http://127.0.0.1:8544|http://127.0.0.1:43180/health/workers|${RQ}" \
    "${GW_ST_MODE}|${GW_ST_FRONT}|${GW_ST_DOMAIN}|${GW_ST_IMAGE}|${GW_ST_LISTEN}|${GW_ST_PROBE}|${GW_ST_METRICS}|${GW_ST_UPSTREAM_RPC}|${GW_ST_UPSTREAM_READINESS}|${GW_ST_REDIRECT_QUERIES}"
: > "$T/not-ready"
rc=0; gw_status quiet || rc=$?
check "status: a worker that is not ready is no issue" "0 false" "${rc} ${GW_ST_READY}"
rm -f "$T/not-ready"
rm -f "$(sd)/active"
rc=0; gw_status quiet || rc=$?
check_rc "status: a stopped unit counts one issue" 1 "$rc"
check "status: a stopped unit, issues and active" "1 false false" "${GW_ST_ISSUES} ${GW_ST_ACTIVE} ${GW_ST_HEALTH}"
: > "$(sd)/active"
if [[ "$(id -u)" == 0 ]]; then
    skip "status: without root" "root reads a 0000 file; run as a user to cover it"
else
    chmod 0000 "$(META_P)"
    SGT_UID=1000
    rc=0; gw_status quiet || rc=$?
    # shellcheck disable=SC2034  # SGT_UID is read by the stand-in _gw_is_root
    SGT_UID=0
    chmod 0600 "$(META_P)"
    check_rc "status: without root and an unreadable gateway.meta is rc 0" 0 "$rc"
    check "status: without root the values come from the unit" \
        "true|same-host|caddy|${IMG}|127.0.0.1:8655|http://127.0.0.1:43180/health/workers|true" \
        "${GW_ST_INSTALLED}|${GW_ST_MODE}|${GW_ST_FRONT}|${GW_ST_IMAGE}|${GW_ST_LISTEN}|${GW_ST_UPSTREAM_READINESS}|${GW_ST_CADDY_BLOCK}"
fi

# =============================================================================
# library: refresh
# =============================================================================
before="$(snap)"
logs_reset
GW_IN_IMAGE=""
rc=0; gw_refresh quiet || rc=$?
check_rc "refresh: no change is rc 0" 0 "$rc"
check "refresh: no change applies nothing" "" "$GW_APPLIED"
check "refresh: no change writes nothing" "$before" "$(snap)"
check "refresh: no change restarts nothing" "" "$(sys_changes)"
logs_reset
GW_IN_IMAGE="$IMG2"
rc=0; gw_refresh quiet || rc=$?
check_rc "refresh: a new image is rc 0" 0 "$rc"
check "refresh: a new image applies refreshed" "refreshed" "$GW_APPLIED"
check "refresh: a new image restarts the gateway once" "daemon-reload;restart telcoin-gateway.service;" "$(sys_changes)"
check "refresh: a new image is written to gateway.meta" "$IMG2" "$(tn_gateway_meta_get IMAGE)"
check "refresh: a new image is the unit's" "$(want_unit same-host caddy "$IMG2" "$ARGS_SH_CADDY")" "$(cat "$(UNIT_P)")"
GW_IN_IMAGE="$OTHER"
before="$(snap)"
rc=0; gw_refresh quiet || rc=$?
check "refresh: an image outside the allow-list is refused, nothing written" "1 yes" "${rc} $([[ "$before" == "$(snap)" ]] && echo yes || echo no)"
# shellcheck disable=SC2034  # GW_IN_IMAGE is read by lib/gateway.sh
GW_IN_IMAGE="$IMG"
rc=0; gw_refresh quiet || rc=$?
check_rc "refresh: back to the first image" 0 "$rc"

# =============================================================================
# library: rollback (a host without a node)
# =============================================================================
host "$SA"
gin MODE=standalone NETWORK=devnet UPSTREAM=10.0.0.12 DOMAIN=gw.example.org
before="$(snap)"
: > "$T/health-fails"
logs_reset
rc=0; gw_enable quiet || rc=$?
rm -f "$T/health-fails"
check_rc "rollback: a first enable whose /health never answers is rc 1" 1 "$rc"
check "rollback: the error names /health" yes "$(has "$GW_ERR" "GET /health")"
check "rollback: no unit is left" no "$(exists "$(UNIT_P)")"
check "rollback: no gateway.meta and no /etc/telcoin is left" "no no" "$(exists "$(META_P)") $(exists "$SA/etc/telcoin")"
check "rollback: the unit is not enabled and not running" "no no" "$(exists "$(sd)/enabled") $(exists "$(sd)/active")"
check "rollback: the tree is as before" "$before" "$(snap)"

rc=0; gw_enable quiet || rc=$?
check_rc "rollback: the same enable with /health answering" 0 "$rc"
unit_sum="$(fsum "$(UNIT_P)")"
meta_sum="$(fsum "$(META_P)")"
before="$(snap)"
gin MODE=standalone NETWORK=devnet UPSTREAM=10.0.0.12 DOMAIN=gw.example.org LISTEN_PORT=8700
: > "$T/health-fails"
rc=0; gw_enable quiet || rc=$?
rm -f "$T/health-fails"
check_rc "rollback: a change over an installation that never answers is rc 1" 1 "$rc"
check "rollback: the previous unit is back byte for byte" "$unit_sum" "$(fsum "$(UNIT_P)")"
check "rollback: the previous gateway.meta is back byte for byte" "$meta_sum" "$(fsum "$(META_P)")"
check "rollback: the tree is as before the change" "$before" "$(snap)"
check "rollback: the previous gateway is enabled and running again" "yes yes" "$(exists "$(sd)/enabled") $(exists "$(sd)/active")"

: > "$T/health-fails"
: > "$T/restore-fails"
rc=0; gw_enable quiet || rc=$?
rm -f "$T/health-fails" "$T/restore-fails"
check_rc "rollback: a put-back that fails is rc 2" 2 "$rc"
check "rollback: a failed put-back says so" yes "$(has "$GW_ERR" "putting the previous state back failed too")"
gin MODE=standalone NETWORK=devnet UPSTREAM=10.0.0.12 DOMAIN=gw.example.org
rc=0; gw_enable quiet || rc=$?
check "rollback: an enable after a failed put-back repairs it" "0 ${unit_sum}" "${rc} $(fsum "$(UNIT_P)")"

# =============================================================================
# library: remove (the node host, front caddy)
# =============================================================================
host "$NODE"
logs_reset
rc=0; gw_remove quiet || rc=$?
check_rc "remove: rc 0" 0 "$rc"
check "remove: applied removed" "removed" "$GW_APPLIED"
check "remove: the unit and /etc/telcoin/gateway are gone" "no no" "$(exists "$(UNIT_P)") $(exists "$NODE/etc/telcoin/gateway")"
check "remove: the container is removed" "1" "$(grep -c '^rm -f telcoin-gateway$' "$T/docker.log")"
check "remove: the unit is neither enabled nor running" "no no" "$(exists "$(sd)/enabled") $(exists "$(sd)/active")"
check "remove: Caddy gateway-disable runs with front caddy" "--json --phase gateway-disable" "$(cat "$T/caddy.log")"
check "remove: .node-meta untouched" "$NMETA_SUM" "$(fsum "$NMETA")"
logs_reset
rc=0; gw_remove quiet || rc=$?
check "remove: nothing installed is rc 0 and applies nothing" "0 " "${rc} ${GW_APPLIED}"
check "remove: nothing installed calls no Caddy phase" "" "$(cat "$T/caddy.log")"
gin MODE=same-host DOMAIN=gw.example.org
before="$(snap)"
: > "$T/caddy-fails"
rc=0; gw_enable quiet || rc=$?
rm -f "$T/caddy-fails"
check_rc "rollback: a first enable whose Caddy phase fails is rc 1" 1 "$rc"
check "rollback: a failed Caddy phase leaves no unit, no meta, nothing enabled or running" "no no no no" \
    "$(exists "$(UNIT_P)") $(exists "$(META_P)") $(exists "$(sd)/enabled") $(exists "$(sd)/active")"
check "rollback: a failed Caddy phase leaves the tree as before" "$before" "$(snap)"

check_lacks "library: the node's unit never reaches systemctl" "telcoin.service" "$(cat "$T/systemctl.all")"
check "library: systemctl never names the node service" "0" \
    "$(grep -cE '(^| )telcoin( |$)' "$T/systemctl.all")"

# =============================================================================
# script: setup-gateway.sh (a copy beside a lib/common.sh that sources the real
# one, then the stand-ins; SGT_OLDLIB=1 drops gw_status and gw_refresh)
# =============================================================================
cp "$TN_TEST_REPO/setup-gateway.sh" "$T/sg/setup-gateway.sh"
cp "$T/install-caddy.sh" "$T/sg/install-caddy.sh"
{
    printf 'source %q\n' "$TN_TEST_REPO/lib/common.sh"
    printf 'source %q\n' "$T/standins.sh"
    printf '%s\n' 'if [[ -n "${SGT_OLDLIB:-}" ]]; then unset -f gw_status gw_refresh; fi'
} > "$T/sg/lib/common.sh"
SGS="$T/sg/setup-gateway.sh"
# sg [K=V... --] ARGS... -- run the copy without a terminal: RC, OUT (stdout), ERR
# (stderr), NDONE (done lines on stdout) and DONE (the last one).
sg() {
    local n=0 a
    for a in "$@"; do
        [[ "$a" == "--" ]] && break
        n=$((n + 1))
    done
    RC=0
    if [[ $n -lt $# ]]; then
        env PATH="$T/sgbin:$PATH" "${@:1:$n}" bash "$SGS" "${@:$((n + 2))}" < /dev/null > "$T/so" 2> "$T/se" || RC=$?
    else
        env PATH="$T/sgbin:$PATH" bash "$SGS" "$@" < /dev/null > "$T/so" 2> "$T/se" || RC=$?
    fi
    OUT="$(cat "$T/so")"
    ERR="$(cat "$T/se")"
    NDONE="$(grep -c '^{"event":"done"' "$T/so")"
    DONE="$(grep '^{"event":"done"' "$T/so" | tail -n 1)"
}
nonjson() { grep -vc '^{"event":"' "$T/so"; }
# jparse LINE -- one "key<TAB>type<TAB>raw value" line per member of a flat JSON
# object (strings, booleans, null, numbers, arrays of strings).
jparse() {
    local s="$1" k t v re_k re_s re_n
    re_k='^[,{]"([a-z_]+)":(.*)$'
    re_s='^("([^"\\]|\\.)*")(.*)$'
    re_n='^([0-9]+)(.*)$'
    s="${s%\}}"
    while [[ "$s" =~ $re_k ]]; do
        k="${BASH_REMATCH[1]}"
        s="${BASH_REMATCH[2]}"
        case "$s" in
            \"*) [[ "$s" =~ $re_s ]] || break; t=str; v="${BASH_REMATCH[1]}"; s="${BASH_REMATCH[3]}" ;;
            true*) t=bool; v=true; s="${s#true}" ;;
            false*) t=bool; v=false; s="${s#false}" ;;
            null*) t=null; v=null; s="${s#null}" ;;
            \[*) t=arr; v="${s%%]*}]"; s="${s#*]}" ;;
            [0-9]*) [[ "$s" =~ $re_n ]] || break; t=num; v="${BASH_REMATCH[1]}"; s="${BASH_REMATCH[2]}" ;;
            *) break ;;
        esac
        printf '%s\t%s\t%s\n' "$k" "$t" "$v"
    done
}
jshape() { jparse "$1" | awk -F'\t' '{ printf "%s%s:%s", (NR > 1 ? " " : ""), $1, $2 }'; }
jval() { jparse "$2" | awk -F'\t' -v k="$1" '$1 == k && !f { print $3; f = 1 }'; }
# shape_ok NETWORK STRINGS CADDY_BLOCK DOMAIN -- contract 3.2's success line, by type.
shape_ok() {
    printf '%s' "event:str ok:bool applied:arr network:$1 installed:bool enabled:bool active:bool mode:$2 front:$2 domain:$4 image:$2 image_held:bool listen:$2 probe:$2 metrics:$2 upstream_rpc:$2 upstream_readiness:$2 redirect_queries:$2 health:bool ready:bool ready_any:bool caddy_block:$3 issues:num msg:str"
}
FAIL_SHAPE="event:str ok:bool msg:str"
# argfail NAME NEEDLE ARGS... -- a command line refused before anything runs, with
# --json (one done line, JSON only, names NEEDLE, ends "Nothing was changed.") and
# without (exit 1, no done line); the tree unchanged.
argfail() {
    local name="$1" needle="$2" before
    shift 2
    before="$(snap)"
    sg --json "$@"
    check_rc "script: ${name} (--json) exits 1" 1 "$RC"
    check "script: ${name} (--json) prints exactly one done line" 1 "$NDONE"
    check "script: ${name} (--json) prints JSON events only" 0 "$(nonjson)"
    check "script: ${name} (--json) ends with the failure shape" "$FAIL_SHAPE" "$(jshape "$DONE")"
    check "script: ${name} (--json) names why and ends Nothing was changed." "yes yes" \
        "$(has "$DONE" "$needle") $(has "$DONE" 'Nothing was changed."}')"
    sg "$@"
    check "script: ${name} (plain) exits 1 with no done line and says why" "1 0 yes" \
        "${RC} ${NDONE} $(has "${ERR}${OUT}" "$needle")"
    check "script: ${name} leaves the tree unchanged" "$before" "$(snap)"
}

host "$NODE"
sg --help
check "script: --help exits 0 and prints the usage" "0 yes" "${RC} $(has "$OUT" "setup-gateway.sh --enable")"
sg --json --help
check "script: --help with --json prints the usage and no done line" "0 0 yes" "${RC} ${NDONE} $(has "$OUT" "setup-gateway.sh --status")"
sg
check "script: no argument prints the usage and exits 0" "0 yes" "${RC} $(has "$OUT" "setup-gateway.sh --refresh")"
sg --yes
check "script: no action without --json prints the usage and exits 0" "0 0 yes" "${RC} ${NDONE} $(has "$OUT" "setup-gateway.sh --remove")"
sg --json
check_rc "script: no action with --json exits 1" 1 "$RC"
check "script: no action with --json prints exactly one done line, the failure shape" "1 ${FAIL_SHAPE}" "${NDONE} $(jshape "$DONE")"
check "script: no action with --json says one action is needed" yes "$(has "$DONE" "needs one action")"
argfail "two actions" "Give one action" --enable --status
argfail "an unknown argument" "Unknown argument: --bogus" --status --bogus
argfail "an unknown argument with a value" "Unknown argument: --bogus" --status --bogus=x
argfail "a missing value" "--mode needs a value" --enable --mode
argfail "an empty --flag=value" "--mode needs a value" --enable --mode=
argfail "a flag outside its action" "--domain goes with --enable" --status --domain gw.example.org
argfail "--image with --remove" "--image goes with --enable or --refresh" --remove --image "$IMG"
argfail "--yes with --status" "--yes goes with" --status --yes
argfail "a mode outside its words" "--mode takes same-host or standalone" --enable --mode both
argfail "a front outside its words" "--front takes caddy or none" --enable --front nginx
argfail "a network outside its words" "--network takes devnet, testnet or mainnet" --enable --network devnet2
argfail "a port with a leading zero" "takes a port number" --enable --listen-port 08655
argfail "an image tag" "a tag is refused" --enable --image "${IMG%@*}:latest"

# --status, nothing installed: the success shape with null strings.
sg --json --status
check "script: --status with nothing installed exits 0 with one done line, JSON only" "0 1 0" "${RC} ${NDONE} $(nonjson)"
check "script: the not-installed done line has contract 3.2's fields and types" "$(shape_ok str null null null)" "$(jshape "$DONE")"
check "script: the not-installed done line, the values" "true [] \"devnet\" false 0" \
    "$(jval ok "$DONE") $(jval applied "$DONE") $(jval network "$DONE") $(jval installed "$DONE") $(jval issues "$DONE")"

# --enable on the node host, then the same again.
: > "$T/baseline.log"
sg --json --enable --mode same-host --domain=gw.example.org --image "$IMG" --redirect-queries "$RQ"
check "script: --enable same-host exits 0 with one done line, JSON only" "0 1 0" "${RC} ${NDONE} $(nonjson)"
check "script: the enable done line has contract 3.2's fields and types" "$(shape_ok str str bool str)" "$(jshape "$DONE")"
check "script: the enable done line, applied" '["gateway:enabled","gateway:caddy"]' "$(jval applied "$DONE")"
check "script: the enable done line, the values" "\"devnet\" true true true \"127.0.0.1:8655\" true true 0" \
    "$(jval network "$DONE") $(jval installed "$DONE") $(jval enabled "$DONE") $(jval active "$DONE") $(jval listen "$DONE") $(jval health "$DONE") $(jval caddy_block "$DONE") $(jval issues "$DONE")"
check "script: --enable refreshes the host baseline after a change" yes "$([[ -s "$T/baseline.log" ]] && echo yes || echo no)"
before="$(snap)"
sg --json --enable --mode same-host --domain gw.example.org --image "$IMG" --redirect-queries "$RQ" --network devnet
check "script: the same --enable (with the node's --network) applies nothing" "0 1 []" "${RC} ${NDONE} $(jval applied "$DONE")"
check "script: the same --enable says nothing had to change" yes "$(has "$DONE" "nothing had to change")"
check "script: the same --enable writes nothing" "$before" "$(snap)"
sg --json --refresh
check "script: --refresh with nothing new applies nothing" "0 1 []" "${RC} ${NDONE} $(jval applied "$DONE")"
sg --json --refresh --image "$IMG2" --yes
check "script: --refresh --image applies gateway:refreshed" "0 1 [\"gateway:refreshed\"] \"${IMG2}\"" \
    "${RC} ${NDONE} $(jval applied "$DONE") $(jval image "$DONE")"
sg --json --refresh --image "$IMG"
check_rc "script: --refresh back to the first image" 0 "$RC"

# Refusals and exits.
sg --json --enable --mode same-host --domain gw.example.org --image "$IMG" --redirect-queries "$RQ" --network testnet
check "script: --network other than the node's is refused (exit 1, one done line)" "1 1 yes" \
    "${RC} ${NDONE} $(has "$DONE" "differs from the node")"
sg --json --enable --mode standalone --upstream 10.0.0.12 --front none --image "$IMG" --redirect-queries "$RQ"
check "script: a library refusal exits 1 with one done line" "1 1 ${FAIL_SHAPE}" "${RC} ${NDONE} $(jshape "$DONE")"
check "script: a library refusal names it and ends Nothing was changed." "yes yes" \
    "$(has "$DONE" "this host runs one") $(has "$DONE" 'Nothing was changed."}')"
sg SGT_UID=1000 -- --json --enable --mode same-host --domain gw.example.org --image "$IMG" --redirect-queries "$RQ"
check "script: --enable without root exits 1 with one done line" "1 1 yes" "${RC} ${NDONE} $(has "$DONE" "as root")"
if [[ "$(id -u)" == 0 ]]; then
    skip "script: --status without root" "root reads a 0000 file; run as a user to cover it"
else
    chmod 0000 "$(META_P)"
    sg SGT_UID=1000 -- --json --status
    chmod 0600 "$(META_P)"
    check "script: --status without root and an unreadable gateway.meta exits 0, one done line" "0 1" "${RC} ${NDONE}"
    check "script: --status without root still sees the installation" "true \"devnet\" \"same-host\"" \
        "$(jval installed "$DONE") $(jval network "$DONE") $(jval mode "$DONE")"
fi

# Consent: plain mode asks; no terminal and no --yes is a refusal.
before="$(snap)"
sg --enable --mode same-host --domain gw.example.org --image "$IMG" --redirect-queries "$RQ" --listen-port 8700
check "script: plain --enable without a terminal or --yes is refused" "1 yes" "${RC} $(has "${ERR}${OUT}" "needs your consent")"
check "script: the refused consent changes nothing" "$before" "$(snap)"
sg --enable --mode same-host --domain gw.example.org --image "$IMG" --redirect-queries "$RQ" --listen-port 8700 --yes
check "script: plain --enable with --yes applies the change" "0 yes" "${RC} $(has "$(cat "$(UNIT_P)")" "--listen-addr 127.0.0.1:8700 ")"
sg --enable --mode same-host --domain gw.example.org --image "$IMG" --redirect-queries "$RQ" --yes
check_rc "script: plain --enable --yes back to the default ports" 0 "$RC"
sg --remove
check "script: plain --remove of an installation without --yes is refused" "1 yes yes" \
    "${RC} $(has "${ERR}${OUT}" "needs your consent") $(exists "$(UNIT_P)")"
sg --json --remove
check "script: --remove --json removes it" "0 1 [\"gateway:removed\"] false" \
    "${RC} ${NDONE} $(jval applied "$DONE") $(jval installed "$DONE")"
sg --remove
check "script: plain --remove with nothing installed asks nothing and exits 0" 0 "$RC"

# A host without a node: --network is required; front none; exit 3; exit 143.
host "$SA"
sg --json --enable --mode standalone --upstream 10.0.0.12 --front none --image "$IMG" --redirect-queries "$RQ"
check "script: no --network on a host without a node is refused" "1 1 yes" "${RC} ${NDONE} $(has "$DONE" "give --network")"
sg --json --enable --mode standalone --upstream 10.0.0.12 --front none --image "$IMG" --redirect-queries "$RQ" --network devnet
check "script: standalone + none with --network exits 0 with one done line" "0 1 0" "${RC} ${NDONE} $(nonjson)"
check "script: the front none done line has domain and caddy_block null" "$(shape_ok str str null null)" "$(jshape "$DONE")"
rc=0; gw_status quiet || rc=$?
check "status: front none leaves GW_ST_CADDY_BLOCK empty (A-1(a))" "0 none " "${rc} ${GW_ST_FRONT} ${GW_ST_CADDY_BLOCK}"
sg --json --status
check "script: --status on a host without a node takes the network from gateway.meta" "0 \"devnet\" \"standalone\"" \
    "${RC} $(jval network "$DONE") $(jval mode "$DONE")"
: > "$T/health-fails"
: > "$T/restore-fails"
sg --json --enable --mode standalone --upstream 10.0.0.12 --front none --image "$IMG" --redirect-queries "$RQ" --network devnet --listen-port 8700
rm -f "$T/health-fails" "$T/restore-fails"
check "script: a failed put-back exits 3 with one done line, the failure shape" "3 1 ${FAIL_SHAPE}" "${RC} ${NDONE} $(jshape "$DONE")"
sg --json --enable --mode standalone --upstream 10.0.0.12 --front none --image "$IMG" --redirect-queries "$RQ" --network devnet
check_rc "script: --enable repairs a failed put-back" 0 "$RC"
if [[ "$(id -u)" == 0 ]]; then
    skip "script: --status without root on a host without a node" "root reads a 0000 file; run as a user to cover it"
else
    chmod 0000 "$(META_P)"
    sg SGT_UID=1000 -- --json --status
    chmod 0600 "$(META_P)"
    check "script: --status without root on a host without a node (gateway.meta unreadable) exits 0, installed" \
        "0 1 true \"standalone\"" "${RC} ${NDONE} $(jval installed "$DONE") $(jval mode "$DONE")"
fi
sg SGT_OLDLIB=1 -- --json --status
check "script: an older library exits 2 with one done line" "2 1" "${RC} ${NDONE}"
check "script: the older-library done line carries error" "event:str ok:bool error:str msg:str" "$(jshape "$DONE")"
check "script: the older-library done line names update-scripts.sh" yes "$(has "$DONE" "update-scripts.sh")"
sg SGT_OLDLIB=1 -- --status
check "script: an older library without --json exits 2 and names update-scripts.sh" "2 yes" "${RC} $(has "${ERR}${OUT}" "update-scripts.sh")"
: > "$T/selfkill"
sg --json --enable --mode standalone --upstream 10.0.0.12 --front none --image "$IMG" --redirect-queries "$RQ" --network devnet --listen-port 8701
rm -f "$T/selfkill"
check "script: SIGTERM during --enable exits 143 with exactly one done line" "143 1 ${FAIL_SHAPE}" "${RC} ${NDONE} $(jshape "$DONE")"
sg --json --remove
check "script: --remove after an interrupted --enable" "0 1" "${RC} ${NDONE}"

# =============================================================================
# review R1b fixes: value checks, the --help time limit, the network check (M1),
# the pin move (M2), the status after a change and the extra file on --remove
# =============================================================================
host "$NODE"
LONGIMG="localhost:5000/worker-gateway@sha256:$(printf '%064d' 0 | tr 0 a)"
refuse "a redirect port above 65535" "a port 1-65535" MODE=same-host DOMAIN=gw.example.org REDIRECT=http://q.example.org:99999
refuse "a redirect host of dashes" "--redirect-queries must be" MODE=same-host DOMAIN=gw.example.org REDIRECT=http://-
refuse "a redirect host of dots" "--redirect-queries must be" MODE=same-host DOMAIN=gw.example.org REDIRECT=http://...
refuse "an IPv4 address as --domain" "is not a hostname" MODE=same-host DOMAIN=1.2.3.4
refuse "a redirect at the node's own RPC" "the worker's own RPC" MODE=same-host DOMAIN=gw.example.org REDIRECT=http://127.0.0.1:8544
refuse "a redirect at the node's readiness port" "the worker's readiness port" MODE=same-host DOMAIN=gw.example.org REDIRECT=http://localhost:43180/
refuse "a redirect at the gateway itself" "this gateway itself" MODE=same-host DOMAIN=gw.example.org REDIRECT=http://127.0.0.1:8655
refuse "an image with a registry port" "registry host:port" MODE=same-host DOMAIN=gw.example.org IMAGE="$LONGIMG"
gin MODE=same-host DOMAIN=gw.example.org REDIRECT=https://q.example.org:8545/rpc
rc=0; gw_validate_inputs quiet || rc=$?
check_rc "value checks: a redirect with a valid port and path still validates" 0 "$rc"

: > "$T/timeout.log"
: > "$T/help-hangs"
rc=0; gw_image_probe "$IMG" quiet || rc=$?
rm -f "$T/help-hangs"
check "--help probe: a probe that times out is refused and says so" "1 yes" "${rc} $(has "$GW_ERR" "within 60 s")"
check "--help probe: it runs under timeout 60" yes "$(grep -q '^60 docker run ' "$T/timeout.log" && echo yes || echo no)"

# The status after a change says nothing in plain mode, and the host baseline
# is refreshed once per change.
: > "$T/baseline.log"
sg --json --enable --mode same-host --domain gw.example.org --image "$IMG" --redirect-queries "$RQ"
check "after a change: one --enable refreshes the host baseline once" "0 1" "${RC} $(grep -c baseline "$T/baseline.log")"
sg --yes --enable --mode same-host --domain gw.example.org --image "$IMG" --redirect-queries "$RQ" --listen-port 8702
check "after a change: plain --enable prints no status lines after it" "0 no" "${RC} $(has "${OUT}${ERR}" "Worker gateway: same-host")"

# M1 on a node host: gateway.meta NETWORK must be the node's.
sed 's/^NETWORK=devnet$/NETWORK=testnet/' "$(META_P)" > "$T/m.edit" && cat "$T/m.edit" > "$(META_P)"
before="$(snap)"
logs_reset
rc=0; GW_IN_IMAGE=""; gw_refresh quiet || rc=$?
check "M1 node host: --refresh with gateway.meta NETWORK not the node's is refused" "1 yes" "${rc} $(has "$GW_ERR" "says NETWORK=testnet and the node on this host runs devnet")"
check "M1 node host: refused refresh, the tree is byte-identical, nothing restarted" "$before " "$(snap) $(sys_changes)"
: > "$T/say.log"
rc=0; gw_status quiet || rc=$?
check "M1 node host: status counts it as an issue" "yes yes" "$([[ "$rc" -ge 1 ]] && echo yes) $(has "$(cat "$T/say.log")" "says NETWORK=testnet and the node on this host runs devnet")"
sed 's/^NETWORK=testnet$/NETWORK=devnet/' "$(META_P)" > "$T/m.edit" && cat "$T/m.edit" > "$(META_P)"
rc=0; gw_status quiet || rc=$?
check_rc "M1 node host: with the node's network again, no issue" 0 "$rc"

# M1 on a host without a node: the upstream's eth_chainId, when it answers.
chain() { _GW_CHAIN_KEY=""; rm -f "$T/chain-id"; if [[ -n "${1:-}" ]]; then printf '%s' "$1" > "$T/chain-id"; fi; }
host "$SA"
chain 0x1e7
: > "$T/curl.args"
gin MODE=standalone NETWORK=devnet UPSTREAM=10.0.0.12 DOMAIN=gw.example.org
before="$(snap)"
logs_reset
rc=0; gw_enable quiet || rc=$?
check "M1 no node: --enable devnet with the upstream on the mainnet chain is refused, naming both" "1 yes yes" \
    "${rc} $(has "$GW_ERR" "chain 487 (mainnet)") $(has "$GW_ERR" "the network given is devnet")"
check "M1 no node: refused, the tree is byte-identical, no change, no docker run" "$before  0" "$(snap) $(sys_changes) $(docker_runs)"
check "M1 no node: one eth_chainId POST, to the upstream, no proxy, no redirect, 3 s" "1 yes yes" \
    "$(grep -c eth_chainId "$T/curl.args") $(has "$(grep eth_chainId "$T/curl.args")" "-q -sS --noproxy * --proto =http --max-redirs 0 --connect-timeout 2 --max-time 3") $(has "$(grep eth_chainId "$T/curl.args")" " http://10.0.0.12:8545/")"
chain ""
: > "$T/say.log"
rc=0; gw_enable quiet || rc=$?
check_rc "M1 no node: an upstream that does not answer: --enable goes on" 0 "$rc"
check "M1 no node: ... with a warning that the network could not be confirmed" yes "$(has "$(cat "$T/say.log")" "warn The network could not be confirmed")"
chain 0x1e7
: > "$T/say.log"
rc=0; gw_status quiet || rc=$?
check "M1 no node: status counts an upstream on another chain, naming both" "1 yes" \
    "${rc} $(has "$(cat "$T/say.log")" "says NETWORK=devnet but the upstream http://10.0.0.12:8545 is on chain 487 (mainnet)")"
before="$(snap)"
logs_reset
GW_IN_IMAGE=""
rc=0; gw_refresh quiet || rc=$?
check "M1 no node: --refresh with the upstream on another chain is refused" "1 yes" "${rc} $(has "$GW_ERR" "chain 487 (mainnet)")"
check "M1 no node: refused refresh, the tree is byte-identical, nothing restarted" "$before " "$(snap) $(sys_changes)"
chain 0x7e1d
rc=0; gw_status quiet || rc=$?
check_rc "M1 no node: an upstream on a devnet chain fits devnet" 0 "$rc"

# M2: a scripts release that changes the pin.
gw_remove quiet
# shellcheck disable=SC2034  # read by lib/gateway.sh
GW_TESTNET_IMAGE_PIN="$IMG"
chain 0x7e1
gin MODE=standalone NETWORK=testnet UPSTREAM=10.0.0.12 DOMAIN=gw.example.org IMAGE=
rc=0; gw_enable quiet || rc=$?
check_rc "M2: testnet with pin A enables" 0 "$rc"
GW_TESTNET_IMAGE_PIN="$IMG2"
: > "$T/say.log"
rc=0; gw_status quiet || rc=$?
check "M2: once the release pins B, status counts the running image A as an issue" "1 yes" \
    "${rc} $(has "$(cat "$T/say.log")" "runs an image this scripts release does not allow")"
GW_IN_IMAGE=""
: > "$T/say.log"
rc=0; gw_refresh quiet || rc=$?
check "M2: --refresh without --image moves to the new pin" "0 refreshed" "${rc} ${GW_APPLIED}"
check "M2: ... and says from which image to which" yes "$(has "$(cat "$T/say.log")" "from ${IMG} to ${IMG2}")"
check "M2: the unit runs the new pin" yes "$(has "$(cat "$(UNIT_P)")" "--stop-timeout 60 ${IMG2} ")"
check "M2: gateway.meta IMAGE is the new pin" "$IMG2" "$(tn_gateway_meta_get IMAGE '')"
rc=0; gw_status quiet || rc=$?
check_rc "M2: status after the move: no issue" 0 "$rc"
GW_IN_IMAGE="$IMG"
rc=0; gw_refresh quiet || rc=$?
check_rc "M2: --refresh --image with a digest other than the pin is still refused" 1 "$rc"
# shellcheck disable=SC2034  # read by lib/gateway.sh
GW_IN_IMAGE=""
# shellcheck disable=SC2034  # read by lib/gateway.sh
GW_TESTNET_IMAGE_PIN=""

# An extra file in /etc/telcoin/gateway: --remove removes the gateway, names the file.
printf 'note\n' > "$SA/etc/telcoin/gateway/NOTES"
: > "$T/say.log"
rc=0; gw_remove quiet || rc=$?
check "remove, extra file: rc 0, removed" "0 removed" "${rc} ${GW_APPLIED}"
check "remove, extra file: the file stays and is named" "yes yes" "$(exists "$SA/etc/telcoin/gateway/NOTES") $(has "$(cat "$T/say.log")" "(NOTES)")"
check "remove, extra file: gateway.meta and the unit are gone" "no no" "$(exists "$(META_P)") $(exists "$(UNIT_P)")"
rc=0; gw_remove quiet || rc=$?
check "remove, extra file: a second --remove has nothing to remove" "0 " "${rc} ${GW_APPLIED}"
rm -rf "$SA/etc/telcoin/gateway"
chain ""

check_lacks "script: the node's unit never reaches systemctl" "telcoin.service" "$(cat "$T/systemctl.all")"


finish
