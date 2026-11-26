#!/usr/bin/env bash
# =============================================================================
# tools/tests/gateway_upstream_test.sh -- edit-config.sh --set
# gateway_upstream=<ipv4[,ipv4...]>|off, the validator side of a worker gateway
# on another host:
#   the refusal    without ufw active, or without both allows for every listed
#                  address, nothing is written (launch file, node.env,
#                  .node-meta byte-identical), nothing restarts, and the message
#                  names firewall-setup.sh --enable --gateway-from;
#   the set        --http.addr 0.0.0.0 and --healthcheck 0.0.0.0:<health port>,
#                  no public-RPC limit flags and no --http.api, --ws.addr as it
#                  was, GATEWAY_UPSTREAM and GATEWAY_PREV_HEALTHCHECK recorded,
#                  one guarded restart; a wider list keeps the recorded previous
#                  value and restarts nothing; allowed on mainnet; bad values
#                  refused;
#   off            --http.addr 127.0.0.1 and --healthcheck back to the recorded
#                  value byte for byte (removed when there was none, left as it
#                  is with a warning when nothing is recorded), both keys unset;
#                  with nothing set it is "no change";
#   stopped node   files written, never started or restarted, done ok:true
#                  saying it stays stopped; another key (verbosity) on a
#                  stopped node still restarts it, as before;
#   rollback       a restart that does not come back puts the launch file,
#                  node.env and .node-meta back byte for byte;
#   unit state     activating (a crashed node waiting for its automatic
#                  restart), deactivating, reloading: refused, nothing written
#                  or started; failed counts as stopped;
#   nobody else    an allow from Anywhere (v4, v6, no protocol, a range) to
#                  either port, or a default policy that is not deny: refused;
#                  the monitor's own health rule is fine;
#   public RPC     an RPC already on 0.0.0.0 without GATEWAY_UPSTREAM: refused;
#   RPC site       on mainnet, a host whose Caddyfile holds the public RPC site
#                  block (tn-rpc): refused, nothing written, the message names
#                  install-caddy.sh --phase=rpc-disable; off is not refused,
#                  nor is testnet, nor mainnet with only the dashboard block;
#   PREV lost      setting again does not record the gateway's wildcard;
#   lib/common.sh  tn_gateway_ports_private, tn_gateway_src_canon, and
#                  kuma_extra_remove keeping a rule a gateway source needs.
#
#   bash tools/tests/run.sh tools/tests/gateway_upstream_test.sh
#   docker run --rm -v "$PWD:/w" -w /w bash:3.2 bash tools/tests/run.sh tools/tests/gateway_upstream_test.sh
#
# A copy of edit-config.sh without its last line (main "$@") is sourced by a
# driver that runs one --set per call (as edit_config_admission_test.sh does).
# The root writers, systemctl (a unit state kept in a file), ufw (a status text
# from a file), the committee guard, the epoch wait, the lock and the RPC URL
# are stand-ins; tn_gateway_from_rules_ok, ufw_active, the launch-flag editors,
# meta_set/meta_unset and the backup and restore logic are the real ones.
# Maintainer tooling (not updater-tracked). bash 3.2 safe.
# =============================================================================

set -u

# shellcheck source=tools/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

T="$TN_TEST_TMP"
export ECA_DIR="$T"
FX="$T/fx"
CFG="$FX/etc/telcoin"
META="$CFG/.node-meta"
ENVF="$CFG/node.env"
LAUNCH="$FX/usr/local/libexec/telcoin/tn-start"

has() {
    case "$2" in
        *"$1"*) echo yes ;;
        *) echo no ;;
    esac
}
# macOS has shasum and no sha256sum
if ! command -v sha256sum >/dev/null 2>&1; then
    # shellcheck disable=SC2329  # exported for the driver, which calls it
    sha256sum() { shasum -a 256 "$@"; }
    export -f sha256sum
fi

mkdir -p "$T/ec" "$T/bin" "$T/bk" "$CFG" "$FX/var/lib/telcoin" "$FX/usr/local/libexec/telcoin" "$FX/etc/systemd/system"
grep -v '^main "\$@"$' "$TN_TEST_REPO/edit-config.sh" > "$T/ec/edit-config.sh"
ln -s "$TN_TEST_REPO/lib" "$T/ec/lib"
KP="$(TN_ROOT_PREFIX="$FX" bash -c '. "$1" > /dev/null 2>&1; printf "%s" "${TN_KUMA_PORT:-}"' _ "$TN_TEST_REPO/lib/common.sh")"
check "the health port is known" yes "$(if [[ "$KP" =~ ^[0-9]+$ ]]; then echo yes; else echo no; fi)"

TN_NC_REAL_ID="$(command -v id)"
export TN_NC_REAL_ID
cat > "$T/bin/id" <<'STUB'
#!/bin/sh
if [ "$*" = "-u telcoin" ]; then echo 991; exit 0; fi
if [ "$*" = "-gn telcoin" ]; then echo telcoin; exit 0; fi
exec "$TN_NC_REAL_ID" "$@"
STUB
cat > "$T/bin/getent" <<'STUB'
#!/bin/sh
if [ "$1" = group ] && [ "$2" = telcoin ]; then echo 'telcoin:x:991:'; exit 0; fi
exit 2
STUB
cat > "$T/bin/setpriv" <<'STUB'
#!/bin/sh
while [ $# -gt 0 ] && [ "$1" != -- ]; do shift; done
[ $# -gt 0 ] && shift
exec "$@"
STUB
chmod 0755 "$T/bin/id" "$T/bin/getent" "$T/bin/setpriv"

cat > "$T/ec/drv.sh" <<'DRV'
# shellcheck shell=bash
# drv.sh FIELD=VALUE -- source the copy of edit-config.sh, then run_set.
TN_ROOT_PREFIX="$ECA_DIR/fx"
# shellcheck source=/dev/null
source "$ECA_DIR/ec/edit-config.sh"
set +e
SERVICE_USER=telcoin
SERVICE_GROUP=telcoin
JSON_MODE=true
exec 3>>"$ECA_DIR/events"
rec() { printf '%s\n' "$*" >> "$ECA_DIR/calls.log"; }
tn_write_root_file() { cat > "$1" && chmod "$2" "$1"; }
tn_backup_file() {
    local copy
    copy="$(mktemp "$ECA_DIR/bk/${2:-${1##*/}}.XXXXXX")" || return 2
    cat -- "$1" > "$copy" || return 2
    printf '%s %s\n' "$copy" "$(sha256sum < "$copy" | cut -d' ' -f1)"
}
tn_restore_backup() {
    [ "$(sha256sum < "$1" | cut -d' ' -f1)" = "$2" ] || return 1
    tn_write_root_file "$3" "$4" "${5:-root}" < "$1"
}
# The unit's state is in unit.state (active, inactive, failed, activating,
# deactivating, reloading); is-active prints it (not with --quiet), as systemd
# does. restart and start make it active, except the restart numbered
# ECA_RESTART_FAIL_AT, which leaves it failed.
systemctl() {
    local st n
    rec "systemctl $*"
    st="$(cat "$ECA_DIR/unit.state" 2>/dev/null)"
    case "${1:-}" in
        is-active)
            [ "${2:-}" = --quiet ] || printf '%s\n' "${st:-active}"
            [ "${st:-active}" = active ]
            return ;;
        restart|start)
            n="$(cat "$ECA_DIR/restart.n" 2>/dev/null)"
            n=$((${n:-0} + 1))
            printf '%s\n' "$n" > "$ECA_DIR/restart.n"
            if [ "$n" = "${ECA_RESTART_FAIL_AT:-}" ]; then
                printf 'failed\n' > "$ECA_DIR/unit.state"
                return 1
            fi
            printf 'active\n' > "$ECA_DIR/unit.state"
            return 0 ;;
        stop) printf 'inactive\n' > "$ECA_DIR/unit.state" ;;
    esac
    return 0
}
ufw() { rec "ufw $*"; cat "$ECA_DIR/ufw.status"; }
sleep() { rec "sleep $*"; }
chown() { :; }
tn_committee_down_guard() { rec guard; return 0; }
tn_wait_restart_window() { rec wait; return 0; }
tn_host_baseline_refresh() { rec baseline; }
tn_local_rpc_url() { printf 'http://127.0.0.1:8545\n'; }
tn_launch_runner() { printf 'binary:/opt/telcoin/telcoin-network\n'; }
tn_node_has_flag() { return 0; }
edit_require_root() { :; }
edit_lock() { EDIT_LOCK_HELD=true; return 0; }
resolve_target() {
    TARGET_SERVICE=telcoin
    TARGET_SERVICE_FILE="$ECA_DIR/fx/etc/systemd/system/telcoin.service"
    TARGET_LAUNCH_FILE="$ECA_DIR/fx/usr/local/libexec/telcoin/tn-start"
}
# ECA_RENDER=1: the start-script renderer (it checks a root-owned binary) writes
# the runner and the arguments it was given.
if [ -n "${ECA_RENDER:-}" ]; then
    tn_write_start_script() { printf '#!/bin/bash\nexec %s %s\n' "$2" "$3" > "$TARGET_LAUNCH_FILE"; }
fi
NO_EPOCH_WAIT=true
EDIT_SET_PAIR="$1"
run_set
DRV

# drv FIELD=VALUE -- one run: RC; its output in $T/out; calls.log and events
# start empty.
drv() {
    : > "$T/calls.log"
    : > "$T/events"
    RC=0
    PATH="$T/bin:$PATH" bash "$T/ec/drv.sh" "$@" > "$T/out" 2>&1 < /dev/null || RC=$?
}
done_line() { grep '"event":"done"' "$T/events"; }
nodeline() { grep ' node ' "$LAUNCH"; }
restarts() { grep -c '^systemctl restart' "$T/calls.log"; }
starts() { grep -cE '^systemctl (start|restart)' "$T/calls.log"; }
gwkeys() { grep -E '^GATEWAY_' "$META" | sort -r | tr '\n' ' ' | sed 's/ $//'; }
unit_state() { cat "$T/unit.state"; }
# ufw_status on|off [SRC...] -- `ufw status` (and `ufw status verbose`, the same
# text): on with the default deny policy, 22/tcp from anywhere and, for each SRC,
# the RPC and health allows from it.
ufw_status() {
    {
        if [[ "$1" == on ]]; then
            printf 'Status: active\nLogging: on (low)\nDefault: deny (incoming), allow (outgoing), disabled (routed)\n'
            printf 'New profiles: skip\n\nTo                         Action      From\n--                         ------      ----\n'
            printf '22/tcp                     ALLOW       Anywhere\n'
        else
            printf 'Status: inactive\n'
        fi
        shift
        local s
        for s in "$@"; do
            printf '8545/tcp                   ALLOW       %s\n%s/tcp                  ALLOW       %s\n' "$s" "$KP" "$s"
        done
    } > "$T/ufw.status"
}
# fixture HC [NETWORK [STATE]] -- the node command (in the current start-script
# form: node.env and --bls-passphrase-source stdin) with HC appended, .node-meta,
# node.env, the unit STATE (active); the three files saved as *.orig.
fixture() {
    printf '#!/bin/bash\nexec /opt/telcoin/telcoin-network node --datadir /var/lib/telcoin --http --http.addr 127.0.0.1 --ws --ws.addr 127.0.0.1 --bls-passphrase-source stdin -vvv%s\n' "$1" > "$LAUNCH"
    printf 'DATA_DIR=%s\nNETWORK=%s\n' "$FX/var/lib/telcoin" "${2:-testnet}" > "$META"
    printf 'PRIMARY_LISTENER_MULTIADDR=/ip4/10.0.0.5/udp/49590/quic-v1\nWORKER_LISTENER_MULTIADDR=/ip4/10.0.0.5/udp/49594/quic-v1\nTN_RPC_ADDR=127.0.0.1\n' > "$ENVF"
    chmod 0600 "$META"
    printf '%s\n' "${3:-active}" > "$T/unit.state"
    : > "$T/restart.n"
    cp -p "$LAUNCH" "$T/launch.orig"
    cp -p "$META" "$T/meta.orig"
    cp -p "$ENVF" "$T/env.orig"
}
same() {
    if cmp -s "$T/launch.orig" "$LAUNCH" && cmp -s "$T/meta.orig" "$META" && cmp -s "$T/env.orig" "$ENVF"; then
        echo same
    else
        echo changed
    fi
}
launch_same() { if cmp -s "$T/launch.orig" "$LAUNCH"; then echo same; else echo changed; fi; }
envrpc() { grep '^TN_RPC_ADDR=' "$ENVF" 2>/dev/null; }

# ---- refusals: ufw inactive, a rule missing ---------------------------------------
fixture " --healthcheck ${KP}"
ufw_status off 10.0.0.7
drv gateway_upstream=10.0.0.7
check_rc "ufw inactive: rc 1" 1 "$RC"
check "ufw inactive: launch file, node.env, .node-meta byte-identical" same "$(same)"
check "ufw inactive: no systemctl start or restart" 0 "$(starts)"
check "ufw inactive: done ok:false" yes "$(has '"ok":false' "$(done_line)")"
check "ufw inactive: says ufw is not active" yes "$(has "ufw is not active" "$(done_line)")"
check "ufw inactive: names firewall-setup.sh --enable --gateway-from" yes \
    "$(has "firewall-setup.sh --enable --gateway-from 10.0.0.7" "$(done_line)")"
ufw_status on 10.0.0.9
drv gateway_upstream=10.0.0.7
check_rc "rule missing: rc 1" 1 "$RC"
check "rule missing: files byte-identical" same "$(same)"
check "rule missing: no systemctl start or restart" 0 "$(starts)"
check "rule missing: names the address and port" yes "$(has "no rule letting 10.0.0.7 in to port 8545" "$(done_line)")"
check "rule missing: names firewall-setup.sh --enable --gateway-from" yes \
    "$(has "firewall-setup.sh --enable --gateway-from 10.0.0.7" "$(done_line)")"
ufw_status on 10.0.0.7
grep -v "^${KP}/tcp" "$T/ufw.status" > "$T/ufw.tmp" && cat "$T/ufw.tmp" > "$T/ufw.status"
drv gateway_upstream=10.0.0.7
check "health rule missing: rc 1, files byte-identical, no restart" "1 same 0" "$RC $(same) $(starts)"
check "health rule missing: names the health port" yes "$(has "no rule letting 10.0.0.7 in to port ${KP}" "$(done_line)")"
ufw_status on 10.0.0.7
drv gateway_upstream=10.0.0.7,10.0.0.8
check "second address without rules: rc 1, files byte-identical" "1 same" "$RC $(same)"
check "second address without rules: names it" yes "$(has "no rule letting 10.0.0.8 in" "$(done_line)")"

# ---- set on an active node ---------------------------------------------------------------
fixture " --healthcheck ${KP}"
ufw_status on 10.0.0.7
drv gateway_upstream=10.0.0.7
check_rc "set active: rc 0" 0 "$RC"
check "set active: one restart" 1 "$(restarts)"
check "set active: --http.addr 0.0.0.0" yes "$(has " --http.addr 0.0.0.0 " "$(nodeline)")"
check "set active: --healthcheck 0.0.0.0:<health port>" yes "$(has " --healthcheck 0.0.0.0:${KP}" "$(nodeline)")"
check "set active: --ws.addr untouched" yes "$(has " --ws.addr 127.0.0.1 " "$(nodeline)")"
check "set active: no public-RPC limit flags" no "$(has "--rpc.max" "$(nodeline)")"
check "set active: no --http.api" no "$(has "--http.api" "$(nodeline)")"
check "set active: the two meta keys" "GATEWAY_UPSTREAM=10.0.0.7 GATEWAY_PREV_HEALTHCHECK=${KP}" "$(gwkeys)"
check "set active: node.env follows the RPC bind" "TN_RPC_ADDR=0.0.0.0" "$(envrpc)"
check "set active: done ok:true, healthy" "yes yes" "$(has '"ok":true' "$(done_line)") $(has "healthy" "$(done_line)")"
check "set active: the unit is active" active "$(unit_state)"
# A wider list: only .node-meta changes, the previous value stays as recorded.
ufw_status on 10.0.0.7 10.0.0.8
drv gateway_upstream=10.0.0.7,10.0.0.8
check_rc "wider list: rc 0" 0 "$RC"
check "wider list: GATEWAY_PREV_HEALTHCHECK kept, list updated" \
    "GATEWAY_UPSTREAM=10.0.0.7,10.0.0.8 GATEWAY_PREV_HEALTHCHECK=${KP}" "$(gwkeys)"
check "wider list: no restart for a .node-meta-only change" 0 "$(starts)"
check "wider list: says only the record changed" yes "$(has "only its record in .node-meta changed" "$(done_line)")"
# off: the bare-port --healthcheck comes back byte for byte.
drv gateway_upstream=off
check_rc "off: rc 0" 0 "$RC"
check "off: one restart" 1 "$(restarts)"
check "off: the launch file byte-identical to before the set" same "$(launch_same)"
check "off: both keys unset" "" "$(gwkeys)"
check "off: node.env back to loopback" "TN_RPC_ADDR=127.0.0.1" "$(envrpc)"
# off with nothing set: no change.
drv gateway_upstream=off
check "off with nothing set: rc 0, no restart, launch file as it was" "0 0 same" "$RC $(starts) $(launch_same)"
check "off with nothing set: says nothing changed" yes "$(has "nothing changed" "$(done_line)")"

# ---- off when there was no --healthcheck before; off with nothing recorded ---------------
fixture ""
ufw_status on 10.0.0.7
drv gateway_upstream=10.0.0.7
check "no flag before: set rc 0, PREV none" "0 GATEWAY_UPSTREAM=10.0.0.7 GATEWAY_PREV_HEALTHCHECK=none" "$RC $(gwkeys)"
drv gateway_upstream=off
check "no flag before: off rc 0, flag removed, launch file byte-identical" "0 no same" \
    "$RC $(has "--healthcheck" "$(nodeline)") $(launch_same)"
fixture " --healthcheck ${KP}"
drv gateway_upstream=10.0.0.7
grep -v '^GATEWAY_PREV_HEALTHCHECK=' "$META" > "$T/meta.tmp" && cat "$T/meta.tmp" > "$META"
drv gateway_upstream=off
check_rc "nothing recorded: off rc 0" 0 "$RC"
check "nothing recorded: --healthcheck left as it is" yes "$(has " --healthcheck 0.0.0.0:${KP}" "$(nodeline)")"
check "nothing recorded: --http.addr back to loopback" yes "$(has " --http.addr 127.0.0.1 " "$(nodeline)")"
check "nothing recorded: warns" yes "$(has "GATEWAY_PREV_HEALTHCHECK is not recorded" "$(cat "$T/events")")"
check "nothing recorded: keys unset" "" "$(gwkeys)"

# ---- a stopped node: files written, never started --------------------------------------
fixture " --healthcheck ${KP}" testnet inactive
ufw_status on 10.0.0.7
drv gateway_upstream=10.0.0.7
check_rc "stopped: rc 0" 0 "$RC"
check "stopped: no systemctl start and no systemctl restart" 0 "$(starts)"
check "stopped: flags written" "yes yes" \
    "$(has " --http.addr 0.0.0.0 " "$(nodeline)") $(has " --healthcheck 0.0.0.0:${KP}" "$(nodeline)")"
check "stopped: the two meta keys" "GATEWAY_UPSTREAM=10.0.0.7 GATEWAY_PREV_HEALTHCHECK=${KP}" "$(gwkeys)"
check "stopped: done ok:true" yes "$(has '"ok":true' "$(done_line)")"
check "stopped: says it stays stopped" yes "$(has "stays stopped" "$(done_line)")"
check "stopped: the unit is still stopped" inactive "$(unit_state)"
drv gateway_upstream=off
check "stopped: off rc 0, never started, launch file restored" "0 0 same" "$RC $(starts) $(launch_same)"
check "stopped: off leaves it stopped" inactive "$(unit_state)"

# ---- a restart that does not come back: everything rolled back ----------------------------
fixture " --healthcheck ${KP}"
ufw_status on 10.0.0.7
ECA_RESTART_FAIL_AT=1 drv gateway_upstream=10.0.0.7
check_rc "restart fails: rc 1" 1 "$RC"
check "restart fails: launch file, node.env, .node-meta byte-identical" same "$(same)"
check "restart fails: done says rolled back" "yes yes" \
    "$(has '"ok":false' "$(done_line)") $(has '"rolled_back":true' "$(done_line)")"
check "restart fails: restarted again after the rollback" 2 "$(restarts)"
check "restart fails: the unit is active on the old files" active "$(unit_state)"

# ---- mainnet allowed; bad values refused ----------------------------------------------------
fixture " --healthcheck ${KP}" mainnet
ufw_status on 10.0.0.7
drv gateway_upstream=10.0.0.7
check "mainnet: rc 0, flags set" "0 yes" "$RC $(has " --http.addr 0.0.0.0 " "$(nodeline)")"
for v in 10.0.0.07 "10.0.0.7," ",10.0.0.7" 0.0.0.0 10.0.0.0/24 256.1.1.1 on "10.0.0.7 10.0.0.8" ::1; do
    fixture " --healthcheck ${KP}"
    drv "gateway_upstream=${v}"
    check "bad value '${v}': rc 1, files byte-identical, no restart" "1 same 0" "$RC $(same) $(starts)"
done
fixture " --healthcheck ${KP}"
drv "gateway_upstream="
check "an empty value: rc 1, files byte-identical" "1 same" "$RC $(same)"

# ---- mainnet: this host's public RPC site or a worker gateway, never both ---------------
CADDYFILE="$FX/etc/caddy/Caddyfile"
mkdir -p "${CADDYFILE%/*}"
# caddyfile dash|rpc -- the managed Caddyfile with the dashboard block and, for
# rpc, the public RPC site block after it.
caddyfile() {
    {
        printf '# >>> tn-dashboard >>>\nstatus.example.com {\n    reverse_proxy 127.0.0.1:3001\n}\n# <<< tn-dashboard <<<\n'
        if [[ "$1" == rpc ]]; then
            printf '\n# >>> tn-rpc >>>\nrpc.example.com {\n    reverse_proxy 127.0.0.1:8545\n}\n# <<< tn-rpc <<<\n'
        fi
    } > "$CADDYFILE"
}
fixture " --healthcheck ${KP}" mainnet
ufw_status on 10.0.0.7
caddyfile rpc
drv gateway_upstream=10.0.0.7
check "mainnet with the RPC site: rc 1, files byte-identical, no restart" "1 same 0" "$RC $(same) $(starts)"
check "mainnet with the RPC site: done ok:false" yes "$(has '"ok":false' "$(done_line)")"
check "mainnet with the RPC site: names rpc-disable" yes \
    "$(has "install-caddy.sh --phase=rpc-disable first" "$(done_line)")"
check "mainnet with the RPC site: says nothing was changed" yes "$(has "nothing was changed" "$(done_line)")"
fixture " --healthcheck ${KP}" mainnet
caddyfile dash
drv gateway_upstream=10.0.0.7
check "mainnet with only the dashboard: rc 0, flags set, one restart" "0 yes 1" \
    "$RC $(has " --http.addr 0.0.0.0 " "$(nodeline)") $(restarts)"
check "mainnet with only the dashboard: the two meta keys" \
    "GATEWAY_UPSTREAM=10.0.0.7 GATEWAY_PREV_HEALTHCHECK=${KP}" "$(gwkeys)"
# The site added while the gateway is set: off still takes the gateway away.
caddyfile rpc
drv gateway_upstream=off
check_rc "mainnet off with the RPC site: rc 0" 0 "$RC"
check "mainnet off with the RPC site: launch file byte-identical to before the set" same "$(launch_same)"
check "mainnet off with the RPC site: both keys unset" "" "$(gwkeys)"
fixture " --healthcheck ${KP}" testnet
drv gateway_upstream=10.0.0.7
check "testnet with the RPC site: rc 0, flags set" "0 yes" "$RC $(has " --http.addr 0.0.0.0 " "$(nodeline)")"
rm -f "$CADDYFILE"

# ---- another key on a stopped node: as before this change (it restarts) -----------------
fixture "" testnet inactive
ECA_RENDER=1 drv verbosity=-vv
check_rc "verbosity on a stopped node: rc 0" 0 "$RC"
check "verbosity on a stopped node: the launch file has -vv" yes "$(has " -vv" "$(cat "$LAUNCH")")"
check "verbosity on a stopped node: no is-active before the edit" "systemctl daemon-reload" \
    "$(grep -m1 '^systemctl' "$T/calls.log")"
check "verbosity on a stopped node: restarted (today's behaviour)" 1 "$(restarts)"
check "verbosity on a stopped node: the unit ends active" active "$(unit_state)"

# ---- a unit that is starting, restarting or stopping: refused; failed counts as stopped ----
# activating includes a crashed node waiting for its automatic restart.
for st in activating deactivating reloading; do
    fixture " --healthcheck ${KP}" testnet "$st"
    ufw_status on 10.0.0.7
    drv gateway_upstream=10.0.0.7
    check "unit ${st}: rc 1, files byte-identical, no start or restart" "1 same 0" "$RC $(same) $(starts)"
    check "unit ${st}: says starting or restarting, wait and run again" "yes yes" \
        "$(has "starting or restarting" "$(done_line)") $(has "run this again" "$(done_line)")"
    check "unit ${st}: state left alone" "$st" "$(unit_state)"
done
fixture " --healthcheck ${KP}" testnet failed
ufw_status on 10.0.0.7
drv gateway_upstream=10.0.0.7
check "unit failed: rc 0, edited, no start or restart" "0 yes 0" "$RC $(has " --http.addr 0.0.0.0 " "$(nodeline)") $(starts)"
check "unit failed: done says it stays stopped" yes "$(has "stays stopped" "$(done_line)")"
check "unit failed: stays failed" failed "$(unit_state)"

# ---- the bind guard keeps everybody else out (tn_gateway_ports_private) -------------------
fixture " --healthcheck ${KP}" mainnet
ufw_status on 10.0.0.7
printf '8545/tcp                   ALLOW       Anywhere\n' >> "$T/ufw.status"
drv gateway_upstream=10.0.0.7
check "Anywhere on the RPC port: rc 1, files byte-identical, no restart" "1 same 0" "$RC $(same) $(starts)"
check "Anywhere on the RPC port: named" yes "$(has "any address (Anywhere) in to port 8545" "$(done_line)")"
ufw_status on 10.0.0.7
printf '%s (v6)                  ALLOW IN    Anywhere (v6)\n' "$KP" >> "$T/ufw.status"
drv gateway_upstream=10.0.0.7
check "Anywhere (v6) on the health port, no protocol: rc 1, files byte-identical" "1 same" "$RC $(same)"
check "Anywhere (v6) on the health port: named" yes "$(has "in to port ${KP}" "$(done_line)")"
ufw_status on 10.0.0.7
printf '8000:9000/tcp              LIMIT       Anywhere\n' >> "$T/ufw.status"
drv gateway_upstream=10.0.0.7
check "a range holding the RPC port open to Anywhere: rc 1, files byte-identical" "1 same" "$RC $(same)"
ufw_status on 10.0.0.7
sed 's/^Default: deny (incoming)/Default: allow (incoming)/' "$T/ufw.status" > "$T/ufw.tmp" && cat "$T/ufw.tmp" > "$T/ufw.status"
drv gateway_upstream=10.0.0.7
check "default allow incoming: rc 1, files byte-identical, no restart" "1 same 0" "$RC $(same) $(starts)"
check "default allow incoming: named" yes "$(has "default policy for incoming traffic is allow" "$(done_line)")"
ufw_status on 10.0.0.7
grep -v '^Default:' "$T/ufw.status" > "$T/ufw.tmp" && cat "$T/ufw.tmp" > "$T/ufw.status"
drv gateway_upstream=10.0.0.7
check "no default policy shown: rc 1, files byte-identical" "1 same" "$RC $(same)"
ufw_status on 10.0.0.7
printf '%s/tcp                  ALLOW       104.155.184.201\n8546/tcp                   ALLOW       Anywhere\n9000/udp                   ALLOW       Anywhere\nOpenSSH                    ALLOW       Anywhere\n' \
    "$KP" >> "$T/ufw.status"
drv gateway_upstream=10.0.0.7
check "the monitor's health rule, other ports and an app profile: not refused, rc 0" "0 yes" \
    "$RC $(has " --http.addr 0.0.0.0 " "$(nodeline)")"

# ---- an RPC already public (no GATEWAY_UPSTREAM): refused, off would take it away --------
fixture " --healthcheck ${KP}"
sed 's/--http.addr 127.0.0.1/--http.addr 0.0.0.0/' "$LAUNCH" > "$T/l.tmp" && cat "$T/l.tmp" > "$LAUNCH" && cp -p "$LAUNCH" "$T/launch.orig"
ufw_status on 10.0.0.7
drv gateway_upstream=10.0.0.7
check "public RPC: rc 1, files byte-identical, no restart" "1 same 0" "$RC $(same) $(starts)"
check "public RPC: names the RPC access item" yes "$(has "choose 'RPC access', then '1) Private" "$(done_line)")"

# ---- GATEWAY_PREV_HEALTHCHECK lost while set: the wildcard is not recorded as "before" ----
fixture " --healthcheck ${KP}"
ufw_status on 10.0.0.7 10.0.0.8
drv gateway_upstream=10.0.0.7
grep -v '^GATEWAY_PREV_HEALTHCHECK=' "$META" > "$T/meta.tmp" && cat "$T/meta.tmp" > "$META"
drv gateway_upstream=10.0.0.7,10.0.0.8
check "PREV lost: rc 0, the wildcard not recorded" "0 GATEWAY_UPSTREAM=10.0.0.7,10.0.0.8" "$RC $(gwkeys)"
check "PREV lost: warns that off leaves --healthcheck" yes "$(has "will leave --healthcheck as it is" "$(cat "$T/events")")"

# ---- GATEWAY_PREV_HEALTHCHECK that is not one word: off is refused (the launch-flag setter
# takes one word) and rolled back ----------------------------------------------------------
fixture " --healthcheck ${KP}"
ufw_status on 10.0.0.7
drv gateway_upstream=10.0.0.7
sed "s/^GATEWAY_PREV_HEALTHCHECK=.*/GATEWAY_PREV_HEALTHCHECK=${KP} --http.api eth,admin/" "$META" > "$T/meta.tmp" && cat "$T/meta.tmp" > "$META"
cp -p "$LAUNCH" "$T/launch.orig" && cp -p "$META" "$T/meta.orig" && cp -p "$ENVF" "$T/env.orig"
drv gateway_upstream=off
check "PREV with a space: off rc 1, files byte-identical, no restart" "1 same 0" "$RC $(same) $(starts)"
check "PREV with a space: no --http.api on the node line" no "$(has "--http.api" "$(nodeline)")"

# ---- lib/common.sh: tn_gateway_ports_private, tn_gateway_src_canon, kuma_extra_remove -----
# lib_run CODE -- run CODE in a bash that sourced lib/common.sh under the fixture
# root, with ufw printing $T/ufw.status and logging its calls to $T/ufw.calls.
lib_run() {
    : > "$T/ufw.calls"
    TN_ROOT_PREFIX="$FX" ECA_DIR="$T" bash -c '. "$1" > /dev/null 2>&1
        set +e
        ufw() { printf "ufw %s\n" "$*" >> "$ECA_DIR/ufw.calls"; cat "$ECA_DIR/ufw.status"; }
        tn_write_root_file() { cat > "$1" && chmod "$2" "$1"; }
        eval "$2"' _ "$TN_TEST_REPO/lib/common.sh" "$1" 2>/dev/null
}
fixture " --healthcheck ${KP}"
ufw_status on 10.0.0.7
check "ports_private: closed, rc 0 and an empty global" "0 []" \
    "$(lib_run 'tn_gateway_ports_private 8545 '"$KP"'; printf "%s [%s]" $? "$TN_GATEWAY_OPEN_FOUND"')"
printf 'Anywhere                   ALLOW       Anywhere\n' >> "$T/ufw.status"
check "ports_private: every port from Anywhere" "1 [Anywhere 8545]" \
    "$(lib_run 'tn_gateway_ports_private 8545 '"$KP"'; printf "%s [%s]" $? "$TN_GATEWAY_OPEN_FOUND"')"
ufw_status off
check "ports_private: ufw inactive" "1 [ufw-inactive]" \
    "$(lib_run 'tn_gateway_ports_private 8545 '"$KP"'; printf "%s [%s]" $? "$TN_GATEWAY_OPEN_FOUND"')"
check "src_canon: /32 dropped, a CIDR by its network address" "10.0.0.7 10.0.0.0/24 10.0.0.7" \
    "$(lib_run 'printf "%s " "$(tn_gateway_src_canon 10.0.0.7/32)" "$(tn_gateway_src_canon 10.0.0.5/24)"; tn_gateway_src_canon 10.0.0.7')"
# kuma_extra_remove: a source that is also a gateway source keeps the health rule.
ufw_status on 10.0.0.7
printf 'KUMA_EXTRA_SRC=10.0.0.7/32 10.0.0.9\nGATEWAY_ALLOW_FROM=10.0.0.7\n' >> "$META"
lib_run 'kuma_extra_remove 10.0.0.7/32'
check "extra that is a gateway source: health rule not deleted" 0 "$(grep -c 'delete' "$T/ufw.calls")"
check "extra that is a gateway source: dropped from the extras" "KUMA_EXTRA_SRC=10.0.0.9" "$(grep '^KUMA_EXTRA_SRC=' "$META")"
lib_run 'kuma_extra_remove 10.0.0.9'
check "extra that is not a gateway source: its rule deleted" "ufw delete allow from 10.0.0.9 to any port ${KP} proto tcp" \
    "$(grep 'delete' "$T/ufw.calls")"

finish
