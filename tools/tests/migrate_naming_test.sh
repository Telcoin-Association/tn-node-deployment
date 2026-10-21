#!/usr/bin/env bash
# =============================================================================
# tools/tests/migrate_naming_test.sh -- migrate-node-naming.sh end to end on a
# legacy telcoin-observer install: the update lock, the restart window before the
# stop, root-only backups, the root-owned unified start script, and a rollback
# that stops the new unit, ignores a link planted at the role dir's name and
# puts the legacy layout back. Also the stops before any change: a duplicated
# DATA_DIR or RPC_PORT in the legacy .node-meta, a held update lock, and the
# committee check refusing the stop (with --allow-quorum-risk overriding it).
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
    --version) [[ -e "$T/sd255" ]] && printf 'systemd 255 (255.4-1ubuntu8)\n' ;;
    is-active) exit 0 ;;
    list-unit-files) exit 0 ;;
    start)
        if [[ "\$2" == telcoin && -e "$T/plant" ]]; then
            ln -s "$T/canary" /var/lib/telcoin/observer
        fi
        # With $T/term the run gets a TERM while the new unit starts.
        if [[ "\$2" == telcoin && -e "$T/term" ]]; then
            kill -TERM "\$PPID"
        fi
        ;;
esac
exit 0
EOF
# systemd-creds "encrypts" by rot13 behind a CRED: prefix (used with $T/sd255).
cat > "$T/bin/systemd-creds" <<'EOF'
#!/bin/sh
cmd="$1"
shift
case "$cmd" in
    has-tpm2) exit 1 ;;
    encrypt) tr 'A-Za-z' 'N-ZA-Mn-za-m' | sed 's/^/CRED:/' ;;
    decrypt)
        in=""
        for a in "$@"; do
            case "$a" in --*) ;; *) [ -n "$in" ] || in="$a" ;; esac
        done
        sed 's/^CRED://' "$in" | tr 'A-Za-z' 'N-ZA-Mn-za-m'
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
# With $T/voting the node is a committee member of 4 and the latest commit has
# two authors: two members down, so one more stop halts consensus.
case "\$m" in
    tn_nodeMode)
        if [[ -e "$T/voting" ]]; then r='"CvvActive"'; else r='"Observer"'; fi ;;
    tn_getCurrentEpochInfo)
        [[ -e "$T/voting" ]] || exit 7
        r='{"epochId":7,"blockHeight":100,"epochDuration":86400,"stakeVersion":0,"committee":["0x0000000000000000000000000000000000000001","0x0000000000000000000000000000000000000002","0x0000000000000000000000000000000000000003","0x0000000000000000000000000000000000000004"]}' ;;
    tn_latestConsensusHeader)
        [[ -e "$T/voting" ]] || exit 7
        r="{\"number\":5,\"sub_dag\":{\"headers\":[{\"author\":\"Auth1x\",\"epoch\":7},{\"author\":\"Auth2x\",\"epoch\":7}],\"commit_timestamp\":\$(date +%s)}}" ;;
    eth_chainId) [[ -e "$T/rpc-fail" ]] && exit 7; r='"0x7e1"' ;;
    *) exit 7 ;;
esac
printf '{"jsonrpc":"2.0","id":1,"result":%s}' "\$r"
[[ -n "\$w" ]] && printf '\n200'
exit 0
EOF
printf '#!/bin/sh\nexit 0\n' > "$T/bin/sleep"
chmod 0755 "$T/bin/systemctl" "$T/bin/curl" "$T/bin/sleep" "$T/bin/systemd-creds"

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
    rm -f "$T/plant" "$T/rpc-fail" "$T/voting" "$T/sd255" "$T/term"
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

# migrate [ARG...] -- run the script with --yes and ARGs; RC, OUT.
migrate() {
    OUT="$(PATH="$T/bin:$PATH" TN_UPDATE_LOCK_FILE="$T/update.lock" TN_EPOCH_POLL=5 \
        bash "$REPO/migrate-node-naming.sh" --yes "$@" 2>&1)"
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
# A legacy unit that holds the passphrase: it moves out of the unit (no
# systemd-creds here, testnet: the root-only file), and every copy is shredded
# -----------------------------------------------------------------------------
legacy
printf '%s\n' "[Service]" 'Environment="TN_BLS_PASSPHRASE=embedded-Pass-1"' "User=telcoin" \
    "ExecStart=/opt/telcoin/start-telcoin-observer.sh" > /etc/systemd/system/telcoin-observer.service
migrate
check_rc "embedded: rc" 0 "$RC"
check "embedded: passphrase file holds the unit's value" "embedded-Pass-1" "$(cat /etc/telcoin/bls-passphrase 2>/dev/null)"
check "embedded: passphrase file root 0600" "root:root 600" "$(om /etc/telcoin/bls-passphrase)"
check "embedded: method recorded" "PASSPHRASE_METHOD=stdin" "$(grep '^PASSPHRASE_METHOD=' /etc/telcoin/.node-meta)"
check "embedded: new unit loads the file, holds no passphrase" "yes no" \
    "$(has "$(cat /etc/systemd/system/telcoin.service)" "LoadCredential=bls-passphrase:/etc/telcoin/bls-passphrase") $(has "$(cat /etc/systemd/system/telcoin.service)" "TN_BLS_PASSPHRASE=")"
check "embedded: no backup holds the passphrase" "" "$(grep -rl 'embedded-Pass-1' /var/backups/telcoin /etc/systemd/system 2>/dev/null)"
check "embedded: lock released" yes "$(lock_free)"

# The same with systemd-creds: the passphrase moves to the credential, and the
# plaintext file, an older unit copy in /var/backups/telcoin and the start
# wrapper of an older release go after the verified start; an unrelated backup
# stays.
legacy
touch "$T/sd255"
printf '%s\n' "[Service]" 'Environment="TN_BLS_PASSPHRASE=embedded-Pass-2"' "User=telcoin" \
    "ExecStart=/opt/telcoin/start-telcoin-observer.sh" > /etc/systemd/system/telcoin-observer.service
printf 'embedded-Pass-2\n' > /etc/telcoin/observer/bls-passphrase
chmod 0600 /etc/telcoin/observer/bls-passphrase
install -d -o root -g root -m 0700 /var/backups/telcoin
printf '[Service]\nEnvironment="TN_BLS_PASSPHRASE=embedded-Pass-2"\n' > /var/backups/telcoin/telcoin-observer.service.QwErTy
printf 'unrelated\n' > /var/backups/telcoin/caddy-launch.AbCdEf
chmod 0600 /var/backups/telcoin/*
printf '#!/bin/sh\n' > /opt/telcoin/start-telcoin.sh
migrate
check_rc "embedded, credential: rc" 0 "$RC" || printf "%s\n" "$OUT" | grep -i "error\|warn\|fail" | head -8
check "embedded, credential: stored and recorded" "yes PASSPHRASE_METHOD=credential" \
    "$([[ -s /etc/telcoin/bls-passphrase.cred ]] && echo yes || echo no) $(grep '^PASSPHRASE_METHOD=' /etc/telcoin/.node-meta)"
check "embedded, credential: plaintext file shredded" "no" "$([[ -e /etc/telcoin/bls-passphrase ]] && echo yes || echo no)"
check "embedded, credential: no file holds the passphrase" "" \
    "$(grep -rl 'embedded-Pass-2' /etc/telcoin /var/backups/telcoin /etc/systemd/system /opt/telcoin 2>/dev/null)"
check "embedded, credential: unrelated backup kept" "yes" "$([[ -e /var/backups/telcoin/caddy-launch.AbCdEf ]] && echo yes || echo no)"
check "embedded, credential: older start wrapper removed" "no" "$([[ -e /opt/telcoin/start-telcoin.sh ]] && echo yes || echo no)"

# systemd-creds failing inside the encrypt step: one rollback, by the run itself.
legacy
touch "$T/sd255"
printf '%s\n' "[Service]" 'Environment="TN_BLS_PASSPHRASE=embedded-Pass-3"' "User=telcoin" \
    "ExecStart=/opt/telcoin/start-telcoin-observer.sh" > /etc/systemd/system/telcoin-observer.service
chmod 0644 "$T/bin/systemd-creds"
migrate
chmod 0755 "$T/bin/systemd-creds"
check "encrypt fails: rolled back once, legacy layout back, no credential" "1 yes no" \
    "$(printf '%s\n' "$OUT" | grep -c 'Rolled back to the legacy layout') $([[ -e /etc/telcoin/observer/.node-meta ]] && echo yes || echo no) $([[ -e /etc/telcoin/bls-passphrase.cred ]] && echo yes || echo no)"

# Sealed TPM blobs refuse the migration whatever .node-meta records.
legacy
printf 'x\n' > /etc/telcoin/observer/bls-tpm.pub
migrate
check "tpm blobs: refused, nothing moved" "1 yes yes" \
    "${RC} $([[ -e /etc/telcoin/observer/.node-meta ]] && echo yes || echo no) $(has "$OUT" "--migrate-credential")"

# A TERM while the new unit starts rolls the run back to the legacy layout.
legacy
touch "$T/term"
migrate
check "signal: exit 143 and rolled back to the legacy layout" "143 yes yes yes" \
    "${RC} $([[ -e /etc/systemd/system/telcoin-observer.service ]] && echo yes || echo no) $([[ -e /etc/telcoin/observer/.node-meta ]] && echo yes || echo no) $(has "$OUT" "Rolled back")"
check "signal: lock released" yes "$(lock_free)"

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
check "rollback: restart did not wait (mode read only by the check and the window before the stop)" 2 "$(grep -c 'curl tn_nodeMode' "$EV")"
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

# The committee check refuses the stop: nothing stopped, nothing left behind, and
# the snapshot copy of a unit that holds the passphrase is gone too.
legacy
: > "$T/voting"
printf '%s\n' "[Service]" 'Environment="TN_BLS_PASSPHRASE=embedded-Pass-1"' "User=telcoin" \
    "ExecStart=/opt/telcoin/start-telcoin-observer.sh" > /etc/systemd/system/telcoin-observer.service
migrate
check_rc "quorum refused: rc" 1 "$RC"
check "quorum refused: says why and names the override" "yes yes" \
    "$(has "$OUT" "committee check refused it") $(has "$OUT" "--allow-quorum-risk")"
check "quorum refused: guard read the committee, no stop, no restart-window wait" "yes no" \
    "$([[ $(line_of "curl tn_latestConsensusHeader http://127.0.0.1:8541") -gt 0 ]] && echo yes || echo no) $(has "$(cat "$EV")" "systemctl stop")"
check "quorum refused: no backup left (passphrase copy included)" "0" \
    "$(find /var/backups/telcoin -type f 2>/dev/null | wc -l | tr -d ' ')"
check "quorum refused: legacy layout untouched" "yes yes yes no" \
    "$([[ -d /etc/telcoin/observer ]] && echo yes || echo no) $([[ -d /var/lib/telcoin/observer ]] && echo yes || echo no) $(has "$(cat /etc/systemd/system/telcoin-observer.service)" "embedded-Pass-1") $([[ -e /etc/systemd/system/telcoin.service ]] && echo yes || echo no)"
check "quorum refused: lock released" yes "$(lock_free)"

legacy
: > "$T/voting"
TN_SKIP_EPOCH_WAIT=1 migrate --allow-quorum-risk
check_rc "quorum override: rc" 0 "$RC"
check "quorum override: warned, then stopped" "yes yes" \
    "$(has "$OUT" "quorum-risk override is set") $(has "$(cat "$EV")" "systemctl stop telcoin-observer")"

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
