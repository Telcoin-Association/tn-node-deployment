#!/usr/bin/env bash
# =============================================================================
# tools/tests/caddy_test.sh -- install-caddy.sh: the Caddy apt key pinned by
# fingerprint (a wrong key, a second key or a failed download stops the install
# before apt-get update), the managed Caddyfile's admin socket block and the restart
# on an admin address change, live file root:caddy 0640 and backups 0600 (five
# kept), the RPC proxy port rule, the node-info.yaml backup in a root-only run
# directory written and restored as the service user, the mainnet validator
# refusal, the dashboard password floor and delivery, the public RPC consent and
# the committee guard before a node restart.
#
#   bash tools/tests/caddy_test.sh
#   docker run --rm -v "$PWD:/w" -w /w bash:3.2 bash tools/tests/caddy_test.sh
#
# The script is sourced from a copy without its `main "$@"` line. apt-get, curl,
# gpg, caddy, systemctl and getent are PATH stubs; tn_write_root_file,
# tn_as_service_user, tn_node_launch_target and node_is_staked_validator are
# replaced by functions (the fixture tree is not root-owned). TN_ROOT_PREFIX and
# TN_CADDY_RUN_PARENT point the paths at the fixture.
# =============================================================================

set -u

# shellcheck source=tools/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
T="$TN_TEST_TMP"
export TN_ROOT_PREFIX="$T/root"
export TN_CADDY_RUN_PARENT="$T/run"
export TN_UPDATE_LOCK_FILE="$T/update.lock"
export TN_BACKUP_DIR="$T/backups"
export APT_LOG="$T/apt.log" SYSCTL_LOG="$T/systemctl.log"
RP="$TN_ROOT_PREFIX"
mkdir -p "$RP/etc/caddy" "$RP/etc/telcoin" "$RP/etc/apt/sources.list.d" "$RP/usr/share/keyrings" \
         "$RP/etc/systemd/system" "$T/run" "$T/bin" "$T/cbin" "$T/c" "$T/data"
printf 'NETWORK=testnet\nOWNERSHIP_LAYOUT=2\nRPC_PORT=8545\n' > "$RP/etc/telcoin/.node-meta"
: > "$APT_LOG"
: > "$SYSCTL_LOG"

# --- PATH stubs ------------------------------------------------------------------------
cat > "$T/bin/apt-get" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${APT_LOG:?}"
case "$*" in
    "install -y caddy") cp "${CADDY_STUB:?}" "${STUB_BIN:?}/caddy" ;;
esac
exit 0
STUB
cat > "$T/bin/curl" <<'STUB'
#!/usr/bin/env bash
out=""
while [ $# -gt 0 ]; do
    case "$1" in
        -o) out="$2"; shift 2 ;;
        *) shift ;;
    esac
done
[ "${CURL_RC:-0}" = "0" ] || exit "$CURL_RC"
printf 'ARMORED-KEY\n' > "$out"
STUB
# gpg: --dearmor copies; --show-keys prints GPG_COLONS (lines separated by |).
cat > "$T/bin/gpg" <<'STUB'
#!/usr/bin/env bash
out="" show=false last=""
while [ $# -gt 0 ]; do
    case "$1" in
        -o) out="$2"; shift 2 ;;
        --show-keys) show=true; shift ;;
        --homedir) shift 2 ;;
        *) last="$1"; shift ;;
    esac
done
if [ "$show" = true ]; then
    printf '%s\n' "${GPG_COLONS:-}" | tr '|' '\n'
    exit 0
fi
[ "${GPG_DEARMOR_RC:-0}" = "0" ] || exit "$GPG_DEARMOR_RC"
cp "$last" "$out"
STUB
cat > "$T/cbin/caddy" <<'STUB'
#!/usr/bin/env bash
case "$1" in
    version) echo "v2.8.4 h1:test" ;;
    validate) exit "${CADDY_VALIDATE_RC:-0}" ;;
    hash-password) read -r _ ; echo '$2a$14$abcdefghijklmnopqrstuv' ;;
esac
STUB
cat > "$T/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${SYSCTL_LOG:?}"
case "$1" in
    is-active) exit "${CADDY_ACTIVE_RC:-0}" ;;
    is-failed) exit 1 ;;
esac
exit 0
STUB
cat > "$T/bin/getent" <<'STUB'
#!/usr/bin/env bash
[ "$1 $2" = "group caddy" ] && [ "${HAS_CADDY_GROUP:-1}" = "1" ] && { echo "caddy:x:998:"; exit 0; }
exit 2
STUB
chmod +x "$T/bin/"* "$T/cbin/caddy"
export CADDY_STUB="$T/cbin/caddy" STUB_BIN="$T/bin"
PATH="$T/bin:/usr/local/bin:/usr/bin:/bin"
hash -r

grep -v '^main "\$@"$' "${TN_TEST_REPO}/install-caddy.sh" > "$T/c/install-caddy.sh"
ln -s "${TN_TEST_REPO}/lib" "$T/c/lib"
# shellcheck source=/dev/null
source "$T/c/install-caddy.sh"
set +e
trap tn_test_cleanup EXIT

export WRITES="$T/writes"
: > "$WRITES"
tn_write_root_file() {
    printf '%s %s %s\n' "${1#"$RP"}" "$2" "${3:-root}" >> "$WRITES"
    [[ -L "$1" || -d "$1" ]] && return 1
    cat > "$1"
}
SU_LOG="$T/su.log"
: > "$SU_LOG"
tn_as_service_user() {
    printf '%s\n' "$*" >> "$SU_LOG"
    "$@"
}
sleep() { :; }

GOOD_FPR="$CADDY_APT_KEY_FPR"
colons_for() { printf 'pub:-:4096:1:X:1::::::scSC:|fpr:::::::::%s:|sub:-:4096:1:Y:1::::::s:|fpr:::::::::2F5C3BE9886ACD2913299EFBABA1F9B8875A6661:' "$1"; }

# --- apt key pin ---------------------------------------------------------------------------
check "constant: the fingerprint checked on 2026-10-15" "65760C51EDEA2017CEA2CA15155B6D79CA56EA34" "$CADDY_APT_KEY_FPR"
export GPG_COLONS
GPG_COLONS="$(colons_for 0000000000000000000000000000000000000000)"
( install_caddy_pkg ) >"$T/out" 2>&1; check_rc "wrong fingerprint stops install_caddy_pkg" 1 $?
check "wrong fingerprint: no apt-get update" "no" "$(grep -q '^update' "$APT_LOG" && echo yes || echo no)"
check "wrong fingerprint: no keyring installed" "no" "$([[ -e "$RP$CADDY_APT_KEYRING" ]] && echo yes || echo no)"
check "wrong fingerprint: no apt source written" "no" "$([[ -e "$RP$CADDY_APT_LIST" ]] && echo yes || echo no)"
check "wrong fingerprint named" "yes" "$(grep -q 'not the expected' "$T/out" && echo yes)"
GPG_COLONS="$(colons_for "$GOOD_FPR")|$(colons_for "$GOOD_FPR")"
( install_caddy_pkg ) >"$T/out" 2>&1; check_rc "two primary keys stop the install" 1 $?
check "two keys: no apt-get update" "no" "$(grep -q '^update' "$APT_LOG" && echo yes || echo no)"
GPG_COLONS="$(colons_for "$GOOD_FPR")"
( CURL_RC=22 install_caddy_pkg ) >"$T/out" 2>&1; check_rc "a 404 for the key stops the install" 1 $?
check "404: no apt-get update" "no" "$(grep -q '^update' "$APT_LOG" && echo yes || echo no)"
( GPG_DEARMOR_RC=2 install_caddy_pkg ) >"$T/out" 2>&1; check_rc "a key gpg cannot read stops the install" 1 $?
( install_caddy_pkg ) >"$T/out" 2>&1; check_rc "pinned fingerprint installs" 0 $?
check "keyring then list, then update" "/usr/share/keyrings/caddy-stable-archive-keyring.gpg 0644 root
/etc/apt/sources.list.d/caddy-stable.list 0644 root" "$(cat "$WRITES")"
check "apt-get update ran" "yes" "$(grep -q '^update' "$APT_LOG" && echo yes)"
check "apt source is signed-by the pinned keyring" "yes" \
    "$(grep -qxF 'deb [signed-by=/usr/share/keyrings/caddy-stable-archive-keyring.gpg] https://dl.cloudsmith.io/public/caddy/stable/deb/debian any-version main' "$RP$CADDY_APT_LIST" && echo yes)"
PATH="$T/bin:$T/cbin:/usr/local/bin:/usr/bin:/bin"
hash -r
: > "$WRITES"

# --- managed Caddyfile: admin socket, modes, backups -----------------------------------------
printf 'example.org {\n\trespond "hi"\n}\n' > "$CADDYFILE"
printf 'dash.example.org {\n\trespond "dash"\n}\n' > "$T/dash"
( caddy_write_managed "$T/dash" "" ) >"$T/out" 2>&1; check_rc "caddy_write_managed rc 0" 0 $?
check "global block: admin on the unix socket" "yes" "$(grep -qxF "$(printf '\tadmin unix//run/caddy/admin.sock|0600')" "$CADDYFILE" && echo yes)"
check "global block comes before the first site" "{" "$(grep -v '^#' "$CADDYFILE" | grep -v '^$' | head -1)"
check "admin address read back" "unix//run/caddy/admin.sock|0600" "$(caddy_admin_addr "$CADDYFILE")"
check "live file root:caddy 0640" "yes" "$(grep -qx '/etc/caddy/Caddyfile 0640 caddy' "$WRITES" && echo yes)"
check "original kept 0600" "yes" "$(grep -qx '/etc/caddy/Caddyfile.tn-orig 0600 root' "$WRITES" && echo yes)"
check "backup written 0600" "yes" "$(grep -qE '^/etc/caddy/Caddyfile\.bak\.[0-9]{8}_[0-9]{6} 0600 root$' "$WRITES" && echo yes)"
check "no temp file left in /etc/caddy" "" "$(cd "$RP/etc/caddy" && ls -a | grep -F 'tn-new' || true)"
cp "$CADDYFILE" "$T/cur"
( HAS_CADDY_GROUP=0 caddy_live_write < "$T/cur" ); check "no caddy group: root 0644" "/etc/caddy/Caddyfile 0644 root" "$(tail -1 "$WRITES")"
printf 'x {\n}\n' > "$T/off"; printf '{\n\tadmin off\n}\n' >> "$T/off"
check "admin off read back" "off" "$(caddy_admin_addr "$T/off")"
printf '# admin localhost:1\nx {\n}\n' > "$T/def"
check "commented admin ignored" "default" "$(caddy_admin_addr "$T/def")"

# First switch to the socket restarts; a second managed swap reloads.
CADDY_SWAPPED=true
CADDY_LAST_BACKUP="$T/def"
: > "$SYSCTL_LOG"
( caddy_apply_live ) >"$T/out" 2>&1; check_rc "first switch applies" 0 $?
check "first switch: restart, no reload" "restart caddy" "$(grep -E '^(restart|reload) caddy' "$SYSCTL_LOG")"
cp "$CADDYFILE" "$T/managed.bak"
CADDY_LAST_BACKUP="$T/managed.bak"
: > "$SYSCTL_LOG"
( caddy_apply_live ) >"$T/out" 2>&1; check_rc "same admin address applies" 0 $?
check "same admin address: reload" "reload caddy" "$(grep -E '^(restart|reload) caddy' "$SYSCTL_LOG")"
CADDY_LAST_BACKUP="$T/off"
: > "$SYSCTL_LOG"
( caddy_apply_live ) >"$T/out" 2>&1
check "from admin off: restart" "restart caddy" "$(grep -E '^(restart|reload) caddy' "$SYSCTL_LOG")"
check "recovery hint uses install, not cp -p" "yes" "$(grep -q 'install -m 0640 -o root -g caddy' <<< "$(caddy_restore_hint /x)" && echo yes)"

# Drop-in for the socket directory (its directory exists: install -d -o root needs root).
mkdir -p "${CADDY_ADMIN_DROPIN%/*}"
: > "$WRITES"
caddy_admin_dropin >/dev/null 2>&1; check_rc "drop-in written" 0 $?
check "drop-in 0644" "/etc/systemd/system/caddy.service.d/tn-admin.conf 0644 root" "$(cat "$WRITES")"
check "drop-in RuntimeDirectory" "yes" "$(grep -qx 'RuntimeDirectory=caddy' "$CADDY_ADMIN_DROPIN" && grep -qx 'RuntimeDirectoryMode=0750' "$CADDY_ADMIN_DROPIN" && echo yes)"
: > "$WRITES"
caddy_admin_dropin >/dev/null 2>&1
check "unchanged drop-in not rewritten" "" "$(cat "$WRITES")"
caddy_admin_dropin remove >/dev/null 2>&1
check "drop-in removed" "no" "$([[ -e "$CADDY_ADMIN_DROPIN" ]] && echo yes || echo no)"
mkdir -p "${CADDY_ADMIN_DROPIN%/*}"

# Validation failure leaves the live file alone.
cp "$CADDYFILE" "$T/live.before"
( CADDY_VALIDATE_RC=1 caddy_write_managed "" "$T/dash" ) >"$T/out" 2>&1; check_rc "failed validate rc 1" 1 $?
check "failed validate: live file unchanged" "yes" "$(cmp -s "$T/live.before" "$CADDYFILE" && echo yes)"

# Prune: five newest kept, all 0600.
rm -f "$CADDYFILE".bak.*
for d in 01 02 03 04 05 06 07; do
    printf 'b\n' > "${CADDYFILE}.bak.202610${d}_000000"
    chmod 0644 "${CADDYFILE}.bak.202610${d}_000000"
done
CADDY_LAST_BACKUP=""
caddy_prune_backups
check "prune keeps five" "5" "$(ls "$CADDYFILE".bak.* | wc -l | tr -d ' ')"
check "prune dropped the oldest" "no" "$([[ -e "${CADDYFILE}.bak.20261001_000000" ]] && echo yes || echo no)"
check "kept backups are 0600" "600" "$(stat -c '%a' "$CADDYFILE".bak.* | sort -u)"

# --- RPC proxy ports ---------------------------------------------------------------------------
LAUNCH="$T/launch"
printf '#!/bin/bash\nexec /usr/local/bin/telcoin-network node --http --http.addr 127.0.0.1 --http.port %s --datadir /var/lib/telcoin\n' 8080 > "$LAUNCH"
tn_node_launch_target() { printf 'telcoin source %s\n' "$LAUNCH"; }
port_case() {   # <http.port in the launch> -> "rc port"
    local out rc=0
    printf '#!/bin/bash\nexec /usr/local/bin/telcoin-network node --http --http.addr 127.0.0.1 --http.port %s --datadir /var/lib/telcoin\n' "$1" > "$LAUNCH"
    out="$(caddy_node_port --http.port RPC_PORT 8545 2>/dev/null)" || rc=$?
    printf '%s %s\n' "$rc" "$out"
}
check "launch port 8545 accepted" "0 8545" "$(port_case 8545)"
check "launch port 9650 accepted" "0 9650" "$(port_case 9650)"
check "UI port 8080 refused" "1 " "$(port_case 8080)"
check "port 80 refused" "1 " "$(port_case 80)"
check "port 1023 refused" "1 " "$(port_case 1023)"
check "port 70000 refused" "1 " "$(port_case 70000)"
check "port 1024 accepted" "0 1024" "$(port_case 1024)"
port_case 8080 >/dev/null
CADDY_RPC_PORT=""
CADDY_WS_PORT_SET=""
rm -f "$T/block"
( write_rpc_block rpc.example.org "$T/block" true ) >"$T/out" 2>&1; check_rc "write_rpc_block refuses the UI port" 1 $?
check "refused block not written" "no" "$([[ -s "$T/block" ]] && echo yes || echo no)"
port_case 8545 >/dev/null
( write_rpc_block rpc.example.org "$T/block" true ) >"$T/out" 2>&1; check_rc "write_rpc_block on 8545" 0 $?
check "block proxies to the launch port" "yes" "$(grep -qxF "$(printf '\t\treverse_proxy 127.0.0.1:8545')" "$T/block" && echo yes)"
check "block proxies WS to 8546" "yes" "$(grep -qxF "$(printf '\t\treverse_proxy 127.0.0.1:8546')" "$T/block" && echo yes)"
tn_node_launch_target() { return 1; }
printf 'NETWORK=testnet\nOWNERSHIP_LAYOUT=2\nRPC_PORT=9545\nWS_PORT=1023\n' > "$RP/etc/telcoin/.node-meta"
check "no launch file: .node-meta RPC_PORT" "9545" "$(caddy_node_port --http.port RPC_PORT 8545 2>/dev/null)"
caddy_node_port --ws.port WS_PORT 8546 >/dev/null 2>&1; check_rc "WS_PORT 1023 refused" 1 $?
printf 'NETWORK=testnet\nOWNERSHIP_LAYOUT=2\nRPC_PORT=9545\nRPC_PORT=9546\n' > "$RP/etc/telcoin/.node-meta"
caddy_node_port --http.port RPC_PORT 8545 >/dev/null 2>&1; check_rc "duplicated RPC_PORT rc 2" 2 $?
printf 'NETWORK=testnet\nOWNERSHIP_LAYOUT=2\n' > "$RP/etc/telcoin/.node-meta"
check "nothing set: default 8546" "8546" "$(caddy_node_port --ws.port WS_PORT 8546 2>/dev/null)"

# --- node-info.yaml backup and restore as the service user -----------------------------------
NI="$T/data/node-info.yaml"
printf 'p2p_info:\n  workers:\n    - rpc: ~\n' > "$NI"
: > "$SU_LOG"
caddy_ni_backup "$NI"; check_rc "node-info backup rc 0" 0 $?
case "$CADDY_NI_BAK" in
    "$T/run/tn-caddy."*/node-info.yaml) where=run ;;
    *) where="$CADDY_NI_BAK" ;;
esac
check "backup under TN_CADDY_RUN_PARENT/tn-caddy.*" "run" "$where"
check "run dir is 0700" "700" "$(stat -c '%a' "${CADDY_NI_BAK%/*}")"
check "backup read as the service user" "cat -- $NI" "$(cat "$SU_LOG")"
check "no backup beside the live file" "no" "$([[ -e "${NI}.tn-bak" ]] && echo yes || echo no)"
printf 'changed\n' > "$NI"
: > "$SU_LOG"
caddy_ni_restore "$NI"; check_rc "restore rc 0" 0 $?
check "restore wrote the backup back" "yes" "$(grep -q 'rpc: ~' "$NI" && echo yes)"
check "restore written by the service user" "yes" "$(grep -q '^sh -c cat > "\$1" sh ' "$SU_LOG" && echo yes)"
: > "$SU_LOG"
caddy_edit_node_info "$NI" get >/dev/null 2>&1
check "python editor runs as the service user" "yes" "$(grep -q '^env TN_NI_FILE=.* python3 -I -$' "$SU_LOG" && echo yes)"
caddy_ni_discard
check "discard drops the backup" "" "$CADDY_NI_BAK"
check "no .tn-bak write or cp -p of node files left in the script" "0" \
    "$(grep -v '^[[:space:]]*#' "${TN_TEST_REPO}/install-caddy.sh" | grep -cE 'tn-bak|chown --reference|chmod --reference' || true)"
check "TN_CADDY_PASSWORD never exported" "0" "$(grep -c 'export TN_CADDY_PASSWORD' "${TN_TEST_REPO}/install-caddy.sh" || true)"

# --- the run directory is removed on exit, also on a signal during the restart -----------------
# A driver process sources the script, arms the traps main arms, backs node-info.yaml
# up (which creates the run directory), uses the directory a second time, and then
# either exits or holds in a stubbed `systemctl restart` until it is sent TERM.
mkdir -p "$T/run2" "$T/hbin"
cat > "$T/hbin/systemctl" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = restart ]; then
    : > "${HOLD_DIR:?}/held"
    while [ ! -e "$HOLD_DIR/release" ]; do sleep 0.1; done
fi
exit 0
STUB
chmod +x "$T/hbin/systemctl"
cat > "$T/c/rundir_driver.sh" <<'DRV'
# shellcheck source=/dev/null
source "$(dirname "$0")/install-caddy.sh"
tn_as_service_user() { "$@"; }
trap 'exit 143' TERM
trap 'exit 130' INT
trap 'exit 129' HUP
trap caddy_exit_cleanup EXIT
caddy_ni_backup "$1" || exit 9
caddy_run_dir || exit 9
printf '%s\n' "$CADDY_RUN_DIR" > "$HOLD_DIR/dir"
[ "$2" = hold ] && systemctl restart telcoin
exit 0
DRV
rundir_run() {
    HOLD_DIR="$T/hold.$1"
    rm -rf "$HOLD_DIR"
    mkdir -p "$HOLD_DIR"
    if [[ "$1" == clean ]]; then
        HOLD_DIR="$HOLD_DIR" TN_CADDY_RUN_PARENT="$T/run2" PATH="$T/hbin:$PATH" \
            bash "$T/c/rundir_driver.sh" "$NI" clean >"$T/out" 2>&1 </dev/null
        RUNDIR_RC=$?
        return
    fi
    set -m
    HOLD_DIR="$HOLD_DIR" TN_CADDY_RUN_PARENT="$T/run2" PATH="$T/hbin:$PATH" \
        bash "$T/c/rundir_driver.sh" "$NI" hold >"$T/out" 2>&1 </dev/null &
    local pid=$! i=0
    set +m
    while [[ ! -e "$HOLD_DIR/held" && "$i" -lt 200 ]]; do command sleep 0.1; i=$((i + 1)); done
    kill -TERM -- "-$pid" 2>/dev/null
    RUNDIR_RC=0
    wait "$pid" || RUNDIR_RC=$?
}
rundir_run clean
check_rc "run dir: clean driver run rc 0" 0 "$RUNDIR_RC"
check "run dir: the backup went into a tn-caddy.* directory" "yes" \
    "$(d="$(cat "$T/hold.clean/dir" 2>/dev/null)"; [[ "$d" == "$T/run2/tn-caddy."* ]] && echo yes)"
check "run dir: a clean run leaves no directory" "" "$(ls "$T/run2")"
rundir_run term
check "run dir: the restart was in flight when TERM came" "yes" "$([[ -e "$T/hold.term/held" ]] && echo yes)"
check_rc "run dir: TERM during the restart exits 143" 143 "$RUNDIR_RC"
check "run dir: TERM during the restart leaves no directory" "" "$(ls "$T/run2")"

# --- mainnet validator refusal ------------------------------------------------------------------
NSV_LOG="$T/nsv.log"
node_is_staked_validator() {
    printf '%s %s\n' "$1" "${2:-local}" >> "$NSV_LOG"
    if [[ "${2:-}" == "$MAINNET_RPC_URL" ]]; then return "${NSV_RC2:-1}"; fi
    return "${NSV_RC:-1}"
}
gate() { : > "$NSV_LOG"; ( CADDY_GATE_DONE=false; caddy_mainnet_gate ) >"$T/out" 2>&1; }
ADDR=0x1111111111111111111111111111111111111111
printf 'NETWORK=mainnet\nOWNERSHIP_LAYOUT=2\nVALIDATOR_ADDRESS=%s\n' "$ADDR" > "$RP/etc/telcoin/.node-meta"
NSV_RC=0 gate; check_rc "mainnet staked validator refused" 1 $?
check "refusal names the validator" "yes" "$(grep -q 'is a staked validator' "$T/out" && echo yes)"
NSV_RC=1 gate; check_rc "mainnet non-validator allowed" 0 $?
NSV_RC=2 NSV_RC2=2 gate; check_rc "mainnet stake unreadable refused" 1 $?
check "unreadable: asked the public RPC too" "2" "$(wc -l < "$NSV_LOG" | tr -d ' ')"
NSV_RC=2 NSV_RC2=1 gate; check_rc "local unreadable, public says not staked: allowed" 0 $?
NSV_RC=2 NSV_RC2=0 gate; check_rc "local unreadable, public says staked: refused" 1 $?
printf 'NETWORK=mainnet\nOWNERSHIP_LAYOUT=2\n' > "$RP/etc/telcoin/.node-meta"
NSV_RC=1 gate; check_rc "mainnet without VALIDATOR_ADDRESS refused" 1 $?
printf 'NETWORK=mainnet\nNETWORK=testnet\n' > "$RP/etc/telcoin/.node-meta"
gate; check_rc "duplicated NETWORK refused" 1 $?
printf 'OWNERSHIP_LAYOUT=2\n' > "$RP/etc/telcoin/.node-meta"
gate; check_rc "unknown network (no NETWORK, no genesis) refused" 1 $?
check "unknown network: said" "yes" "$(grep -q 'network of this node cannot be told' "$T/out" && echo yes)"
printf 'NETWORK=devnet\nOWNERSHIP_LAYOUT=2\n' > "$RP/etc/telcoin/.node-meta"
gate; check_rc "devnet allowed" 0 $?
printf 'NETWORK=testnet\nOWNERSHIP_LAYOUT=2\nVALIDATOR_ADDRESS=%s\n' "$ADDR" > "$RP/etc/telcoin/.node-meta"
NSV_RC=0 gate; check_rc "testnet staked validator allowed" 0 $?
check "testnet: stake not asked" "" "$(cat "$NSV_LOG")"
CADDY_PASSWORD="abcdefghijklmnop"
printf 'NETWORK=mainnet\nOWNERSHIP_LAYOUT=2\nVALIDATOR_ADDRESS=%s\n' "$ADDR" > "$RP/etc/telcoin/.node-meta"
( NSV_RC=0; CADDY_GATE_DONE=false; caddy_dashboard_precheck dash.example.org admin ) >"$T/out" 2>&1
check_rc "dashboard precheck refuses a staked mainnet node" 1 $?
( NSV_RC=0; CADDY_GATE_DONE=false; caddy_rpc_enable_precheck rpc.example.org "" ) >"$T/out" 2>&1
check_rc "rpc-enable precheck refuses a staked mainnet node" 1 $?

# --- DATA_DIR on more than one line stops rpc-enable before any write ---------------------------
mkdir -p "$RP/data"
printf 'NETWORK=testnet\nOWNERSHIP_LAYOUT=2\nDATA_DIR=/data\n' > "$RP/etc/telcoin/.node-meta"
check "DATA_DIR once: node-info.yaml under it" "$RP/data/node-info.yaml" "$(caddy_node_info_path 2>/dev/null)"
printf 'NETWORK=testnet\nOWNERSHIP_LAYOUT=2\nDATA_DIR=/data\nDATA_DIR=/srv/other\n' > "$RP/etc/telcoin/.node-meta"
caddy_node_info_path >/dev/null 2>&1; check_rc "DATA_DIR twice: node-info path rc 2" 2 $?
: > "$WRITES"
( CADDY_GATE_DONE=false; caddy_rpc_enable_precheck rpc.example.org "" ) >"$T/out" 2>&1
check_rc "DATA_DIR twice: rpc-enable precheck stops" 1 $?
check "DATA_DIR twice: said" "yes" "$(grep -q 'DATA_DIR is set more than once' "$T/out" && echo yes)"
check "DATA_DIR twice: nothing written" "" "$(cat "$WRITES")"
check "DATA_DIR twice: status reads no advertisement" "|" "$(caddy_node_info_advertised 2>/dev/null)"
printf 'NETWORK=testnet\nOWNERSHIP_LAYOUT=2\n' > "$RP/etc/telcoin/.node-meta"

# --- dashboard password ---------------------------------------------------------------------------
check "15 characters refused" "the password must be at least 16 characters" "$(caddy_password_problem abcdefghijklmno)"
check "16 characters accepted" "" "$(caddy_password_problem abcdefghijklmnop)"
check "control character refused" "the password must not contain control characters" "$(caddy_password_problem "$(printf 'abcdefghijklmnop\tq')")"
( CADDY_PASSWORD=short; CADDY_GATE_DONE=true; caddy_dashboard_precheck dash.example.org admin ) >"$T/out" 2>&1
check_rc "dashboard precheck refuses a short password" 1 $?
printf 'secret-line-value\r\nsecond\n' > "$T/pw"
caddy_read_password_stdin < "$T/pw"
check "--password-stdin reads one line, CR dropped" "secret-line-value" "$CADDY_PASSWORD"
gen="$(caddy_generate_password)"
check "generated password passes the rule" "" "$(caddy_password_problem "$gen")"
out="$(TN_CADDY_PASSWORD=abcdefghijklmnopq bash "${TN_TEST_REPO}/install-caddy.sh" --password-stdin --phase=bogus < /dev/null 2>&1)"; rc=$?
check_rc "password from both stdin and the environment refused" 2 "$rc"
check "both sources named" "yes" "$(grep -q 'give it one way only' <<< "$out" && echo yes)"

# --- public RPC consent ---------------------------------------------------------------------------
( CADDY_YES=false; JSON_MODE=false; caddy_rpc_confirm rpc.example.org < /dev/null ) >"$T/out" 2>&1
check_rc "no terminal, no --yes: refused" 1 $?
check "summary printed before the refusal" "yes" "$(grep -q 'rate-limited gateway' "$T/out" && echo yes)"
( CADDY_YES=true; JSON_MODE=false; caddy_rpc_confirm rpc.example.org < /dev/null ) >"$T/out" 2>&1
check_rc "--yes accepts" 0 $?
( CADDY_YES=false; JSON_MODE=true; exec 3>"$T/events"; caddy_rpc_confirm rpc.example.org < /dev/null ) >"$T/out" 2>&1
check_rc "--json: the UI action is the consent" 0 $?
check "--json: summary is a warn event" "yes" "$(grep -q '^{"event":"warn","msg":"Public RPC on https://rpc.example.org/' "$T/events" && echo yes)"

# --- committee guard, then the epoch wait, right before a node restart ---------------------------
REAL_CDG="$(declare -f tn_committee_down_guard)"
tn_local_rpc_url() { echo http://127.0.0.1:8545; }
tn_wait_restart_window() { return 0; }
caddy_node_lock() { return 0; }
tn_committee_down_guard() { return "${CDG_RC:-0}"; }
( CDG_RC=1; CADDY_WINDOW_DONE=false; caddy_restart_window ) >"$T/out" 2>&1; check_rc "quorum risk refuses the restart" 1 $?
( CDG_RC=2; CADDY_WINDOW_DONE=false; caddy_restart_window ) >"$T/out" 2>&1; check_rc "guard rc 2 refuses the restart" 1 $?
check "guard rc 2: said" "yes" "$(grep -q 'committee could not be read on a node whose vote counts' "$T/out" && echo yes)"
( CDG_RC=0; CADDY_WINDOW_DONE=false; caddy_restart_window ) >"$T/out" 2>&1; check_rc "guard passes" 0 $?
( CDG_RC=0; CADDY_WINDOW_DONE=false; tn_wait_restart_window() { return 3; }; caddy_restart_window ) >"$T/out" 2>&1
check_rc "a failed epoch wait refuses the restart" 1 $?
eval "$REAL_CDG"

# The real guard with the committee unreadable (the node votes, no RPC answers).
tn_node_mode() { echo CvvActive; }
tn_epoch_info() { return 1; }
tn_rpc_call() { return 1; }
cguard() { # cguard NAME EXPECTED-RC META [ENV=VAL]
    local name="$1" want="$2"
    printf '%b\n' "$3" > "$RP/etc/telcoin/.node-meta"
    ( [[ -n "${4:-}" ]] && export "${4?}"; CADDY_WINDOW_DONE=false; caddy_restart_window ) >"$T/out" 2>&1
    check_rc "real guard: ${name}" "$want" $?
}
cguard "testnet, committee unreadable: restart" 0 'NETWORK=testnet\nOWNERSHIP_LAYOUT=2'
cguard "mainnet voting node, committee unreadable: refused" 1 'NETWORK=mainnet\nOWNERSHIP_LAYOUT=2'
cguard "mainnet with TN_ALLOW_QUORUM_RISK=1: restart" 0 'NETWORK=mainnet\nOWNERSHIP_LAYOUT=2' TN_ALLOW_QUORUM_RISK=1
cguard "unknown network, committee unreadable: refused" 1 'OWNERSHIP_LAYOUT=2'
unset -f tn_node_mode tn_epoch_info tn_rpc_call

# rpc-enable and rpc-disable through caddy_node_info_advertise: the lock before the edit,
# then guard, wait and restart; a refusal puts node-info.yaml back and never restarts.
ORDER="$T/order"
NIF="$RP/data/node-info.yaml"
mkdir -p "$RP/data"
caddy_node_lock() { [[ "${_LOCKED:-}" == 1 ]] && return 0; _LOCKED=1; echo lock >> "$ORDER"; }
tn_committee_down_guard() { echo guard >> "$ORDER"; return "${CDG_RC:-0}"; }
tn_wait_restart_window() { echo wait >> "$ORDER"; return "${WAIT_RC:-0}"; }
caddy_node_info_can_edit() { return 0; }
caddy_node_info_rpc_get() { echo "${NI_CUR:-none none}"; }
caddy_node_info_write() { echo edit >> "$ORDER"; printf 'edited\n' > "$1"; return 0; }
tn_resolve_service() { echo telcoin; }
systemctl() { [[ "$1" == restart ]] && echo restart >> "$ORDER"; [[ "$1" == is-failed ]] && return 1; return 0; }
curl() { echo '{"result":"0x7e1"}'; }
adv() { # adv MODE -- one advertise run on a fresh node-info.yaml; RC and ORDER
    printf 'NETWORK=testnet\nOWNERSHIP_LAYOUT=2\nDATA_DIR=/data\n' > "$RP/etc/telcoin/.node-meta"
    printf 'original\n' > "$NIF"
    : > "$ORDER"
    RC=0
    ( caddy_operation_reset; CADDY_RPC_PORT=8545
      if [[ "$1" == set ]]; then caddy_node_info_advertise set rpc.example.org true
      else NI_CUR="https://rpc.example.org/ none"; caddy_node_info_advertise clear; fi
      caddy_exit_cleanup ) >"$T/out" 2>&1 || RC=$?
}
adv set
check_rc "rpc-enable advertise rc 0" 0 "$RC"
check "rpc-enable: lock, edit, guard, wait, restart" "lock edit guard wait restart" "$(paste -sd' ' "$ORDER")"
check "rpc-enable: the edit is kept" "edited" "$(cat "$NIF")"
CDG_RC=1 adv set
check_rc "rpc-enable, guard refuses: rc 1" 1 "$RC"
check "rpc-enable, guard refuses: no wait, no restart" "lock edit guard" "$(paste -sd' ' "$ORDER")"
check "rpc-enable, guard refuses: node-info.yaml put back" "original" "$(cat "$NIF")"
check "rpc-enable, guard refuses: said" "yes" "$(grep -q 'node changes were put back' "$T/out" && echo yes)"
WAIT_RC=4 adv set
check_rc "rpc-enable, wait fails: rc 1" 1 "$RC"
check "rpc-enable, wait fails: no restart" "lock edit guard wait" "$(paste -sd' ' "$ORDER")"
check "rpc-enable, wait fails: node-info.yaml put back" "original" "$(cat "$NIF")"
adv clear
check_rc "rpc-disable advertise rc 0" 0 "$RC"
check "rpc-disable: lock, edit, guard, wait, restart" "lock edit guard wait restart" "$(paste -sd' ' "$ORDER")"
CDG_RC=2 adv clear
check_rc "rpc-disable on a node whose vote counts, committee unreadable: rc 1" 1 "$RC"
check "rpc-disable, guard rc 2: no restart" "lock edit guard" "$(paste -sd' ' "$ORDER")"
check "rpc-disable, guard rc 2: node-info.yaml put back" "original" "$(cat "$NIF")"
unset -f caddy_node_info_can_edit caddy_node_info_rpc_get caddy_node_info_write tn_resolve_service systemctl curl
eval "$REAL_CDG"

# A TERM during the epoch wait (after the edit): the EXIT trap puts node-info.yaml back.
cat > "$T/c/wait_driver.sh" <<'DRV'
# shellcheck source=/dev/null
source "$(dirname "$0")/install-caddy.sh"
tn_as_service_user() { "$@"; }
caddy_node_lock() { :; }
tn_local_rpc_url() { echo http://127.0.0.1:8545; }
tn_committee_down_guard() { return 0; }
tn_wait_restart_window() { : > "$HOLD_DIR/held"; while :; do command sleep 0.1; done; }
caddy_node_info_can_edit() { return 0; }
caddy_node_info_rpc_get() { echo "none none"; }
caddy_node_info_write() { printf 'edited\n' > "$1"; return 0; }
tn_resolve_service() { echo telcoin; }
trap 'exit 143' TERM
trap caddy_exit_cleanup EXIT
CADDY_RPC_PORT=8545
caddy_node_info_advertise set rpc.example.org true
DRV
printf 'NETWORK=testnet\nOWNERSHIP_LAYOUT=2\nDATA_DIR=/data\n' > "$RP/etc/telcoin/.node-meta"
printf 'original\n' > "$NIF"
HOLD_DIR="$T/hold.wait"
rm -rf "$HOLD_DIR"; mkdir -p "$HOLD_DIR"
set -m
HOLD_DIR="$HOLD_DIR" TN_CADDY_RUN_PARENT="$T/run2" bash "$T/c/wait_driver.sh" >"$T/out" 2>&1 </dev/null &
wpid=$!
set +m
i=0
while [[ ! -e "$HOLD_DIR/held" && "$i" -lt 200 ]]; do command sleep 0.1; i=$((i + 1)); done
check "TERM in the wait: the edit was made first" "edited" "$(cat "$NIF")"
kill -TERM -- "-$wpid" 2>/dev/null
wrc=0
wait "$wpid" || wrc=$?
check_rc "TERM in the wait: exit 143" 143 "$wrc"
check "TERM in the wait: node-info.yaml put back" "original" "$(cat "$NIF")"
check "TERM in the wait: no run directory left" "" "$(ls "$T/run2")"
printf 'NETWORK=testnet\nOWNERSHIP_LAYOUT=2\n' > "$RP/etc/telcoin/.node-meta"

finish
