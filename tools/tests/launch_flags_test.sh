#!/usr/bin/env bash
# tools/tests/launch_flags_test.sh -- launch-line flags. setup-node.sh adds the
# public RPC limits (bounded log queries, subscriptions and request size, HTTP
# limited to eth, net, web3 and tn) only when the node serves public RPC, and
# stops when the release's node --help lacks one of them; the library's flag
# rule and the start-script writer accept them, and the launch editors read
# them back. A copy of setup-node.sh without its last line is
# sourced at the top level with the host-touching steps replaced. Maintainer
# tooling (not updater-tracked). bash 3.2 safe.
# shellcheck source=tools/tests/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
T="$TN_TEST_TMP"
mkdir -p "$T/sn" "$T/root"
grep -v '^main "\$@"$' "$TN_TEST_REPO/setup-node.sh" > "$T/sn/setup-node.sh"
ln -s "$TN_TEST_REPO/lib" "$T/sn/lib"
TN_ROOT_PREFIX="$T/root"
tn_test_pre_common
# shellcheck source=/dev/null
source "$T/sn/setup-node.sh"
set +e  # setup-node.sh makes SERVICE_NAME readonly; tn_test_post_common would assign it

LIMITS="--rpc.max-blocks-per-filter 10000 --rpc.max-logs-per-response 10000 --rpc.max-subscriptions-per-connection 100 --rpc.max-request-size 2 --http.api eth,net,web3,tn"

# Host-touching steps of prepare_node_extra_flags.
node_runner_spec() { printf 'binary:/opt/telcoin/telcoin-network\n'; }
require_node_flag() { return 0; }
install_bootstrap_peers() { return 0; }
write_node_meta() { return 0; }
node_flag_warnings() { return 0; }

prep() {  # prep ENABLE_PUBLIC_RPC -> NODE_EXTRA_FLAGS
    NODE_EXTRA_FLAGS="" NODE_EXTRA_FLAGS_SPEC="" ENABLE_PUBLIC_RPC="$1" STATE_EXPORT=off BOOTSTRAP_PEERS_SRC=""
    prepare_node_extra_flags >/dev/null 2>&1
}
prep true
check "public RPC: the limits are on the launch line" "$LIMITS" "$NODE_EXTRA_FLAGS"
prep false
check "private RPC: no limits" "" "$NODE_EXTRA_FLAGS"
STATE_EXPORT=3
NODE_EXTRA_FLAGS="" NODE_EXTRA_FLAGS_SPEC="" ENABLE_PUBLIC_RPC=true BOOTSTRAP_PEERS_SRC=""
# shellcheck disable=SC2218  # sourced from setup-node.sh; a later stub replaces it
prepare_node_extra_flags >/dev/null 2>&1
check "public RPC with state export: both" "--enable-state-export --state-export-keep 3 ${LIMITS}" "$NODE_EXTRA_FLAGS"

for w in $LIMITS; do
    case "$w" in
        --*) rc=0; _tn_launch_flag_ok "$w" || rc=$?; check_rc "flag rule accepts ${w}" 0 "$rc" ;;
    esac
done

# The release must list each limit flag in its node --help, as for the other
# optional flags: the real require_node_flag, a --help stub without one flag.
eval "$(sed -n '/^require_node_flag() {/,/^}/p' "$T/sn/setup-node.sh")"
HELP_FLAGS="--rpc.max-blocks-per-filter --rpc.max-logs-per-response --rpc.max-subscriptions-per-connection --http.api"
tn_node_has_flag() { case " ${HELP_FLAGS} " in *" $2 "*) return 0 ;; esac; return 1; }
prep_sub() {  # prep_sub ENABLE_PUBLIC_RPC -> rc of prepare_node_extra_flags in a subshell, output in $T/prep.out
    ( NODE_EXTRA_FLAGS="" NODE_EXTRA_FLAGS_SPEC="" ENABLE_PUBLIC_RPC="$1" STATE_EXPORT=off BOOTSTRAP_PEERS_SRC=""
      prepare_node_extra_flags ) > "$T/prep.out" 2>&1
}
rc=0; prep_sub true || rc=$?
check_rc "public RPC on a release without --rpc.max-request-size: setup stops" 1 "$rc"
check "the stop names the missing flag" yes "$(grep -q -- '--rpc.max-request-size needs telcoin-network v0.13.0-adiri' "$T/prep.out" && echo yes || echo no)"
rc=0; prep_sub false || rc=$?
check_rc "private RPC on that release: the limits are not asked for" 0 "$rc"
HELP_FLAGS="${HELP_FLAGS} --rpc.max-request-size"
rc=0; prep_sub true || rc=$?
check_rc "public RPC on a release with all five: goes on" 0 "$rc"
require_node_flag() { return 0; }
unset -f tn_node_has_flag

# The start-script writer takes them, and the launch editors read them back.
NETWORK=testnet DATA_DIR=/var/lib/telcoin PASSPHRASE_METHOD=stdin LOG_TARGET=file
ARGS="--datadir /var/lib/telcoin --http --http.addr 127.0.0.1 --ws --ws.addr 127.0.0.1 ${LIMITS}"
rc=0; _tn_start_script_text source /opt/telcoin/telcoin-network "$ARGS" > "$T/tn-start" 2>/dev/null || rc=$?
check_rc "start script with the limits renders" 0 "$rc"
check "editor reads --rpc.max-request-size" "2" "$(tn_launch_flag_get "$T/tn-start" --rpc.max-request-size 2>/dev/null)"
check "editor reads --http.api" "eth,net,web3,tn" "$(tn_launch_flag_get "$T/tn-start" --http.api 2>/dev/null)"
check "editor reads --rpc.max-logs-per-response" "10000" "$(tn_launch_flag_get "$T/tn-start" --rpc.max-logs-per-response 2>/dev/null)"
# --- setup-node.sh step_create_service goes through the library writers ---------------
REC="$T/rec"
mkdir -p "$REC"
tn_write_node_env() { printf '%s\n' "$@" > "$REC/env"; }
tn_write_start_script() { printf '%s\n' "$@" > "$REC/script"; }
tn_write_node_unit() { printf '%s|%s|%s\n' "$1" "$LOG_TARGET" "$PASSPHRASE_METHOD" > "$REC/unit"; }
tn_install_journald_dropin() { : > "$REC/journald"; }
setup_start_script_dir() { return 0; }
prepare_node_extra_flags() { NODE_EXTRA_FLAGS="--enable-state-export"; }
systemctl() { return 0; }
write_node_meta() { printf '%s\n' "$@" > "$REC/meta"; }
write_node_meta_runner() { return 0; }
tn_precreate_log_files() { return 0; }
confirm() { return 1; }
PRIMARY_LISTENER_MULTIADDR=/ip4/10.0.0.5/udp/49590/quic-v1
WORKER_LISTENER_MULTIADDR=/ip4/10.0.0.5/udp/49594/quic-v1
INSTALL_METHOD=docker DOCKER_IMAGE="us-docker.pkg.dev/telcoin-network/tn-public/adiri:v0.16.0-adiri"
NETWORK=mainnet LOG_TARGET="" ENABLE_HEALTHCHECK_MONITOR=false
rc=0; ( step_create_service ) >/dev/null 2>&1 || rc=$?
check_rc "step_create_service (docker) runs" 0 "$rc"
step_create_service >/dev/null 2>&1
check "node.env gets the two listeners" "$(printf '%s\n%s' "$PRIMARY_LISTENER_MULTIADDR" "$WORKER_LISTENER_MULTIADDR")" "$(cat "$REC/env")"
check "docker start script: method, image, container args" \
    "$(printf 'docker\n%s\n%s' "$DOCKER_IMAGE" "--datadir /home/nonroot --log.stdout.format log-fmt -vvv --http --http.addr 127.0.0.1 --ws --ws.addr 127.0.0.1 --enable-state-export")" \
    "$(cat "$REC/script")"
check "mainnet unit logs to the journal" "docker|journal|stdin" "$(cat "$REC/unit")"
check "journald cap written for the journal target" "yes" "$([[ -e "$REC/journald" ]] && echo yes)"
check_has "LOG_TARGET recorded in .node-meta" "LOG_TARGET=journal" "$(cat "$REC/meta")"
rm -f "$REC/journald"
INSTALL_METHOD=source BINARY_PATH="$T/telcoin-network" NETWORK=testnet LOG_TARGET=""
printf '#!/bin/sh\n' > "$BINARY_PATH"; chmod 0755 "$BINARY_PATH"
step_create_service >/dev/null 2>&1
check "binary start script: method, binary, args" \
    "$(printf 'source\n%s\n%s' "$BINARY_PATH" "--datadir ${DATA_DIR} --log.stdout.format log-fmt -vvv --http --http.addr 127.0.0.1 --ws --ws.addr 127.0.0.1 --enable-state-export")" \
    "$(cat "$REC/script")"
check "testnet unit logs to the files" "source|file|stdin" "$(cat "$REC/unit")"
check "no journald cap for the file target" "no" "$([[ -e "$REC/journald" ]] && echo yes || echo no)"
LOG_TARGET=""
# An empty listener stops finalize before anything is written.
finalize_install_inputs() { return 0; }
finalize_node_extra_flags() { : > "$REC/finalize-went-on"; }
json_refuse_installed() { return 0; }
for pair in "|${WORKER_LISTENER_MULTIADDR}" "${PRIMARY_LISTENER_MULTIADDR}|" "/ip4/x/udp/1/quic-v1|${WORKER_LISTENER_MULTIADDR}"; do
    rm -f "$REC/finalize-went-on"
    rc=0; out="$(PRIMARY_LISTENER_MULTIADDR="${pair%%|*}" WORKER_LISTENER_MULTIADDR="${pair#*|}" json_phase_finalize 2>&1)" || rc=$?
    check "finalize refuses listener pair '${pair}'" "1 no" "$rc $([[ -e "$REC/finalize-went-on" ]] && echo yes || echo no)"
done
finish
