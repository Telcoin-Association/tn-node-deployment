#!/usr/bin/env bash
# =============================================================================
# tools/tests/migrate_naming_test.sh -- migrate-node-naming.sh end to end on a
# legacy telcoin-observer install: the update lock, the restart window before the
# stop, root-only backups, the root-owned unified start script, and a rollback
# that stops the new unit, ignores a link planted at the role dir's name and
# puts the legacy layout back. Also the stops before any change: a duplicated
# DATA_DIR or RPC_PORT in the legacy .node-meta, and a held update lock.
#
#   docker run --rm -v "$PWD:/w" -w /w ubuntu:24.04 bash tools/tests/migrate_naming_test.sh
#
# The script has fixed paths (/etc/telcoin, /opt/telcoin, /var/lib/telcoin,
# /etc/systemd/system, /usr/local/libexec/telcoin, /var/backups/telcoin), so this
# test runs only as root inside a container (/.dockerenv) where none of them
# exists yet, and removes what it created. Elsewhere, and where mv -T, useradd,
# flock or sha256sum is missing (busybox), it prints SKIP. systemctl, curl and
# sleep are stubs on PATH that append to an ordered event log. bash 3.2 safe.
# =============================================================================

set -u

# shellcheck source=tools/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

T="$TN_TEST_TMP"
REPO="$TN_TEST_REPO"
PATHS="/etc/telcoin /opt/telcoin /var/lib/telcoin /usr/local/libexec/telcoin /var/backups/telcoin /etc/systemd/system/telcoin.service /etc/systemd/system/telcoin-observer.service"

why=""
if [[ "$(id -u)" != 0 ]]; then
    why="not root"
elif [[ ! -e /.dockerenv ]]; then
    why="writes system paths; runs only inside a container"
else
    : > "$T/p1"
    if ! mv -T -- "$T/p1" "$T/p2" 2>/dev/null; then
        why="mv -T absent"
    fi
    for c in useradd flock sha256sum setpriv; do
        command -v "$c" >/dev/null 2>&1 || why="${c} absent"
    done
    for p in $PATHS; do
        if [[ -e "$p" || -L "$p" ]]; then
            why="${p} exists (not a clean container)"
        fi
    done
fi
if [[ -n "$why" ]]; then
    skip "migrate-node-naming end to end" "$why"
    finish
fi

# What this test creates outside $T, removed at exit.
MADE_USER=0
MADE_LIBEXEC=0
MADE_SYSTEMD=0
[[ -d /usr/local/libexec ]] || MADE_LIBEXEC=1
[[ -d /etc/systemd/system ]] || MADE_SYSTEMD=1
if ! id -u telcoin >/dev/null 2>&1; then
    useradd -r -M -U -s /usr/sbin/nologin telcoin || { skip "migrate-node-naming end to end" "useradd failed"; finish; }
    MADE_USER=1
fi
cleanup_system() {
    local p
    for p in $PATHS; do
        rm -rf -- "$p"
    done
    [[ $MADE_LIBEXEC == 1 ]] && rm -rf /usr/local/libexec
    [[ $MADE_SYSTEMD == 1 ]] && rm -rf /etc/systemd/system
    [[ $MADE_USER == 1 ]] && userdel telcoin >/dev/null 2>&1
    return 0
}
trap 'cleanup_system; tn_test_cleanup' EXIT

EV="$T/events"
mkdir -p "$T/bin" "$T/canary"
cat > "$T/bin/systemctl" <<EOF
#!/bin/bash
printf 'systemctl %s\n' "\$*" >> "$EV"
case "\$1" in
    is-active) exit 0 ;;
    list-unit-files) exit 0 ;;
    start)
        if [[ "\$2" == telcoin && -e "$T/plant" ]]; then
            ln -s "$T/canary" /var/lib/telcoin/observer
        fi
        ;;
esac
exit 0
EOF
cat > "$T/bin/curl" <<EOF
#!/bin/bash
data="" w="" url=""
while [[ \$# -gt 0 ]]; do
    case "\$1" in
        --data) data="\$2"; shift 2 ;;
        -w) w="\$2"; shift 2 ;;
        --url) url="\$2"; shift 2 ;;
        http*) url="\$1"; shift ;;
        *) shift ;;
    esac
done
m="\$(printf '%s' "\$data" | sed -n 's/.*"method":"\([A-Za-z0-9_]*\)".*/\1/p')"
printf 'curl %s %s\n' "\$m" "\$url" >> "$EV"
case "\$m" in
    tn_nodeMode) r='"Observer"' ;;
    eth_chainId) [[ -e "$T/rpc-fail" ]] && exit 7; r='"0x7e1"' ;;
    *) exit 7 ;;
esac
printf '{"jsonrpc":"2.0","id":1,"result":%s}' "\$r"
[[ -n "\$w" ]] && printf '\n200'
exit 0
EOF
printf '#!/bin/sh\nexit 0\n' > "$T/bin/sleep"
chmod 0755 "$T/bin/systemctl" "$T/bin/curl" "$T/bin/sleep"

UNIT_TEXT='[Unit]
Description=Telcoin Network Observer Node
[Service]
User=telcoin
ExecStart=/opt/telcoin/start-telcoin-observer.sh
SyslogIdentifier=telcoin-observer'
WRAPPER_TEXT='#!/bin/bash
exec /opt/telcoin/telcoin-network node \
    --datadir /var/lib/telcoin/observer \
    --observer \
    --instance 5 \
    --http'
META_TEXT='NETWORK=testnet
NODE_TYPE=observer
RPC_PORT=8541
INSTALL_METHOD=binary'
ADDR="0x1111111111111111111111111111111111111111"

# legacy [META] -- a fresh legacy telcoin-observer install in the old layout:
# install, config role dir and data role dir owned by the service account.
legacy() {
    local p
    for p in $PATHS; do
        rm -rf -- "$p"
    done
    rm -f "$T/plant" "$T/rpc-fail"
    rm -rf "$T/canary"
    mkdir -p "$T/canary" /etc/systemd/system
    printf '%s\n' "$UNIT_TEXT" > /etc/systemd/system/telcoin-observer.service
    chmod 0644 /etc/systemd/system/telcoin-observer.service
    install -d -o telcoin -g telcoin -m 0755 /opt/telcoin
    printf '%s\n' "$WRAPPER_TEXT" > /opt/telcoin/start-telcoin-observer.sh
    chown telcoin:telcoin /opt/telcoin/start-telcoin-observer.sh
    chmod 0755 /opt/telcoin/start-telcoin-observer.sh
    install -d -o root -g root -m 0755 /etc/telcoin
    install -d -o telcoin -g telcoin -m 0755 /etc/telcoin/observer
    printf '%s\n' "${1:-$META_TEXT}" > /etc/telcoin/observer/.node-meta
    chmod 0600 /etc/telcoin/observer/.node-meta
    printf 'p: 1\n' > /etc/telcoin/observer/parameters.yaml
    chown telcoin:telcoin /etc/telcoin/observer/parameters.yaml
    install -d -o root -g root -m 0755 /var/lib/telcoin
    install -d -o telcoin -g telcoin -m 0700 /var/lib/telcoin/observer /var/lib/telcoin/observer/db
    printf 'execution_address: "%s"\n' "$ADDR" > /var/lib/telcoin/observer/node-info.yaml
    chown telcoin:telcoin /var/lib/telcoin/observer/node-info.yaml
    : > "$EV"
}

# migrate -- run the script; RC, OUT.
migrate() {
    OUT="$(PATH="$T/bin:$PATH" TN_UPDATE_LOCK_FILE="$T/update.lock" TN_EPOCH_POLL=5 \
        bash "$REPO/migrate-node-naming.sh" --yes 2>&1)"
    RC=$?
}
has() {
    case "$1" in
        *"$2"*) echo yes ;;
        *) echo no ;;
    esac
}
om() { stat -c '%U:%G %a' -- "$1" 2>/dev/null; }
# line_of LINE -- number of the first event log line that is exactly LINE (0 if none).
line_of() { awk -v p="$1" '$0 == p { print NR; f = 1; exit } END { if (!f) print 0 }' "$EV"; }
lock_free() {
    if flock -n "$T/update.lock" true 2>/dev/null; then echo yes; else echo no; fi
}

# -----------------------------------------------------------------------------
# A clean migration
# -----------------------------------------------------------------------------
legacy
migrate
check_rc "migrate: rc" 0 "$RC"
w="$(line_of "curl tn_nodeMode http://127.0.0.1:8541")"
st="$(line_of "systemctl stop telcoin-observer")"
check "migrate: restart window read on the legacy port before the stop" yes \
    "$([[ $w -gt 0 && $st -gt $w ]] && echo yes || echo no)"
check "migrate: unit points at the root-owned start script" "ExecStart=/usr/local/libexec/telcoin/tn-start" \
    "$(grep '^ExecStart=' /etc/systemd/system/telcoin.service)"
check "migrate: unit root 0644" "root:root 644" "$(om /etc/systemd/system/telcoin.service)"
check "migrate: start script root 0755" "root:root 755" "$(om /usr/local/libexec/telcoin/tn-start)"
check "migrate: start script has no --observer/--instance, unified data dir" "no no yes" \
    "$(has "$(cat /usr/local/libexec/telcoin/tn-start)" "--observer") $(has "$(cat /usr/local/libexec/telcoin/tn-start)" "--instance") $(has "$(cat /usr/local/libexec/telcoin/tn-start)" "--datadir /var/lib/telcoin ")"
check "migrate: nothing written under /opt/telcoin" "" "$(find /opt/telcoin -mindepth 1 2>/dev/null)"
check "migrate: config dir root 0755" "root:root 755" "$(om /etc/telcoin)"
check "migrate: .node-meta root 0600" "root:root 600" "$(om /etc/telcoin/.node-meta)"
check "migrate: .node-meta rewritten" "NETWORK=testnet
INSTALL_METHOD=binary
DATA_DIR=/var/lib/telcoin
RPC_PORT=8545
WS_PORT=8546
VALIDATOR_ADDRESS=${ADDR}" "$(cat /etc/telcoin/.node-meta)"
check "migrate: data dir is the service account's, 0700" "telcoin:telcoin 700" "$(om /var/lib/telcoin)"
check "migrate: data entries moved" "db node-info.yaml" "$(cd /var/lib/telcoin && echo *)"
check "migrate: role dirs gone" "no no" \
    "$([[ -e /var/lib/telcoin/observer ]] && echo yes || echo no) $([[ -e /etc/telcoin/observer ]] && echo yes || echo no)"
check "migrate: legacy unit and wrapper removed after the start" "no no" \
    "$([[ -e /etc/systemd/system/telcoin-observer.service ]] && echo yes || echo no) $([[ -e /opt/telcoin/start-telcoin-observer.sh ]] && echo yes || echo no)"
check "migrate: legacy files removed only after the verified start" yes \
    "$([[ $(line_of "curl eth_chainId http://127.0.0.1:8545") -gt 0 && $(grep -c 'daemon-reload' "$EV") -ge 2 ]] && echo yes || echo no)"
check "migrate: backups root-only" "root:root 700 3" \
    "$(om /var/backups/telcoin) $(find /var/backups/telcoin -type f -perm 0600 -user root | wc -l | tr -d ' ')"
check "migrate: no .bak beside live files" "" "$(find /etc /opt -name '*.bak.*' 2>/dev/null)"
check "migrate: lock released" yes "$(lock_free)"

# -----------------------------------------------------------------------------
# Rollback: the new node never answers; a link is planted at the role dir's name
# -----------------------------------------------------------------------------
legacy
: > "$T/plant"
: > "$T/rpc-fail"
migrate
check_rc "rollback: rc" 1 "$RC"
check "rollback: reported" yes "$(has "$OUT" "Rolled back to the legacy layout")"
s_new="$(line_of "systemctl stop telcoin")"
s_old="$(line_of "systemctl start telcoin-observer")"
check "rollback: new unit stopped before the legacy one starts" yes \
    "$([[ $s_new -gt 0 && $s_old -gt $s_new ]] && echo yes || echo no)"
check "rollback: restart did not wait (one mode read, before the stop)" 1 "$(grep -c 'curl tn_nodeMode' "$EV")"
check "rollback: nothing moved through the planted link" "" "$(ls -A "$T/canary")"
check "rollback: data role dir a real dir, the account's, 0750" "no telcoin:telcoin 750" \
    "$([[ -L /var/lib/telcoin/observer ]] && echo yes || echo no) $(om /var/lib/telcoin/observer)"
check "rollback: data entries back" "db node-info.yaml" "$(cd /var/lib/telcoin/observer && echo *)"
check "rollback: data parent root 0755" "root:root 755" "$(om /var/lib/telcoin)"
check "rollback: .node-meta restored from the backup" "$META_TEXT" "$(cat /etc/telcoin/observer/.node-meta)"
check "rollback: .node-meta root 0600" "root:root 600" "$(om /etc/telcoin/observer/.node-meta)"
check "rollback: config entries back" "yes no" \
    "$([[ -f /etc/telcoin/observer/parameters.yaml ]] && echo yes || echo no) $([[ -e /etc/telcoin/parameters.yaml ]] && echo yes || echo no)"
check "rollback: new unit and start script removed" "no no" \
    "$([[ -e /etc/systemd/system/telcoin.service ]] && echo yes || echo no) $([[ -e /usr/local/libexec/telcoin/tn-start ]] && echo yes || echo no)"
check "rollback: legacy unit untouched" "$UNIT_TEXT" "$(cat /etc/systemd/system/telcoin-observer.service)"
check "rollback: legacy wrapper untouched" "$WRAPPER_TEXT" "$(cat /opt/telcoin/start-telcoin-observer.sh)"
check "rollback: lock released" yes "$(lock_free)"

# -----------------------------------------------------------------------------
# Stops before any change
# -----------------------------------------------------------------------------
legacy "${META_TEXT}
DATA_DIR=/var/lib/telcoin/observer
DATA_DIR=/mnt/other"
migrate
check_rc "duplicate DATA_DIR: rc" 1 "$RC"
check "duplicate DATA_DIR: says why" yes "$(has "$OUT" "DATA_DIR is set more than once")"
check "duplicate DATA_DIR: nothing stopped, nothing backed up" "no no" \
    "$(has "$(cat "$EV")" "systemctl stop") $([[ -e /var/backups/telcoin ]] && echo yes || echo no)"

legacy "${META_TEXT}
RPC_PORT=8545"
migrate
check_rc "duplicate RPC_PORT: rc" 1 "$RC"
check "duplicate RPC_PORT: says why" yes "$(has "$OUT" "RPC_PORT is set more than once")"
check "duplicate RPC_PORT: nothing stopped" no "$(has "$(cat "$EV")" "systemctl stop")"

legacy
exec 8>>"$T/update.lock"
flock -n 8
migrate
flock -u 8
exec 8>&-
check_rc "lock held: rc" 1 "$RC"
check "lock held: says why" yes "$(has "$OUT" "holds the update lock")"
check "lock held: nothing stopped, nothing backed up" "no no" \
    "$(has "$(cat "$EV")" "systemctl stop") $([[ -e /var/backups/telcoin ]] && echo yes || echo no)"
check "lock held: legacy layout untouched" "yes yes" \
    "$([[ -d /etc/telcoin/observer ]] && echo yes || echo no) $([[ -d /var/lib/telcoin/observer ]] && echo yes || echo no)"

finish
