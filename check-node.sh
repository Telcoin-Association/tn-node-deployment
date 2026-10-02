#!/usr/bin/env bash
# =============================================================================
# check-node.sh -- Telcoin Network Node Health Check
#
# Queries the Telcoin Network consensus RPC for ground truth and compares
# the local node state against it. Every node is checked the same way: the
# role is decided on-chain each epoch, so there is no validator/observer
# switch. Committee membership of the current epoch (on-chain, from the
# network RPC) decides whether absence from the consensus headers is an
# error. The network RPC is the public RPC of the network recorded in
# .node-meta. Falls back gracefully if the local RPC is unreachable -- the
# network's view of your node is still reported. Runs on Linux and macOS.
#
# USAGE:
#   bash check-node.sh                              # check the installed node
#   bash check-node.sh --address 0xYOUR_ADDRESS     # include on-chain status
#   bash check-node.sh --authority-id <BASE58>      # id to use when tn_info is unavailable
#   bash check-node.sh --rpc <URL>                  # custom local RPC
#   bash check-node.sh --network-rpc <URL>          # custom network RPC
#   bash check-node.sh --no-network                 # skip network query
#   bash check-node.sh --service <name>             # custom service name
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

# common.sh enables `set -euo pipefail`. check-node.sh is a read-only
# diagnostic that MUST run to completion and print a full report even when
# individual probes fail -- it uses graceful-degradation patterns throughout
# (`... || echo ""`, and helpers that return non-zero to mean "not found").
# Leaving `-e` active repeatedly caused silent early exits where a helper
# returning non-zero inside a command substitution killed the script
# mid-report (e.g. read_prev_block_state before the state file exists). So we
# explicitly DISABLE -e here while keeping -u (unset-var detection) and
# pipefail. The summary at the end is the authoritative pass/fail; nothing
# else should abort the run.
set +e

readonly SCRIPT_VERSION="1.2.0"
readonly STALE_THRESHOLD_SECONDS=60
# WorkerConfigs system contract: numWorkers() is the number of workers every
# committee member must run.
readonly WORKER_CONFIGS="0xFee0FEe0fee0fEE0FEe0fee0FEE0fEe0feE0FEe0"
readonly NUM_WORKERS_SELECTOR="0x57eb3b30"
# EVM execution lag (network block - local block) above which the node is
# considered "catching up" rather than caught up. The execution-layer lag is
# the authoritative sync signal on Telcoin -- the consensus "tip" comparison
# only confirms the node sees the same tip, NOT that it has processed up to it,
# and eth_syncing returns false even mid-catch-up. See v1.1.43 changelog.
readonly EVM_SYNC_THRESHOLD=50

# Defaults that get overridden by auto-detection or explicit flags.
RPC_URL=""
SERVICE_NAME=""
VALIDATOR_ADDRESS=""
VALIDATOR_ADDRESS_SRC="--address"
AUTHORITY_ID=""
NETWORK_RPC=""
QUERY_NETWORK=true

# The network this node belongs to, set by resolve_network: NODE_NETWORK is
# testnet, mainnet or devnet ("" when unknown), NETWORK_SRC says where that came
# from and EXPECTED_CHAIN_ID is its chain id ("" accepts any Telcoin chain id).
NODE_NETWORK=""
NETWORK_SRC=""
NETWORK_NOTE=""
EXPECTED_CHAIN_ID=""

# The node's own identity, set by resolve_identity: the authority id that
# consensus headers carry as author, and the execution address that committees
# list. The _SRC variables say where each value came from.
AUTH_ID=""
AUTH_SRC=""
EXEC_ADDR=""
EXEC_SRC=""

# Set by the epoch section (§5.5). IN_COMMITTEE is yes or no only when the
# committee was read on-chain through the network RPC; otherwise it stays
# unknown and COMMITTEE_WHY says why. LOCAL_NODE_MODE is the local tn_nodeMode
# answer (§4), empty when it could not be read.
EPOCH_E=""
IN_COMMITTEE="unknown"
COMMITTEE_WHY=""
LOCAL_NODE_MODE=""

# On-chain stake status, read once per run from the ConsensusRegistry through
# the network RPC by probe_onchain_validator_status. ONCHAIN_STAKE_LINE /
# ONCHAIN_STAKE_RC hold the raw node_stake_status result that §5.5 (activation
# epoch) and §7 render, so the status is decided and printed from one round trip.
ONCHAIN_STAKE_LINE=""
ONCHAIN_STAKE_RC=""

# Fill in what the flags left empty, from the installed node. RPC_URL comes from
# RPC_PORT in .node-meta (default DEFAULT_RPC_PORT) and is set only when --rpc
# did not set it. SERVICE_NAME comes from tn_resolve_service (the unified telcoin
# unit, or a legacy role-suffixed unit) unless --service set it; with no node
# installed it falls back to telcoin so the report still renders.
detect_node() {
    local rpc_port svc
    if [[ -z "$RPC_URL" ]]; then
        rpc_port="$(meta_get RPC_PORT 2>/dev/null || true)"
        [[ "$rpc_port" =~ ^[0-9]+$ ]] || rpc_port="$DEFAULT_RPC_PORT"
        RPC_URL="http://127.0.0.1:${rpc_port}"
    fi
    [[ -z "$SERVICE_NAME" ]] || return 0
    if svc="$(tn_resolve_service 2>/dev/null)" && [[ -n "$svc" ]]; then
        SERVICE_NAME="$svc"
    else
        SERVICE_NAME="telcoin"
        print_warn "No Telcoin node detected on this server -- checking service '${SERVICE_NAME}'."
    fi
    return 0
}

# Read the on-chain stake status ONCE per run (node_stake_status in lib/common.sh,
# a single eth_call against the network RPC) and cache the result line for §5.5
# and §7: "<status> <activation_epoch> <is_retired> <exit_epoch>", "none" (no
# ConsensusNFT) or "unknown ..." (rc 1 bad address, rc 2 unreadable). No-op unless
# VALIDATOR_ADDRESS is set and the network RPC is usable (NETWORK_OK), so it is
# called after section 3 resolves NETWORK_OK.
probe_onchain_validator_status() {
    local line rc
    [[ -n "$VALIDATOR_ADDRESS" ]] || return 0
    [[ "$NETWORK_OK" == "true" ]] || return 0
    rc=0
    line="$(node_stake_status "$VALIDATOR_ADDRESS" "$NETWORK_RPC" 2>/dev/null)" || rc=$?
    ONCHAIN_STAKE_LINE="$line"
    ONCHAIN_STAKE_RC="$rc"
    return 0
}

# Render the cached probe result (§7). print_validator_onchain_status owns the
# status labels and the "Next step" text; given the current epoch it also tells
# an Exited validator whether unstake() is eligible now. An unreadable status is
# a warning only and never a health issue.
report_onchain_validator_status() {
    local reason cur_epoch
    print_step "Checking validator on-chain status..."
    print_info "Address:  ${VALIDATOR_ADDRESS}"
    print_info "Contract: ${CONSENSUS_REGISTRY}"
    echo ""
    cur_epoch="${EPOCH_E:-${NET_EPOCH:-}}"
    case "$ONCHAIN_STAKE_RC" in
        0) print_validator_onchain_status "$VALIDATOR_ADDRESS" "$ONCHAIN_STAKE_LINE" "" "$cur_epoch" || true ;;
        1) print_warn "Invalid validator address ${VALIDATOR_ADDRESS} -- skipping the on-chain check." ;;
        *)
            # "unknown <kind> <detail>"; an older library prints a bare "unknown".
            reason="${ONCHAIN_STAKE_LINE#unknown}"
            reason="${reason# }"
            print_warn "Could not read the on-chain stake status from ${NETWORK_RPC}${reason:+ (${reason})} -- validator-only checks are skipped this run."
            ;;
    esac
    return 0
}

while [[ $# -gt 0 ]]; do
    # A value-taking flag given last, or followed by another --flag, has no value.
    # Say so on stderr and stop before set -u turns the missing "$2" into an
    # "unbound variable" crash. Exit 0, like --help and every other way out.
    case "$1" in
        --rpc|--service|--address|--authority-id|--network-rpc)
            if [[ $# -lt 2 || "$2" == --* ]]; then
                echo "error: $1 needs a value (see $0 --help)" >&2
                exit 0
            fi
            ;;
    esac
    case "$1" in
        --validator|--observer)
            # Role flags are gone: the role is decided on-chain each epoch.
            echo "note: $1 is ignored; the role is decided on-chain each epoch" >&2
            shift ;;
        --rpc)          RPC_URL="$2";           shift 2 ;;
        --service)      SERVICE_NAME="$2";      shift 2 ;;
        --address)      VALIDATOR_ADDRESS="$2"; shift 2 ;;
        --authority-id) AUTHORITY_ID="$2";      shift 2 ;;
        --network-rpc)  NETWORK_RPC="$2";       shift 2 ;;
        --no-network)   QUERY_NETWORK=false;    shift ;;
        -h|--help)
            cat <<EOF

Usage: $0 [OPTIONS]

  (no flag)                Check the installed node (service and RPC port auto-detected)
  --rpc <URL>              Local RPC endpoint (default: http://127.0.0.1:<RPC_PORT from .node-meta, or ${DEFAULT_RPC_PORT}>)
  --network-rpc <URL>      Network RPC for ground truth (default: the public RPC of the network in
                           .node-meta: testnet ${TESTNET_RPC_URL}, devnet ${DEVNET_RPC_URL},
                           mainnet ${MAINNET_RPC_URL})
  --no-network             Skip the network RPC query (local-only mode)
  --service <name>         systemd service name override
  --address <0x...>        Validator address for on-chain status check
  --authority-id <BASE58>  Authority ID to look for in the consensus headers when the local
                           node does not answer tn_info (the node's own answer wins)

EOF
            exit 0
            ;;
        *) print_warn "Unknown argument: $1"; shift ;;
    esac
done

# Fill in the service name and local RPC URL from the installed node.
detect_node

# VALIDATOR_ADDRESS is recorded in .node-meta for ALL nodes (every node is
# provisioned validator-capable; the on-chain registry decides the role). Load
# it from meta unless --address already supplied one, so the on-chain status
# checks run automatically.
if [[ -z "$VALIDATOR_ADDRESS" ]]; then
    VALIDATOR_ADDRESS="$(meta_get VALIDATOR_ADDRESS 2>/dev/null || true)"
    VALIDATOR_ADDRESS_SRC=".node-meta"
fi

HEALTH_ISSUES=0
# EVM execution lag (network - local) and catch-up flag. Set in section 5,
# read by the summary in section 10. The execution lag -- not the consensus
# tip match -- is the real "am I synced" signal.
EVM_LAG=""
CATCHING_UP=false
# Set true if the §3 network RPC probe fails while --no-network was NOT passed.
# When this is true, §4 / §6 / §7 are silently skipped, so the §10 summary
# surfaces an explicit banner naming which sections did not run -- otherwise an
# operator sees a half-empty report and may misread it as "everything passed".
NETWORK_PROBE_FAILED=false
# Set true when the network RPC answers for a different chain than this node's
# network (§3). The comparison is skipped the same way, but it is the endpoint
# that is wrong, not the node, so it is not a health issue. NET_CHAIN_DEC is the
# chain id the endpoint reported.
NETWORK_WRONG_CHAIN=false
NET_CHAIN_DEC=""
# Where §6 found the consensus headers it checks: "network", "local node" (the
# network RPC was unavailable) or "" (§6 did not run).
PARTICIPATION_SRC=""

# =============================================================================
# HELPERS
# =============================================================================

# Detect this node's data directory from .node-meta so disk checks land on
# the actual chain-data mount, not just /var/lib/telcoin. Always returns 0
# (echoes the default path if nothing else found) so set -e doesn't fire.
detect_data_dir() {
    local meta; meta="$(node_meta_path || true)"
    local default; default="$(tn_resolve_data_dir)"
    if [[ -n "$meta" ]] && [[ -f "$meta" ]]; then
        local data_dir
        data_dir=$(grep "^DATA_DIR=" "$meta" 2>/dev/null | cut -d= -f2 || true)
        if [[ -n "$data_dir" ]] && [[ -d "$data_dir" ]]; then
            echo "$data_dir"
            return 0
        fi
    fi
    echo "$default"
    return 0
}

# have_fns <name>... -- rc 0 when lib/common.sh defines every named function.
# The checks added in v1.2.0 call helpers from lib/common.sh 1.6.0; with an older
# library (check-node.sh updated, lib/ not) they are skipped instead of dying on
# "command not found". The report header warns once when the library is older.
have_fns() {
    local f
    for f in "$@"; do
        declare -F "$f" >/dev/null 2>&1 || return 1
    done
    return 0
}

# lower <text> -- the text in lower case (bash 3.2 has no ${v,,}).
lower() {
    printf '%s\n' "$1" | tr '[:upper:]' '[:lower:]'
}

# Network name <-> chain id <-> public RPC, from the lib/common.sh constants.
# Testnet is matched first: an older library gives mainnet the testnet chain id.
network_chain_id() {
    case "$1" in
        testnet) printf '%s\n' "$TESTNET_CHAIN_ID" ;;
        mainnet) printf '%s\n' "$MAINNET_CHAIN_ID" ;;
        devnet)  printf '%s\n' "$DEVNET_CHAIN_ID" ;;
    esac
}
network_rpc_url() {
    case "$1" in
        testnet) printf '%s\n' "$TESTNET_RPC_URL" ;;
        mainnet) printf '%s\n' "$MAINNET_RPC_URL" ;;
        devnet)  printf '%s\n' "$DEVNET_RPC_URL" ;;
    esac
}
chain_network() {
    case "$1" in
        "$TESTNET_CHAIN_ID") printf 'testnet\n' ;;
        "$MAINNET_CHAIN_ID") printf 'mainnet\n' ;;
        "$DEVNET_CHAIN_ID")  printf 'devnet\n' ;;
    esac
}

# resolve_network -- decide which network this node is on and which RPC it is
# compared with. NETWORK in .node-meta decides. When it is missing or the file
# cannot be read (a run without sudo), a Telcoin chain id from the local RPC
# (LOCAL_CHAIN_ID, probed before the report starts) stands in for it. With
# neither, EXPECTED_CHAIN_ID stays empty and any Telcoin chain id is accepted.
# NETWORK_RPC keeps a --network-rpc value; otherwise it becomes the public RPC of
# that network, or the testnet RPC when the network is unknown.
resolve_network() {
    local meta net chain_dec
    meta="$(node_meta_path 2>/dev/null || true)"
    net=""
    if [[ -n "$meta" && -f "$meta" ]]; then
        if [[ -r "$meta" ]]; then
            net="$(meta_get NETWORK "$meta" 2>/dev/null || true)"
            [[ -n "$net" ]] || NETWORK_NOTE="no NETWORK in .node-meta"
        else
            NETWORK_NOTE=".node-meta not readable (run with sudo)"
        fi
    else
        NETWORK_NOTE="no .node-meta"
    fi
    case "$net" in
        testnet|mainnet|devnet)
            NODE_NETWORK="$net"
            NETWORK_SRC=".node-meta"
            ;;
        "") ;;
        *) NETWORK_NOTE="NETWORK=${net} in .node-meta is not testnet, mainnet or devnet" ;;
    esac
    if [[ -z "$NODE_NETWORK" && -n "$LOCAL_CHAIN_ID" ]]; then
        chain_dec="$(hex_to_dec "$LOCAL_CHAIN_ID")"
        NODE_NETWORK="$(chain_network "$chain_dec")"
        [[ -z "$NODE_NETWORK" ]] || NETWORK_SRC="the local chain id"
    fi
    EXPECTED_CHAIN_ID="$(network_chain_id "$NODE_NETWORK")"
    if [[ -z "$NETWORK_RPC" ]]; then
        NETWORK_RPC="$(network_rpc_url "$NODE_NETWORK")"
        NETWORK_RPC="${NETWORK_RPC:-$TESTNET_RPC_URL}"
    fi
    return 0
}

# resolve_identity -- the node's own identity, from tn_info on the local RPC:
# authority_id (consensus headers carry it as author, in the same base58 form)
# and execution_address (committees list it). --authority-id is the fallback
# when the local node does not answer; the execution address falls back to
# node-info.yaml, then to VALIDATOR_ADDRESS. Earlier versions read
# primary_network_key from node-info.yaml, which is the libp2p key, not the
# authority id, so the header check never matched. Always returns 0.
resolve_identity() {
    local out rc v node_info
    if [[ "$LOCAL_RPC_MODE" == "HEALTHY" || "$LOCAL_RPC_MODE" == "SLOW" ]] \
        && have_fns tn_rpc_call tn_json_field; then
        rc=0
        out="$(tn_rpc_call "$RPC_URL" tn_info '[]' 8)" || rc=$?
        if [[ "$rc" -eq 0 ]]; then
            v="$(tn_json_field "$out" authority_id || true)"
            if [[ "$v" =~ ^[1-9A-HJ-NP-Za-km-z]{20,64}$ ]]; then
                AUTH_ID="$v"
                AUTH_SRC="tn_info on the local node"
            fi
            v="$(tn_json_field "$out" execution_address || true)"
            if [[ "$v" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
                EXEC_ADDR="$(lower "$v")"
                EXEC_SRC="tn_info"
            fi
        fi
    fi
    if [[ -z "$AUTH_ID" && -n "$AUTHORITY_ID" ]]; then
        AUTH_ID="$AUTHORITY_ID"
        AUTH_SRC="--authority-id"
    fi
    if [[ -z "$EXEC_ADDR" ]] && have_fns tn_node_info_field; then
        node_info="$(detect_data_dir)/node-info.yaml"
        v="$(tn_node_info_field "$node_info" execution_address 2>/dev/null || true)"
        if [[ "$v" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
            EXEC_ADDR="$(lower "$v")"
            EXEC_SRC="node-info.yaml"
        fi
    fi
    if [[ -z "$EXEC_ADDR" && "$VALIDATOR_ADDRESS" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
        EXEC_ADDR="$(lower "$VALIDATOR_ADDRESS")"
        EXEC_SRC="$VALIDATOR_ADDRESS_SRC"
    fi
    return 0
}

# fmt_secs <n> -- a non-negative duration as "5h 43m", "4m 10s" or "45s".
fmt_secs() {
    local s="${1:-0}" h m
    [[ "$s" =~ ^[0-9]+$ ]] || s=0
    s=$(( 10#$s ))
    h=$(( s / 3600 ))
    m=$(( (s % 3600) / 60 ))
    s=$(( s % 60 ))
    if (( h > 0 )); then
        echo "${h}h ${m}m"
    elif (( m > 0 )); then
        echo "${m}m ${s}s"
    else
        echo "${s}s"
    fi
}

# utc_time <unix-seconds> -- "YYYY-MM-DD HH:MM:SS UTC". GNU date takes -d @N;
# BSD and macOS date reject -d and take -r N instead.
utc_time() {
    date -u -d "@$1" '+%Y-%m-%d %H:%M:%S UTC' 2>/dev/null \
        || date -u -r "$1" '+%Y-%m-%d %H:%M:%S UTC' 2>/dev/null \
        || echo "?"
}

# df_line <path> -- "<total_kb> <used_kb> <avail_kb> <percent> <mount point>" for
# the filesystem holding <path>, parsed from POSIX `df -Pk` output, which GNU and
# BSD/macOS df both print. The capacity column is found by its % sign, so a
# filesystem name with spaces does not shift the columns. Nothing when df fails.
df_line() {
    df -Pk "$1" 2>/dev/null | awk '
        NR == 1 { next }
        {
            for (i = 5; i <= NF; i++)
                if ($i ~ /^[0-9]+%$/ && $(i-1) ~ /^[0-9]+$/ && $(i-2) ~ /^[0-9]+$/ && $(i-3) ~ /^[0-9]+$/) break
            if (i > NF) next
            m = $(i + 1)
            for (j = i + 2; j <= NF; j++) m = m " " $j
            p = $i; sub(/%$/, "", p)
            print $(i-3), $(i-2), $(i-1), p, m
            exit
        }'
}

# ws_upgrade_status <url> [curl options...] -- the status line a WebSocket
# upgrade request to <url> gets ("HTTP/1.1 101 Switching Protocols"), or an empty
# line when nothing answered. A successful upgrade keeps the connection open, so
# curl runs in the background, writing the response headers to a temp file
# (curl flushes each header line as it arrives); the loop reads the status line
# as soon as it is there (about 0.1 s for a 101), then stops curl. It gives up
# after about 1.5 s. The temp file goes in this run's temp directory, so an
# interrupted probe leaves nothing behind.
ws_upgrade_status() {
    local url="$1" tmp pid i line
    shift
    tmp="$(mktemp "${CN_TMP_DIR:-${TMPDIR:-/tmp}}/check-node.ws.XXXXXX" 2>/dev/null)" || { echo ""; return 0; }
    curl -s --http1.1 --max-time 8 "$@" \
        -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
        -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
        -D "$tmp" -o /dev/null "$url" >/dev/null 2>&1 &
    pid=$!
    i=0
    while (( i < 15 )); do
        line="$(head -n 1 "$tmp" 2>/dev/null)"
        [[ "$line" == *$'\r' ]] && break
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.1
        i=$(( i + 1 ))
    done
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    line="$(head -n 1 "$tmp" 2>/dev/null)"
    rm -f "$tmp"
    echo "${line%$'\r'}"
    return 0
}

# Probe local RPC and classify the mode.
# Echoes "<MODE> [<chain_id_hex>]" on stdout. MODE is one of HEALTHY | SLOW |
# DOWN | DISABLED; the chain_id is present only on HEALTHY (parsed from the
# eth_chainId result we already fetched), empty otherwise. Caller uses
# `read -r MODE CHAIN_ID <<< "$(probe_local_rpc ...)"` to split.
# The response body goes to RPC_BODY_TMP, a file in this run's temp directory
# (see check_node_cleanup), emptied first so a failed call never reads an old
# body. Without it (mktemp -d failed in TMPDIR and /tmp) the body is lost and the
# mode reads DISABLED, as the old fixed /tmp path did when /tmp was not writable.
probe_local_rpc() {
    local url="$1"
    local body
    local http_code
    [[ -z "${RPC_BODY_TMP:-}" ]] || : > "$RPC_BODY_TMP"
    # Use --connect-timeout separate from --max-time so we can distinguish
    # "refused" (down) from "took too long" (slow).
    body=$(curl -sS --connect-timeout 3 --max-time 6 \
        -o "${RPC_BODY_TMP:-/dev/null}" -w "%{http_code}" \
        -X POST -H 'Content-Type: application/json' \
        --data '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' \
        "$url" 2>/dev/null)
    http_code="$body"
    local resp=""
    [[ -n "${RPC_BODY_TMP:-}" && -f "$RPC_BODY_TMP" ]] && resp=$(cat "$RPC_BODY_TMP" 2>/dev/null)

    case "$http_code" in
        "")          echo "DOWN" ;;          # curl failed entirely
        000)         echo "DOWN" ;;          # connection refused / timeout
        200)
            if echo "$resp" | grep -q '"result"'; then
                # Parse the chain ID hex out of "result":"0x...". Empty string
                # if anything goes wrong -- the caller treats absent chain ID
                # as "skip the sanity check".
                local chain_id
                chain_id=$(echo "$resp" | grep -oE '"result"[[:space:]]*:[[:space:]]*"[^"]*"' | \
                    sed -E 's/.*"([^"]*)"$/\1/')
                echo "HEALTHY ${chain_id}"
            elif echo "$resp" | grep -q '"-32601"'; then
                echo "DISABLED"
            else
                echo "DISABLED"
            fi
            ;;
        *)           echo "DOWN" ;;
    esac
}

# check_node_cleanup -- the EXIT trap: remove this run's temp directory
# (CN_TMP_DIR, made by mktemp -d), then run the EXIT trap that was set before
# ours (CN_PREV_EXIT_TRAP), if there was one. Only the trap calls it; the
# directive below tells the linter so.
# shellcheck disable=SC2329
check_node_cleanup() {
    [[ -z "${CN_TMP_DIR:-}" || ! -d "$CN_TMP_DIR" ]] || rm -rf "$CN_TMP_DIR"
    [[ -z "${CN_PREV_EXIT_TRAP:-}" ]] || eval "$CN_PREV_EXIT_TRAP"
}

# Call tn_latestConsensusHeader and parse out the fields we need.
# Sets shell variables when successful:
#   CH_BLOCK, CH_TS, CH_EPOCH, CH_AUTHORS (space-sep), CH_REPS (k=v pairs space-sep)
# Returns 0 on success, 1 on RPC failure, 2 on parse failure.
fetch_consensus_header() {
    local url="$1"
    local timeout="${2:-10}"
    local resp
    resp=$(curl -sS --connect-timeout 5 --max-time "$timeout" \
        -X POST -H 'Content-Type: application/json' \
        --data '{"jsonrpc":"2.0","method":"tn_latestConsensusHeader","params":[],"id":1}' \
        "$url" 2>/dev/null) || return 1

    [[ -z "$resp" ]] && return 1

    # Parse JSON with python3. Outputs shell variable assignments on stdout.
    # Errors go to stderr and are captured into CH_ERROR by the caller.
    # Response is passed via environment so the heredoc can be single-quoted
    # (no quote-escaping required inside the Python script).
    local parsed
    parsed=$(RESP="$resp" python3 <<'PYEOF' 2>&1
import os, json, sys
raw = os.environ.get('RESP', '')
try:
    d = json.loads(raw)
except Exception as e:
    sys.stderr.write('parse_error=' + str(e))
    sys.exit(2)
if isinstance(d, dict) and 'error' in d:
    msg = d.get('error', {}).get('message', 'unknown')
    sys.stderr.write('rpc_error=' + msg)
    sys.exit(3)
r = (d.get('result') if isinstance(d, dict) else None) or {}
sd = r.get('sub_dag') or {}
hdrs = sd.get('headers') or []
reps = (sd.get('reputation_score') or {}).get('scores_per_authority') or {}
block = r.get('number', 0)
ts = sd.get('commit_timestamp', 0)
epoch = hdrs[0].get('epoch', 0) if hdrs else 0
authors = sorted({h.get('author', '') for h in hdrs if h.get('author')})
# Highest execution block referenced by any header in this commit -- gives
# the network's view of the latest EVM block without a second RPC call.
exec_blocks = [
    (h.get('latest_execution_block') or {}).get('number', 0)
    for h in hdrs
]
max_exec = max(exec_blocks) if exec_blocks else 0
print('CH_BLOCK=' + str(block))
print('CH_TS=' + str(ts))
print('CH_EPOCH=' + str(epoch))
print('CH_EXEC_BLOCK=' + str(max_exec))
print('CH_AUTHORS="' + ' '.join(authors) + '"')
print('CH_REPS="' + ' '.join(k + '=' + str(v) for k, v in sorted(reps.items())) + '"')
PYEOF
)
    local rc=$?
    if [[ $rc -ne 0 ]]; then
        # parsed contains the error message; expose via global for caller
        CH_ERROR="$parsed"
        return 2
    fi
    eval "$parsed"
    return 0
}

# Render a human-readable "X ago" string from elapsed seconds.
fmt_age() {
    local s="$1"
    if (( s < 0 ));      then echo "in the future (${s}s -- clock skew?)"
    elif (( s < 60 ));   then echo "${s}s ago"
    elif (( s < 3600 )); then echo "$(( s / 60 ))m ago"
    else                       echo "$(( s / 3600 ))h ago"
    fi
}

# Convert a JSON-RPC hex string ("0x1234") to decimal. Echoes 0 on error.
hex_to_dec() {
    local h="${1:-0x0}"
    h="${h#0x}"
    [[ -z "$h" ]] && { echo 0; return; }
    [[ "$h" =~ ^[0-9a-fA-F]+$ ]] || { echo 0; return; }
    printf '%d\n' "0x${h}" 2>/dev/null || echo 0
}

# Call eth_blockNumber on the given RPC URL (local OR network). Echoes the
# decoded decimal block number on success, or empty string on failure.
# Caller uses exit code: 0 = ok (value echoed), 1 = failure (empty).
# Side-effect-free: returns the value via stdout so it works in command
# substitution (a side-effect via global would not propagate out of $( )).
fetch_exec_block() {
    local url="$1"
    local resp
    resp=$(curl -sS --connect-timeout 3 --max-time 6 \
        -X POST -H 'Content-Type: application/json' \
        --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
        "$url" 2>/dev/null) || { echo ""; return 1; }
    local hex
    hex=$(echo "$resp" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    r = d.get("result")
    print(r if isinstance(r, str) else "")
except Exception:
    print("")
' 2>/dev/null)
    if [[ -z "$hex" ]]; then
        echo ""
        return 1
    fi
    hex_to_dec "$hex"
    return 0
}

# fetch_node_mode <url> -- print the node's consensus role from tn_nodeMode:
# CvvActive (voting in the current committee), CvvInactive (in the committee but
# catching up) or Observer (following consensus, not in the committee). The role
# is decided on-chain each epoch, so this is the live answer, not a setting.
# The answer is kept in LOCAL_NODE_MODE for §5.5 and §6. Best-effort: a failed
# call, a JSON-RPC error (older binaries lack the method) or any other result
# prints nothing. Always returns 0.
fetch_node_mode() {
    local url="$1" resp mode re
    if have_fns tn_node_mode; then
        mode="$(tn_node_mode "$url" 2>/dev/null)" || return 0
    else
        re='"result"[[:space:]]*:[[:space:]]*"([A-Za-z]+)"'
        resp=$(curl -s --max-time 5 -X POST -H 'Content-Type: application/json' \
            --data '{"jsonrpc":"2.0","method":"tn_nodeMode","params":[],"id":1}' \
            "$url" 2>/dev/null) || return 0
        [[ "$resp" =~ $re ]] || return 0
        mode="${BASH_REMATCH[1]}"
    fi
    case "$mode" in
        CvvActive|CvvInactive|Observer) LOCAL_NODE_MODE="$mode" ;;
    esac
    case "$mode" in
        CvvActive)   print_info "Consensus role: CvvActive (voting in the current committee)" ;;
        CvvInactive) print_info "Consensus role: CvvInactive (in the committee, catching up)" ;;
        Observer)    print_info "Consensus role: Observer (following consensus; not in the current committee)" ;;
    esac
    return 0
}

# report_legacy_observer_flag -- warn when the node launch file (start wrapper, or
# the unit of a legacy docker install) still passes --observer. v0.15.0-adiri
# ignores the flag, but later releases reject it, so the node would not start
# after a binary/image update. Warn-only: never touches HEALTH_ISSUES, and silent
# when there is no node or the launch file is missing or unreadable (e.g. run
# without sudo).
report_legacy_observer_flag() {
    local target svc file
    target="$(tn_node_launch_target 2>/dev/null)" || return 0
    read -r svc _ file <<<"$target"
    [[ -n "$file" && -r "$file" ]] || return 0
    tn_node_has_observer_flag "$file" || return 0
    print_warn "Launch file ${file} still passes --observer; releases after v0.15.0-adiri reject it and the node will not start after an update."
    print_info "Fix: bash ${SCRIPT_DIR}/update-scripts.sh && sudo bash ${SCRIPT_DIR}/update-node.sh (strips the flag),"
    print_info "     or delete the --observer token from ${file} and restart ${svc}."
    return 0
}

# report_node_config -- what the node launch file and node-info.yaml say about
# this node: the docker image or binary the launch file runs, the bootstrap
# peers and state export flags when set, the P2P ports and the RPC endpoint
# advertised to the network. Info only; each line is left out when its source
# cannot be read (no node, a run without sudo, or an older lib/common.sh).
report_node_config() {
    local target file runner v keep node_info primary ports p n line adv
    file=""
    if have_fns tn_launch_runner tn_launch_flag_get \
        && target="$(tn_node_launch_target 2>/dev/null)"; then
        read -r _ _ file <<<"$target"
    fi
    if [[ -n "$file" && -r "$file" ]]; then
        if runner="$(tn_launch_runner "$file" 2>/dev/null)"; then
            case "$runner" in
                docker:*) print_info "Runs:             docker image ${runner#docker:}" ;;
                binary:*) print_info "Runs:             binary ${runner#binary:}" ;;
            esac
        fi
        if v="$(tn_launch_flag_get "$file" --bootstrap-peers 2>/dev/null)"; then
            (( ${#v} <= 80 )) || v="${v:0:77}..."
            print_info "Bootstrap peers:  ${v:-set (no value)}"
        fi
        if tn_launch_flag_get "$file" --enable-state-export >/dev/null 2>&1; then
            keep="$(tn_launch_flag_get "$file" --state-export-keep 2>/dev/null || true)"
            if [[ -n "$keep" ]]; then
                print_info "State export:     on, keeps the last ${keep} epochs"
            else
                print_info "State export:     on, keeps every epoch"
            fi
        fi
    fi
    node_info="$(detect_data_dir)/node-info.yaml"
    [[ -r "$node_info" ]] || return 0
    if have_fns tn_node_info_field tn_node_info_worker_ports; then
        primary="$(tn_node_info_field "$node_info" primary_port 2>/dev/null || true)"
        ports="$(tn_node_info_worker_ports "$node_info" 2>/dev/null || true)"
        line="${primary:+primary ${primary}}"
        n=0
        for p in $ports; do
            line="${line:+${line}, }worker ${n} ${p}"
            n=$(( n + 1 ))
        done
        [[ -z "$line" ]] || print_info "P2P ports (UDP):  ${line}"
    fi
    adv="$(advertised_rpc "$node_info")"
    print_info "Advertised RPC:   http=${adv%% *} ws=${adv#* }"
    return 0
}

# Cross-run state file for tracking whether the local execution block is
# actually advancing between checks. One file per host (check-node.state).
# Format: "<local_evm> <unix_ts> <consensus_height> <network_evm>". Trailing
# fields default to empty when absent (so an older two-field state file from
# v1.1.48 still reads cleanly). Write failures are tolerated.
state_file_path() {
    echo "${TMPDIR:-/tmp}/check-node.state"
}

read_prev_block_state() {
    local f
    f=$(state_file_path)
    # Always return 0 -- "no state file yet" is normal, not an error. (Returning
    # non-zero here previously tripped the inherited set -e and aborted the run.)
    if [[ -f "$f" ]]; then
        cat "$f" 2>/dev/null
    fi
    return 0
}

write_block_state() {
    local block="$1" ts="$2" cons_height="${3:-}" net_evm="${4:-}" f
    f=$(state_file_path)
    echo "${block} ${ts} ${cons_height} ${net_evm}" > "$f" 2>/dev/null || true
}

# Note: an earlier `fetch_local_sync_state` (eth_syncing) helper was removed
# in v1.1.47. On Telcoin, eth_syncing stays `false` during consensus-layer
# backfill, so it can't be trusted as a sync guarantee; and when it does
# report "syncing" it added no signal beyond what EVM_LAG already shows
# (and could spuriously flip the global CATCHING_UP flag with a small lag).
# The EVM-lag + block-advancement signals together cover the same question.

# Resolve the node's log file path. The setup scripts write the systemd unit
# with `StandardOutput=append:${LOG_DIR}/${SERVICE_NAME}.log`, where LOG_DIR
# defaults to /var/log/telcoin but is operator-configurable. Try the default
# first, then parse the unit. Echoes the path or empty string; always returns 0
# (so use the echo to drive control flow, not the exit code).
locate_node_log() {
    local default="/var/log/telcoin/${SERVICE_NAME}.log"
    if [[ -r "$default" ]]; then echo "$default"; return 0; fi
    local unit="/etc/systemd/system/${SERVICE_NAME}.service"
    if [[ -f "$unit" ]]; then
        local path
        path=$(grep -oE '^StandardOutput=append:[^[:space:]]+' "$unit" 2>/dev/null | head -1 | cut -d: -f2-)
        if [[ -n "$path" ]] && [[ -r "$path" ]]; then echo "$path"; return 0; fi
    fi
    echo ""
    return 0
}

# Read the most recent state-sync progress signal from the node log.
#
# State-sync emits a recurring warning every ~60s when the node is still
# catching up to the consensus tip:
#
#   level=warn target=state-sync message="could not catch up to consensus
#   target after retries, waiting for next gossip update"
#   epoch=N last_consensus_height=H target=T
#
# The `epoch=N` field is the *target's* epoch (it advances as the network
# advances) -- it is NOT a "missing pack" indicator, despite an earlier
# misreading. We deliberately do not surface it here; the height/target/age
# fields are the actionable data and they speak for themselves.
#
# On hit, sets SS_HEIGHT / SS_TARGET / SS_AGE_S and returns 0. Only fires
# when the most recent warning is within 120 seconds (two emit intervals +
# slack), so a node that has since caught up won't trigger.
read_sync_progress() {
    local log
    log=$(locate_node_log)
    [[ -z "$log" ]] && return 1
    local recent
    recent=$(tail -c 200000 "$log" 2>/dev/null | \
        grep -F "could not catch up to consensus target" | \
        tail -1)
    [[ -z "$recent" ]] && return 1
    SS_HEIGHT=$(echo "$recent" | grep -oE 'last_consensus_height=[0-9]+' | cut -d= -f2)
    SS_TARGET=$(echo "$recent" | grep -oE 'target=[0-9]+' | cut -d= -f2)
    [[ -z "$SS_HEIGHT" ]] && return 1
    local ts_iso
    ts_iso=$(echo "$recent" | grep -oE '^ts=[^ ]+' | cut -d= -f2)
    if [[ -n "$ts_iso" ]]; then
        local ts_epoch now
        ts_epoch=$(date -d "$ts_iso" +%s 2>/dev/null || echo 0)
        now=$(date +%s)
        SS_AGE_S=$(( now - ts_epoch ))
        (( SS_AGE_S > 120 )) && return 1
    else
        SS_AGE_S="?"
    fi
    return 0
}

# report_testnet_addons -- supplementary status for the opt-in add-ons (only on a
# testnet node). -e-safe: every probe is guarded.
report_testnet_addons() {
    local meta net
    meta="$(node_meta_path 2>/dev/null || true)"
    [[ -n "$meta" ]] || return 0
    net="$(meta_get NETWORK "$meta" 2>/dev/null || true)"
    [[ "$net" == "testnet" ]] || return 0

    echo ""
    print_step "Checking testnet add-ons..."

    # Centralized logging (Alloy) -- reuse the shared status helper if present.
    if declare -F obs_status >/dev/null 2>&1; then
        obs_status || true
    fi

    # Health-monitor endpoint.
    local hc
    hc="$(meta_get ENABLE_HEALTHCHECK_MONITOR "$meta" 2>/dev/null || echo false)"
    if [[ "$hc" == "true" ]]; then
        if curl -fsS "http://127.0.0.1:${TN_KUMA_PORT}" >/dev/null 2>&1; then
            print_ok "Health endpoint responds on 127.0.0.1:${TN_KUMA_PORT}"
        else
            print_warn "Health endpoint not responding on 127.0.0.1:${TN_KUMA_PORT} (node down, or flag not yet applied)"
        fi
    fi

    # WireGuard admin overlay.
    local vpn
    vpn="$(meta_get ENABLE_VPN "$meta" 2>/dev/null || echo false)"
    if [[ "$vpn" == "true" || "$vpn" == "pending" ]]; then
        if ip link show wg0 >/dev/null 2>&1; then
            if command -v wg >/dev/null 2>&1 && wg show wg0 2>/dev/null | grep -qE 'latest handshake'; then
                print_ok "VPN overlay wg0 up, hub handshake present"
            else
                print_warn "VPN overlay wg0 up but no hub handshake yet (overlay enrollment pending?)"
            fi
        else
            print_warn "VPN recorded as '${vpn}' in .node-meta but wg0 is not up -- run setup-vpn.sh"
        fi
    fi
}

# read_advertised_rpc <node-info.yaml> -- echo "<http> <ws>": the worker RPC
# endpoint advertised in node-info.yaml (p2p_info -> worker 0 -> rpc -> http/ws),
# "none" for a field that is absent or null. Plain awk text parsing (no
# python3/PyYAML needed). Handles both on-disk shapes:
# the current `workers:` list (first entry = worker 0) and the legacy single
# `worker:` mapping; primary.rpc is never read. Always returns 0 ("none none"
# when the file is missing or unparsable).
read_advertised_rpc() {
    local node_info="$1" parsed="" http="none" ws="none"
    if [[ -r "$node_info" ]]; then
        parsed=$(awk -v q="'" '
            function ind(s) { match(s, /^ */); return RLENGTH }
            function val(s,   c) {
                sub(/^[^:]*:[ \t]*/, "", s); sub(/[ \t]+#.*$/, "", s); sub(/[ \t]+$/, "", s)
                c = substr(s, 1, 1)
                if ((c == "\"" || c == q) && length(s) >= 2 && substr(s, length(s), 1) == c)
                    s = substr(s, 2, length(s) - 2)
                if (s == "~" || s == "null" || s == "Null" || s == "NULL") s = ""
                return s
            }
            BEGIN { st = 0; items = 0; h = ""; w = "" }
            {
                sub(/\r$/, "")
                if ($0 ~ /^[ \t]*(#|$)/) next
                i = ind($0); s = substr($0, i + 1)
                if (st == 0) { if (i == 0 && s ~ /^p2p_info:/) st = 1; next }
                if (st == 1) {
                    if (i == 0) exit
                    if (s ~ /^workers?:/) { wi = i; st = 2 }
                    next
                }
                # Inside worker(s): stop at the next sibling of worker(s)/p2p_info.
                if (i < wi || (i == wi && s !~ /^- /)) exit
                if (s ~ /^- /) {                    # sequence item = one worker
                    if (++items > 1) exit           # worker 0 only
                    s = substr(s, 3); i += 2
                    while (substr(s, 1, 1) == " ") { s = substr(s, 2); i++ }
                }
                if (st == 3 && i <= ri) st = 2      # left the rpc: mapping
                if (st == 3) {
                    if (s ~ /^http:/) h = val(s)
                    else if (s ~ /^ws:/) w = val(s)
                    next
                }
                if (s ~ /^rpc:/) {
                    ri = i; v = val(s)
                    if (v == "") { st = 3; next }
                    if (v ~ /^[{]/) {               # flow style {http: X, ws: Y}
                        gsub(/^[{][ \t]*|[ \t]*[}]$/, "", v)
                        n = split(v, kv, /,[ \t]*/)
                        for (k = 1; k <= n; k++) {
                            if (kv[k] ~ /^http:/) h = val(kv[k])
                            else if (kv[k] ~ /^ws:/) w = val(kv[k])
                        }
                    }
                }
            }
            END { print (h == "" ? "none" : h) " " (w == "" ? "none" : w) }
        ' "$node_info" 2>/dev/null || true)
    fi
    [[ -n "$parsed" ]] && read -r http ws <<<"$parsed"
    echo "${http:-none} ${ws:-none}"
    return 0
}

# advertised_rpc <node-info.yaml> -- "<http> <ws>" that worker 0 advertises,
# "none" for a field that is not set. Uses tn_node_info_rpc from lib/common.sh;
# read_advertised_rpc above stays as the fallback for an older library and for
# a flow-style rpc map, which the library reader does not parse.
advertised_rpc() {
    local out
    if have_fns tn_node_info_rpc && out="$(tn_node_info_rpc "$1" 2>/dev/null)" && [[ -n "$out" ]]; then
        echo "$out"
        return 0
    fi
    read_advertised_rpc "$1"
}

# rpc_block_check <caddyfile> -- is the Caddy tn-rpc block older than block v2
# (case-insensitive WebSocket match, 2 MB request cap, browser page)? Sets
# RPC_BLOCK_STALE to true, false or "" (unknown) and RPC_BLOCK_OLD_TOOL to true
# when install-caddy.sh is too old to write block v2. install-caddy.sh decides
# first (rpc-status JSON, "block_stale"), so the rule lives in one place. When
# that script is missing, fails, reports a different Caddyfile or predates the
# key, the block itself is searched for the "tn-rpc block v2" stamp that
# install-caddy.sh 1.4.0 and later write.
RPC_BLOCK_STALE=""
RPC_BLOCK_OLD_TOOL=false
rpc_block_check() {
    local caddyfile="$1" tool="${SCRIPT_DIR}/install-caddy.sh" json=""
    RPC_BLOCK_STALE=""
    RPC_BLOCK_OLD_TOOL=false
    if [[ -r "$tool" ]]; then
        if command -v timeout >/dev/null 2>&1; then
            json="$(timeout 20 bash "$tool" --json --phase=rpc-status 2>/dev/null | tail -n 1)"
        else
            json="$(bash "$tool" --json --phase=rpc-status 2>/dev/null | tail -n 1)"
        fi
    fi
    json="${json// /}"
    case "$json" in
        *'"enabled":true'*'"block_stale":true'*|*'"block_stale":true'*'"enabled":true'*)
            RPC_BLOCK_STALE=true; return 0 ;;
        *'"enabled":true'*'"block_stale":false'*|*'"block_stale":false'*'"enabled":true'*)
            RPC_BLOCK_STALE=false; return 0 ;;
        *'"enabled":true'*)
            RPC_BLOCK_OLD_TOOL=true ;;
    esac
    [[ -r "$caddyfile" ]] || return 0
    if awk -v b="# >>> tn-rpc >>>" -v e="# <<< tn-rpc <<<" '
        $0 == b { inb = 1; next }
        $0 == e { inb = 0; next }
        inb && index($0, "tn-rpc block v2") { found = 1 }
        END { exit !found }' "$caddyfile" 2>/dev/null; then
        RPC_BLOCK_STALE=false
    else
        RPC_BLOCK_STALE=true
    fi
    return 0
}

# risky_api_modules <launch-file> <flag> -- print the namespaces among debug,
# trace, admin and all that <flag> (--http.api or --ws.api) names on the node
# command, comma-separated; rc 1 when there are none or the flag is absent.
risky_api_modules() {
    local v m out=""
    v="$(tn_launch_flag_get "$1" "$2" 2>/dev/null)" || return 1
    v=",$(lower "$v" | tr ' ' ','),"
    for m in debug trace admin all; do
        case "$v" in
            *",${m},"*) out="${out:+${out}, }${m}" ;;
        esac
    done
    [[ -n "$out" ]] || return 1
    echo "$out"
}

# report_public_rpc -- status of the operator's public RPC endpoint (Caddy vhost
# "tn-rpc" written by install-caddy.sh, hostname persisted by setup-node.sh as
# PUBLIC_RPC_DOMAIN in .node-meta). Probes https + wss through Caddy on loopback
# (--resolve, real certificate) and compares worker.rpc in node-info.yaml with the
# served hostname. Warn-only: never touches HEALTH_ISSUES and every probe is
# guarded, so it cannot change the exit code or abort the report.
report_public_rpc() {
    local caddyfile="${TN_ROOT_PREFIX:-}/etc/caddy/Caddyfile"
    local rpc_begin="# >>> tn-rpc >>>" rpc_end="# <<< tn-rpc <<<"
    local meta domain="" caddy_domain="" have_block=false src=""
    meta="$(node_meta_path 2>/dev/null || true)"
    # .node-meta is root-owned 0600: without sudo it exists but cannot be read, so
    # an empty PUBLIC_RPC_DOMAIN would be a false "private node". Say so instead.
    if [[ -n "$meta" && -f "$meta" && ! -r "$meta" ]]; then
        print_info "public RPC: unknown (.node-meta not readable — run with sudo)"
        return 0
    fi
    domain="$(meta_get PUBLIC_RPC_DOMAIN "$meta" 2>/dev/null || true)"
    if [[ -f "$caddyfile" ]] && grep -qF "$rpc_begin" "$caddyfile" 2>/dev/null; then
        have_block=true
        # Site address = first "<host> {" line inside the fenced block (same rule
        # as install-caddy.sh do_rpc_status).
        caddy_domain=$(awk -v b="$rpc_begin" -v e="$rpc_end" '
            $0 == b { inb = 1; next }
            $0 == e { inb = 0; next }
            inb && /^[A-Za-z0-9].*[{][ \t]*$/ { sub(/[ \t]*[{].*$/, ""); gsub(/ /, ""); print; exit }
        ' "$caddyfile" 2>/dev/null || true)
    fi

    if [[ -z "$domain" && "$have_block" != "true" ]]; then
        print_info "public RPC: not configured (private node)"
        return 0
    fi

    print_step "Checking public RPC..."
    local fix_cmd="sudo bash ${SCRIPT_DIR}/install-caddy.sh --phase=rpc-enable --rpc-domain"
    if [[ -n "$domain" ]]; then
        src=".node-meta"
    else
        domain="$caddy_domain"; src="Caddyfile tn-rpc block; PUBLIC_RPC_DOMAIN not set in .node-meta"
    fi
    if [[ -z "$domain" ]]; then
        print_warn "public RPC: WARN -- tn-rpc block in ${caddyfile} has no parsable site address"
        print_info "fix: ${fix_cmd} <your-rpc-hostname>"
        return 0
    fi
    print_info "public RPC: ${domain} (from ${src})"

    local issues=""
    if [[ "$have_block" != "true" ]]; then
        issues="${issues}; no tn-rpc vhost in ${caddyfile}"
    elif [[ -n "$caddy_domain" && "$caddy_domain" != "$domain" ]]; then
        issues="${issues}; Caddyfile tn-rpc vhost serves ${caddy_domain}, not ${domain}"
    fi

    # Caddy service.
    local caddy_state="not installed"
    if command -v caddy >/dev/null 2>&1; then
        if systemctl is-active --quiet caddy 2>/dev/null; then caddy_state="active"; else caddy_state="inactive"; fi
    fi
    print_info "caddy: ${caddy_state}"
    [[ "$caddy_state" == "active" ]] || issues="${issues}; caddy ${caddy_state}"

    # HTTPS JSON-RPC through Caddy on loopback, real certificate (no -k).
    local body="" https_ok=false
    body=$(curl -s --max-time 8 --resolve "${domain}:443:127.0.0.1" \
        -X POST -H 'Content-Type: application/json' \
        --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
        "https://${domain}/" 2>/dev/null || true)
    [[ "$body" == *'"result"'* ]] && https_ok=true
    if [[ "$https_ok" == "true" ]]; then
        print_info "https: ok"
    else
        print_info "https: FAIL"
        issues="${issues}; https probe failed"
    fi

    # RFC-6455 WebSocket handshake through Caddy, judged by the status line (a
    # successful upgrade leaves the connection open; ws_upgrade_status stops curl
    # as soon as the line arrives).
    local ws_status="" wss_ok=false
    ws_status="$(ws_upgrade_status "https://${domain}/" --resolve "${domain}:443:127.0.0.1")"
    [[ "$ws_status" =~ ^HTTP/[0-9.]+\ 101 ]] && wss_ok=true
    if [[ "$wss_ok" == "true" ]]; then
        print_info "wss: ok (101)"
    else
        print_info "wss: FAIL (${ws_status:-no response})"
        issues="${issues}; wss handshake failed"
    fi

    # reth WebSocket listener behind the wss route.
    local ws_port ws_listen="unknown (ss not found)"
    ws_port="$(meta_get WS_PORT "$meta" 2>/dev/null || true)"
    [[ "$ws_port" =~ ^[0-9]+$ ]] || ws_port=8546
    if command -v ss >/dev/null 2>&1; then
        if ss -ltn 2>/dev/null | awk -v p=":${ws_port}" '
            NR > 1 && length($4) >= length(p) && substr($4, length($4) - length(p) + 1) == p { f = 1 }
            END { exit !f }'; then
            ws_listen="listening"
        else
            ws_listen="not listening"
            issues="${issues}; WS port ${ws_port} not listening (node started without --ws?)"
        fi
    fi
    print_info "ws port: ${ws_port} ${ws_listen}"

    # On-network advertisement (worker.rpc in node-info.yaml).
    local node_info adv adv_http adv_ws want_http want_ws
    node_info="$(detect_data_dir)/node-info.yaml"
    adv="$(advertised_rpc "$node_info")"
    read -r adv_http adv_ws <<<"$adv"
    want_http="https://${domain}/"; want_ws="wss://${domain}/"
    if [[ -f "$node_info" ]]; then
        print_info "advertised: http=${adv_http} ws=${adv_ws}"
    else
        print_info "advertised: http=${adv_http} ws=${adv_ws} (${node_info} not found)"
    fi
    [[ "$adv_http" == "$want_http" ]] || issues="${issues}; advertised http=${adv_http}, want ${want_http}"
    [[ "$adv_ws" == "$want_ws" ]]     || issues="${issues}; advertised ws=${adv_ws}, want ${want_ws}"

    # Verdict: OK needs https + wss + both advertised URLs matching; the other
    # findings above are listed to explain a WARN.
    if [[ "$https_ok" == "true" && "$wss_ok" == "true" \
          && "$adv_http" == "$want_http" && "$adv_ws" == "$want_ws" ]]; then
        print_ok "public RPC: OK"
    else
        print_warn "public RPC: WARN -- ${issues#; }"
        print_info "fix: ${fix_cmd} ${domain}"
    fi

    # Caddy block written before block v2: running rpc-enable again with the same
    # hostname rewrites it, which needs install-caddy.sh 1.4.0 or later.
    if [[ "$have_block" == "true" ]]; then
        rpc_block_check "$caddyfile"
        if [[ "$RPC_BLOCK_STALE" == "true" ]]; then
            print_warn "public RPC: the Caddy tn-rpc block predates block v2 (WebSocket upgrades from proxies that send 'Connection: upgrade' get 405; no 2 MB request cap)"
            if [[ "$RPC_BLOCK_OLD_TOOL" == "true" ]]; then
                print_info "refresh: bash ${SCRIPT_DIR}/update-scripts.sh, then ${fix_cmd} ${domain}"
            else
                print_info "refresh: ${fix_cmd} ${domain} (same hostname; rewrites the block and reloads Caddy)"
            fi
        fi
    fi

    # Namespaces a public endpoint should not serve: Caddy forwards every method
    # the node serves on --http / --ws to anyone who reaches the hostname.
    local target svc file flag mods
    if have_fns tn_launch_flag_get && target="$(tn_node_launch_target 2>/dev/null)"; then
        read -r svc _ file <<<"$target"
        if [[ -n "$file" && -r "$file" ]]; then
            for flag in --http.api --ws.api; do
                mods="$(risky_api_modules "$file" "$flag")" || continue
                print_warn "public RPC: ${flag} on the node command names ${mods}; Caddy serves those methods to anyone who reaches ${domain}"
                print_info "fix: remove ${mods} from ${flag} in ${file}, then restart ${svc}"
            done
        fi
    fi
    return 0
}

# check_network_chain -- read the network RPC's own eth_chainId (§3). When it is
# not the chain this node's network uses, the endpoint is the wrong yardstick
# (today https://rpc.telcoin.network, the planned mainnet RPC, still serves the
# Adiri testnet, chain 2017): warn, set NETWORK_WRONG_CHAIN and let §3 skip the
# comparison instead of blaming the node. Says nothing when the chain id cannot
# be read; the consensus probe that follows reports an endpoint that is down.
check_network_chain() {
    local out rc hex net
    [[ -n "$EXPECTED_CHAIN_ID" ]] || return 0
    have_fns tn_rpc_call tn_json_field || return 0
    rc=0
    out="$(tn_rpc_call "$NETWORK_RPC" eth_chainId '[]' 10)" || rc=$?
    [[ "$rc" -eq 0 ]] || return 0
    hex="$(tn_json_field "$out" result)" || return 0
    NET_CHAIN_DEC="$(hex_to_dec "$hex")"
    if [[ ! "$NET_CHAIN_DEC" =~ ^[1-9][0-9]*$ ]]; then
        NET_CHAIN_DEC=""
        return 0
    fi
    [[ "$NET_CHAIN_DEC" != "$EXPECTED_CHAIN_ID" ]] || return 0
    NETWORK_WRONG_CHAIN=true
    net="$(chain_network "$NET_CHAIN_DEC")"
    print_warn "${NETWORK_RPC} serves chain ${NET_CHAIN_DEC}${net:+ (${net})}, not chain ${EXPECTED_CHAIN_ID} (${NODE_NETWORK}) -- skipping the network comparison"
    print_info "Pass --network-rpc <URL> with an RPC for chain ${EXPECTED_CHAIN_ID} to compare this node with its network."
    return 0
}

# stake_label <status> -- a short name for a node_stake_status first field.
stake_label() {
    case "$1" in
        none) echo "no validator record" ;;
        0) echo "Undefined" ;;
        1) echo "Staked" ;;
        2) echo "Pending Activation" ;;
        3) echo "Active" ;;
        4) echo "Pending Exit" ;;
        5) echo "Exited" ;;
        6) echo "Retired" ;;
        *) echo "status $1" ;;
    esac
}

# epochs_away <n> -- "next epoch" for 1, "in N epochs" above that, "reached" at 0 or below.
epochs_away() {
    if (( $1 <= 0 )); then
        echo "reached"
    elif (( $1 == 1 )); then
        echo "next epoch"
    else
        echo "in $1 epochs"
    fi
}

# probe_worker_rpcs <count> -- probe the JSON-RPC of workers 1 .. count-1 with
# eth_chainId, and their WebSocket ports with an upgrade request. Worker N
# serves HTTP on the node's RPC port minus 200*N and WebSocket on its WS port
# plus 400*N. WebSocket ports are probed only when worker 0 answers an upgrade,
# so a node started without --ws stays quiet. Warn-only.
probe_worker_rpcs() {
    local count="$1" re base port ws_port ws0 n hp wp out rc st
    re='^(https?://[^/]+):([0-9]+)/?$'
    [[ "$RPC_URL" =~ $re ]] || return 0
    base="${BASH_REMATCH[1]}"
    port="${BASH_REMATCH[2]}"
    ws_port="$(meta_get WS_PORT 2>/dev/null || true)"
    [[ "$ws_port" =~ ^[0-9]+$ ]] || ws_port=8546
    ws0="$(ws_upgrade_status "${base}:${ws_port}/")"
    n=1
    while (( n < count )); do
        hp=$(( port - 200 * n ))
        wp=$(( ws_port + 400 * n ))
        rc=0
        out="$(tn_rpc_call "${base}:${hp}" eth_chainId '[]' 4)" || rc=$?
        if [[ "$rc" -eq 0 ]]; then
            print_info "Worker ${n} RPC ${base}:${hp}: answers"
        else
            print_warn "Worker ${n} RPC ${base}:${hp}: no answer (${out})"
        fi
        if [[ "$ws0" =~ ^HTTP/[0-9.]+\ 101 ]]; then
            st="$(ws_upgrade_status "${base}:${wp}/")"
            if [[ "$st" =~ ^HTTP/[0-9.]+\ 101 ]]; then
                print_info "Worker ${n} WebSocket ${base}:${wp}: answers"
            else
                print_warn "Worker ${n} WebSocket ${base}:${wp}: no upgrade (${st:-no response})"
            fi
        fi
        n=$(( n + 1 ))
    done
    return 0
}

# report_worker_count <rpc-url> <source> -- compare WorkerConfigs.numWorkers(),
# the number of workers every committee member must run, with the workers in
# node-info.yaml. More required than configured is a health issue. Says nothing
# when either count cannot be read. With more than one local worker it also
# probes the extra workers' RPC ports.
report_worker_count() {
    local url="$1" src="$2" node_info ports local_n out rc hex need re
    have_fns tn_node_info_worker_ports tn_rpc_call tn_json_field || return 0
    node_info="$(detect_data_dir)/node-info.yaml"
    ports="$(tn_node_info_worker_ports "$node_info" 2>/dev/null)" || return 0
    local_n="$(printf '%s\n' "$ports" | grep -c '[0-9]')"
    [[ "$local_n" =~ ^[0-9]+$ ]] || return 0
    rc=0
    out="$(tn_rpc_call "$url" eth_call "[{\"to\":\"${WORKER_CONFIGS}\",\"data\":\"${NUM_WORKERS_SELECTOR}\"},\"latest\"]" 10)" || rc=$?
    if [[ "$rc" -eq 0 ]]; then
        hex="$(tn_json_field "$out" result || true)"
        re='^0x0{56}([0-9a-fA-F]{8})$'
        if [[ "$hex" =~ $re ]]; then
            need=$(( 16#${BASH_REMATCH[1]} ))
            if (( need > local_n )); then
                print_error "Workers: the network requires ${need} per node (WorkerConfigs.numWorkers(), ${src}) but node-info.yaml lists ${local_n}"
                print_info "  The node cannot join a committee that expects ${need} workers."
                (( ++HEALTH_ISSUES ))
            else
                print_info "Workers: ${local_n} configured, ${need} required on-chain"
            fi
        fi
    fi
    if (( local_n > 1 )); then
        probe_worker_rpcs "$local_n"
    fi
    return 0
}

# network_gap_reason -- why the network RPC is not being used this run.
network_gap_reason() {
    if [[ "$QUERY_NETWORK" != "true" ]]; then
        echo "--no-network"
    elif [[ "$NETWORK_WRONG_CHAIN" == "true" ]]; then
        echo "the network RPC serves another chain"
    else
        echo "the network RPC is unavailable"
    fi
}

# report_epoch_committee -- §5.5: the current epoch and when it ends, this node's
# committee membership for the current and the next two epochs (nodes answer
# tn_getEpochInfo up to current+2), a staked validator's activation epoch and
# earliest committee seat (activationEpoch + 2), and the worker count. Reads
# through the network RPC when it is usable, else through the local node
# (labelled; its view lags while it catches up). Only a committee read through
# the network RPC sets IN_COMMITTEE, which §6 relies on.
report_epoch_committee() {
    local url src info rc e committee line secs boundary d m st act seat
    if [[ "$NETWORK_OK" == "true" ]]; then
        url="$NETWORK_RPC"
        src="network"
    elif [[ "$LOCAL_RPC_MODE" == "HEALTHY" || "$LOCAL_RPC_MODE" == "SLOW" ]]; then
        url="$RPC_URL"
        src="local node"
        COMMITTEE_WHY="$(network_gap_reason)"
    else
        COMMITTEE_WHY="no RPC answered"
        return 0
    fi
    print_step "Checking epoch and committee..."
    if ! have_fns tn_epoch_info tn_epoch_secs_left tn_rpc_call tn_json_field; then
        print_info "Skipped: this check needs lib/common.sh 1.6.0 (run update-scripts.sh)."
        COMMITTEE_WHY="lib/common.sh is older than 1.6.0"
        return 0
    fi

    rc=0
    info="$(tn_epoch_info "$url")" || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        print_warn "Could not read the current epoch from the ${src} RPC (${info})"
        [[ "$src" != "network" ]] || COMMITTEE_WHY="tn_getCurrentEpochInfo failed: ${info}"
        report_worker_count "$url" "$src"
        return 0
    fi
    read -r e _ _ _ committee <<<"$info"
    EPOCH_E="$e"

    # Time to the boundary: timestamp of the epoch's parent block + duration.
    rc=0
    line="$(tn_epoch_secs_left "$url")" || rc=$?
    if [[ "$rc" -eq 0 ]]; then
        read -r secs _ boundary _ <<<"$line"
        if (( secs > 0 )); then
            print_info "Epoch ${e} (${src}): next boundary in $(fmt_secs "$secs"), at $(utc_time "$boundary")"
        else
            print_info "Epoch ${e} (${src}): the boundary passed $(fmt_secs $(( -secs ))) ago, at $(utc_time "$boundary"); the epoch closes at the next commit"
        fi
    else
        print_info "Epoch ${e} (${src}): end time not available (${line})"
    fi

    # Membership of E, E+1 and E+2, by execution address (lists are lowercase).
    if [[ -z "$EXEC_ADDR" ]]; then
        print_info "Committee membership not checked: execution address unknown"
        [[ "$src" != "network" ]] || COMMITTEE_WHY="the execution address is unknown"
    else
        if [[ ",${committee}," == *",${EXEC_ADDR},"* ]]; then
            m="member"
        else
            m="not a member"
        fi
        if [[ "$src" == "network" ]]; then
            if [[ "$m" == "member" ]]; then IN_COMMITTEE=yes; else IN_COMMITTEE=no; fi
        fi
        line="epoch ${e}: ${m}"
        for d in 1 2; do
            rc=0
            info="$(tn_epoch_info "$url" "$(( e + d ))")" || rc=$?
            m="unknown"
            if [[ "$rc" -eq 0 ]]; then
                read -r _ _ _ _ committee <<<"$info"
                if [[ ",${committee}," == *",${EXEC_ADDR},"* ]]; then
                    m="member"
                else
                    m="not a member"
                fi
            fi
            line="${line} · $(( e + d )): ${m}"
        done
        print_info "Committee membership of ${EXEC_ADDR} (from ${EXEC_SRC}):"
        print_info "  ${line}"
        if [[ "$IN_COMMITTEE" == "yes" && "$LOCAL_NODE_MODE" == "Observer" ]]; then
            print_warn "In the committee for epoch ${e}, but the node reports Observer: it is not taking part in consensus"
            if [[ -n "${LOC_EPOCH:-}" && "${LOC_EPOCH:-}" != "$e" ]]; then
                print_info "  The node is at epoch ${LOC_EPOCH}; it joins once it reaches epoch ${e}."
            fi
        fi
    fi

    # The stake status is read for VALIDATOR_ADDRESS. Say so when .node-meta
    # records an address other than the one the node itself runs with.
    if [[ "$VALIDATOR_ADDRESS_SRC" == ".node-meta" && "$EXEC_SRC" != ".node-meta" && -n "$EXEC_ADDR" ]] \
        && [[ "$(lower "$VALIDATOR_ADDRESS")" != "$EXEC_ADDR" ]]; then
        print_warn "VALIDATOR_ADDRESS in .node-meta (${VALIDATOR_ADDRESS}) is not the node's execution address (${EXEC_ADDR}, from ${EXEC_SRC}); the stake status is read for the .node-meta address"
    fi

    # Activation epoch of a staked validator (status read in §3's probe).
    if [[ "$ONCHAIN_STAKE_RC" == "0" ]]; then
        read -r st act _ <<<"$ONCHAIN_STAKE_LINE"
        case "$st" in
            1)
                print_info "Staked, not activated: activate() now gives activation epoch $(( e + 1 )) and an earliest committee seat of epoch $(( e + 3 ))"
                ;;
            2|3|4)
                if [[ "$act" == "0" && "$st" != "2" ]]; then
                    print_info "Activation epoch: 0 (genesis validator)"
                elif [[ "$act" =~ ^[0-9]+$ ]]; then
                    seat=$(( act + 2 ))
                    print_info "Activation epoch: ${act}; earliest committee seat: epoch ${seat} ($(epochs_away $(( seat - e ))))"
                fi
                ;;
        esac
    fi

    report_worker_count "$url" "$src"
    return 0
}

# stake_status_for_rule -- the stake status (node_stake_status first field) that
# §6 uses when committee membership is unknown: the network read when it worked,
# else a read through the local node (its state lags while it catches up), else
# an empty line.
stake_status_for_rule() {
    local line rc addr
    if [[ "$ONCHAIN_STAKE_RC" == "0" ]]; then
        echo "${ONCHAIN_STAKE_LINE%% *}"
        return 0
    fi
    addr="${VALIDATOR_ADDRESS:-$EXEC_ADDR}"
    if [[ -n "$addr" ]] && [[ "$LOCAL_RPC_MODE" == "HEALTHY" || "$LOCAL_RPC_MODE" == "SLOW" ]]; then
        rc=0
        line="$(node_stake_status "$addr" "$RPC_URL" 2>/dev/null)" || rc=$?
        if [[ "$rc" -eq 0 ]]; then
            echo "${line%% *}"
            return 0
        fi
    fi
    echo ""
}

# report_participation <authors> <reputation pairs> -- §6. Is this node's
# authority among the authors of the latest commit, and what does absence mean?
#   in the committee (on-chain, §5.5)  -> error, a health issue
#   not in the committee               -> expected, info
#   membership unknown                 -> error only for an Active or Pending Exit
#                                         validator whose node does not report
#                                         Observer; info for a node whose stake
#                                         status rules out a seat; else a warning
#                                         that the check could not run
report_participation() {
    local authors="$1" reps="$2" st mode_text kv k v own_rep committee_total committee_count avg
    print_step "Checking your participation in network consensus..."
    if [[ -n "$AUTH_ID" ]]; then
        print_info "Authority ID: ${AUTH_ID} (from ${AUTH_SRC})"
        if [[ -n "$AUTHORITY_ID" && "$AUTHORITY_ID" != "$AUTH_ID" ]]; then
            print_info "  --authority-id ${AUTHORITY_ID} is not this node's id and was not used"
        fi
    fi
    if [[ "$PARTICIPATION_SRC" == "local node" ]]; then
        print_info "Headers: the latest commit the local node has seen ($(network_gap_reason))"
    fi
    case "$IN_COMMITTEE" in
        yes) print_info "Committee: member of epoch ${EPOCH_E} (on-chain)" ;;
        no)  print_info "Committee: not a member of epoch ${EPOCH_E} (on-chain)" ;;
        *)   print_info "Committee: unknown (${COMMITTEE_WHY:-not read})" ;;
    esac

    if [[ -z "$AUTH_ID" ]]; then
        if [[ "$IN_COMMITTEE" == "yes" ]]; then
            print_warn "In the committee for epoch ${EPOCH_E}, but the authority id is unknown (no tn_info answer), so header presence was not checked"
            print_info "  Pass --authority-id <BASE58> to check it."
        else
            print_info "Authority ID unknown (no tn_info answer). Pass --authority-id <BASE58> to check header presence."
        fi
        return 0
    fi

    if [[ " ${authors} " == *" ${AUTH_ID} "* ]]; then
        print_ok "Your authority appears as an author in recent headers -- participating"
    else
        case "$IN_COMMITTEE" in
            yes)
                print_error "In the committee for epoch ${EPOCH_E} but NOT in recent headers -- node may be running but silent"
                print_info "  (authors in the latest commit: ${authors:-none})"
                (( ++HEALTH_ISSUES ))
                ;;
            no)
                print_info "Not in recent headers -- expected: this node is not in the committee for epoch ${EPOCH_E}"
                ;;
            *)
                st="$(stake_status_for_rule)"
                mode_text="reports ${LOCAL_NODE_MODE}"
                [[ -n "$LOCAL_NODE_MODE" ]] || mode_text="did not report a mode"
                case "$st" in
                    3|4)
                        if [[ "$LOCAL_NODE_MODE" != "Observer" ]]; then
                            print_error "NOT in recent headers, and committee membership is unknown (${COMMITTEE_WHY:-not read}); the registry has this node as $(stake_label "$st") and the node ${mode_text}"
                            print_info "  An active validator that is not authoring headers may be running but silent."
                            (( ++HEALTH_ISSUES ))
                        else
                            print_warn "Not in recent headers; committee membership is unknown (${COMMITTEE_WHY:-not read}) and the node reports Observer, so participation could not be checked"
                        fi
                        ;;
                    "")
                        print_warn "Not in recent headers; committee membership (${COMMITTEE_WHY:-not read}) and stake status are unknown, so participation could not be checked"
                        ;;
                    *)
                        print_info "Not in recent headers -- expected: the registry has this node as $(stake_label "$st"), which holds no committee seat"
                        ;;
                esac
                ;;
        esac
    fi

    # Reputation: this node's score against the committee average.
    own_rep=""
    committee_total=0
    committee_count=0
    for kv in $reps; do
        k="${kv%=*}"
        v="${kv#*=}"
        [[ "$v" =~ ^[0-9]+$ ]] || continue
        [[ "$k" == "$AUTH_ID" ]] && own_rep="$v"
        committee_total=$(( committee_total + v ))
        (( ++committee_count ))
    done
    if [[ -n "$own_rep" ]] && (( committee_count > 0 )); then
        avg=$(( committee_total / committee_count ))
        if (( own_rep < avg / 2 )); then
            print_warn "Your reputation score: ${own_rep} (committee avg: ${avg}) -- well below average"
        elif (( own_rep < avg )); then
            print_info "Your reputation score: ${own_rep} (committee avg: ${avg})"
        else
            print_ok "Your reputation score: ${own_rep} (committee avg: ${avg})"
        fi
    elif [[ "$IN_COMMITTEE" == "yes" ]] && (( committee_count > 0 )); then
        print_info "Your authority is not in the reputation map of the latest commit"
    fi
    return 0
}

# =============================================================================
# REPORT HEADER
# =============================================================================

# This run's private temp directory, made once with mktemp -d so two concurrent
# runs never share a file, and removed on exit (signals included) by
# check_node_cleanup. It holds the local RPC probe's response body and the wss
# probe's header files. A directory rather than a file: a probe still running
# after a signal cannot recreate anything once the directory is gone. /tmp is
# the fallback when TMPDIR names a missing or read-only directory. An EXIT trap
# set before this point keeps running after ours; sourcing lib/common.sh sets
# none today.
CN_TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/check-node.XXXXXX" 2>/dev/null \
    || mktemp -d /tmp/check-node.XXXXXX 2>/dev/null || true)"
RPC_BODY_TMP=""
[[ -z "$CN_TMP_DIR" ]] || RPC_BODY_TMP="${CN_TMP_DIR}/rpc-body"
CN_PREV_EXIT_TRAP=""
if [[ -n "$(trap -p EXIT)" ]]; then
    eval "set -- $(trap -p EXIT)"
    CN_PREV_EXIT_TRAP="${3:-}"
fi
trap check_node_cleanup EXIT

# The local RPC is probed before the header: when .node-meta does not say which
# network this node is on, its chain id decides which network RPC to compare with.
LOCAL_CHAIN_ID=""
read -r LOCAL_RPC_MODE LOCAL_CHAIN_ID <<< "$(probe_local_rpc "$RPC_URL")"
resolve_network

print_header "Telcoin Network Node Health Check  v${SCRIPT_VERSION}"
print_info "Service:      ${SERVICE_NAME}"
print_info "Local RPC:    ${RPC_URL}"
if [[ -n "$NODE_NETWORK" ]]; then
    print_info "Network:      ${NODE_NETWORK} (chain ${EXPECTED_CHAIN_ID}, from ${NETWORK_SRC}${NETWORK_NOTE:+; ${NETWORK_NOTE}})"
else
    print_info "Network:      unknown (${NETWORK_NOTE:-not recorded}; any Telcoin chain id is accepted)"
fi
[[ "$QUERY_NETWORK" == "true" ]] && print_info "Network RPC:  ${NETWORK_RPC}"
print_info "Time:         $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
if ! version_gte "${COMMON_VERSION:-0}" "1.6.0"; then
    print_warn "lib/common.sh ${COMMON_VERSION:-unknown} is older than 1.6.0: checks that need its newer helpers are skipped. Run update-scripts.sh."
fi
echo ""

# =============================================================================
# 1. SERVICE STATUS
# =============================================================================
print_step "Checking systemd service..."
if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
    print_ok "Service '${SERVICE_NAME}' is running"
    uptime_line=$(systemctl show "$SERVICE_NAME" --property=ActiveEnterTimestamp 2>/dev/null | cut -d= -f2-)
    [[ -n "$uptime_line" ]] && print_info "Running since: ${uptime_line}"
    # Restart-loop check
    n_restarts=$(systemctl show "$SERVICE_NAME" --property=NRestarts 2>/dev/null | cut -d= -f2)
    if [[ -n "$n_restarts" ]] && (( n_restarts > 5 )); then
        print_warn "Service has restarted ${n_restarts} times -- check logs for crash loop"
    fi
else
    print_error "Service '${SERVICE_NAME}' is NOT running"
    print_info "  Start it: systemctl start ${SERVICE_NAME}"
    print_info "  Logs:     journalctl -u ${SERVICE_NAME} --no-pager -n 30"
    (( ++HEALTH_ISSUES ))
fi
report_legacy_observer_flag
report_node_config

# =============================================================================
# 2. LOCAL RPC PROBE (probed before the report header; rendered here)
# =============================================================================
print_step "Probing local RPC..."
case "$LOCAL_RPC_MODE" in
    HEALTHY)
        print_ok "Local RPC responds to eth_chainId"
        # Sanity-check the chain ID against the network in .node-meta. A node
        # configured for a different network (wrong genesis, copy-pasted
        # config) would otherwise pass every downstream check while comparing
        # against the wrong network. Without a recorded network any Telcoin
        # chain id passes: testnet 2017, mainnet 487, devnet 32285.
        if [[ -n "$LOCAL_CHAIN_ID" ]]; then
            chain_dec=$(hex_to_dec "$LOCAL_CHAIN_ID")
            chain_net="$(chain_network "$chain_dec")"
            if [[ "$NETWORK_SRC" == ".node-meta" ]]; then
                if [[ "$chain_dec" == "$EXPECTED_CHAIN_ID" ]]; then
                    print_info "  Chain ID:        ${LOCAL_CHAIN_ID} (${chain_dec} -- ${NODE_NETWORK})"
                else
                    print_error "Chain ID mismatch: ${LOCAL_CHAIN_ID} (${chain_dec}${chain_net:+ -- ${chain_net}}) -- .node-meta says ${NODE_NETWORK} (chain ${EXPECTED_CHAIN_ID})"
                    print_info "  Node may be configured for the wrong network."
                    (( ++HEALTH_ISSUES ))
                fi
            elif [[ -n "$chain_net" ]]; then
                print_info "  Chain ID:        ${LOCAL_CHAIN_ID} (${chain_dec} -- ${chain_net})"
                print_info "  Any Telcoin chain id is accepted: ${NETWORK_NOTE:-no network recorded}."
            else
                print_error "Chain ID ${LOCAL_CHAIN_ID} (${chain_dec}) is not a Telcoin network (testnet ${TESTNET_CHAIN_ID}, mainnet ${MAINNET_CHAIN_ID}, devnet ${DEVNET_CHAIN_ID})"
                print_info "  Node may be configured for the wrong network."
                (( ++HEALTH_ISSUES ))
            fi
        fi
        ;;
    SLOW)
        print_warn "Local RPC is responding but slow (>6s) -- node may be under load"
        ;;
    DISABLED)
        print_info "Local RPC reachable but eth_chainId is disabled or filtered"
        print_info "(This is normal if --http is off, or nginx is filtering methods)"
        ;;
    DOWN)
        print_info "Local RPC not reachable at ${RPC_URL}"
        print_info "(Expected if the node runs without --http; pass --rpc <URL> if it listens elsewhere)"
        ;;
esac

# =============================================================================
# 3. NETWORK STATE (ground truth)
# =============================================================================
NETWORK_OK=false
if [[ "$QUERY_NETWORK" == "true" ]]; then
    print_step "Querying network consensus state (${NETWORK_RPC})..."
    CH_ERROR=""
    # An endpoint serving another chain is warned about by check_network_chain
    # and not compared with; that is the endpoint's problem, not the node's.
    check_network_chain
    if [[ "$NETWORK_WRONG_CHAIN" == "true" ]]; then
        :
    elif fetch_consensus_header "$NETWORK_RPC" 15; then
        NETWORK_OK=true
        NET_BLOCK="$CH_BLOCK"
        NET_TS="$CH_TS"
        NET_EPOCH="$CH_EPOCH"
        NET_AUTHORS="$CH_AUTHORS"
        NET_REPS="$CH_REPS"
        NOW=$(date +%s)
        NET_AGE=$(( NOW - NET_TS ))
        print_ok "Network consensus current"
        committee_size=$(echo "$NET_AUTHORS" | wc -w | tr -d ' ')
        print_info "Network: block ${NET_BLOCK} · epoch ${NET_EPOCH} · committee ${committee_size} · commit $(fmt_age "$NET_AGE")"
        if (( NET_AGE > STALE_THRESHOLD_SECONDS )); then
            print_warn "Network commit is older than ${STALE_THRESHOLD_SECONDS}s -- network may be quiet"
        fi
    else
        print_warn "Could not reach network RPC: ${CH_ERROR:-no response}"
        print_info "Skipping network-comparison checks. Use --no-network to silence this."
        # An unreachable network RPC is a real issue on a node that should be
        # comparing itself to the network -- otherwise §4/§6/§7 silently skip
        # and the §10 verdict no longer has the ground truth it needs.
        NETWORK_PROBE_FAILED=true
        (( ++HEALTH_ISSUES ))
    fi
else
    print_info "Network query skipped (--no-network)"
fi

# =============================================================================
# 4. LOCAL CONSENSUS STATE (if local RPC is up)
# =============================================================================
LOCAL_CONSENSUS_OK=false
# Authors and reputation of the latest commit the local node has seen; §6 uses
# them when the network RPC is unavailable.
LOC_AUTHORS=""
LOC_REPS=""
if [[ "$LOCAL_RPC_MODE" == "HEALTHY" ]] || [[ "$LOCAL_RPC_MODE" == "SLOW" ]]; then
    print_step "Querying local consensus state..."
    CH_ERROR=""
    if fetch_consensus_header "$RPC_URL" 8; then
        LOCAL_CONSENSUS_OK=true
        LOC_BLOCK="$CH_BLOCK"
        LOC_TS="$CH_TS"
        LOC_EPOCH="$CH_EPOCH"
        LOC_AUTHORS="$CH_AUTHORS"
        LOC_REPS="$CH_REPS"
        NOW=$(date +%s)
        LOC_AGE=$(( NOW - LOC_TS ))

        # block==0 -> fully stalled; stale commit timestamp -> not tracking tip.
        # NOTE: this section confirms the node is TRACKING the latest consensus
        # tip -- it does NOT prove the node has PROCESSED up to that tip. The
        # node can track a fresh tip (so this looks "current") while its
        # execution layer is thousands of blocks behind. The authoritative
        # sync signal is the EVM execution lag in section 5, not this.
        if (( LOC_BLOCK == 0 )); then
            print_error "Local consensus block is 0 -- node is FULLY STALLED"
            (( ++HEALTH_ISSUES ))
        elif (( LOC_AGE > STALE_THRESHOLD_SECONDS )); then
            # Local consensus tip is older than the network's. This is a
            # symptom of catching-up, not a confirmed failure -- a node that
            # is state-syncing legitimately lags the live tip. Reported as
            # info; the operator interprets alongside the §5 state-sync data.
            print_info "Consensus tip: block ${LOC_BLOCK} ($(fmt_age "$LOC_AGE")) -- older than ${STALE_THRESHOLD_SECONDS}s threshold"
        else
            print_ok "Consensus tip tracked: block ${LOC_BLOCK} ($(fmt_age "$LOC_AGE"))"
        fi
        print_info "  Local epoch:     ${LOC_EPOCH}"

        # Tip match vs network. This only confirms the node sees the same tip
        # as the network -- it is NOT a measure of catch-up progress.
        if [[ "$NETWORK_OK" == "true" ]]; then
            lag=$(( NET_BLOCK - LOC_BLOCK ))
            # This is the CONSENSUS tip delta only -- it doesn't reflect EVM
            # catch-up progress (the authoritative signal is §5's EVM lag). So
            # all branches are info-only; the §10 verdict reads HEALTH_ISSUES
            # and CATCHING_UP, neither of which this section sets.
            if (( lag < -5 )); then
                print_info "  Tip vs network:  local tip ahead by $(( -lag )) (clock/routing skew)"
            elif (( lag > 100 )); then
                print_info "  Tip vs network:  ${lag} blocks behind on the tracked tip (see EVM state below for catch-up)"
            else
                print_ok "  Tip vs network:  matched (delta ${lag}) -- tracking the network tip"
            fi
            if [[ "$LOC_EPOCH" != "$NET_EPOCH" ]]; then
                print_warn "  Epoch mismatch:  local=${LOC_EPOCH} network=${NET_EPOCH}"
            fi
        fi
    else
        print_warn "Could not query local consensus: ${CH_ERROR:-no response}"
        if [[ "$LOCAL_RPC_MODE" == "HEALTHY" ]]; then
            print_info "  eth_chainId works but tn_latestConsensusHeader does not"
            print_info "  -- this node may be running an older binary"
        fi
    fi
    # Live consensus role (tn_nodeMode), kept in LOCAL_NODE_MODE: §5.5 warns when a
    # committee member reports Observer, and §6 reads it when membership is unknown.
    fetch_node_mode "$RPC_URL"
else
    print_info "Skipping local consensus query (local RPC ${LOCAL_RPC_MODE})"
fi

# =============================================================================
# 5. EVM EXECUTION STATE (block + advancement + sync)
# The execution lag is the AUTHORITATIVE sync signal (per Telcoin dev guidance).
# Network execution block is read by calling eth_blockNumber DIRECTLY on the
# network RPC -- NOT derived from latest_execution_block in consensus headers,
# which could differ from the network's real execution tip.
# Also tracks whether the LOCAL block advanced since the previous run, to
# distinguish "caught up" / "catching up" / "stuck".
# =============================================================================
LOCAL_EXEC_BLOCK=""
NET_EXEC_BLOCK=""

# Network execution tip via direct eth_blockNumber on the network RPC (not from
# an endpoint that serves another chain).
if [[ "$QUERY_NETWORK" == "true" && "$NETWORK_WRONG_CHAIN" != "true" ]]; then
    NET_EXEC_BLOCK=$(fetch_exec_block "$NETWORK_RPC" || echo "")
fi

if [[ "$LOCAL_RPC_MODE" == "HEALTHY" ]] || [[ "$LOCAL_RPC_MODE" == "SLOW" ]]; then
    print_step "Querying EVM execution state..."
    if ! LOCAL_EXEC_BLOCK=$(fetch_exec_block "$RPC_URL"); then
        print_warn "Could not query local eth_blockNumber"
        LOCAL_EXEC_BLOCK=""
    fi

    # --- Advancement since the previous run ---
    # Read prior state before writing the new one. State format:
    #   "<local_evm> <unix_ts> <consensus_height> <network_evm>"
    local_now_ts=$(date +%s)
    prev_state=$(read_prev_block_state)
    prev_block=""; prev_ts=""; prev_net_evm=""
    if [[ -n "$prev_state" ]]; then
        prev_block=$(echo "$prev_state" | awk '{print $1}')
        prev_ts=$(echo "$prev_state" | awk '{print $2}')
        prev_net_evm=$(echo "$prev_state" | awk '{print $4}')
    fi
    if [[ -n "$LOCAL_EXEC_BLOCK" ]]; then
        write_block_state "$LOCAL_EXEC_BLOCK" "$local_now_ts" "${LOC_BLOCK:-}" "${NET_EXEC_BLOCK:-}"
    fi

    # Compute local delta + elapsed for the consolidated EVM line.
    local_delta=""
    local_elapsed=""
    if [[ -n "$LOCAL_EXEC_BLOCK" ]] \
        && [[ -n "$prev_block" ]] && [[ "$prev_block" =~ ^[0-9]+$ ]] \
        && [[ -n "$prev_ts" ]]    && [[ "$prev_ts" =~ ^[0-9]+$ ]]; then
        local_delta=$(( LOCAL_EXEC_BLOCK - prev_block ))
        local_elapsed=$(( local_now_ts - prev_ts ))
    fi

    # --- Lag vs network (single consolidated line) ---
    if [[ -n "$NET_EXEC_BLOCK" ]] && [[ "$NET_EXEC_BLOCK" != "0" ]] && [[ -n "$LOCAL_EXEC_BLOCK" ]]; then
        EVM_LAG=$(( NET_EXEC_BLOCK - LOCAL_EXEC_BLOCK ))
        advance_note=""
        if [[ -n "$local_delta" ]]; then
            advance_note=", advancing +${local_delta} since last check"
        fi
        if (( EVM_LAG > EVM_SYNC_THRESHOLD )); then
            CATCHING_UP=true
            print_warn "EVM: local ${LOCAL_EXEC_BLOCK} / network ${NET_EXEC_BLOCK} (lag ${EVM_LAG}${advance_note})"
        elif (( EVM_LAG < -5 )); then
            print_info "EVM: local ${LOCAL_EXEC_BLOCK} / network ${NET_EXEC_BLOCK} (local ahead by $(( -EVM_LAG ))${advance_note})"
        else
            print_ok "EVM: local ${LOCAL_EXEC_BLOCK} / network ${NET_EXEC_BLOCK} (lag ${EVM_LAG}${advance_note})"
        fi
    elif [[ -n "$LOCAL_EXEC_BLOCK" ]]; then
        print_info "EVM: local ${LOCAL_EXEC_BLOCK} (network EVM unavailable)"
        [[ "$QUERY_NETWORK" == "true" && "$NETWORK_WRONG_CHAIN" != "true" ]] \
            && [[ -z "$NET_EXEC_BLOCK" || "$NET_EXEC_BLOCK" == "0" ]] && \
            print_warn "Could not read network eth_blockNumber from ${NETWORK_RPC}"
    elif [[ -n "$NET_EXEC_BLOCK" ]] && [[ "$NET_EXEC_BLOCK" != "0" ]]; then
        print_info "EVM: network ${NET_EXEC_BLOCK} (local unavailable)"
    fi

    # --- Advancement narrative (info-only; never increments HEALTH_ISSUES) ---
    if [[ -n "$LOCAL_EXEC_BLOCK" ]]; then
        if [[ -n "$local_delta" ]]; then
            if (( local_delta < 0 )); then
                print_warn "Block went backwards: ${local_delta} since last check -- unusual (reorg or DB reset?)"
            elif (( local_delta == 0 )) && (( local_elapsed >= 60 )); then
                # Local EVM unchanged over a meaningful window. Cross-reference
                # network EVM to distinguish "we're frozen, network's moving"
                # from "everyone is quiet". Both branches are info-only -- the
                # script reports facts; operators interpret.
                net_delta=""
                if [[ -n "$NET_EXEC_BLOCK" ]] && [[ -n "$prev_net_evm" ]] \
                    && [[ "$NET_EXEC_BLOCK" =~ ^[0-9]+$ ]] && [[ "$prev_net_evm" =~ ^[0-9]+$ ]]; then
                    net_delta=$(( NET_EXEC_BLOCK - prev_net_evm ))
                fi
                if [[ -n "$net_delta" ]] && (( net_delta > 0 )); then
                    print_info "Local EVM unchanged for ${local_elapsed}s -- network advanced +${net_delta} in same window"
                elif [[ -n "$net_delta" ]]; then
                    print_info "Local EVM unchanged for ${local_elapsed}s -- network also quiet (no new blocks)"
                else
                    print_info "Local EVM unchanged for ${local_elapsed}s (no prior network reading to compare)"
                fi
            fi
        else
            print_info "No prior reading -- run check-node.sh again to measure block advancement"
        fi
    fi

elif [[ -n "$NET_EXEC_BLOCK" ]] && [[ "$NET_EXEC_BLOCK" != "0" ]]; then
    print_step "EVM execution state (network only -- local RPC unreachable)..."
    print_info "EVM: network ${NET_EXEC_BLOCK} (local unavailable, RPC ${LOCAL_RPC_MODE})"
fi

# State-sync progress (info-only). Reads the node log directly, so it runs
# regardless of LOCAL_RPC_MODE. Pure measurement -- no verdict, no
# HEALTH_ISSUES++. The §10 "CATCHING UP" line plus the data here is what an
# operator needs to decide if action is warranted.
if read_sync_progress; then
    ss_gap=$(( SS_TARGET - SS_HEIGHT ))
    print_info "State-sync activity:  height ${SS_HEIGHT}, target ${SS_TARGET} (gap ${ss_gap}), last warning ${SS_AGE_S}s ago"
    if [[ -n "${LOC_BLOCK:-}" ]] && [[ -n "${prev_state:-}" ]]; then
        prev_cons=$(echo "$prev_state" | awk '{print $3}')
        if [[ -n "$prev_cons" ]] && [[ "$prev_cons" =~ ^[0-9]+$ ]] && [[ "$LOC_BLOCK" =~ ^[0-9]+$ ]] && [[ -n "${local_elapsed:-}" ]]; then
            cons_delta=$(( LOC_BLOCK - prev_cons ))
            print_info "                      consensus height advanced +${cons_delta} since last check (${local_elapsed}s ago)"
        fi
    fi
fi

# The node's own authority id and execution address (tn_info), then the on-chain
# stake status: §5.5 shows the activation epoch from it, §6 falls back on it when
# committee membership is unknown, and §7 renders it. Without --address or a
# readable .node-meta, the node's execution address is the one checked.
resolve_identity
if [[ -z "$VALIDATOR_ADDRESS" && -n "$EXEC_ADDR" ]]; then
    VALIDATOR_ADDRESS="$EXEC_ADDR"
    VALIDATOR_ADDRESS_SRC="$EXEC_SRC"
fi
probe_onchain_validator_status

# =============================================================================
# 5.5 EPOCH AND COMMITTEE (epoch timing, committee seats, workers)
# =============================================================================
report_epoch_committee

# =============================================================================
# 6. AUTHORITY-SPECIFIC CHECKS (author presence + own reputation)
# Uses the NETWORK's latest commit, so it still works if the local RPC is
# closed; when the network RPC is unavailable, the latest commit the local node
# has seen stands in. Committee membership (§5.5) decides what absence means.
# =============================================================================
if [[ "$NETWORK_OK" == "true" ]]; then
    PARTICIPATION_SRC="network"
    report_participation "$NET_AUTHORS" "$NET_REPS"
elif [[ "$LOCAL_CONSENSUS_OK" == "true" ]]; then
    PARTICIPATION_SRC="local node"
    report_participation "$LOC_AUTHORS" "$LOC_REPS"
fi

# =============================================================================
# 7. ON-CHAIN VALIDATOR STATUS
# VALIDATOR_ADDRESS is populated for ALL nodes (--address, .node-meta, or the
# node's own execution address), so we always report on-chain status when we
# have an address -- the registry is the authority for validator-ness. The chain
# was already probed once above; render that cached result line rather than
# calling out again.
# =============================================================================
if [[ -n "$VALIDATOR_ADDRESS" ]]; then
    echo ""
    if [[ "$NETWORK_OK" == "true" ]]; then
        # Render the cached probe result (single on-chain round-trip per run).
        report_onchain_validator_status
    else
        # Without the network RPC there is no stake status to show, and a
        # "No validator record found" here would mislead. The §10 banner
        # enumerates the skip.
        print_info "Skipping on-chain validator status (network RPC unreachable)"
    fi
else
    echo ""
    print_info "Tip: run with --address 0xYOUR_ADDRESS to check on-chain validator status."
fi

# =============================================================================
# 8. DISK
# =============================================================================
print_step "Checking disk space..."
DATA_DIR=$(detect_data_dir)
# Find the mount point that contains the data dir. df_line parses POSIX
# `df -Pk`, so this works with GNU df (Linux) and BSD df (macOS) alike.
DATA_MOUNT=""
data_df="$(df_line "$DATA_DIR")"
[[ -n "$data_df" ]] && read -r _ _ _ _ DATA_MOUNT <<<"$data_df"
mounts_to_check=("/" "$DATA_MOUNT")
# De-duplicate
seen=""
for mount_path in "${mounts_to_check[@]}"; do
    [[ -z "$mount_path" ]] && continue
    [[ " $seen " == *" $mount_path "* ]] && continue
    seen="$seen $mount_path"
    [[ -d "$mount_path" ]] || continue
    disk_info=""
    usage_pct=""
    disk_line="$(df_line "$mount_path")"
    if [[ -n "$disk_line" ]]; then
        read -r disk_total disk_used _ usage_pct _ <<<"$disk_line"
        # Whole GiB, rounded up like `df -BG`.
        disk_info="$(( (disk_used + 1048575) / 1048576 ))G used / $(( (disk_total + 1048575) / 1048576 ))G total (${usage_pct}% full)"
    fi
    # Annotate the data-mount line with the resolved data dir so the operator
    # can verify detect_data_dir landed on the right path -- replaces the old
    # trailing "Data dir checked:" line.
    label="$mount_path"
    [[ "$mount_path" == "$DATA_MOUNT" ]] && label="${mount_path} (data: ${DATA_DIR})"
    if [[ -n "$disk_info" ]] && [[ -n "$usage_pct" ]]; then
        if (( usage_pct >= 90 )); then
            print_error "Disk at ${label}: ${disk_info} -- CRITICAL"
            (( ++HEALTH_ISSUES ))
        elif (( usage_pct >= 75 )); then
            print_warn "Disk at ${label}: ${disk_info} -- getting full"
        else
            print_ok "Disk at ${label}: ${disk_info}"
        fi
    fi
done

# =============================================================================
# 9. MEMORY AND CPU
# Memory comes from /proc/meminfo (Linux; TN_PROC_MEMINFO points a test at a
# fixture). Elsewhere, macOS included, the memory check is skipped with a note.
# =============================================================================
print_step "Checking memory and CPU..."
MEMINFO="${TN_PROC_MEMINFO:-/proc/meminfo}"
MEM_TOTAL=""
MEM_AVAIL=""
if [[ -r "$MEMINFO" ]]; then
    MEM_TOTAL=$(awk '/^MemTotal:/ { print $2; exit }' "$MEMINFO" 2>/dev/null)
    MEM_AVAIL=$(awk '/^MemAvailable:/ { print $2; exit }' "$MEMINFO" 2>/dev/null)
fi
if [[ ! -r "$MEMINFO" ]]; then
    print_info "Memory: not checked -- the memory check needs /proc/meminfo"
elif [[ ! "$MEM_TOTAL" =~ ^[1-9][0-9]*$ || ! "$MEM_AVAIL" =~ ^[0-9]+$ ]]; then
    print_info "Memory: not checked -- no MemTotal/MemAvailable in ${MEMINFO}"
else
    MEM_USED=$(( MEM_TOTAL - MEM_AVAIL ))
    MEM_PCT=$(( MEM_USED * 100 / MEM_TOTAL ))
    MEM_USED_GB=$(( MEM_USED / 1024 / 1024 ))
    MEM_TOTAL_GB=$(( MEM_TOTAL / 1024 / 1024 ))

    if (( MEM_PCT >= 95 )); then
        print_error "Memory: ${MEM_USED_GB}GB / ${MEM_TOTAL_GB}GB (${MEM_PCT}%) -- CRITICAL"
        (( ++HEALTH_ISSUES ))
    elif (( MEM_PCT >= 85 )); then
        print_warn "Memory: ${MEM_USED_GB}GB / ${MEM_TOTAL_GB}GB (${MEM_PCT}%) -- high"
    else
        print_ok "Memory: ${MEM_USED_GB}GB / ${MEM_TOTAL_GB}GB (${MEM_PCT}%)"
    fi
fi
# CPU count for reference: physical cores where the system reports them (lscpu,
# /proc/cpuinfo or sysctl), else logical CPUs. Needs lib/common.sh 1.6.0.
if have_fns tn_physical_cores && cpu_count="$(tn_physical_cores 2>/dev/null)"; then
    case "$cpu_count" in
        *" physical") print_info "CPU: ${cpu_count% physical} physical cores" ;;
        *" logical")  print_info "CPU: ${cpu_count% logical} logical CPUs (physical cores not reported)" ;;
    esac
fi

# =============================================================================
# 9.5 TESTNET ADD-ONS (Alloy / health endpoint / VPN overlay)
# =============================================================================
report_testnet_addons

# =============================================================================
# 9.6 PUBLIC RPC (Caddy tn-rpc vhost / https + wss probes / worker.rpc advert)
# =============================================================================
report_public_rpc

# =============================================================================
# 10. SUMMARY
# =============================================================================
echo ""
print_sep
echo ""

# Surface skipped sections explicitly. Without this, a network probe failure
# in §3 buries a single yellow warning and the operator gets a report missing
# §4/§6/§7 with no clear "you are missing data" signal. §6 still runs on the
# local node's view of the latest commit when the local RPC answers.
if [[ "$NETWORK_PROBE_FAILED" == "true" || "$NETWORK_WRONG_CHAIN" == "true" ]]; then
    if [[ "$NETWORK_WRONG_CHAIN" == "true" ]]; then
        print_warn "Network RPC serves chain ${NET_CHAIN_DEC}, not ${EXPECTED_CHAIN_ID} -- the following sections were SKIPPED:"
    else
        print_warn "Network probe failed -- the following sections were SKIPPED:"
    fi
    print_info "  - Consensus tip and EVM lag comparison (§4, §5 cross-network)"
    [[ -n "$PARTICIPATION_SRC" ]] || print_info "  - Author presence and reputation (§6)"
    print_info "  - On-chain validator status (§7)"
    if [[ "$NETWORK_WRONG_CHAIN" == "true" ]]; then
        print_info "Pass --network-rpc <URL> with an RPC for chain ${EXPECTED_CHAIN_ID}, or --no-network to silence."
    else
        print_info "Re-run when network connectivity is restored, or pass --no-network to silence."
    fi
    echo ""
fi

# The verdict prioritises the EVM execution lag as the real sync signal.
# A node can pass every other check (service up, RPC healthy, consensus tip
# tracked) while still being thousands of execution blocks behind -- so
# "catching up" is reported distinctly from "healthy".
if [[ "$CATCHING_UP" == "true" ]]; then
    if [[ -n "$EVM_LAG" ]]; then
        print_warn "CATCHING UP: ${EVM_LAG} execution blocks behind"
    else
        print_warn "CATCHING UP: execution layer is behind the network"
    fi
elif (( HEALTH_ISSUES == 0 )); then
    if [[ -n "$EVM_LAG" ]]; then
        print_ok "All checks passed -- node is healthy and caught up (EVM lag ${EVM_LAG})"
    else
        print_ok "All checks passed -- node appears healthy"
        [[ "$LOCAL_RPC_MODE" != "HEALTHY" ]] && [[ "$LOCAL_RPC_MODE" != "SLOW" ]] && \
            print_info "Note: local RPC was ${LOCAL_RPC_MODE} -- execution sync could not be verified directly."
    fi
else
    print_warn "${HEALTH_ISSUES} issue(s) found -- review warnings/errors above"
fi
echo ""
# A diagnostic: the report above is the result; the exit status is always 0.
exit 0
