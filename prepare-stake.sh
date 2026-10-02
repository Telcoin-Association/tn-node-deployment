#!/usr/bin/env bash
# =============================================================================
# prepare-stake.sh -- Check that this node can stake, and print the commands
#
# Run it on the node once it has keys (setup-node.sh). It takes the validator
# address from node-info.yaml and checks, in this order: that the network RPC
# serves this node's chain, that the address holds the ConsensusNFT (the
# governance whitelist), its validator status, the stake amount the registry
# asks for, the address's TEL balance, the stake() calldata keytool exports, a
# simulation of stake() from the address (eth_estimateGas), and how far this
# node trails the network. Then it prints the exact `cast send` commands for
# stake() and activate(), to run on the machine that holds the validator wallet.
#
# It never reads, asks for or prints a private key, and it never sends a
# transaction: it prints the commands and you run them.
#
# --rotate-address re-signs the node's proof of possession for another
# execution address with `keytool generate pop`. The BLS key stays the same;
# node-info.yaml and VALIDATOR_ADDRESS in .node-meta change, and the node
# restarts. It is refused once the current address has staked, because a
# registered BLS key cannot move to another address, when the new address has
# staked or is retired, and while update-node.sh is applying an update (the two
# share the update lock). The BLS key passphrase comes from
# TN_BLS_PASSPHRASE, then <config dir>/bls-passphrase, then a prompt on the
# terminal. It only ever reaches keytool through the environment, never a
# command line.
#
# USAGE:
#   sudo bash prepare-stake.sh [--network-rpc <URL>] [--json]
#   sudo bash prepare-stake.sh --rotate-address <0xNEW> [--yes] [--no-restart]
#                              [--network-rpc <URL>] [--json]
#
# EXIT CODES:
#   0  ready to stake, staked and ready to activate, nothing to do, or rotated
#   1  usage or environment: a bad flag, not root, no node-info.yaml, no way
#      to run keytool, no passphrase, a restart that failed
#   2  the network RPC could not be reached, serves another chain, or the
#      on-chain state could not be read
#   3  not ready or refused: not whitelisted, short of TEL, the simulation
#      reverts, or a rotation that cannot be done now (an address has staked,
#      an update is in progress, or the confirmation was declined)
#   4  the rotation failed and node-info.yaml was put back as it was
# =============================================================================

# Take the BLS key passphrase out of the environment before any command runs,
# so nothing this script starts inherits it. Only --rotate-address uses the
# private copy, for its one keytool call. The unset also drops an export flag
# these names may have arrived with.
unset PS_PASS PS_ENV_PASS
PS_ENV_PASS="${TN_BLS_PASSPHRASE:-}"
unset TN_BLS_PASSPHRASE

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
if ! version_gte "${COMMON_VERSION:-0}" "1.6.0"; then
    _tn_old="lib/common.sh ${COMMON_VERSION:-unknown} is older than 1.6.0. Run update-scripts.sh and try again."
    case " $* " in
        *" --json "*) printf '{"event":"error","msg":"%s"}\n{"event":"done","ok":false,"msg":"%s"}\n' "$_tn_old" "$_tn_old" ;;
        *) printf '[ERROR] %s\n' "$_tn_old" >&2 ;;
    esac
    exit 1
fi

readonly SCRIPT_VERSION="1.0.0"

# lib/common.sh turns on errexit. Every step here checks its own result and
# says what went wrong, so errexit stays off; nounset and pipefail stay on.
set +e
set -u

# ConsensusRegistry selectors this script adds to the ones in lib/common.sh.
readonly STAKE_SELECTOR="0x2fb0d025"        # stake(bytes,(bytes))
readonly BALANCE_OF_SELECTOR="0x70a08231"   # balanceOf(address)
# Gas the balance check allows for on top of the stake. stake() itself uses a
# few hundred thousand; the simulation reports the real figure.
readonly STAKE_GAS_ALLOWANCE=1000000
# Blocks this node may trail the network before the sync warning.
readonly SYNC_LAG_BLOCKS=50

# Options.
PS_JSON=0
PS_YES=0
PS_NO_RESTART=0
PS_ROTATE=""
PS_NETWORK_RPC_ARG=""

# How the run ended, for the final JSON object (set by ps_done / ps_fail).
PS_STATE=""
PS_MSG=""
PS_JSON_SENT=0
PS_WARNINGS=""

# The node, set by ps_resolve_node.
CONFIG_DIR=""
DATA_DIR=""
NODE_INFO=""
META_FILE=""
META_ADDR=""
NETWORK=""
NETWORK_SRC=""
EXPECTED_CHAIN_ID=""
NETWORK_RPC=""
SERVICE=""
RUNNER=""

# Values the checks compute. Wei amounts are decimal strings: they do not fit
# in 64 bits, so they never go through bash arithmetic.
NET_CHAIN_ID=""
ADDR=""
ADDR_CS=""
NFT_BALANCE=""
WHITELISTED=""
STATUS_LINE=""
STATUS_RC=""
STAKE_WEI=""
STAKE_TEL=""
STAKE_HEX=""
STAKE_VERSION=""
BALANCE_WEI=""
GAS_PRICE_WEI=""
GAS_ALLOWANCE_WEI=""
NEED_WEI=""
BALANCE_OK=""
CALLDATA=""
SIM_RESULT=""
SIM_ERROR=""
SIM_GAS=""
LOCAL_RPC=""
LOCAL_BLOCK=""
NET_BLOCK=""
SYNC_LAG=""
EPOCH=""
EPOCH_SECS_LEFT=""
ACTIVATION_EPOCH=""
SEAT_EPOCH=""
CMD_STAKE=""
CMD_ACTIVATE=""
NOT_READY=""

# Rotation.
NEW_ADDR=""
NEW_CS=""
OLD_ADDR=""
BACKUP=""
RESTARTED=""
PS_PASS=""
# Where a rotation stands, for a run ended by a signal: "window" from the
# node-info.yaml backup until the re-signed file has been checked, "rotated"
# after that. PS_KT_PID is the keytool job while it runs; PS_SIGNAL names the
# signal that ended the run.
PS_PHASE=""
PS_KT_PID=""
PS_SIGNAL=""

# =============================================================================
# OUTPUT
# =============================================================================

ps_warn() {
    print_warn "$1"
    PS_WARNINGS="${PS_WARNINGS}${1}"$'\n'
}

# ps_done CODE STATE MESSAGE -- the verdict line, then exit CODE. 0 is a
# success; anything else is reported as an error.
ps_done() {
    PS_STATE="$2"
    PS_MSG="$3"
    if [[ "$1" -eq 0 ]]; then
        echo ""
        print_ok "$3"
        echo ""
    else
        print_error "$3"
    fi
    exit "$1"
}

# ps_fail CODE MESSAGE -- a check that could not finish: error, then exit CODE.
ps_fail() {
    PS_STATE="error"
    PS_MSG="$2"
    print_error "$2"
    exit "$1"
}

# ps_json_str TEXT -- TEXT as a JSON string literal.
ps_json_str() {
    local s="${1:-}"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\t'/\\t}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\n'/\\n}"
    s="$(printf '%s' "$s" | LC_ALL=C tr -d '\000-\010\013\014\016-\037\177')"
    printf '"%s"' "$s"
}

# ps_jf KEY VALUE TYPE -- one "KEY":VALUE member. TYPE s is a string, n a
# number, b true/false; an empty VALUE (or a number that is not one) is null.
ps_jf() {
    local key="$1" val="${2:-}" type="${3:-s}"
    printf '"%s":' "$key"
    if [[ -z "$val" ]]; then
        printf 'null'
        return 0
    fi
    case "$type" in
        n) if [[ "$val" =~ ^-?[0-9]+$ ]]; then printf '%s' "$val"; else printf 'null'; fi ;;
        b) if [[ "$val" == "true" || "$val" == "false" ]]; then printf '%s' "$val"; else printf 'null'; fi ;;
        *) ps_json_str "$val" ;;
    esac
}

# ps_json_object CODE -- the single JSON object a --json run prints at the end.
# Large numbers (wei, block numbers) are strings, so no JSON reader rounds them.
ps_json_object() {
    local code="$1" ok="false" w warns="" line
    [[ "$code" -eq 0 ]] && ok="true"
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        warns="${warns:+${warns},}$(ps_json_str "$line")"
    done <<<"$PS_WARNINGS"
    w="{\"event\":\"done\",\"ok\":${ok}"
    w="${w},$(ps_jf exit "$code" n),$(ps_jf state "${PS_STATE:-error}"),$(ps_jf msg "$PS_MSG")"
    w="${w},$(ps_jf script_version "$SCRIPT_VERSION")"
    w="${w},$(ps_jf network "$NETWORK"),$(ps_jf network_source "$NETWORK_SRC")"
    w="${w},$(ps_jf expected_chain_id "$EXPECTED_CHAIN_ID" n),$(ps_jf network_rpc "$NETWORK_RPC")"
    w="${w},$(ps_jf chain_id "$NET_CHAIN_ID" n)"
    w="${w},$(ps_jf config_dir "$CONFIG_DIR"),$(ps_jf data_dir "$DATA_DIR"),$(ps_jf node_info "$NODE_INFO")"
    w="${w},$(ps_jf runner "$RUNNER"),$(ps_jf service "$SERVICE")"
    w="${w},$(ps_jf address "$ADDR"),$(ps_jf address_checksum "$ADDR_CS"),$(ps_jf meta_address "$META_ADDR")"
    w="${w},$(ps_jf whitelisted "$WHITELISTED" b),$(ps_jf nft_balance "$NFT_BALANCE")"
    w="${w},$(ps_jf status "$STATUS_LINE")"
    w="${w},$(ps_jf stake_wei "$STAKE_WEI"),$(ps_jf stake_tel "$STAKE_TEL"),$(ps_jf stake_version "$STAKE_VERSION" n)"
    w="${w},$(ps_jf balance_wei "$BALANCE_WEI"),$(ps_jf gas_price_wei "$GAS_PRICE_WEI")"
    w="${w},$(ps_jf gas_allowance_wei "$GAS_ALLOWANCE_WEI"),$(ps_jf needed_wei "$NEED_WEI"),$(ps_jf balance_ok "$BALANCE_OK" b)"
    w="${w},$(ps_jf calldata "$CALLDATA")"
    w="${w},$(ps_jf simulation "$SIM_RESULT"),$(ps_jf simulation_error "$SIM_ERROR"),$(ps_jf simulation_gas "$SIM_GAS")"
    w="${w},$(ps_jf local_rpc "$LOCAL_RPC"),$(ps_jf local_block "$LOCAL_BLOCK"),$(ps_jf network_block "$NET_BLOCK"),$(ps_jf sync_lag "$SYNC_LAG" n)"
    w="${w},$(ps_jf epoch "$EPOCH" n),$(ps_jf epoch_secs_left "$EPOCH_SECS_LEFT" n)"
    w="${w},$(ps_jf activation_epoch "$ACTIVATION_EPOCH" n),$(ps_jf earliest_seat_epoch "$SEAT_EPOCH" n)"
    w="${w},$(ps_jf stake_command "$CMD_STAKE"),$(ps_jf activate_command "$CMD_ACTIVATE")"
    w="${w},$(ps_jf old_address "$OLD_ADDR"),$(ps_jf new_address "$NEW_CS"),$(ps_jf backup "$BACKUP"),$(ps_jf restarted "$RESTARTED" b)"
    w="${w},\"warnings\":[${warns}]}"
    printf '%s\n' "$w"
}

# ps_on_interrupt -- the run was ended by a signal (PS_SIGNAL). Inside the
# rotation window, wait for the keytool job first (it ignores the signal, so it
# never stops half way through writing node-info.yaml), then put node-info.yaml
# back from the backup. The EXIT trap releases the update lock only after this,
# so nothing edits node-info.yaml once the lock is gone.
ps_on_interrupt() {
    local why="Interrupted by SIG${PS_SIGNAL}"
    if [[ -n "$PS_KT_PID" ]]; then
        wait "$PS_KT_PID" 2>/dev/null
        PS_KT_PID=""
    fi
    case "$PS_PHASE" in
        window)
            if cp -p "$BACKUP" "$NODE_INFO" 2>/dev/null; then
                chown "${NI_UID}:${NI_GID}" "$NODE_INFO" 2>/dev/null || true
                chmod "$NI_MODE" "$NODE_INFO" 2>/dev/null || true
                PS_MSG="${why} while the proof of possession was being signed; node-info.yaml is back as it was (from ${BACKUP})."
            else
                PS_MSG="${why} while the proof of possession was being signed, and putting node-info.yaml back failed: copy ${BACKUP} over ${NODE_INFO} by hand."
            fi
            ;;
        rotated)
            PS_MSG="${why} after node-info.yaml was signed for ${NEW_CS}; .node-meta and the restart may not have caught up. To finish, run: sudo bash prepare-stake.sh --rotate-address ${NEW_CS} --yes"
            ;;
        *)
            PS_MSG="${why}; nothing was changed."
            ;;
    esac
    PS_PHASE=""
    PS_STATE="interrupted"
    print_error "$PS_MSG"
}

# EXIT trap: ignore further signals, forget the passphrase, finish an
# interrupted rotation (ps_on_interrupt), release the update lock a rotation
# took (a no-op when none is held), then (--json) print the final object on
# the saved stdout, whatever way the run ends.
ps_on_exit() {
    local code=$?
    trap '' TERM INT HUP
    PS_PASS=""
    PS_ENV_PASS=""
    unset TN_BLS_PASSPHRASE
    if [[ -n "$PS_SIGNAL" ]]; then
        ps_on_interrupt
    fi
    tn_release_update_lock
    if [[ "$PS_JSON" -eq 1 && "$PS_JSON_SENT" -eq 0 ]]; then
        PS_JSON_SENT=1
        ps_json_object "$code" >&3
    fi
    return 0
}

ps_usage() {
    cat <<EOF

Usage:
  sudo bash prepare-stake.sh [--network-rpc <URL>] [--json]
  sudo bash prepare-stake.sh --rotate-address <0xNEW> [--yes] [--no-restart]
                             [--network-rpc <URL>] [--json]

Checks that this node can stake: the network, the whitelist (ConsensusNFT),
the validator status, the stake amount, the TEL balance, the stake() calldata
and a simulation of stake(). Then prints the cast commands for stake() and
activate(). Nothing is sent and no private key is read, asked for or printed:
run the printed commands on the machine that holds the validator wallet.

  --network-rpc <URL>       Network RPC to read the chain from. Default: the
                            public RPC of the network in .node-meta (testnet
                            ${TESTNET_RPC_URL}, mainnet ${MAINNET_RPC_URL},
                            devnet ${DEVNET_RPC_URL})
  --json                    Human output on stderr, and one JSON object on
                            stdout at the end with every value the run read
  --rotate-address <0xNEW>  Re-sign the proof of possession in node-info.yaml
                            for 0xNEW (the BLS key stays the same), record it
                            in .node-meta and restart the node. Refused once
                            the current address has staked, and while an
                            update is running.
  --yes                     Rotate without asking first (needed with --json)
  --no-restart              Rotate without restarting the node

Rotation needs the BLS key passphrase: from TN_BLS_PASSPHRASE, else the
bls-passphrase file in the config dir, else a prompt. sudo drops
TN_BLS_PASSPHRASE unless you run sudo --preserve-env=TN_BLS_PASSPHRASE.

Exit codes: 0 ready, staked (activate next), nothing to do, or rotated;
1 usage or environment; 2 network RPC unreachable, wrong chain, or on-chain
state unreadable; 3 not ready or refused; 4 rotation failed and node-info.yaml
was restored.

EOF
}

# =============================================================================
# NUMBERS AND ADDRESSES
# =============================================================================
#
# Wei amounts are decimal strings of up to 78 digits. The helpers below work on
# one digit or one 9-digit limb at a time, so no bash arithmetic ever holds more
# than about 2^31; the library's tn_hex_to_dec and tn_wei_to_tel do the rest.

# ps_dec_norm DEC -- DEC without leading zeros ("0" for zero).
ps_dec_norm() {
    local d="${1:-0}"
    d="${d#"${d%%[!0]*}"}"
    printf '%s\n' "${d:-0}"
}

# ps_dec_cmp A B -- print -1, 0 or 1 as A is less than, equal to or above B.
ps_dec_cmp() {
    local a b
    a="$(ps_dec_norm "${1:-0}")"
    b="$(ps_dec_norm "${2:-0}")"
    if [[ ${#a} -ne ${#b} ]]; then
        if [[ ${#a} -lt ${#b} ]]; then echo -1; else echo 1; fi
    elif [[ "$a" == "$b" ]]; then
        echo 0
    elif [[ "$a" < "$b" ]]; then
        echo -1
    else
        echo 1
    fi
}

# ps_dec_add A B -- A + B.
ps_dec_add() {
    local a b out="" carry=0 x y s
    a="$(ps_dec_norm "${1:-0}")"
    b="$(ps_dec_norm "${2:-0}")"
    while [[ -n "$a" || -n "$b" || "$carry" -ne 0 ]]; do
        x=0
        y=0
        if [[ ${#a} -gt 9 ]]; then x="${a:${#a}-9}"; a="${a:0:${#a}-9}"; elif [[ -n "$a" ]]; then x="$a"; a=""; fi
        if [[ ${#b} -gt 9 ]]; then y="${b:${#b}-9}"; b="${b:0:${#b}-9}"; elif [[ -n "$b" ]]; then y="$b"; b=""; fi
        s=$(( 10#$x + 10#$y + carry ))
        carry=$(( s / 1000000000 ))
        printf -v x '%09d' $(( s % 1000000000 ))
        out="${x}${out}"
    done
    ps_dec_norm "$out"
}

# ps_dec_sub A B -- A - B, for A >= B.
ps_dec_sub() {
    local a b out="" borrow=0 x y s
    a="$(ps_dec_norm "${1:-0}")"
    b="$(ps_dec_norm "${2:-0}")"
    while [[ -n "$a" ]]; do
        x=0
        y=0
        if [[ ${#a} -gt 9 ]]; then x="${a:${#a}-9}"; a="${a:0:${#a}-9}"; else x="$a"; a=""; fi
        if [[ ${#b} -gt 9 ]]; then y="${b:${#b}-9}"; b="${b:0:${#b}-9}"; elif [[ -n "$b" ]]; then y="$b"; b=""; fi
        s=$(( 10#$x - 10#$y - borrow ))
        if [[ "$s" -lt 0 ]]; then s=$(( s + 1000000000 )); borrow=1; else borrow=0; fi
        printf -v x '%09d' "$s"
        out="${x}${out}"
    done
    ps_dec_norm "$out"
}

# ps_dec_mul DEC N -- DEC times N, where N has at most 9 digits.
ps_dec_mul() {
    local a n out="" carry=0 x s
    a="$(ps_dec_norm "${1:-0}")"
    n="$(ps_dec_norm "${2:-0}")"
    [[ "$n" =~ ^[0-9]{1,9}$ ]] || return 1
    while [[ -n "$a" || "$carry" -ne 0 ]]; do
        x=0
        if [[ ${#a} -gt 9 ]]; then x="${a:${#a}-9}"; a="${a:0:${#a}-9}"; elif [[ -n "$a" ]]; then x="$a"; a=""; fi
        s=$(( 10#$x * 10#$n + carry ))
        carry=$(( s / 1000000000 ))
        printf -v x '%09d' $(( s % 1000000000 ))
        out="${x}${out}"
    done
    ps_dec_norm "$out"
}

# ps_dec_to_hex DEC -- DEC as a 0x-prefixed hex quantity (JSON-RPC style),
# by long division by 16, one decimal digit at a time.
ps_dec_to_hex() {
    local dec digits="0123456789abcdef" hex="" q r i d
    dec="$(ps_dec_norm "${1:-}")"
    [[ "$dec" =~ ^[0-9]+$ ]] || return 1
    while [[ "$dec" != "0" ]]; do
        q=""
        r=0
        i=0
        while [[ "$i" -lt ${#dec} ]]; do
            d=$(( r * 10 + ${dec:i:1} ))
            q="${q}$(( d / 16 ))"
            r=$(( d % 16 ))
            i=$(( i + 1 ))
        done
        hex="${digits:r:1}${hex}"
        dec="${q#"${q%%[!0]*}"}"
        dec="${dec:-0}"
    done
    printf '0x%s\n' "${hex:-0}"
}

# ps_lower TEXT -- TEXT in lower case (bash 3.2 has no case-changing expansion).
ps_lower() {
    printf '%s\n' "${1:-}" | tr '[:upper:]' '[:lower:]'
}

# ps_is_addr TEXT -- rc 0 for 0x and 40 hex digits.
ps_is_addr() {
    [[ "${1:-}" =~ ^0x[0-9a-fA-F]{40}$ ]]
}

# ps_keccak256_hex TEXT -- Keccak-256 (the Ethereum hash, not FIPS SHA3-256) of
# an ASCII TEXT shorter than 136 bytes, as 64 hex digits. Used only for the
# EIP-55 checksum of an address, so nothing on the node needs cast or a Python
# crypto module. Keccak-f[1600] on 64-bit lanes: bash arithmetic is 64-bit
# two's complement, and a right shift is masked to make it logical.
ps_keccak256_hex() {
    local msg="${1:-}" n i j r t c x y lane out
    local -a ks=() bc=() rc=() rotc=() piln=()
    n=${#msg}
    [[ "$n" -lt 136 ]] || return 1
    rc=(0x0000000000000001 0x0000000000008082 0x800000000000808a 0x8000000080008000
        0x000000000000808b 0x0000000080000001 0x8000000080008081 0x8000000000008009
        0x000000000000008a 0x0000000000000088 0x0000000080008009 0x000000008000000a
        0x000000008000808b 0x800000000000008b 0x8000000000008089 0x8000000000008003
        0x8000000000008002 0x8000000000000080 0x000000000000800a 0x800000008000000a
        0x8000000080008081 0x8000000000008080 0x0000000080000001 0x8000000080008008)
    rotc=(1 3 6 10 15 21 28 36 45 55 2 14 27 41 56 8 25 43 62 18 39 61 20 44)
    piln=(10 7 11 17 18 3 5 16 8 21 24 4 15 23 19 13 12 2 20 14 22 9 6 1)
    i=0
    while [[ "$i" -lt 25 ]]; do ks[i]=0; i=$(( i + 1 )); done
    # Absorb the text and the padding (0x01 after it, 0x80 in the last byte of
    # the 136-byte block) into the first 17 lanes, little-endian.
    i=0
    while [[ "$i" -lt "$n" ]]; do
        printf -v c '%d' "'${msg:i:1}"
        [[ "$c" -ge 0 && "$c" -lt 128 ]] || return 1
        ks[i/8]=$(( ks[i/8] ^ (c << (8 * (i % 8))) ))
        i=$(( i + 1 ))
    done
    ks[n/8]=$(( ks[n/8] ^ (1 << (8 * (n % 8))) ))
    ks[16]=$(( ks[16] ^ (0x80 << 56) ))
    r=0
    while [[ "$r" -lt 24 ]]; do
        # theta
        x=0
        while [[ "$x" -lt 5 ]]; do
            bc[x]=$(( ks[x] ^ ks[x+5] ^ ks[x+10] ^ ks[x+15] ^ ks[x+20] ))
            x=$(( x + 1 ))
        done
        x=0
        while [[ "$x" -lt 5 ]]; do
            c=${bc[(x+1)%5]}
            t=$(( bc[(x+4)%5] ^ ((c << 1) | ((c >> 63) & 1)) ))
            y=0
            while [[ "$y" -lt 25 ]]; do
                ks[y+x]=$(( ks[y+x] ^ t ))
                y=$(( y + 5 ))
            done
            x=$(( x + 1 ))
        done
        # rho and pi
        t=${ks[1]}
        i=0
        while [[ "$i" -lt 24 ]]; do
            j=${piln[i]}
            c=${ks[j]}
            x=${rotc[i]}
            ks[j]=$(( (t << x) | ((t >> (64 - x)) & ((1 << x) - 1)) ))
            t=$c
            i=$(( i + 1 ))
        done
        # chi
        y=0
        while [[ "$y" -lt 25 ]]; do
            x=0
            while [[ "$x" -lt 5 ]]; do bc[x]=${ks[y+x]}; x=$(( x + 1 )); done
            x=0
            while [[ "$x" -lt 5 ]]; do
                ks[y+x]=$(( bc[x] ^ ((~bc[(x+1)%5]) & bc[(x+2)%5]) ))
                x=$(( x + 1 ))
            done
            y=$(( y + 5 ))
        done
        # iota
        ks[0]=$(( ks[0] ^ rc[r] ))
        r=$(( r + 1 ))
    done
    out=""
    i=0
    while [[ "$i" -lt 4 ]]; do
        lane=${ks[i]}
        j=0
        while [[ "$j" -lt 8 ]]; do
            printf -v c '%02x' $(( (lane >> (8 * j)) & 255 ))
            out="${out}${c}"
            j=$(( j + 1 ))
        done
        i=$(( i + 1 ))
    done
    printf '%s\n' "$out"
}

# ps_checksum_address ADDR -- ADDR in EIP-55 mixed case, as wallets show it.
# Prints ADDR in lower case and returns 1 when the checksum cannot be made.
ps_checksum_address() {
    local a h out="" i c
    a="$(ps_lower "${1:-}")"
    a="${a#0x}"
    [[ "$a" =~ ^[0-9a-f]{40}$ ]] || { printf '%s\n' "${1:-}"; return 1; }
    h="$(ps_keccak256_hex "$a")" || { printf '0x%s\n' "$a"; return 1; }
    i=0
    while [[ "$i" -lt 40 ]]; do
        c="${a:i:1}"
        case "${h:i:1}" in
            [89abcdef])
                case "$c" in
                    a) c=A ;; b) c=B ;; c) c=C ;; d) c=D ;; e) c=E ;; f) c=F ;;
                esac
                ;;
        esac
        out="${out}${c}"
        i=$(( i + 1 ))
    done
    printf '0x%s\n' "$out"
}

# ps_checksum_ok ADDR -- rc 0 unless ADDR is mixed case with a wrong EIP-55
# checksum (a typo). All-lower and all-upper addresses carry no checksum.
ps_checksum_ok() {
    local hex="${1#0x}"
    [[ "$hex" =~ [a-f] && "$hex" =~ [A-F] ]] || return 0
    [[ "$(ps_checksum_address "$1")" == "0x${hex}" ]]
}

# ps_word_uint WORD -- a 32-byte hex word holding a small unsigned number
# (block, epoch, enum) in decimal; rc 1 when it does not fit in 60 bits.
ps_word_uint() {
    local w="${1#0x}"
    [[ "$w" =~ ^[0-9a-fA-F]{1,64}$ ]] || return 1
    while [[ ${#w} -gt 15 ]]; do
        [[ "${w:0:1}" == "0" ]] || return 1
        w="${w:1}"
    done
    printf '%s\n' "$(( 16#$w ))"
}

# ps_fmt_secs SECONDS -- "2h 5m", "4m 10s" or "12s".
ps_fmt_secs() {
    local s="${1:-0}"
    [[ "$s" =~ ^[0-9]+$ ]] || s=0
    if [[ "$s" -ge 3600 ]]; then
        printf '%sh %sm\n' $(( s / 3600 )) $(( s % 3600 / 60 ))
    elif [[ "$s" -ge 60 ]]; then
        printf '%sm %ss\n' $(( s / 60 )) $(( s % 60 ))
    else
        printf '%ss\n' "$s"
    fi
}

# =============================================================================
# RPC
# =============================================================================

# ps_rpc_raw URL METHOD PARAMS [MAX_TIME] -- one JSON-RPC POST, like
# tn_rpc_call, except that an answer holding an error object is returned too
# (rc 0, the body on one line), so a revert's data can be decoded. rc 1 with
# "transport <reason>", "http <code>" or "malformed <what>" otherwise.
ps_rpc_raw() {
    local url="${1:-}" method="${2:-}" params="${3:-[]}" max_time="${4:-15}"
    local body raw rc code resp nl
    nl=$'\n'
    body="{\"jsonrpc\":\"2.0\",\"method\":\"${method}\",\"params\":${params},\"id\":1}"
    rc=0
    raw="$(curl -sS --max-time "$max_time" -X POST \
        -H 'Content-Type: application/json' \
        --data "$body" -w '\n%{http_code}' --url "$url" 2>/dev/null)" || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        if declare -F _tn_curl_reason >/dev/null 2>&1; then
            printf 'transport %s\n' "$(_tn_curl_reason "$rc")"
        else
            printf 'transport curl-exit-%s\n' "$rc"
        fi
        return 1
    fi
    code="${raw##*"$nl"}"
    resp=""
    if [[ "$raw" == *"$nl"* ]]; then
        resp="${raw%"$nl"*}"
    fi
    if [[ ! "$code" =~ ^2[0-9][0-9]$ ]]; then
        printf 'http %s\n' "$(printf '%s' "$code" | tr -cd '0-9')"
        return 1
    fi
    resp="$(printf '%s' "$resp" | tr '\r\n' '  ')"
    if [[ "$resp" != *"{"* ]]; then
        printf 'malformed not-json\n'
        return 1
    fi
    printf '%s\n' "$resp"
}

# ps_call_word DATA -- eth_call DATA on the ConsensusRegistry through the
# network RPC and print the first 32-byte word of the result (64 hex digits).
# rc 1 with the reason on stdout.
ps_call_word() {
    local out rc re
    rc=0
    out="$(tn_rpc_call "$NETWORK_RPC" eth_call "[{\"to\":\"${CONSENSUS_REGISTRY}\",\"data\":\"${1}\"},\"latest\"]" 15)" || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        printf '%s\n' "$out"
        return 1
    fi
    re='"result"[[:space:]]*:[[:space:]]*"0x([0-9a-fA-F]{64})'
    if [[ ! "$out" =~ $re ]]; then
        printf 'malformed result\n'
        return 1
    fi
    printf '%s\n' "${BASH_REMATCH[1]}"
}

# ps_rpc_uint URL METHOD [PARAMS] -- a JSON-RPC call whose result is a hex
# quantity, printed in decimal (any size). rc 1 with the reason on stdout.
ps_rpc_uint() {
    local out rc hex dec
    rc=0
    out="$(tn_rpc_call "$1" "$2" "${3:-[]}" 15)" || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        printf '%s\n' "$out"
        return 1
    fi
    hex="$(tn_json_field "$out" result 2>/dev/null || true)"
    if [[ ! "$hex" =~ ^0x[0-9a-fA-F]{1,64}$ ]]; then
        printf 'malformed result\n'
        return 1
    fi
    dec="$(tn_hex_to_dec "$hex")" || { printf 'malformed result\n'; return 1; }
    printf '%s\n' "$dec"
}

# ps_chain_name ID -- testnet, mainnet or devnet for a Telcoin chain id.
ps_chain_name() {
    case "${1:-}" in
        "$TESTNET_CHAIN_ID") printf 'testnet\n' ;;
        "$MAINNET_CHAIN_ID") printf 'mainnet\n' ;;
        "$DEVNET_CHAIN_ID")  printf 'devnet\n' ;;
        *) printf 'not a Telcoin network\n' ;;
    esac
}

# =============================================================================
# SETUP
# =============================================================================

ps_parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --network-rpc|--rotate-address)
                if [[ $# -lt 2 || -z "$2" || "$2" == --* ]]; then
                    ps_fail 1 "$1 needs a value (see --help)."
                fi
                ;;
        esac
        case "$1" in
            --network-rpc)    PS_NETWORK_RPC_ARG="$2"; shift 2 ;;
            --rotate-address) PS_ROTATE="$2";          shift 2 ;;
            --json)           PS_JSON=1;               shift ;;
            --yes)            PS_YES=1;                shift ;;
            --no-restart)     PS_NO_RESTART=1;         shift ;;
            -h|--help)
                ps_usage
                PS_STATE="help"
                exit 0
                ;;
            *) ps_fail 1 "Unknown argument: $1 (see --help)." ;;
        esac
    done
    if [[ -n "$PS_NETWORK_RPC_ARG" ]] && ! validate_rpc_url "$PS_NETWORK_RPC_ARG" http; then
        ps_fail 1 "--network-rpc ${PS_NETWORK_RPC_ARG} is not an http:// or https:// URL."
    fi
    if [[ -z "$PS_ROTATE" ]]; then
        if [[ "$PS_YES" -eq 1 || "$PS_NO_RESTART" -eq 1 ]]; then
            ps_fail 1 "--yes and --no-restart only apply to --rotate-address."
        fi
        return 0
    fi
    if ! ps_is_addr "$PS_ROTATE"; then
        ps_fail 1 "--rotate-address ${PS_ROTATE} is not an address (0x and 40 hex digits)."
    fi
    if [[ "$PS_ROTATE" =~ ^0x0{40}$ ]]; then
        ps_fail 1 "--rotate-address cannot be the zero address."
    fi
    if ! ps_checksum_ok "$PS_ROTATE"; then
        ps_fail 1 "--rotate-address ${PS_ROTATE} has a wrong checksum (the mix of upper and lower case does not match); check it for a typo."
    fi
    if [[ "$PS_JSON" -eq 1 && "$PS_YES" -eq 0 ]]; then
        ps_fail 1 "--json --rotate-address needs --yes: a JSON run cannot ask first."
    fi
    return 0
}

# ps_is_root -- rc 0 when running as root. A function so tests can replace it.
ps_is_root() {
    [[ "$(id -u 2>/dev/null)" == "0" ]]
}

# Fill in the node this script works on: config and data dirs, node-info.yaml,
# the network (NETWORK in .node-meta, testnet when absent), its chain id and
# public RPC (or --network-rpc), the service and the recorded address.
ps_resolve_node() {
    local def_rpc=""
    CONFIG_DIR="$(tn_resolve_config_dir)"
    DATA_DIR="$(tn_resolve_data_dir)"
    NODE_INFO="${DATA_DIR}/node-info.yaml"
    META_FILE="$(node_meta_path 2>/dev/null || true)"
    NETWORK=""
    if [[ -n "$META_FILE" ]]; then
        NETWORK="$(meta_get NETWORK "$META_FILE" 2>/dev/null || true)"
        META_ADDR="$(meta_get VALIDATOR_ADDRESS "$META_FILE" 2>/dev/null || true)"
        NETWORK_SRC="from .node-meta"
        if [[ -z "$NETWORK" ]]; then
            NETWORK="testnet"
            NETWORK_SRC="default: no NETWORK in .node-meta"
        fi
    else
        NETWORK="testnet"
        NETWORK_SRC="default: no .node-meta"
    fi
    case "$NETWORK" in
        testnet) EXPECTED_CHAIN_ID="$TESTNET_CHAIN_ID"; def_rpc="$TESTNET_RPC_URL" ;;
        mainnet) EXPECTED_CHAIN_ID="$MAINNET_CHAIN_ID"; def_rpc="$MAINNET_RPC_URL" ;;
        devnet)  EXPECTED_CHAIN_ID="$DEVNET_CHAIN_ID";  def_rpc="$DEVNET_RPC_URL" ;;
        *) ps_fail 1 "NETWORK=${NETWORK} in ${META_FILE} is not testnet, mainnet or devnet." ;;
    esac
    NETWORK_RPC="${PS_NETWORK_RPC_ARG:-$def_rpc}"
    if [[ -z "$NETWORK_RPC" ]]; then
        ps_fail 1 "There is no public RPC for ${NETWORK}; pass --network-rpc <URL>."
    fi
    SERVICE="$(tn_resolve_service 2>/dev/null || true)"
    LOCAL_RPC="$(tn_local_rpc_url)"

    print_step "Node"
    print_info "Config dir:   ${CONFIG_DIR}"
    print_info "node-info:    ${NODE_INFO}"
    print_info "Network:      ${NETWORK} (chain ${EXPECTED_CHAIN_ID}, ${NETWORK_SRC})"
    print_info "Network RPC:  ${NETWORK_RPC}"
    if [[ ! -f "$NODE_INFO" || ! -r "$NODE_INFO" ]]; then
        ps_fail 1 "No readable node-info.yaml at ${NODE_INFO}. Generate the node keys first with setup-node.sh."
    fi
    if [[ -z "$META_FILE" ]]; then
        ps_warn "No .node-meta found; assuming testnet."
    fi
}

# ps_runner -- RUNNER, the runner spec (docker:<image> or binary:<path>) that
# starts this node, read from its launch file. Exit 1 when it cannot be read.
ps_runner() {
    local rc=0
    [[ -z "$RUNNER" ]] || return 0
    RUNNER="$(tn_launch_runner 2>/dev/null)" || rc=$?
    if [[ "$rc" -ne 0 || -z "$RUNNER" ]]; then
        RUNNER=""
        ps_fail 1 "Could not tell how this node runs keytool: no docker image or node binary was found in its launch file (tn_launch_runner rc ${rc}). Check that the node was installed with setup-node.sh."
    fi
}

# =============================================================================
# PREPARE (the default run)
# =============================================================================

# (a) The network RPC must serve the chain of this node's network before
# anything else is read from it.
ps_check_chain() {
    local dec rc=0
    print_step "Network RPC"
    dec="$(ps_rpc_uint "$NETWORK_RPC" eth_chainId)" || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        ps_fail 2 "Could not read the chain id from ${NETWORK_RPC} (${dec}). Check the URL and the internet access of this server, or pass --network-rpc <URL>."
    fi
    NET_CHAIN_ID="$dec"
    if [[ "$dec" != "$EXPECTED_CHAIN_ID" ]]; then
        ps_fail 2 "${NETWORK_RPC} serves chain ${dec} ($(ps_chain_name "$dec")), not chain ${EXPECTED_CHAIN_ID} (${NETWORK}). Pass --network-rpc <URL> with an RPC for chain ${EXPECTED_CHAIN_ID}."
    fi
    print_ok "${NETWORK_RPC} serves chain ${dec} (${NETWORK})"
}

# (b) The address the stake must come from: execution_address in node-info.yaml,
# which the proof of possession is signed for.
ps_read_address() {
    local addr="" rc=0
    print_step "Validator address"
    addr="$(tn_node_info_field "$NODE_INFO" execution_address)" || rc=$?
    if [[ "$rc" -ne 0 ]] || ! ps_is_addr "$addr"; then
        ps_fail 1 "${NODE_INFO} has no usable execution_address${addr:+ (${addr})}."
    fi
    ADDR="$(ps_lower "$addr")"
    ADDR_CS="$(ps_checksum_address "$ADDR")"
    print_ok "${ADDR_CS} (execution_address in node-info.yaml)"
    if [[ -n "$META_ADDR" && "$(ps_lower "$META_ADDR")" != "$ADDR" ]]; then
        # A rotation is the fix this warning would suggest, so say what it does.
        if [[ -n "$PS_ROTATE" ]]; then
            if [[ "$(ps_lower "$META_ADDR")" == "$NEW_ADDR" ]]; then
                print_info ".node-meta already records ${META_ADDR}; this rotation brings node-info.yaml in line with it."
            else
                print_info ".node-meta records VALIDATOR_ADDRESS=${META_ADDR}; this rotation replaces it with ${NEW_CS}."
            fi
        elif ps_is_addr "$META_ADDR"; then
            ps_warn ".node-meta records VALIDATOR_ADDRESS=${META_ADDR}, not ${ADDR_CS}. The stake must come from ${ADDR_CS}, the address the proof of possession in node-info.yaml is signed for. To stake from ${META_ADDR} instead, first run: sudo bash prepare-stake.sh --rotate-address ${META_ADDR}"
        else
            ps_warn ".node-meta records VALIDATOR_ADDRESS=${META_ADDR}, which is not an address. The stake must come from ${ADDR_CS}."
        fi
    fi
}

# STATUS_LINE and STATUS_RC: node_stake_status of ADDR through the network RPC.
ps_read_status() {
    STATUS_RC=0
    STATUS_LINE="$(node_stake_status "$ADDR" "$NETWORK_RPC")" || STATUS_RC=$?
}

# ps_registered LINE -- rc 0 when a node_stake_status line shows an address that
# has staked (status 1 to 5) or is retired. Its BLS key, if any, is bound to it.
ps_registered() {
    local st="" ret=""
    read -r st _ ret _ <<<"${1:-}"
    [[ "$ret" == "1" ]] && return 0
    case "$st" in
        1|2|3|4|5|6) return 0 ;;
    esac
    return 1
}

# EPOCH: the network's current epoch (empty when it cannot be read).
ps_read_epoch() {
    local info="" rc=0
    [[ -z "$EPOCH" ]] || return 0
    info="$(tn_epoch_info "$NETWORK_RPC" "" 15)" || rc=$?
    if [[ "$rc" -eq 0 && "${info%% *}" =~ ^[0-9]+$ ]]; then
        EPOCH="${info%% *}"
    fi
}

# The address is past staking: activation under way, active, exiting, exited
# or retired. Show the registry's view and stop.
ps_report_final_status() {
    local st="" ret="" msg
    read -r st _ ret _ <<<"$STATUS_LINE"
    ps_read_epoch
    print_validator_onchain_status "$ADDR_CS" "$STATUS_LINE" "" "$EPOCH"
    case "$st" in
        2) msg="activation is under way" ;;
        3) msg="the validator is active" ;;
        4) msg="the validator is exiting" ;;
        5) msg="the validator has exited" ;;
        *) msg="the address has staked" ;;
    esac
    if [[ "$ret" == "1" ]]; then
        msg="the address is retired and can never stake again"
    fi
    ps_done 0 "nothing-to-do" "Nothing to do: ${msg}."
}

# (c) The governance whitelist: balanceOf(address) on the ConsensusRegistry,
# the ConsensusNFT governance mints to an approved address.
ps_check_whitelist() {
    local word="" rc=0
    print_step "Whitelist (ConsensusNFT)"
    word="$(ps_call_word "${BALANCE_OF_SELECTOR}000000000000000000000000${ADDR#0x}")" || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        ps_fail 2 "Could not read balanceOf(${ADDR_CS}) on the ConsensusRegistry from ${NETWORK_RPC} (${word})."
    fi
    NFT_BALANCE="$(tn_hex_to_dec "$word")"
    if [[ "$NFT_BALANCE" != "0" ]]; then
        WHITELISTED="true"
        print_ok "${ADDR_CS} holds the ConsensusNFT: governance has whitelisted it."
        return 0
    fi
    WHITELISTED="false"
    # Retiring a validator burns its NFT too; its record tells the two apart.
    ps_read_status
    if [[ "$STATUS_RC" -eq 0 ]] && ps_registered "$STATUS_LINE"; then
        ps_report_final_status
    fi
    print_warn "${ADDR_CS} holds no ConsensusNFT: governance has not whitelisted it yet."
    print_info "Send ${ADDR_CS} to the Telcoin Association for governance approval. Once governance mints the ConsensusNFT to it, run this script again."
    ps_done 3 "not-whitelisted" "Not ready: ${ADDR_CS} is not whitelisted."
}

# (d) The validator status. Returns 0 when stake() is next and 1 when the
# address has staked and activate() is next; every later state ends the run.
ps_check_status() {
    local st="" ret=""
    print_step "Validator status"
    ps_read_status
    if [[ "$STATUS_RC" -ne 0 ]]; then
        ps_fail 2 "Could not read the validator status of ${ADDR_CS} from ${NETWORK_RPC} (${STATUS_LINE#unknown })."
    fi
    if [[ "$STATUS_LINE" == "none" ]]; then
        print_ok "No validator record yet: stake() is next."
        return 0
    fi
    read -r st _ ret _ <<<"$STATUS_LINE"
    if [[ "$ret" != "1" && "$st" == "0" ]]; then
        print_ok "Not staked yet (status Undefined): stake() is next."
        return 0
    fi
    if [[ "$ret" != "1" && "$st" == "1" ]]; then
        print_ok "Staked: the stake is recorded and activate() is next."
        return 1
    fi
    ps_report_final_status
}

# (e) The stake the registry asks for now: stakeConfig(getCurrentStakeVersion()).
ps_stake_amount() {
    local out="" rc=0
    print_step "Stake amount"
    out="$(tn_stake_amount_wei "$NETWORK_RPC" 15)" || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        ps_fail 2 "Could not read the stake amount from ${NETWORK_RPC} (${out})."
    fi
    read -r STAKE_WEI STAKE_VERSION _ <<<"$out"
    STAKE_TEL="$(tn_wei_to_tel "$STAKE_WEI")"
    STAKE_HEX="$(ps_dec_to_hex "$STAKE_WEI")"
    if [[ -z "$STAKE_TEL" || -z "$STAKE_HEX" ]]; then
        ps_fail 2 "The stake amount read from ${NETWORK_RPC} is not a number (${out})."
    fi
    print_ok "${STAKE_TEL} TEL (${STAKE_WEI} wei, stake version ${STAKE_VERSION})"
}

# (f) The address must hold the stake plus gas. Short is not ready; a balance
# that cannot be read is only a warning, since the simulation checks it too.
ps_check_balance() {
    local out="" rc=0 short
    print_step "Balance"
    out="$(ps_rpc_uint "$NETWORK_RPC" eth_getBalance "[\"${ADDR}\",\"latest\"]")" || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        ps_warn "Could not read the TEL balance of ${ADDR_CS} (${out}). The simulation below still shows whether it can pay."
        return 0
    fi
    BALANCE_WEI="$out"
    rc=0
    out="$(ps_rpc_uint "$NETWORK_RPC" eth_gasPrice)" || rc=$?
    if [[ "$rc" -eq 0 ]]; then
        GAS_PRICE_WEI="$out"
        GAS_ALLOWANCE_WEI="$(ps_dec_mul "$GAS_PRICE_WEI" "$STAKE_GAS_ALLOWANCE")"
    else
        GAS_ALLOWANCE_WEI="0"
        ps_warn "Could not read the gas price (${out}), so the balance is compared with the stake alone."
    fi
    NEED_WEI="$(ps_dec_add "$STAKE_WEI" "$GAS_ALLOWANCE_WEI")"
    if [[ "$(ps_dec_cmp "$BALANCE_WEI" "$NEED_WEI")" -ge 0 ]]; then
        BALANCE_OK="true"
        print_ok "${ADDR_CS} holds $(tn_wei_to_tel "$BALANCE_WEI") TEL: enough for the stake and gas."
        return 0
    fi
    BALANCE_OK="false"
    short="$(ps_dec_sub "$NEED_WEI" "$BALANCE_WEI")"
    ps_warn "${ADDR_CS} holds $(tn_wei_to_tel "$BALANCE_WEI") TEL. The stake needs ${STAKE_TEL} TEL plus up to $(tn_wei_to_tel "$GAS_ALLOWANCE_WEI") TEL for gas: send at least $(tn_wei_to_tel "$short") TEL more to it before you stake."
    NOT_READY="${NOT_READY:+${NOT_READY}; }${ADDR_CS} is short of TEL"
}

# ps_keytool_error FILE -- keytool's own message from its stderr in FILE: the
# first paragraph (the "Error ..." line and any "hint:" line after it, joined
# with "; "), without the "Location:" trailer or a final period, cut at a word
# boundary when it is longer than 500 characters.
ps_keytool_error() {
    local msg
    msg="$(awk '
        /^[[:space:]]*$/ { if (out != "") exit; next }
        /^Location:/ { exit }
        { sub(/^[[:space:]]+/, ""); sub(/[[:space:]]+$/, ""); out = (out == "" ? $0 : out "; " $0) }
        END { print out }' "$1" 2>/dev/null)"
    msg="${msg%.}"
    if [[ ${#msg} -gt 500 ]]; then
        msg="${msg:0:500}"
        msg="${msg% *} ..."
    fi
    printf '%s\n' "$msg"
}

# (g) The stake() calldata, exported by the node's own keytool from
# node-info.yaml (the BLS public key and the proof of possession).
ps_export_calldata() {
    local out="" rc=0 errf err="" re
    print_step "stake() calldata"
    ps_runner
    errf="$(mktemp 2>/dev/null || true)"
    out="$(tn_keytool "$RUNNER" "$DATA_DIR" export-staking-args --node-info @DATADIR@/node-info.yaml --calldata 2>"${errf:-/dev/null}")" || rc=$?
    if [[ -n "$errf" ]]; then
        err="$(ps_keytool_error "$errf")"
        rm -f "$errf"
    fi
    if [[ "$rc" -eq 4 ]]; then
        ps_fail 1 "Could not start keytool with ${RUNNER}${err:+: ${err}}"
    fi
    if [[ "$rc" -ne 0 ]]; then
        ps_fail 2 "keytool could not export the stake() calldata from ${NODE_INFO} (exit ${rc})${err:+: ${err}}"
    fi
    out="$(printf '%s\n' "$out" | tr -d '\r' | awk 'NF')"
    re="^${STAKE_SELECTOR}([0-9a-fA-F][0-9a-fA-F])+\$"
    if [[ "$out" == *$'\n'* || ! "$out" =~ $re ]]; then
        ps_fail 2 "keytool did not print one line of stake() calldata starting with ${STAKE_SELECTOR}: ${out:0:80}"
    fi
    CALLDATA="$out"
    print_ok "Exported from node-info.yaml with keytool: $(( (${#out} - 2) / 2 )) bytes, stake(bytes,(bytes)) ${STAKE_SELECTOR}"
}

# ps_abi_string HEX -- the text of an ABI-encoded string (offset word, length
# word, bytes), printable ASCII only, at most 200 characters.
ps_abi_string() {
    local h="${1:-}" len bytes out="" i c
    len="$(ps_word_uint "${h:64:64}")" || return 1
    [[ "$len" -le 200 ]] || len=200
    bytes="${h:128:$(( len * 2 ))}"
    i=0
    while [[ "$i" -lt ${#bytes} ]]; do
        c="${bytes:i:2}"
        if [[ "$c" =~ ^(2[0-9a-fA-F]|[3-6][0-9a-fA-F]|7[0-9a-eA-E])$ ]]; then
            printf -v c '%b' "\\x${c}"
        else
            c="?"
        fi
        out="${out}${c}"
        i=$(( i + 2 ))
    done
    printf '%s\n' "$out"
}

# ps_explain_revert DATA -- name the registry error in revert DATA (selector and
# arguments) and say what to do about it.
ps_explain_revert() {
    local data="${1#0x}" sel args name why fix="" st
    sel="0x$(ps_lower "${data:0:8}")"
    args="${data:8}"
    case "$sel" in
        0xa865bb35)
            name="InvalidProofOfPossession"
            why="the proof of possession in node-info.yaml was signed for a different address than ${ADDR_CS}. The keys themselves are fine."
            fix="Re-sign it for the address you will stake from (this one, unless you stake from another wallet): sudo bash prepare-stake.sh --rotate-address ${ADDR_CS}"
            ;;
        0x674469f2)
            name="InvalidBLSPubkey"
            why="the BLS public key in node-info.yaml is not a valid key."
            fix="node-info.yaml may have been edited or damaged: restore it from your backup."
            ;;
        0x8d12779f)
            name="DuplicateBLSPubkey"
            why="this BLS key is already registered to a validator. A BLS key can be staked only once."
            fix="If you staked it from another address, that address is this node's validator: check it with sudo bash check-node.sh --address <that address>."
            ;;
        0x88b4590c)
            name="InvalidStakeAmount"
            why="the registry expects a different amount than ${STAKE_TEL} TEL; the stake configuration changed after it was read."
            fix="Run this script again to read the current amount."
            ;;
        0xed15e6cf)
            name="InvalidTokenId"
            why="${ADDR_CS} holds no ConsensusNFT, so it is not whitelisted."
            fix="Ask the Telcoin Association for governance approval of ${ADDR_CS}, then run this script again."
            ;;
        0x61f51356)
            name="RequiresConsensusNFT"
            why="the ConsensusNFT for ${ADDR_CS} is not held by ${ADDR_CS}."
            fix="Contact the Telcoin Association."
            ;;
        0x774f7f12)
            name="InvalidStatus"
            st="$(ps_word_uint "${args:0:64}" || echo "?")"
            why="the registry already holds a validator record for ${ADDR_CS} (status ${st}), so it cannot stake again."
            fix="Check it with sudo bash check-node.sh."
            ;;
        0xd93c0665)
            name="EnforcedPause"
            why="the ConsensusRegistry is paused, so staking is closed for now."
            fix="Try again later."
            ;;
        0x37f33ed8)
            name="LowLevelCallFailure"
            why="the registry could not run its BLS signature check."
            fix="Try again later; if it keeps failing, contact the Telcoin Association."
            ;;
        0x08c379a0)
            name="Error"
            why="the registry rejected it: $(ps_abi_string "$args" || echo "message not readable")"
            ;;
        0x4e487b71)
            name="Panic"
            why="the registry hit an internal error (panic code $(ps_word_uint "${args:0:64}" || echo "?"))."
            fix="Contact the Telcoin Association."
            ;;
        *)
            name="unknown error ${sel}"
            why="the registry rejected it with error data this script does not know: 0x${data:0:72}"
            fix="Contact the Telcoin Association with that data."
            ;;
    esac
    SIM_RESULT="reverted"
    SIM_ERROR="$name"
    print_warn "stake() from ${ADDR_CS} would revert with ${name}: ${why}"
    [[ -z "$fix" ]] || print_info "$fix"
    NOT_READY="${NOT_READY:+${NOT_READY}; }stake() would revert with ${name}"
}

# (h) Simulate stake() from the address with the stake as value
# (eth_estimateGas). A revert is decoded; an RPC that cannot run the
# simulation is a warning only.
ps_simulate() {
    local params body="" rc=0 rest re code="" msg="" data="" hex gas
    print_step "Simulating stake() from ${ADDR_CS}"
    params="[{\"from\":\"${ADDR}\",\"to\":\"${CONSENSUS_REGISTRY}\",\"value\":\"${STAKE_HEX}\",\"data\":\"${CALLDATA}\"}]"
    body="$(ps_rpc_raw "$NETWORK_RPC" eth_estimateGas "$params" 30)" || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        SIM_RESULT="failed"
        SIM_ERROR="$body"
        ps_warn "Could not run the simulation (${body}). The checks above still hold; run this script again before you send the stake."
        return 0
    fi
    re='"error"[[:space:]]*:[[:space:]]*[{]'
    if [[ ! "$body" =~ $re ]]; then
        hex="$(tn_json_field "$body" result 2>/dev/null || true)"
        gas="$(tn_hex_to_dec "$hex" 2>/dev/null || true)"
        if [[ "$hex" =~ ^0x[0-9a-fA-F]+$ && -n "$gas" ]]; then
            SIM_RESULT="ok"
            SIM_GAS="$gas"
            print_ok "The registry accepts stake() from ${ADDR_CS} (estimated gas ${gas})."
        else
            SIM_RESULT="failed"
            SIM_ERROR="malformed"
            ps_warn "The simulation answer was not understood (${body:0:120}). The checks above still hold."
        fi
        return 0
    fi
    rest="${body#*\"error\"}"
    re='"code"[[:space:]]*:[[:space:]]*(-?[0-9]+)'
    [[ "$rest" =~ $re ]] && code="${BASH_REMATCH[1]}"
    re='"message"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)"'
    [[ "$rest" =~ $re ]] && msg="${BASH_REMATCH[1]}"
    re='"data"[[:space:]]*:[[:space:]]*"(0x[0-9a-fA-F]*)"'
    [[ "$rest" =~ $re ]] && data="${BASH_REMATCH[1]}"
    if [[ ${#data} -ge 10 ]]; then
        ps_explain_revert "$data"
        return 0
    fi
    re='[Ii]nsufficient funds'
    if [[ "$msg" =~ $re ]]; then
        SIM_RESULT="no-funds"
        SIM_ERROR="insufficient funds"
        ps_warn "The simulation stopped before stake() ran: ${ADDR_CS} cannot pay ${STAKE_TEL} TEL plus gas."
        if [[ "$BALANCE_OK" != "false" ]]; then
            NOT_READY="${NOT_READY:+${NOT_READY}; }${ADDR_CS} is short of TEL"
        fi
        return 0
    fi
    if [[ "$code" == "3" || "$msg" =~ [Rr]evert ]]; then
        SIM_RESULT="reverted"
        SIM_ERROR="no reason given"
        print_warn "stake() from ${ADDR_CS} would revert, and the registry gave no reason${msg:+ (${msg})}."
        NOT_READY="${NOT_READY:+${NOT_READY}; }stake() would revert"
        return 0
    fi
    SIM_RESULT="failed"
    SIM_ERROR="rpc-error ${code:-?}${msg:+ ${msg}}"
    ps_warn "The RPC did not run the simulation (rpc-error ${code:-?}${msg:+: ${msg}}). The checks above still hold."
}

# (i) How far this node trails the network. A node that is behind can stake,
# but it should catch up before activate(): once in a committee it must vote.
ps_check_sync() {
    local out="" rc=0 lag
    print_step "Local node sync"
    out="$(ps_rpc_uint "$NETWORK_RPC" eth_blockNumber)" || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        ps_warn "Could not read the block height of the network (${out}), so the sync check is skipped."
        return 0
    fi
    NET_BLOCK="$out"
    rc=0
    out="$(ps_rpc_uint "$LOCAL_RPC" eth_blockNumber)" || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        ps_warn "The local node did not answer at ${LOCAL_RPC} (${out}). Start it and let it catch up with the network before you call activate()."
        return 0
    fi
    LOCAL_BLOCK="$out"
    if [[ ${#NET_BLOCK} -gt 15 || ${#LOCAL_BLOCK} -gt 15 ]]; then
        ps_warn "Block heights out of range (local ${LOCAL_BLOCK}, network ${NET_BLOCK}); the sync check is skipped."
        return 0
    fi
    lag=$(( 10#$NET_BLOCK - 10#$LOCAL_BLOCK ))
    if [[ "$lag" -lt 0 ]]; then
        lag=0
    fi
    SYNC_LAG="$lag"
    if [[ "$lag" -gt "$SYNC_LAG_BLOCKS" ]]; then
        ps_warn "This node is ${lag} blocks behind the network (block ${LOCAL_BLOCK}, network ${NET_BLOCK}). Let it catch up before you call activate()."
    else
        print_ok "In step with the network: block ${LOCAL_BLOCK}, network ${NET_BLOCK}."
    fi
}

# (j) The commands, for the machine that holds the validator wallet.
ps_print_stake_command() {
    CMD_STAKE="cast send --rpc-url ${NETWORK_RPC} ${CONSENSUS_REGISTRY} ${CALLDATA} --value ${STAKE_WEI} --from ${ADDR_CS} --ledger"
    echo "    cast send --rpc-url ${NETWORK_RPC} ${CONSENSUS_REGISTRY} \\"
    echo "      ${CALLDATA} \\"
    echo "      --value ${STAKE_WEI} --from ${ADDR_CS} --ledger"
}

ps_print_activate_command() {
    CMD_ACTIVATE="cast send --rpc-url ${NETWORK_RPC} ${CONSENSUS_REGISTRY} 'activate()' --from ${ADDR_CS} --ledger"
    echo "    cast send --rpc-url ${NETWORK_RPC} ${CONSENSUS_REGISTRY} \\"
    echo "      'activate()' --from ${ADDR_CS} --ledger"
}

ps_print_key_note() {
    echo "  Signing: --ledger signs on a Ledger; use --trezor for a Trezor. For a key in"
    echo "  software, use --account <name>, an encrypted keystore you create once with"
    echo "  'cast wallet import <name> --interactive', or --interactive to paste the key"
    echo "  when cast asks for it. Do not use --private-key: the key would be on the"
    echo "  command line of cast, where any user of that machine can read it with ps."
}

# The epoch arithmetic for activate(): mined in epoch E, the validator is active
# from epoch E+1, and its earliest committee seat is the activation epoch + 2.
ps_print_epochs() {
    local out="" rc=0 secs="" when=""
    ps_read_epoch
    out="$(tn_epoch_secs_left "$NETWORK_RPC")" || rc=$?
    if [[ "$rc" -eq 0 ]]; then
        read -r secs _ <<<"$out"
        if [[ "$secs" =~ ^-?[0-9]+$ ]]; then
            EPOCH_SECS_LEFT="$secs"
            if [[ "$secs" -gt 0 ]]; then
                when=", which ends in about $(ps_fmt_secs "$secs")"
            fi
        fi
    fi
    echo "  Epochs: activate() mined in epoch E makes the validator active at epoch E+1,"
    echo "  and its earliest committee seat is epoch E+3 (the activation epoch plus 2)."
    if [[ -n "$EPOCH" ]]; then
        ACTIVATION_EPOCH=$(( 10#$EPOCH + 1 ))
        SEAT_EPOCH=$(( 10#$EPOCH + 3 ))
        echo "  The network is in epoch ${EPOCH}${when}."
        echo "  activate() mined now: active at epoch ${ACTIVATION_EPOCH}, earliest seat at epoch ${SEAT_EPOCH}."
    fi
    echo ""
}

ps_prepare() {
    ps_check_chain
    ps_read_address
    ps_check_whitelist
    if ! ps_check_status; then
        ps_check_sync
        print_step "Next: activate()"
        echo ""
        echo "  The stake is recorded. Once this node has caught up with the network,"
        echo "  activate from the wallet that holds ${ADDR_CS}:"
        echo ""
        ps_print_activate_command
        echo ""
        ps_print_key_note
        echo ""
        ps_print_epochs
        ps_done 0 "staked" "Staked: activate() is next."
    fi
    ps_stake_amount
    ps_check_balance
    ps_export_calldata
    ps_simulate
    ps_check_sync
    if [[ "$SIM_RESULT" == "reverted" ]]; then
        ps_done 3 "not-ready" "Not ready: ${NOT_READY}. Fix that before you send the stake."
    fi
    print_step "Commands"
    echo ""
    if [[ -n "$NOT_READY" ]]; then
        echo "  1. Once ${ADDR_CS} holds enough TEL, send the stake from its wallet:"
    else
        echo "  1. Send the stake from the wallet that holds ${ADDR_CS}:"
    fi
    echo ""
    ps_print_stake_command
    echo ""
    echo "  2. When the stake is mined and this node has caught up, activate:"
    echo ""
    ps_print_activate_command
    echo ""
    ps_print_key_note
    echo ""
    ps_print_epochs
    if [[ -n "$NOT_READY" ]]; then
        ps_done 3 "not-ready" "Not ready: ${NOT_READY}."
    fi
    ps_done 0 "ready" "Ready to stake: run the commands above."
}

# =============================================================================
# ROTATE (--rotate-address)
# =============================================================================

# Owner and mode of node-info.yaml before the rotation, put back afterwards.
NI_UID=""
NI_GID=""
NI_MODE=""

# ps_stat FILE -- "<uid> <gid> <octal mode>" of FILE (GNU stat, then BSD stat).
ps_stat() {
    local out re='^[0-9]+ [0-9]+ [0-7]+$'
    out="$(stat -c '%u %g %a' "$1" 2>/dev/null || true)"
    if [[ ! "$out" =~ $re ]]; then
        out="$(stat -f '%u %g %Lp' "$1" 2>/dev/null || true)"
    fi
    [[ "$out" =~ $re ]] || return 1
    printf '%s\n' "$out"
}

ps_status_label() {
    case "${1:-}" in
        1) printf 'Staked\n' ;;
        2) printf 'PendingActivation\n' ;;
        3) printf 'Active\n' ;;
        4) printf 'PendingExit\n' ;;
        5) printf 'Exited\n' ;;
        *) printf 'status %s\n' "${1:-?}" ;;
    esac
}

# PS_PASS: the BLS key passphrase, from TN_BLS_PASSPHRASE (taken out of the
# environment when the script started, kept in PS_ENV_PASS), else the config
# dir's bls-passphrase file (setup-node.sh writes it, mode 600), else a prompt
# on the terminal. Only the keytool call gets it back; the EXIT trap forgets it.
# Exit 1 when there is no passphrase.
ps_get_passphrase() {
    local f info="" mode=""
    if [[ -n "$PS_ENV_PASS" ]]; then
        PS_PASS="$PS_ENV_PASS"
        PS_ENV_PASS=""
        print_ok "BLS key passphrase: from TN_BLS_PASSPHRASE"
        return 0
    fi
    f="${CONFIG_DIR}/bls-passphrase"
    if [[ -L "$f" ]]; then
        ps_warn "${f} is a symbolic link, so it is not used for the passphrase."
    elif [[ -f "$f" ]]; then
        info="$(ps_stat "$f" || true)"
        mode="${info##* }"
        if [[ ! "$mode" =~ ^[0-7]+$ ]]; then
            ps_warn "Could not read the mode of ${f}, so it is not used for the passphrase."
        elif [[ $(( 8#$mode & 8#077 )) -ne 0 ]]; then
            ps_warn "${f} is mode ${mode}, open to other users, so it is not used. Restrict it with: sudo chmod 600 ${f}"
        else
            IFS= read -r PS_PASS <"$f" || true
            if [[ -n "$PS_PASS" ]]; then
                print_ok "BLS key passphrase: from ${f}"
                return 0
            fi
            ps_warn "${f} is empty."
        fi
    fi
    if [[ -t 0 ]]; then
        IFS= read -r -s -p "  BLS key passphrase: " PS_PASS
        echo "" >&2
        if [[ -n "$PS_PASS" ]]; then
            return 0
        fi
    fi
    ps_fail 1 "No BLS key passphrase. Set TN_BLS_PASSPHRASE (sudo drops it unless you run sudo --preserve-env=TN_BLS_PASSPHRASE), keep it in ${f} with mode 600, or run this on a terminal to type it."
}

# ps_rollback WHY -- put node-info.yaml back from BACKUP, then exit 4.
ps_rollback() {
    local why="$1"
    if cp -p "$BACKUP" "$NODE_INFO" 2>/dev/null; then
        chown "${NI_UID}:${NI_GID}" "$NODE_INFO" 2>/dev/null || true
        chmod "$NI_MODE" "$NODE_INFO" 2>/dev/null || true
        PS_PHASE=""
        ps_done 4 "rolled-back" "${why} node-info.yaml is back as it was (from ${BACKUP})."
    fi
    ps_fail 1 "${why} Putting node-info.yaml back failed too: copy ${BACKUP} over ${NODE_INFO} by hand."
}

# Restart the node so it starts with the new address, after the epoch wait a
# committee node gets. Exit 1 when it does not come back up.
ps_restart_node() {
    if [[ "$PS_NO_RESTART" -eq 1 ]]; then
        RESTARTED="false"
        print_info "Not restarting (--no-restart). The node uses the new address after its next restart: sudo systemctl restart ${SERVICE:-telcoin}"
        return 0
    fi
    if [[ -z "$SERVICE" ]]; then
        RESTARTED="false"
        ps_warn "No node service was found on this server. Restart the node yourself so it uses the new address."
        return 0
    fi
    print_step "Restarting ${SERVICE}"
    tn_wait_restart_window "$LOCAL_RPC"
    systemctl restart "$SERVICE" 2>&1 || true
    sleep 3
    if systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
        RESTARTED="true"
        print_ok "${SERVICE} restarted"
        return 0
    fi
    RESTARTED="false"
    print_info "Check the logs: journalctl -u ${SERVICE} -n 50 --no-pager"
    ps_fail 1 "node-info.yaml now names ${NEW_CS}, but ${SERVICE} did not come back up after the restart."
}

ps_rotate() {
    local rc=0 st="" ret="" new_line="" old_bls="" old_name="" info=""
    local got_addr="" got_bls="" got_name="" errf err=""
    NEW_ADDR="$(ps_lower "$PS_ROTATE")"
    NEW_CS="$(ps_checksum_address "$NEW_ADDR")"
    ps_check_chain
    ps_read_address
    OLD_ADDR="$ADDR_CS"

    # A registered BLS key is bound to the address that staked it, so the proof
    # of possession may only move while neither address has staked.
    print_step "Can the proof of possession move?"
    ps_read_status
    if [[ "$STATUS_RC" -ne 0 ]]; then
        ps_fail 2 "Could not read the validator status of ${ADDR_CS} from ${NETWORK_RPC} (${STATUS_LINE#unknown })."
    fi
    if ps_registered "$STATUS_LINE"; then
        read -r st _ ret _ <<<"$STATUS_LINE"
        if [[ "$ret" == "1" ]]; then
            ps_done 3 "refused" "Refused: ${ADDR_CS} is retired. Its BLS key stays registered to it and cannot move to another address."
        fi
        ps_done 3 "refused" "Refused: ${ADDR_CS} has staked ($(ps_status_label "$st")). Its BLS key is registered to it on-chain and cannot move to another address."
    fi
    print_ok "${ADDR_CS} has not staked, so the proof of possession can be signed for another address."
    if [[ "$NEW_ADDR" == "$ADDR" ]]; then
        print_info "${NEW_CS} is the address node-info.yaml already names; the proof of possession is signed for it again."
    else
        rc=0
        new_line="$(node_stake_status "$NEW_ADDR" "$NETWORK_RPC")" || rc=$?
        if [[ "$rc" -ne 0 ]]; then
            ps_fail 2 "Could not read the validator status of ${NEW_CS} from ${NETWORK_RPC} (${new_line#unknown })."
        fi
        if ps_registered "$new_line"; then
            read -r st _ ret _ <<<"$new_line"
            if [[ "$ret" == "1" ]]; then
                ps_done 3 "refused" "Refused: ${NEW_CS} is retired and can never stake again."
            fi
            ps_done 3 "refused" "Refused: ${NEW_CS} already has a validator record ($(ps_status_label "$st")): it has staked with another BLS key."
        fi
        if [[ "$new_line" == "none" ]]; then
            print_info "${NEW_CS} holds no ConsensusNFT yet: it needs governance approval before it can stake."
        else
            print_ok "${NEW_CS} is whitelisted and has not staked."
        fi
    fi

    print_step "Rotation"
    print_info "node-info.yaml: ${NODE_INFO}"
    print_info "From:           ${ADDR_CS}"
    print_info "To:             ${NEW_CS}"
    print_info "The BLS key stays the same. node-info.yaml gets the new execution_address and proof of possession, .node-meta records the address, and the node restarts unless --no-restart is given."
    if [[ "$PS_YES" -ne 1 ]] && ! confirm "Sign the proof of possession for ${NEW_CS}?"; then
        ps_done 3 "cancelled" "Cancelled: nothing changed."
    fi
    ps_runner
    ps_get_passphrase
    # update-node.sh holds the update lock while it stops, swaps and restarts
    # the node, so a rotation edits nothing while it runs. It is taken only
    # after the passphrase, so a prompt nobody answers never holds up
    # update-node.sh, edit-config.sh or install-caddy.sh. The EXIT trap releases
    # it (the flock kind goes with the process).
    TN_EXIT_TRAP_OWNED=1
    if ! tn_acquire_update_lock >/dev/null 2>&1; then
        ps_done 3 "refused" "Refused: an update is in progress${TN_UPDATE_LOCK_HOLDER:+ (PID ${TN_UPDATE_LOCK_HOLDER})}; try again when it has finished."
    fi
    old_bls="$(tn_node_info_field "$NODE_INFO" bls_public_key || true)"
    old_name="$(tn_node_info_field "$NODE_INFO" name || true)"
    if [[ -z "$old_bls" ]]; then
        ps_fail 1 "${NODE_INFO} has no bls_public_key; nothing changed."
    fi
    info="$(ps_stat "$NODE_INFO")" || ps_fail 1 "Could not read the owner and mode of ${NODE_INFO}; nothing changed."
    read -r NI_UID NI_GID NI_MODE <<<"$info"

    BACKUP="${NODE_INFO}.bak.$(date -u +%Y%m%dT%H%M%SZ)"
    if [[ -e "$BACKUP" ]]; then
        BACKUP="${BACKUP}.$$"
    fi
    if ! cp -p "$NODE_INFO" "$BACKUP"; then
        BACKUP=""
        ps_fail 1 "Could not back up ${NODE_INFO}; nothing changed."
    fi
    chown "${NI_UID}:${NI_GID}" "$BACKUP" 2>/dev/null || true
    chmod "$NI_MODE" "$BACKUP" 2>/dev/null || true
    PS_PHASE="window"
    print_ok "Backed up node-info.yaml to ${BACKUP}"

    print_step "Signing the proof of possession for ${NEW_CS} (keytool generate pop)"
    errf="$(mktemp 2>/dev/null || true)"
    rc=0
    # keytool runs as a background job that ignores TERM, INT and HUP, so a
    # signal never stops it half way through writing node-info.yaml; `wait`
    # returns at once on a signal and the EXIT trap waits for the job before it
    # puts the backup back. In the job the passphrase is a plain shell variable,
    # not exported (ps_get_passphrase unset the environment copy), and
    # tn_keytool passes it to the keytool process alone. The job does not get
    # descriptor 9 (the flock kind of the update lock). keytool's own report
    # (and its hint to run export-staking-args) is dropped; the checks below
    # read node-info.yaml instead.
    ( trap '' TERM INT HUP
      TN_BLS_PASSPHRASE="$PS_PASS"
      tn_keytool "$RUNNER" "$DATA_DIR" generate pop --address "$NEW_ADDR" ) \
        >/dev/null 2>"${errf:-/dev/null}" 9>&- &
    PS_KT_PID=$!
    wait "$PS_KT_PID" || rc=$?
    PS_KT_PID=""
    PS_PASS=""
    unset TN_BLS_PASSPHRASE
    if [[ -n "$errf" ]]; then
        err="$(ps_keytool_error "$errf")"
        rm -f "$errf"
    fi
    if [[ "$rc" -ne 0 ]]; then
        ps_rollback "keytool generate pop failed (exit ${rc})${err:+: ${err}}. A wrong passphrase is the usual cause."
    fi
    got_addr="$(tn_node_info_field "$NODE_INFO" execution_address || true)"
    got_bls="$(tn_node_info_field "$NODE_INFO" bls_public_key || true)"
    got_name="$(tn_node_info_field "$NODE_INFO" name || true)"
    if [[ "$(ps_lower "$got_addr")" != "$NEW_ADDR" ]]; then
        ps_rollback "After keytool, node-info.yaml names ${got_addr:-no address}, not ${NEW_CS}."
    fi
    if [[ "$got_bls" != "$old_bls" ]]; then
        ps_rollback "After keytool, the BLS public key in node-info.yaml is different; it must not change."
    fi
    if [[ "$got_name" != "$old_name" ]]; then
        ps_rollback "After keytool, the node name in node-info.yaml is different; it must not change."
    fi
    chown "${NI_UID}:${NI_GID}" "$NODE_INFO" 2>/dev/null || ps_warn "Could not set the owner of ${NODE_INFO} back to ${NI_UID}:${NI_GID}."
    chmod "$NI_MODE" "$NODE_INFO" 2>/dev/null || ps_warn "Could not set the mode of ${NODE_INFO} back to ${NI_MODE}."
    PS_PHASE="rotated"
    print_ok "node-info.yaml names ${NEW_CS}; the BLS key and the node name are unchanged."

    if [[ -z "$META_FILE" ]]; then
        ps_warn "No .node-meta, so VALIDATOR_ADDRESS was not recorded."
    elif meta_set VALIDATOR_ADDRESS "$NEW_CS" "$META_FILE"; then
        print_ok "VALIDATOR_ADDRESS=${NEW_CS} recorded in ${META_FILE}"
    else
        ps_warn "Could not record VALIDATOR_ADDRESS=${NEW_CS} in ${META_FILE}."
    fi
    ps_restart_node
    print_info "Next: sudo bash prepare-stake.sh checks the stake from ${NEW_CS}."
    ps_done 0 "rotated" "Rotated: node-info.yaml now names ${NEW_CS}."
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    # Find --json before anything can print, so stdout carries only the final
    # JSON object: fd 3 keeps the real stdout, and stdout joins stderr.
    case " $* " in
        *" --json "*)
            PS_JSON=1
            exec 3>&1
            exec 1>&2
            ;;
    esac
    trap ps_on_exit EXIT
    # A signal ends the run through the EXIT trap with the usual status (128 +
    # the signal number), so --json reports ok:false and an interrupted
    # rotation is put back first. A trap runs once the command in progress
    # returns; the keytool job is waited for with `wait`, which returns at once.
    trap 'PS_SIGNAL=TERM; exit 143' TERM
    trap 'PS_SIGNAL=INT; exit 130' INT
    trap 'PS_SIGNAL=HUP; exit 129' HUP
    ps_parse_args "$@"
    print_header "Telcoin Network: prepare stake (v${SCRIPT_VERSION})"
    if ! ps_is_root; then
        ps_fail 1 "Run this as root: sudo bash prepare-stake.sh${*:+ $*}"
    fi
    ps_resolve_node
    if [[ -n "$PS_ROTATE" ]]; then
        ps_rotate
    else
        ps_prepare
    fi
}

main "$@"
