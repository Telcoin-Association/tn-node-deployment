#!/usr/bin/env bash
# =============================================================================
# check-node.sh -- Telcoin Network Node Health Check
#
# Queries the Telcoin Network consensus RPC for ground truth and compares
# the local node state against it. Works for both validator and observer
# nodes. Falls back gracefully if the local RPC is unreachable -- the
# network's view of your node is still reported.
#
# USAGE:
#   bash check-node.sh                              # auto-detect node type
#   bash check-node.sh --validator                  # force validator
#   bash check-node.sh --observer                   # force observer
#   bash check-node.sh --address 0xYOUR_ADDRESS     # include on-chain status
#   bash check-node.sh --authority-id <BASE58>      # override author/rep check
#   bash check-node.sh --rpc <URL>                  # custom local RPC
#   bash check-node.sh --network-rpc <URL>          # custom network RPC
#   bash check-node.sh --no-network                 # skip network query
#   bash check-node.sh --service <name>             # custom service name
# =============================================================================

set -uo pipefail
# `set -e` is inherited from lib/common.sh; left active intentionally.
# Counters use ++var (pre-increment) to avoid the post-increment-returns-0
# pitfall under set -e.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

readonly SCRIPT_VERSION="1.1.36"
readonly DEFAULT_NETWORK_RPC="https://rpc.telcoin.network"
readonly STALE_THRESHOLD_SECONDS=60

# Defaults that get overridden by auto-detection or explicit flags.
RPC_URL=""
SERVICE_NAME=""
NODE_TYPE=""
VALIDATOR_ADDRESS=""
AUTHORITY_ID=""
NETWORK_RPC="$DEFAULT_NETWORK_RPC"
QUERY_NETWORK=true
NODE_TYPE_EXPLICITLY_SET=false

# Apply node-type defaults. Called by --validator/--observer and by
# detect_node_type() when running with no flag.
set_node_type() {
    case "$1" in
        validator)
            NODE_TYPE="validator"
            SERVICE_NAME="telcoin-validator"
            [[ -z "$RPC_URL" ]] && RPC_URL="http://127.0.0.1:8545"
            ;;
        observer)
            NODE_TYPE="observer"
            SERVICE_NAME="telcoin-observer"
            [[ -z "$RPC_URL" ]] && RPC_URL="http://127.0.0.1:8541"
            ;;
    esac
}

# Pick a default node type from installed systemd units.
# If both are installed, default to validator and tell the operator how to
# switch. If neither, default to validator with a note. Honours explicit
# flags via NODE_TYPE_EXPLICITLY_SET.
detect_node_type() {
    [[ "$NODE_TYPE_EXPLICITLY_SET" == "true" ]] && return 0
    local val_unit="/etc/systemd/system/telcoin-validator.service"
    local obs_unit="/etc/systemd/system/telcoin-observer.service"
    local has_val=false has_obs=false
    [[ -f "$val_unit" ]] && has_val=true
    [[ -f "$obs_unit" ]] && has_obs=true

    if   [[ "$has_val" == "true" ]] && [[ "$has_obs" == "true" ]]; then
        set_node_type validator
        print_info "Auto-detected: BOTH validator and observer installed -- checking validator."
        print_info "Use --observer to check the observer instead."
    elif [[ "$has_val" == "true" ]]; then
        set_node_type validator
        print_info "Auto-detected node type: validator"
    elif [[ "$has_obs" == "true" ]]; then
        set_node_type observer
        print_info "Auto-detected node type: observer"
    else
        set_node_type validator
        print_warn "No Telcoin node detected on this server -- defaulting to validator."
        print_info "Pass --observer or --validator explicitly if needed."
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --validator)    set_node_type validator; NODE_TYPE_EXPLICITLY_SET=true; shift ;;
        --observer)     set_node_type observer;  NODE_TYPE_EXPLICITLY_SET=true; shift ;;
        --rpc)          RPC_URL="$2";           shift 2 ;;
        --service)      SERVICE_NAME="$2";      shift 2 ;;
        --address)      VALIDATOR_ADDRESS="$2"; shift 2 ;;
        --authority-id) AUTHORITY_ID="$2";      shift 2 ;;
        --network-rpc)  NETWORK_RPC="$2";       shift 2 ;;
        --no-network)   QUERY_NETWORK=false;    shift ;;
        -h|--help)
            cat <<EOF

Usage: $0 [OPTIONS]

  (no flag)                Auto-detect node type from installed systemd units
  --validator              Force validator check
  --observer               Force observer check
  --rpc <URL>              Local RPC endpoint (default: http://127.0.0.1:8545 / 8541)
  --network-rpc <URL>      Network RPC for ground truth (default: ${DEFAULT_NETWORK_RPC})
  --no-network             Skip the network RPC query (local-only mode)
  --service <name>         systemd service name override
  --address <0x...>        Validator address for on-chain status check
  --authority-id <BASE58>  Authority ID override (else auto-detected from node-info.yaml)

EOF
            exit 0
            ;;
        *) print_warn "Unknown argument: $1"; shift ;;
    esac
done

# Auto-detect node type if neither --validator nor --observer was passed.
detect_node_type

HEALTH_ISSUES=0

# =============================================================================
# HELPERS
# =============================================================================

# Detect this node's data directory from .node-meta so disk checks land on
# the actual chain-data mount, not just /var/lib/telcoin. Always returns 0
# (echoes the default path if nothing else found) so set -e doesn't fire.
detect_data_dir() {
    local meta="/etc/telcoin/${NODE_TYPE}/.node-meta"
    local default="/var/lib/telcoin/${NODE_TYPE}"
    if [[ -f "$meta" ]]; then
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

# Auto-detect the operator's authority ID from node-info.yaml. The setup
# keytool writes a YAML field `primary_network_key:` holding a base58 string.
# Echoes empty string when not found. Always returns 0 -- caller checks for
# empty rather than relying on exit status (so set -e never trips here).
detect_authority_id() {
    if [[ -n "$AUTHORITY_ID" ]]; then
        echo "$AUTHORITY_ID"
        return 0
    fi
    local data_dir node_info
    data_dir=$(detect_data_dir)
    node_info="${data_dir}/node-info.yaml"
    if [[ ! -f "$node_info" ]]; then
        echo ""
        return 0
    fi
    # Strip key/quotes/whitespace; value is base58 (no 0/O/I/l, 40-50 chars typical)
    local found=""
    found=$(grep -E '^[[:space:]]*primary_network_key:' "$node_info" 2>/dev/null | \
        head -1 | \
        sed -E 's/^[[:space:]]*primary_network_key:[[:space:]]*//; s/^["\x27]//; s/["\x27]$//' | \
        tr -d '[:space:]' || true)
    echo "$found"
    return 0
}

# Probe local RPC and classify the mode.
# Returns one of: HEALTHY | SLOW | DOWN | DISABLED | NO_RPC
# Echoes the mode on stdout.
probe_local_rpc() {
    local url="$1"
    local body
    local http_code
    # Use --connect-timeout separate from --max-time so we can distinguish
    # "refused" (down) from "took too long" (slow).
    body=$(curl -sS --connect-timeout 3 --max-time 6 \
        -o /tmp/check-node.rpc.tmp -w "%{http_code}" \
        -X POST -H 'Content-Type: application/json' \
        --data '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' \
        "$url" 2>/dev/null)
    http_code="$body"
    local resp=""
    [[ -f /tmp/check-node.rpc.tmp ]] && resp=$(cat /tmp/check-node.rpc.tmp 2>/dev/null)
    rm -f /tmp/check-node.rpc.tmp

    case "$http_code" in
        "")          echo "DOWN" ;;          # curl failed entirely
        000)         echo "DOWN" ;;          # connection refused / timeout
        200)
            if echo "$resp" | grep -q '"result"'; then
                echo "HEALTHY"
            elif echo "$resp" | grep -q '"-32601"'; then
                echo "DISABLED"
            else
                echo "DISABLED"
            fi
            ;;
        *)           echo "DOWN" ;;
    esac
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

# Call eth_blockNumber locally. Echoes the decoded decimal block number on
# success, or empty string on failure. Caller uses exit code:
#   0 = ok (value echoed)
#   1 = failure (empty)
# Side-effect-free: returns the value via stdout so it works in command
# substitution (a side-effect via global would not propagate out of $( )).
fetch_local_exec_block() {
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

# Call eth_syncing locally. Returns one of:
#   "synced"
#   "syncing <current>/<highest>"
#   "err"
fetch_local_sync_state() {
    local url="$1"
    local resp
    resp=$(curl -sS --connect-timeout 3 --max-time 6 \
        -X POST -H 'Content-Type: application/json' \
        --data '{"jsonrpc":"2.0","method":"eth_syncing","params":[],"id":1}' \
        "$url" 2>/dev/null) || { echo "err"; return; }
    echo "$resp" | python3 -c '
import json, sys
def to_int(x):
    if not isinstance(x, str): return 0
    try: return int(x, 16)
    except Exception: return 0
try:
    d = json.load(sys.stdin)
    r = d.get("result")
    if r is False:
        print("synced")
    elif isinstance(r, dict):
        cur = to_int(r.get("currentBlock", "0x0"))
        hi  = to_int(r.get("highestBlock", "0x0"))
        print(f"syncing {cur}/{hi}")
    else:
        print("err")
except Exception:
    print("err")
'
}

# =============================================================================
# REPORT HEADER
# =============================================================================

print_header "Telcoin Network Node Health Check  v${SCRIPT_VERSION}"
print_info "Node type:    ${NODE_TYPE}"
print_info "Service:      ${SERVICE_NAME}"
print_info "Local RPC:    ${RPC_URL}"
[[ "$QUERY_NETWORK" == "true" ]] && print_info "Network RPC:  ${NETWORK_RPC}"
print_info "Time:         $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
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

# =============================================================================
# 2. LOCAL RPC PROBE
# =============================================================================
print_step "Probing local RPC..."
LOCAL_RPC_MODE=$(probe_local_rpc "$RPC_URL")
case "$LOCAL_RPC_MODE" in
    HEALTHY)
        print_ok "Local RPC responds to eth_chainId"
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
        print_info "(This is expected on observers that don't expose RPC publicly)"
        ;;
esac

# =============================================================================
# 3. NETWORK STATE (ground truth)
# =============================================================================
NETWORK_OK=false
if [[ "$QUERY_NETWORK" == "true" ]]; then
    print_step "Querying network consensus state (${NETWORK_RPC})..."
    CH_ERROR=""
    if fetch_consensus_header "$NETWORK_RPC" 15; then
        NETWORK_OK=true
        NET_BLOCK="$CH_BLOCK"
        NET_TS="$CH_TS"
        NET_EPOCH="$CH_EPOCH"
        NET_AUTHORS="$CH_AUTHORS"
        NET_REPS="$CH_REPS"
        NOW=$(date +%s)
        NET_AGE=$(( NOW - NET_TS ))
        print_ok "Network consensus current"
        print_info "  Block:           ${NET_BLOCK}"
        print_info "  Epoch:           ${NET_EPOCH}"
        committee_size=$(echo "$NET_AUTHORS" | wc -w)
        print_info "  Committee size:  ${committee_size}"
        print_info "  Commit age:      $(fmt_age "$NET_AGE")"
        if (( NET_AGE > STALE_THRESHOLD_SECONDS )); then
            print_warn "Network commit is older than ${STALE_THRESHOLD_SECONDS}s -- network may be quiet"
        fi
    else
        print_warn "Could not reach network RPC: ${CH_ERROR:-no response}"
        print_info "Skipping network-comparison checks. Use --no-network to silence this."
    fi
else
    print_info "Network query skipped (--no-network)"
fi

# =============================================================================
# 4. LOCAL CONSENSUS STATE (if local RPC is up)
# =============================================================================
LOCAL_CONSENSUS_OK=false
if [[ "$LOCAL_RPC_MODE" == "HEALTHY" ]] || [[ "$LOCAL_RPC_MODE" == "SLOW" ]]; then
    print_step "Querying local consensus state..."
    CH_ERROR=""
    if fetch_consensus_header "$RPC_URL" 8; then
        LOCAL_CONSENSUS_OK=true
        LOC_BLOCK="$CH_BLOCK"
        LOC_TS="$CH_TS"
        LOC_EPOCH="$CH_EPOCH"
        NOW=$(date +%s)
        LOC_AGE=$(( NOW - LOC_TS ))

        # Apply user's contract: block==0 -> stalled, age>60 -> stale
        if (( LOC_BLOCK == 0 )); then
            print_error "Local consensus block is 0 -- node is FULLY STALLED"
            (( ++HEALTH_ISSUES ))
        elif (( LOC_AGE > STALE_THRESHOLD_SECONDS )); then
            print_warn "Local consensus is STALE: ${LOC_AGE}s behind (threshold ${STALE_THRESHOLD_SECONDS}s)"
            (( ++HEALTH_ISSUES ))
        else
            print_ok "Local consensus current: block ${LOC_BLOCK} ($(fmt_age "$LOC_AGE"))"
        fi
        print_info "  Local epoch:     ${LOC_EPOCH}"

        # Lag vs network (only if we have both)
        if [[ "$NETWORK_OK" == "true" ]]; then
            lag=$(( NET_BLOCK - LOC_BLOCK ))
            if (( lag > 100 )); then
                print_warn "  Lag vs network:  ${lag} blocks behind"
            elif (( lag < -5 )); then
                print_info "  Lag vs network:  ${lag} blocks (local ahead -- clock or routing skew)"
            else
                print_ok "  Lag vs network:  ${lag} blocks"
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
else
    print_info "Skipping local consensus query (local RPC ${LOCAL_RPC_MODE})"
fi

# =============================================================================
# 5. EVM EXECUTION STATE (block + sync)
# Local: eth_blockNumber + eth_syncing  (skipped if local RPC unreachable)
# Network: highest latest_execution_block.number from the consensus headers
#          we already fetched in section 3 -- no extra network RPC call.
# =============================================================================
LOCAL_EXEC_BLOCK=""
NET_EXEC_BLOCK=""
[[ "$NETWORK_OK" == "true" ]] && NET_EXEC_BLOCK="$CH_EXEC_BLOCK"

if [[ "$LOCAL_RPC_MODE" == "HEALTHY" ]] || [[ "$LOCAL_RPC_MODE" == "SLOW" ]]; then
    print_step "Querying EVM execution state..."
    if LOCAL_EXEC_BLOCK=$(fetch_local_exec_block "$RPC_URL"); then
        print_ok "Local EVM block:    ${LOCAL_EXEC_BLOCK}"
    else
        print_warn "Could not query local eth_blockNumber"
        LOCAL_EXEC_BLOCK=""
    fi

    if [[ -n "$NET_EXEC_BLOCK" ]] && [[ "$NET_EXEC_BLOCK" != "0" ]]; then
        if [[ -n "$LOCAL_EXEC_BLOCK" ]]; then
            evm_lag=$(( NET_EXEC_BLOCK - LOCAL_EXEC_BLOCK ))
            if (( evm_lag > 100 )); then
                print_warn "Network EVM block:  ${NET_EXEC_BLOCK}  (${evm_lag} blocks behind)"
            elif (( evm_lag < -5 )); then
                print_info "Network EVM block:  ${NET_EXEC_BLOCK}  (local ahead by $(( -evm_lag )))"
            else
                print_ok "Network EVM block:  ${NET_EXEC_BLOCK}  (lag ${evm_lag})"
            fi
        else
            print_info "Network EVM block:  ${NET_EXEC_BLOCK}"
        fi
    fi

    sync_state=$(fetch_local_sync_state "$RPC_URL")
    case "$sync_state" in
        synced)
            print_ok "eth_syncing:        false (synced)"
            ;;
        syncing*)
            # syncing <current>/<highest>
            cur_hi="${sync_state#syncing }"
            cur="${cur_hi%/*}"
            hi="${cur_hi#*/}"
            behind=$(( hi - cur ))
            print_warn "eth_syncing:        IN PROGRESS at ${cur} / ${hi}  (${behind} behind)"
            (( ++HEALTH_ISSUES ))
            ;;
        err|*)
            print_info "eth_syncing:        could not determine"
            ;;
    esac
elif [[ -n "$NET_EXEC_BLOCK" ]] && [[ "$NET_EXEC_BLOCK" != "0" ]]; then
    print_step "EVM execution state (network only -- local RPC unreachable)..."
    print_info "Network EVM block:  ${NET_EXEC_BLOCK}"
    print_info "Local EVM block:    N/A (RPC ${LOCAL_RPC_MODE})"
fi

# =============================================================================
# 6. AUTHORITY-SPECIFIC CHECKS (author presence + own reputation)
# Uses NETWORK response so it still works if local RPC is closed.
# =============================================================================
if [[ "$NETWORK_OK" == "true" ]]; then
    AUTH_ID=$(detect_authority_id)
    if [[ -z "$AUTH_ID" ]]; then
        if [[ "$NODE_TYPE" == "validator" ]]; then
            echo ""
            print_info "Tip: pass --authority-id <BASE58> (or ensure node-info.yaml has primary_network_key)"
            print_info "to enable author-presence and reputation checks for this validator."
        fi
    else
        print_step "Checking your participation in network consensus..."
        print_info "Authority ID: ${AUTH_ID}"

        # Author presence: is your ID in the recent headers' author list?
        if echo " ${NET_AUTHORS} " | grep -qF " ${AUTH_ID} "; then
            print_ok "Your authority appears as an author in recent headers -- participating"
        else
            if [[ "$NODE_TYPE" == "validator" ]]; then
                # Observer nodes never author headers; only flag for validators.
                print_error "Your authority is NOT in recent headers -- node may be running but silent"
                print_info "  (committee was: ${NET_AUTHORS})"
                (( ++HEALTH_ISSUES ))
            else
                print_info "Your authority is not in recent headers (expected for observer node)"
            fi
        fi

        # Reputation: pull your own score from the reputation map
        own_rep=""
        committee_total=0
        committee_count=0
        for kv in $NET_REPS; do
            k="${kv%=*}"
            v="${kv#*=}"
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
        elif [[ "$NODE_TYPE" == "validator" ]]; then
            print_info "Your authority not present in reputation map (may not be in current committee)"
        fi
    fi
fi

# =============================================================================
# 7. ON-CHAIN VALIDATOR STATUS
# =============================================================================
if [[ "$NODE_TYPE" == "validator" ]] && [[ -n "$VALIDATOR_ADDRESS" ]]; then
    echo ""
    # Use network RPC for the on-chain call since local may be closed
    check_validator_onchain_status "$VALIDATOR_ADDRESS" "$NETWORK_RPC" || true
elif [[ "$NODE_TYPE" == "validator" ]]; then
    echo ""
    print_info "Tip: run with --address 0xYOUR_ADDRESS to check on-chain validator status."
fi

# =============================================================================
# 8. DISK
# =============================================================================
print_step "Checking disk space..."
DATA_DIR=$(detect_data_dir)
# Find the mount point that contains the data dir
DATA_MOUNT=$(df --output=target "$DATA_DIR" 2>/dev/null | tail -1)
mounts_to_check=("/" "$DATA_MOUNT")
# De-duplicate
seen=""
for mount_path in "${mounts_to_check[@]}"; do
    [[ -z "$mount_path" ]] && continue
    [[ " $seen " == *" $mount_path "* ]] && continue
    seen="$seen $mount_path"
    [[ -d "$mount_path" ]] || continue
    disk_info=$(df -BG --output=used,size,pcent "$mount_path" 2>/dev/null | awk 'NR==2 {gsub("G","",$1); gsub("G","",$2); print $1"G used / "$2"G total ("$3" full)"}')
    usage_pct=$(df --output=pcent "$mount_path" 2>/dev/null | awk 'NR==2 {gsub("%",""); print $1}')
    if [[ -n "$disk_info" ]] && [[ -n "$usage_pct" ]]; then
        if (( usage_pct >= 90 )); then
            print_error "Disk at ${mount_path}: ${disk_info} -- CRITICAL"
            (( ++HEALTH_ISSUES ))
        elif (( usage_pct >= 75 )); then
            print_warn "Disk at ${mount_path}: ${disk_info} -- getting full"
        else
            print_ok "Disk at ${mount_path}: ${disk_info}"
        fi
    fi
done
print_info "Data dir checked: ${DATA_DIR}  (mount: ${DATA_MOUNT:-unknown})"

# =============================================================================
# 9. MEMORY
# =============================================================================
print_step "Checking memory..."
MEM_TOTAL=$(grep MemTotal /proc/meminfo | awk '{print $2}')
MEM_AVAIL=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
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

# =============================================================================
# 10. SUMMARY
# =============================================================================
echo ""
print_sep
echo ""
if (( HEALTH_ISSUES == 0 )); then
    print_ok "All checks passed -- node appears healthy"
else
    print_warn "${HEALTH_ISSUES} issue(s) found -- review warnings/errors above"
fi
echo ""
