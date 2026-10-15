#!/usr/bin/env bash
# =============================================================================
# tools/tests/edit_passphrase_test.sh -- edit-config.sh's BLS passphrase edit:
# the tn_passphrase_ok refusals (blanks at either end, short on mainnet, an
# unknown network read as mainnet), the root 0600 write (a host without
# systemd-creds keeps the root-only file), the move of a legacy Docker unit
# that embeds the value, the refusal of every other edit on such a unit, a
# committee check refusing the restart (edit put back, update lock released), and
# that the value never reaches a child process's argument list or environment.
#
#   bash tools/tests/edit_passphrase_test.sh
#   docker run --rm -v "$PWD:/w" -w /w bash:3.2 bash tools/tests/edit_passphrase_test.sh
#   docker run --rm -v "$PWD:/w" -w /w ubuntu:24.04 bash tools/tests/edit_passphrase_test.sh
#
# Every external command the edit can run is a wrapper on PATH that appends
# its argv and its environment to logs, then runs the real tool (systemctl,
# perl, docker and telcoin-network are stubs; systemctl reports the node
# stopped, so nothing restarts). The start script and unit re-render is a stub
# (it has its own tests). As a normal user a valid value is refused by the
# root-only backup or write (the fixture is not root-owned), which the test
# checks; as root (under /root) the write itself is checked.
# =============================================================================

set -u

# shellcheck source=tools/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

T="$TN_TEST_TMP"
RB=""
trap 'tn_test_cleanup; if [[ -n "$RB" ]]; then rm -rf "$RB"; fi' EXIT

mkdir -p "$T/h" "$T/bin"
grep -v '^main "\$@"$' "$TN_TEST_REPO/edit-config.sh" > "$T/h/edit-config.sh"
ln -s "$TN_TEST_REPO/lib" "$T/h/lib"
TN_ROOT_PREFIX="$T/fx"
tn_test_pre_common
# shellcheck source=/dev/null
source "$T/h/edit-config.sh"
tn_test_post_common

has() {
    case "$1" in
        *"$2"*) echo yes ;;
        *) echo no ;;
    esac
}
owner_mode() { stat -c '%u %g %a' -- "$1" 2>/dev/null; }

IS_ROOT=0
[[ "$(id -u)" == 0 ]] && IS_ROOT=1
if [[ $IS_ROOT == 1 ]]; then
    RB="$(mktemp -d /root/.tn-test.XXXXXX 2>/dev/null)" || RB=""
    if [[ -n "$RB" ]]; then
        chmod 0700 "$RB"
        tn_root_dir_ok "$RB" || { rm -rf "$RB"; RB=""; }
    fi
fi
: > "$T/probe1"
HAVE_MV_T=0
mv -f -T -- "$T/probe1" "$T/probe2" 2>/dev/null && HAVE_MV_T=1
HAVE_CP_NP=0
cp --no-preserve=all -- "$T/probe2" "$T/probe3" 2>/dev/null && HAVE_CP_NP=1
ROOT_OK=0
ROOT_WHY="not root"
if [[ $IS_ROOT == 1 && -n "$RB" && $HAVE_MV_T == 1 ]]; then
    ROOT_OK=1
elif [[ $IS_ROOT == 1 ]]; then
    ROOT_WHY="no mv -T, or no root-only temp dir under /root"
fi
# A passphrase write backs up the files it changes first (tn_backup_file needs
# cp --no-preserve, which busybox lacks).
WRITE_OK=0
if [[ $ROOT_OK == 1 && $HAVE_CP_NP == 1 ]]; then
    WRITE_OK=1
elif [[ $ROOT_OK == 1 ]]; then
    ROOT_WHY="cp --no-preserve absent"
fi

# Wrappers: log argv and environment, then run the real tool.
ARGV_LOG="$T/argv.log"
ALL_ARGV="$T/argv-all.log"
ENV_LOG="$T/env.log"
# The wrappers call env by its real path: through PATH they would reach the
# env wrapper itself.
REAL_ENV="$(command -v env)"
: > "$ARGV_LOG"
: > "$ALL_ARGV"
: > "$ENV_LOG"
for c in cat chmod chown cp grep mktemp mv rm sed sha256sum stat sleep awk head \
         tail tr wc env id getent flock dirname basename sh setpriv runuser cmp date; do
    real="$(command -v "$c" 2>/dev/null)" || real=""
    [[ -n "$real" && "$real" == /* ]] || continue
    printf '#!/bin/sh\nprintf "%%s\\n" "%s $*" >> "%s"\nprintf "%%s\\n" "%s $*" >> "%s"\n"%s" >> "%s"\nexec "%s" "$@"\n' \
        "$c" "$ARGV_LOG" "$c" "$ALL_ARGV" "$REAL_ENV" "$ENV_LOG" "$real" > "$T/bin/$c"
    chmod 0755 "$T/bin/$c"
done
# systemctl reports the node stopped; the rest only record.
for c in systemctl perl docker telcoin-network; do
    printf '#!/bin/sh\nprintf "%%s\\n" "%s $*" >> "%s"\nprintf "%%s\\n" "%s $*" >> "%s"\n"%s" >> "%s"\n' \
        "$c" "$ARGV_LOG" "$c" "$ALL_ARGV" "$REAL_ENV" "$ENV_LOG" > "$T/bin/$c"
    [[ "$c" == systemctl ]] && printf 'case "$1" in is-active) exit 3 ;; esac\n' >> "$T/bin/$c"
    printf 'exit 0\n' >> "$T/bin/$c"
    chmod 0755 "$T/bin/$c"
done
ORIG_PATH="$PATH"
PATH="$T/bin:$PATH"

confirm() { return 0; }
apply_changes() { :; }
edit_epoch_wait() { :; }
edit_pause() { edit_unlock; }
# The re-render writes a unit for the method it is given (legacy units included).
tn_rerender_node_launch() {
    printf '[Service]\nLoadCredential=bls-passphrase:/etc/telcoin/bls-passphrase\nExecStart=/usr/local/libexec/telcoin/tn-start\n' \
        | tn_write_root_file "$TARGET_SERVICE_FILE" 0644
}
TN_UPDATE_LOCK_FILE="$T/update.lock"
TARGET_SERVICE="telcoin"

# fixture BASE -- a node tree at BASE: .node-meta, the passphrase file, a
# LoadCredential unit; TN_ROOT_PREFIX, TARGET_SERVICE_FILE and TN_BACKUP_DIR
# point at it. Directories are 0755 (root-owned when run as root).
fixture() {
    FXB="$1"
    rm -rf "$FXB"
    mkdir -p "$FXB/etc/telcoin" "$FXB/etc/systemd/system"
    chmod 0755 "$FXB" "$FXB/etc" "$FXB/etc/telcoin" "$FXB/etc/systemd" "$FXB/etc/systemd/system"
    TN_ROOT_PREFIX="$FXB"
    TN_BACKUP_DIR="$FXB/backups"
    PASSFILE="$FXB/etc/telcoin/bls-passphrase"
    printf 'old-passphrase-value\n' > "$PASSFILE"
    chmod 0600 "$PASSFILE"
    TARGET_SERVICE_FILE="$FXB/etc/systemd/system/telcoin.service"
    printf '[Service]\nLoadCredential=bls-passphrase:/etc/telcoin/bls-passphrase\nExecStart=/usr/local/libexec/telcoin/tn-start\n' > "$TARGET_SERVICE_FILE"
    chmod 0644 "$TARGET_SERVICE_FILE"
}
# set_network NETWORK [old-layout] -- .node-meta for a node set up by this
# release (OWNERSHIP_LAYOUT=2, so tn_migrate_ownership has nothing to do), or,
# with old-layout, for one still on the service-user-owned layout.
set_network() {
    if [[ -n "$1" ]]; then
        printf 'NETWORK=%s\n' "$1" > "$FXB/etc/telcoin/.node-meta"
    else
        : > "$FXB/etc/telcoin/.node-meta"
    fi
    if [[ "${2:-}" != "old-layout" ]]; then
        printf 'OWNERSHIP_LAYOUT=2\n' >> "$FXB/etc/telcoin/.node-meta"
    fi
}

USED=()
# edit VALUE [CONFIRM] -- run edit_bls_passphrase with VALUE typed twice (or
# VALUE then CONFIRM, then VALUE twice); OUT gets everything it printed.
edit() {
    USED+=("$1")
    if [[ $# -ge 2 ]]; then
        printf '1\n%s\n%s\n%s\n%s\n' "$1" "$2" "$1" "$1" > "$T/in"
    else
        printf '1\n%s\n%s\n' "$1" "$1" > "$T/in"
    fi
    edit_bls_passphrase < "$T/in" > "$T/out" 2>&1
    RC=$?
    OUT="$(cat "$T/out")"
    edit_unlock
}

if [[ $ROOT_OK == 1 ]]; then
    BASE="$RB/fx"
else
    BASE="$T/fx"
fi

# -----------------------------------------------------------------------------
# Refusals: nothing is written, nothing is stopped
# -----------------------------------------------------------------------------
fixture "$BASE"
set_network testnet
: > "$ARGV_LOG"
edit " leading-blank"
check "refused: leading blank" yes "$(has "$OUT" "Passphrase refused")"
check "refused: leading blank, file unchanged" "old-passphrase-value" "$(cat "$PASSFILE")"
check "refused: nothing stopped" no "$(has "$(cat "$ARGV_LOG")" "systemctl stop")"
edit "trailing-blank "
check "refused: trailing blank" yes "$(has "$OUT" "Passphrase refused")"
edit $'tab-at-end\t'
check "refused: trailing tab" yes "$(has "$OUT" "Passphrase refused")"
check "refused: testnet message has no 16-byte rule" no "$(has "$OUT" "16 bytes")"
check "refused: file still unchanged" "old-passphrase-value" "$(cat "$PASSFILE")"

set_network mainnet
edit "abcdefghijklmno"
check "refused: 15 bytes on mainnet" yes "$(has "$OUT" "Passphrase refused")"
check "refused: mainnet names the 16-byte rule" yes "$(has "$OUT" "at least 16 bytes")"
check "refused: 15 bytes, file unchanged" "old-passphrase-value" "$(cat "$PASSFILE")"

set_network ""
edit "short"
check "unknown network: mainnet rules apply" yes "$(has "$OUT" "at least 16 bytes")"
printf 'NETWORK=testnet\nNETWORK=testnet\n' > "$FXB/etc/telcoin/.node-meta"
edit "short"
check "duplicate NETWORK: mainnet rules apply" yes "$(has "$OUT" "at least 16 bytes")"

# A mainnet node still on the old ownership layout is not migrated in place:
# the edit stops under the lock, before anything is written or stopped.
set_network mainnet old-layout
: > "$ARGV_LOG"
edit "abcdefghijklmnop"
check "old layout on mainnet: refused, fresh install asked for" yes "$(has "$OUT" "must be installed fresh")"
check "old layout on mainnet: file unchanged" "old-passphrase-value" "$(cat "$PASSFILE")"
check "old layout on mainnet: nothing stopped" no "$(has "$(cat "$ARGV_LOG")" "systemctl stop")"
check "old layout on mainnet: .node-meta unchanged" "NETWORK=mainnet" "$(cat "$FXB/etc/telcoin/.node-meta")"

# -----------------------------------------------------------------------------
# Accepted values: root 0600 write (as root), refused directory (otherwise)
# -----------------------------------------------------------------------------
# Mainnet keeps the passphrase only as an encrypted credential: without
# systemd-creds the accepted value is refused before anything is written.
set_network mainnet
edit "abcdefghijklmnop"
check "16 bytes on mainnet, no systemd-creds: refused" yes "$(has "$OUT" "only as an encrypted credential")"
check "16 bytes on mainnet, no systemd-creds: file unchanged" "old-passphrase-value" "$(cat "$PASSFILE")"
set_network testnet
edit "abcdefghijklmnop"
if [[ $WRITE_OK == 1 ]]; then
    check "testnet: written" "abcdefghijklmnop" "$(cat "$PASSFILE")"
    check "written file is root 0600" "0 0 600" "$(owner_mode "$PASSFILE")"
    check "no temp file left in the config dir" "" "$(find "$FXB/etc/telcoin" -name '.tn.*' 2>/dev/null)"
    check "method recorded as stdin" "stdin" "$(meta_get PASSPHRASE_METHOD "$FXB/etc/telcoin/.node-meta" 2>/dev/null)"
    check "backups shredded afterwards" "0" "$(find "$TN_BACKUP_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')"
else
    check "testnet: passes the check, backup or write refused here" yes "$(has "$OUT" "nothing was changed")"
    check "testnet: file unchanged when refused" "old-passphrase-value" "$(cat "$PASSFILE")"
fi

edit "mismatch-one-value-xx" "mismatch-two-value-yy"
check "mismatch: asked again" yes "$(has "$OUT" "do not match")"
if [[ $WRITE_OK == 1 ]]; then
    check "mismatch then match: the matched value is written" "mismatch-one-value-xx" "$(cat "$PASSFILE")"
fi

edit $'crlf-pasted-value-1\r'
USED+=("crlf-pasted-value-1")
if [[ $WRITE_OK == 1 ]]; then
    check "one trailing CR dropped" "crlf-pasted-value-1" "$(cat "$PASSFILE")"
fi

set_network testnet
edit "a b c interior spaces ok"
if [[ $WRITE_OK == 1 ]]; then
    check "interior blanks accepted for a credential unit" "a b c interior spaces ok" "$(cat "$PASSFILE")"
else
    skip "root 0600 write of accepted values" "$ROOT_WHY"
fi

# -----------------------------------------------------------------------------
# Legacy Docker unit with the value on ExecStart: every other edit is refused;
# the passphrase menu moves it (the value read from the unit by awk)
# -----------------------------------------------------------------------------
fixture "$BASE"
set_network testnet
UNIT_BEFORE="[Service]
User=root
ExecStart=/usr/bin/docker run --rm -e TN_BLS_PASSPHRASE=old-docker-value-1 -e X=1 img:v1 telcoin node
Environment=\"OTHER=1\""
printf '%s\n' "$UNIT_BEFORE" > "$TARGET_SERVICE_FILE"
chmod 0644 "$TARGET_SERVICE_FILE"
USED+=("old-docker-value-1")

rc=0; edit_lock > "$T/out" 2>&1 || rc=$?
edit_unlock
check_rc "legacy unit: any other edit refused under the lock" 1 "$rc"
check "legacy unit: the refusal names --migrate-credential" yes "$(has "$(cat "$T/out")" "--migrate-credential")"

: > "$ARGV_LOG"
printf 'y\n' > "$T/in"
edit_bls_passphrase < "$T/in" > "$T/out" 2>&1
OUT="$(cat "$T/out")"
edit_unlock
check "legacy unit: the menu offers the move" yes "$(has "$OUT" "must move to the current unit")"
check "legacy unit: perl never runs" no "$(has "$(cat "$ARGV_LOG")" "perl ")"
if [[ $ROOT_OK == 1 && $HAVE_CP_NP == 1 ]]; then
    check "legacy unit: the unit no longer holds the value" no "$(has "$(cat "$TARGET_SERVICE_FILE")" "TN_BLS_PASSPHRASE=")"
    check "legacy unit: passphrase file holds the unit's value" "old-docker-value-1" "$(cat "$PASSFILE")"
    check "legacy unit: method recorded as stdin" "stdin" "$(meta_get PASSPHRASE_METHOD "$FXB/etc/telcoin/.node-meta" 2>/dev/null)"
    check "legacy unit: backups shredded" "0" "$(find "$TN_BACKUP_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')"
else
    check "legacy unit: unit unchanged when the backup or write is refused" "$UNIT_BEFORE" "$(cat "$TARGET_SERVICE_FILE")"
    check "legacy unit: passphrase file unchanged too" "old-passphrase-value" "$(cat "$PASSFILE")"
    if [[ $ROOT_OK == 1 ]]; then
        skip "legacy unit: root move" "cp --no-preserve absent"
    else
        skip "legacy unit: root move" "$ROOT_WHY"
    fi
fi

# -----------------------------------------------------------------------------
# A running node and a committee check that refuses the restart: the edit is
# put back and the update lock is free once the menu item returns
# -----------------------------------------------------------------------------
fixture "$BASE"
set_network testnet
TARGET_LAUNCH_FILE=""
systemctl() {
    printf 'systemctl %s\n' "$*" >> "$ARGV_LOG"
    case "$1" in is-active) return 0 ;; esac
    return 0
}
tn_committee_down_guard() { printf 'guard\n' >> "$ARGV_LOG"; return 1; }
: > "$ARGV_LOG"
USED+=("guard-refused-value-5")
printf '1\n%s\n%s\n' "guard-refused-value-5" "guard-refused-value-5" > "$T/in"
edit_bls_passphrase < "$T/in" > "$T/out" 2>&1
OUT="$(cat "$T/out")"
lock_probe=free
if command -v flock >/dev/null 2>&1 && [[ -e "$TN_UPDATE_LOCK_FILE" ]]; then
    flock -n "$TN_UPDATE_LOCK_FILE" true 2>/dev/null || lock_probe=held
fi
check "guard refusal: the update lock is released (state, kind, probe)" "false - free" \
    "${EDIT_LOCK_HELD} ${TN_UPDATE_LOCK_KIND:--} ${lock_probe}"
check "guard refusal: the stored passphrase is as before" "old-passphrase-value" "$(cat "$PASSFILE")"
check "guard refusal: nothing stopped or restarted" "no no" \
    "$(has "$(cat "$ARGV_LOG")" "systemctl stop") $(has "$(cat "$ARGV_LOG")" "systemctl restart")"
if [[ $WRITE_OK == 1 ]]; then
    check "guard refusal: the check ran and the reason is shown" "yes yes" \
        "$(has "$(cat "$ARGV_LOG")" "guard") $(has "$OUT" "quorum")"
fi
edit_unlock
unset -f systemctl tn_committee_down_guard

# -----------------------------------------------------------------------------
# The value never reached a child's argv or environment
# -----------------------------------------------------------------------------
check "wrappers recorded commands (control)" yes "$(has "$(cat "$ARGV_LOG")" "grep ")"
fixture "$BASE"
set_network testnet
: > "$ARGV_LOG"
edit "argv-probe-value-77"
check "control: commands ran during the edit" yes "$([[ -s "$ARGV_LOG" ]] && echo yes || echo no)"
# Every value typed in this test, against every command line and environment
# recorded since the start.
for v in "${USED[@]}"; do
    [[ ${#v} -ge 8 ]] || continue
    check "argv never holds '${v}'" no "$(has "$(cat "$ALL_ARGV")" "$v")"
    check "environment never holds '${v}'" no "$(has "$(cat "$ENV_LOG")" "$v")"
done

PATH="$ORIG_PATH"
finish
