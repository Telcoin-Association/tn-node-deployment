#!/usr/bin/env bash
# =============================================================================
# check-node.sh -- Telcoin Network Node Health Check
#
# USAGE:
#   bash check-node.sh                              # check validator (default)
#   bash check-node.sh --observer                   # check observer node
#   bash check-node.sh --address 0xYOUR_ADDRESS     # include on-chain status
#   bash check-node.sh --rpc <URL>                  # custom RPC endpoint
#   bash check-node.sh --service <name>             # custom service name
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

readonly SCRIPT_VERSION="1.1.13"

RPC_URL="http://127.0.0.1:8545"
SERVICE_NAME="telcoin-validator"
VALIDATOR_ADDRESS=""
IS_OBSERVER=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --validator)  SERVICE_NAME="telcoin-validator"; RPC_URL="http://127.0.0.1:8545"; IS_OBSERVER=false; shift ;;
        --observer)   SERVICE_NAME="telcoin-observer";  RPC_URL="http://127.0.0.1:8541"; IS_OBSERVER=true;  shift ;;
        --rpc)        RPC_URL="$2";           shift 2 ;;
        --service)    SERVICE_NAME="$2";      shift 2 ;;
        --address)    VALIDATOR_ADDRESS="$2"; shift 2 ;;
        -h|--help)
            echo ""
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "  --validator              Check validator node (default)"
            echo "  --observer               Check observer node"
            echo "  --rpc <URL>              Custom RPC endpoint"
            echo "  --service <name>         Custom systemd service name"
            echo "  --address <0x...>        Validator address for on-chain status check"
            echo ""
            echo "Examples:"
            echo "  $0                                           # check validator"
            echo "  $0 --observer                                # check observer"
            echo "  $0 --address 0xYOUR_VALIDATOR_ADDRESS        # with on-chain status"
            echo ""
            exit 0
            ;;
        *) print_warn "Unknown argument: $1"; shift ;;
    esac
done

HEALTH_ISSUES=0

print_header "Telcoin Network Node Health Check"
print_info "Service:   ${SERVICE_NAME}"
print_info "RPC:       ${RPC_URL}"
print_info "Time:      $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo ""

# --- Service status ---
print_step "Checking systemd service..."
if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
    print_ok "Service '${SERVICE_NAME}' is running"
    local_uptime=$(systemctl show "$SERVICE_NAME" --property=ActiveEnterTimestamp 2>/dev/null | cut -d= -f2)
    [[ -n "$local_uptime" ]] && print_info "Running since: ${local_uptime}"
else
    print_error "Service '${SERVICE_NAME}' is NOT running"
    print_info "Start it: systemctl start ${SERVICE_NAME}"
    print_info "Logs:     journalctl -u ${SERVICE_NAME} --no-pager -n 30"
    (( HEALTH_ISSUES++ ))
fi

# --- RPC check ---
print_step "Checking RPC endpoint..."
RPC_RESPONSE=$(curl -s --max-time 5 -X POST \
    -H "Content-Type: application/json" \
    --data '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' \
    "$RPC_URL" 2>/dev/null || echo "")

if echo "$RPC_RESPONSE" | grep -q '"result"'; then
    CHAIN_ID_HEX=$(echo "$RPC_RESPONSE" | grep -o '"result":"[^"]*"' | cut -d'"' -f4)
    CHAIN_ID_DEC=$(( 16#${CHAIN_ID_HEX#0x} ))
    print_ok "RPC responding. Chain ID: ${CHAIN_ID_DEC}"
else
    print_error "RPC not responding at ${RPC_URL}"
    (( HEALTH_ISSUES++ ))
fi

# --- Sync status ---
print_step "Checking sync status..."
SYNC_RESPONSE=$(curl -s --max-time 5 -X POST \
    -H "Content-Type: application/json" \
    --data '{"jsonrpc":"2.0","method":"eth_syncing","params":[],"id":1}' \
    "$RPC_URL" 2>/dev/null || echo "")

# --- Block number ---
print_step "Checking latest block..."
BLOCK_RESPONSE=$(curl -s --max-time 5 -X POST \
    -H "Content-Type: application/json" \
    --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
    "$RPC_URL" 2>/dev/null || echo "")

BLOCK_NUM=0
if echo "$BLOCK_RESPONSE" | grep -q '"result"'; then
    BLOCK_HEX=$(echo "$BLOCK_RESPONSE" | grep -o '"result":"[^"]*"' | cut -d'"' -f4)
    BLOCK_NUM=$(( 16#${BLOCK_HEX#0x} ))
fi

if echo "$SYNC_RESPONSE" | grep -q '"result":false'; then
    if [[ $BLOCK_NUM -eq 0 ]]; then
        print_warn "Node reports synced but is at block 0 -- may still be catching up"
        print_info "This is expected on Adiri testnet until state sync PRs are merged"
    else
        print_ok "Node is synced at block ${BLOCK_NUM}"
    fi
elif echo "$SYNC_RESPONSE" | grep -q '"currentBlock"'; then
    CURRENT_HEX=$(echo "$SYNC_RESPONSE" | grep -o '"currentBlock":"[^"]*"' | cut -d'"' -f4)
    HIGHEST_HEX=$(echo "$SYNC_RESPONSE" | grep -o '"highestBlock":"[^"]*"' | cut -d'"' -f4)
    CURRENT=$(( 16#${CURRENT_HEX#0x} ))
    HIGHEST=$(( 16#${HIGHEST_HEX#0x} ))
    print_warn "Syncing: block ${CURRENT} / ${HIGHEST} ($(( HIGHEST - CURRENT )) behind)"
else
    print_warn "Could not determine sync status."
fi

if [[ $BLOCK_NUM -gt 0 ]]; then
    print_ok "Latest block: ${BLOCK_NUM}"
else
    print_info "Latest block: 0"
fi

# --- Peer count ---
print_step "Checking peers..."

# Determine log file based on service name
LOG_FILE="/var/log/telcoin/${SERVICE_NAME}.log"

# Get consensus peer count from log heartbeat
CONSENSUS_PEERS=""
if [[ -f "$LOG_FILE" ]]; then
    CONSENSUS_PEERS=$(grep "peer metrics heartbeat" "$LOG_FILE" 2>/dev/null | \
        tail -1 | grep -o "connected_count=[0-9]*" | cut -d= -f2)
fi

# Get unique P2P peers since node started from log file
P2P_RECENT=0
if [[ -f "$LOG_FILE" ]]; then
    P2P_RECENT=$(grep "new connection established" "$LOG_FILE" 2>/dev/null | \
        grep -oE 'send_back_addr: /ip[46]/[0-9a-f:.]+/' | \
        sort -u | wc -l 2>/dev/null || echo "0")
    P2P_RECENT=$(echo "$P2P_RECENT" | tr -d '[:space:]')
    [[ "$P2P_RECENT" =~ ^[0-9]+$ ]] || P2P_RECENT=0
fi

if [[ "$IS_OBSERVER" == "true" ]]; then
    if [[ -n "$CONSENSUS_PEERS" ]] && [[ "$CONSENSUS_PEERS" -gt 0 ]]; then
        print_ok "Consensus peers: ${CONSENSUS_PEERS}"
    else
        print_info "Consensus peers: ${CONSENSUS_PEERS:-0}"
        print_info "If this stays at 0 check UDP ports 49590/49594 are open inbound"
    fi
    print_info "Unique P2P peers (since startup): ${P2P_RECENT}"
    if [[ ${P2P_RECENT} -gt 0 ]]; then
        print_ok "P2P activity confirms network connectivity"
    else
        print_info "No unique P2P peers in last 5 min -- node may be between connection cycles"
    fi
    print_info "Note: net_peerCount via RPC reflects consensus peers only."
    print_info "      Peer data is read from log file: ${LOG_FILE}"
else
    # Validator
    if [[ -n "$CONSENSUS_PEERS" ]] && [[ $CONSENSUS_PEERS -gt 0 ]]; then
        print_ok "Consensus peers: ${CONSENSUS_PEERS}"
    else
        print_warn "Consensus peers: 0 -- validator may not yet be active in committee"
        print_info "Also check UDP ports 49590/49594 are open inbound"
    fi
    print_info "Unique P2P peers (since startup): ${P2P_RECENT}"
    print_info "Note: Peer data is read from log file: ${LOG_FILE}"
fi

# --- Disk space ---
print_step "Checking disk space..."
for mount_path in "/" "/var/lib/telcoin"; do
    if [[ -d "$mount_path" ]]; then
        disk_info=$(df -BG "$mount_path" 2>/dev/null | awk 'NR==2 {print $3" used / "$2" total ("$5" full)"}')
        usage_pct=$(df -BG "$mount_path" 2>/dev/null | awk 'NR==2 {gsub("%",""); print $5}')
        if [[ -n "$disk_info" ]]; then
            if [[ $usage_pct -ge 90 ]]; then
                print_error "Disk at ${mount_path}: ${disk_info} -- CRITICAL"
                (( HEALTH_ISSUES++ ))
            elif [[ $usage_pct -ge 75 ]]; then
                print_warn "Disk at ${mount_path}: ${disk_info} -- getting full"
            else
                print_ok "Disk at ${mount_path}: ${disk_info}"
            fi
        fi
    fi
done

# --- Memory ---
print_step "Checking memory..."
MEM_TOTAL=$(grep MemTotal /proc/meminfo | awk '{print $2}')
MEM_AVAIL=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
MEM_USED=$(( MEM_TOTAL - MEM_AVAIL ))
MEM_PCT=$(( MEM_USED * 100 / MEM_TOTAL ))
MEM_USED_GB=$(( MEM_USED / 1024 / 1024 ))
MEM_TOTAL_GB=$(( MEM_TOTAL / 1024 / 1024 ))

if [[ $MEM_PCT -ge 95 ]]; then
    print_error "Memory: ${MEM_USED_GB}GB / ${MEM_TOTAL_GB}GB (${MEM_PCT}%) -- CRITICAL"
    (( HEALTH_ISSUES++ ))
elif [[ $MEM_PCT -ge 85 ]]; then
    print_warn "Memory: ${MEM_USED_GB}GB / ${MEM_TOTAL_GB}GB (${MEM_PCT}%) -- high"
else
    print_ok "Memory: ${MEM_USED_GB}GB / ${MEM_TOTAL_GB}GB (${MEM_PCT}%)"
fi

# --- Validator on-chain status (only for validator nodes with an address provided) ---
if [[ "$IS_OBSERVER" == "false" ]] && [[ -n "$VALIDATOR_ADDRESS" ]]; then
    echo ""
    check_validator_onchain_status "$VALIDATOR_ADDRESS" "$RPC_URL"
elif [[ "$IS_OBSERVER" == "false" ]] && [[ -z "$VALIDATOR_ADDRESS" ]]; then
    echo ""
    print_info "Tip: Run with --address 0xYOUR_ADDRESS to check your on-chain validator status."
fi

# --- Result ---
echo ""
print_sep
echo ""
if [[ $HEALTH_ISSUES -eq 0 ]]; then
    print_ok "All checks passed -- node appears healthy"
else
    print_warn "${HEALTH_ISSUES} issue(s) found -- review warnings above"
fi
echo ""
