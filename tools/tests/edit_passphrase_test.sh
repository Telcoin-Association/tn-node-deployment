#!/usr/bin/env bash
# =============================================================================
# tools/tests/edit_passphrase_test.sh -- edit-config.sh's BLS passphrase edit:
# the tn_passphrase_ok refusals (blanks at either end, short on mainnet, an
# unknown network read as mainnet), the root 0600 write (a host without
# systemd-creds keeps the root-only file), the move of a legacy Docker unit
# that embeds the value, the refusal of every other edit on such a unit, a
# committee check refusing the restart (edit put back, update lock released),
# keytool verify before each credential action writes (change, reseal, the three
# kinds of move: refused, passed, absent from the release, probe failed), and
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
# A signal during a passphrase move: the --json done says where it stopped
# -----------------------------------------------------------------------------
( JSON_MODE=true JSON_DONE_SENT=false EDIT_SIGNAL=TERM EDIT_PENDING=false EDIT_LAST_ERROR=""
  _TN_CS_STATE=restarting _TN_CS_SVC=telcoin _TN_CS_BAK=("$T/bak.1")
  edit_on_exit ) 3> "$T/json.done" 2>/dev/null
check "signal after the restart was issued: done names the state, not 'nothing was changed'" "yes no" \
    "$(has "$(cat "$T/json.done")" "restarted on the new passphrase delivery") $(has "$(cat "$T/json.done")" "nothing was changed")"
( JSON_MODE=true JSON_DONE_SENT=false EDIT_SIGNAL=TERM EDIT_PENDING=false EDIT_LAST_ERROR=""
  _TN_CS_STATE=saving
  edit_on_exit ) 3> "$T/json.done" 2>/dev/null
check "signal while backing up: done says nothing was changed" "yes" "$(has "$(cat "$T/json.done")" "SIGTERM: stopped before the passphrase move changed anything")"

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

# -----------------------------------------------------------------------------
# KEYS: keytool verify before a credential action writes (edit_keytool_verify).
# The docker wrapper stands in for the node image: its `keytool --help` lists
# verify (KT_MODE=has), does not (lacks), or fails like docker (probe4, exit
# 125); `keytool verify` succeeds when its stdin is the key's passphrase
# ($T/kt.key). The write entry points are stubs that record the call and then
# rewrite the file the action would change, so a refusal shows as unchanged
# bytes and mtime and a pass as a recorded write.
# -----------------------------------------------------------------------------
KT_CALLS="$T/kt.calls"
export KT_CALLS KT_MODE=has
printf 'key-pass-correct-1\n' > "$T/kt.key"
SU_SAVE="$SERVICE_USER"
SG_SAVE="$SERVICE_GROUP"
if [[ $IS_ROOT == 1 ]]; then
    SERVICE_USER=nobody
    SERVICE_GROUP="$(id -gn nobody 2>/dev/null || echo nogroup)"
else
    SERVICE_USER="$(id -un)"
    SERVICE_GROUP="$(id -gn)"
fi
cat > "$T/bin/docker" <<STUB
#!/bin/sh
printf '%s\n' "docker \$*" >> "$ARGV_LOG"
printf '%s\n' "docker \$*" >> "$ALL_ARGV"
"$REAL_ENV" >> "$ENV_LOG"
case " \$* " in
    *" keytool --help "*)
        case "\$KT_MODE" in
            probe4) exit 125 ;;
            dockerfail)
                printf 'docker: Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?\n' >&2
                exit 1
                ;;
            claperr)
                printf "error: unrecognized subcommand 'verify'\n\nUsage: telcoin-network keytool <COMMAND>\n\nFor more information, try '--help'.\n" >&2
                exit 2
                ;;
            lacks) printf 'Usage: telcoin keytool <COMMAND>\n\nCommands:\n  generate  Generate keys\n  set-rpc   Set the RPC\n  help      Print help\n' ;;
            *) printf 'Usage: telcoin keytool <COMMAND>\n\nCommands:\n  generate  Generate keys\n  verify    Check that the passphrase opens the BLS key\n  help      Print help\n' ;;
        esac
        exit 0
        ;;
    *" keytool verify "*)
        IFS= read -r p || p=""
        if [ "\$p" = "\$(cat "$T/kt.key")" ]; then
            printf 'verify ok\n' >> "\$KT_CALLS"
            exit 0
        fi
        printf 'verify bad\n' >> "\$KT_CALLS"
        printf 'error: the passphrase does not decrypt the BLS key\n' >&2
        exit 1
        ;;
esac
exit 0
STUB
chmod 0755 "$T/bin/docker"
# systemd-creds: the credential is "CRED:<value>"; decrypt prints the value.
cat > "$T/bin/systemd-creds" <<STUB
#!/bin/sh
printf '%s\n' "systemd-creds \$*" >> "$ARGV_LOG"
printf '%s\n' "systemd-creds \$*" >> "$ALL_ARGV"
case "\$1" in
    decrypt) sed 's/^CRED://' "\$3" ;;
    *) exit 1 ;;
esac
STUB
chmod 0755 "$T/bin/systemd-creds"

tn_launch_runner() { printf 'docker:img:verify\n'; }
tn_creds_supported() { [[ "${KT_CREDS:-0}" == 1 ]]; }
# The fixture files stand in for root-owned ones.
_tn_cred_plain_ok() { [[ -f "$1" && ! -L "$1" ]]; }
# kt_write NAME -- what a write entry point records: its name, and "match" when
# the passphrase it is about to keep is the key's (the same as was verified).
kt_write() {
    local m=nomatch
    [[ "$TN_CRED_PASS" == "$(cat "$T/kt.key")" ]] && m=match
    printf 'write %s %s\n' "$1" "$m" >> "$KT_CALLS"
    printf 'CRED:rewritten\n' > "$CRED"
}
_tn_cred_switch() { kt_write switch; return 0; }
tn_migrate_embedded_passphrase() { kt_write embedded; return 0; }
# The plaintext file is what this one reads, as the real one does.
tn_migrate_credential() {
    if [[ -z "$TN_CRED_PASS" ]]; then
        IFS= read -r TN_CRED_PASS < "$PASSFILE" || true
    fi
    kt_write migrate
    TN_CRED_PASS=""
    return 0
}
mtime() { stat -c %Y -- "$1" 2>/dev/null || stat -f %m -- "$1" 2>/dev/null; }
# kt_fixture METHOD -- a testnet node with METHOD recorded, a data dir owned by
# the service user, a credential and a passphrase file dated 2020.
kt_fixture() {
    fixture "$BASE"
    set_network testnet
    printf 'PASSPHRASE_METHOD=%s\nDATA_DIR=%s\n' "$1" "$FXB/data" >> "$FXB/etc/telcoin/.node-meta"
    mkdir -p "$FXB/data"
    [[ $IS_ROOT == 1 ]] && chown nobody "$FXB/data"
    CRED="$FXB/etc/telcoin/bls-passphrase.cred"
    printf 'CRED:%s\n' "${KT_SEALED:-sealed-before-7}" > "$CRED"
    touch -t 202001010000 "$CRED" "$PASSFILE"
    CRED_BEFORE="$(cat "$CRED") $(mtime "$CRED")"
    PASS_BEFORE="$(cat "$PASSFILE") $(mtime "$PASSFILE")"
    TARGET_LAUNCH_FILE="$TARGET_SERVICE_FILE"
    : > "$KT_CALLS"
}
kt_calls() { tr '\n' '|' < "$KT_CALLS" | sed 's/|$//'; }
# kt_unchanged LABEL -- the credential and the passphrase file kept their bytes
# and mtime, and no write entry point ran.
kt_unchanged() {
    check "$1: credential bytes and mtime unchanged" "$CRED_BEFORE" "$(cat "$CRED") $(mtime "$CRED")"
    check "$1: passphrase file bytes and mtime unchanged" "$PASS_BEFORE" "$(cat "$PASSFILE") $(mtime "$PASSFILE")"
    check_lacks "$1: nothing written" "write" "$(kt_calls)"
}
# kt_run FN STDIN -- run FN with STDIN; RC and OUT as edit.
kt_run() {
    printf '%s' "$2" > "$T/in"
    RC=0
    "$1" < "$T/in" > "$T/out" 2>&1 || RC=$?
    OUT="$(cat "$T/out")"
    cat "$T/out" >> "$T/kt.allout"
    edit_unlock
}
: > "$T/kt.allout"
USED_KT=(key-pass-correct-1 wrong-new-pass-2 sealed-wrong-pass-4 typed-wrong-pass-5 unit-wrong-pass-6 plain-wrong-pass-8)

# --- edit_change_passphrase (menu 5, 1): the new passphrase is verified --------
KT_MODE=has; kt_fixture stdin
kt_run edit_bls_passphrase $'1\nwrong-new-pass-2\nwrong-new-pass-2\n'
check "change, verify fails: the refusal says the new passphrase does not open the key" yes \
    "$(has "$OUT" "The new passphrase does not open the BLS key in ${FXB}/data")"
check "change, verify fails: passphrase unchanged" yes "$(has "$OUT" "Passphrase unchanged.")"
check "change, verify fails: keytool verify saw the typed value on stdin (and refused it)" "verify bad" "$(kt_calls)"
kt_unchanged "change, verify fails"
check "change, verify fails: the update lock is released" false "$EDIT_LOCK_HELD"

kt_fixture stdin
kt_run edit_bls_passphrase $'1\nkey-pass-correct-1\nkey-pass-correct-1\n'
check "change, verify passes: verified, then written" "verify ok|write switch match" "$(kt_calls)"
check "change, verify passes: says so" yes "$(has "$OUT" "keytool verify: the passphrase opens the BLS key")"
check "change, verify passes: keytool reads the passphrase on stdin" yes "$(has "$(cat "$ALL_ARGV")" "--bls-passphrase-source stdin keytool verify")"

KT_MODE=lacks; kt_fixture stdin
kt_run edit_bls_passphrase $'1\nanything-value-3x\nanything-value-3x\n'
check "change, no verify in the release: written without a check" "write switch nomatch" "$(kt_calls)"
check "change, no verify in the release: the log line" yes "$(has "$OUT" "keytool verify is not in this release; skipped")"
check "change, no verify in the release: no warning" no "$(has "$OUT" "Could not run the node binary")"

KT_MODE=probe4; kt_fixture stdin
kt_run edit_bls_passphrase $'1\nanything-value-3x\nanything-value-3x\n'
check "change, probe fails: written without a check" "write switch nomatch" "$(kt_calls)"
check "change, probe fails: warns that the probe could not run" yes "$(has "$OUT" "Could not run the node binary of docker:img:verify to see whether it has keytool verify; skipped")"

# keytool verify is in the release but cannot start (no data dir): stop.
KT_MODE=has; kt_fixture stdin
rm -rf "$FXB/data"
kt_run edit_bls_passphrase $'1\nkey-pass-correct-1\nkey-pass-correct-1\n'
check "change, verify cannot start: refused with tn_keytool's reason" yes \
    "$(has "$OUT" "keytool verify could not run (exit 4: tn_keytool: data dir")"
kt_unchanged "change, verify cannot start"

# The probe's rc 1 or 2 is "not listed" only when the output is clap's own (a
# Usage: line naming keytool); a runner or privilege-drop wrapper failing with 1
# is rc 4 (busybox setpriv rejects --reuid with exit 1).
KT_BIN="binary:$T/bin/telcoin-network"
cp "$T/bin/setpriv" "$T/setpriv.wrapper" 2>/dev/null || : > "$T/setpriv.wrapper"
cat > "$T/bin/setpriv.fail" <<STUB
#!/bin/sh
printf '%s\n' "setpriv \$*" >> "$ALL_ARGV"
printf "setpriv: unrecognized option '--reuid'\n" >&2
exit 1
STUB
chmod 0755 "$T/bin/setpriv.fail"
_tn_root_binary_ok() { TN_ROOT_BINARY_REAL="$1"; return 0; }
kt_has_rc() { local rc=0; tn_keytool_has "$1" verify >/dev/null 2>&1 || rc=$?; printf '%s\n' "$rc"; }
for m in has lacks claperr probe4 dockerfail; do
    KT_MODE="$m"
    eval "KT_RC_${m}=\$(kt_has_rc docker:img:verify)"
done
check "tn_keytool_has: listed / not listed / clap error / docker 125 / docker 1 with its own message" \
    "0 1 1 4 4" "${KT_RC_has} ${KT_RC_lacks} ${KT_RC_claperr} ${KT_RC_probe4} ${KT_RC_dockerfail}"
mv -f "$T/bin/setpriv.fail" "$T/bin/setpriv"
check "tn_keytool_has: a binary whose privilege drop fails with 1 could not be probed" 4 "$(kt_has_rc "$KT_BIN")"

# The menu's change on that host: a warning, not "not in this release", and the
# probe-rc-4 path (no check, the write goes ahead as without keytool verify).
KT_MODE=has; kt_fixture stdin
tn_launch_runner() { printf '%s\n' "$KT_BIN"; }
kt_run edit_bls_passphrase $'1\nwrong-new-pass-2\nwrong-new-pass-2\n'
check "change, privilege drop fails: warns that the probe could not run" yes \
    "$(has "$OUT" "Could not run the node binary of ${KT_BIN} to see whether it has keytool verify; skipped")"
check "change, privilege drop fails: not taken for a release without verify" no "$(has "$OUT" "not in this release")"
check "change, privilege drop fails: the probe-rc-4 path (no check, then the write)" "write switch nomatch" "$(kt_calls)"
cp "$T/setpriv.wrapper" "$T/bin/setpriv"
[[ -s "$T/bin/setpriv" ]] || rm -f "$T/bin/setpriv"
unset -f _tn_root_binary_ok

# A clap error from the release is its answer: verify is not in it.
KT_MODE=claperr; kt_fixture stdin
tn_launch_runner() { printf 'docker:img:verify\n'; }
kt_run edit_bls_passphrase $'1\nanything-value-3x\nanything-value-3x\n'
check "change, clap error from the probe: the log line, no warning" "yes no" \
    "$(has "$OUT" "keytool verify is not in this release; skipped") $(has "$OUT" "Could not run the node binary")"
check "change, clap error from the probe: written without a check" "write switch nomatch" "$(kt_calls)"

KT_MODE=has; kt_fixture stdin
tn_launch_runner() { return 2; }
kt_run edit_bls_passphrase $'1\nanything-value-3x\nanything-value-3x\n'
tn_launch_runner() { printf 'docker:img:verify\n'; }
check "change, runner unknown: written without a check" "write switch nomatch" "$(kt_calls)"
check "change, runner unknown: warns" yes "$(has "$OUT" "keytool verify skipped")"

# --- edit_reseal (--reseal, and menu 5, 2): the decrypted value is verified ----
KT_CREDS=1
KT_MODE=has; KT_SEALED=sealed-wrong-pass-4; kt_fixture credential
kt_run edit_reseal ""
check_rc "reseal, verify fails: rc 1" 1 "$RC"
check "reseal, verify fails: the refusal" yes "$(has "$OUT" "The passphrase does not open the BLS key")"
check "reseal, verify fails: keytool verify refused the sealed value" "verify bad" "$(kt_calls)"
kt_unchanged "reseal, verify fails"

KT_SEALED=key-pass-correct-1; kt_fixture credential
kt_run edit_reseal ""
check_rc "reseal, verify passes: rc 0" 0 "$RC"
check "reseal, verify passes: verified, then sealed again" "verify ok|write switch match" "$(kt_calls)"

KT_MODE=lacks; KT_SEALED=sealed-before-7; kt_fixture credential
kt_run edit_reseal ""
check "reseal, no verify in the release: sealed again without a check" "write switch nomatch" "$(kt_calls)"
check "reseal, no verify in the release: the log line" yes "$(has "$OUT" "keytool verify is not in this release; skipped")"

KT_MODE=probe4; kt_fixture credential
kt_run edit_reseal ""
check "reseal, probe fails: sealed again without a check" "write switch nomatch" "$(kt_calls)"
check "reseal, probe fails: the warning" yes "$(has "$OUT" "to see whether it has keytool verify; skipped")"

# The same refusal reached from the menu.
KT_MODE=has; KT_SEALED=sealed-wrong-pass-4; kt_fixture credential
kt_run edit_bls_passphrase $'2\n'
check "menu reseal, verify fails: the refusal" yes "$(has "$OUT" "The passphrase does not open the BLS key")"
kt_unchanged "menu reseal, verify fails"
KT_CREDS=0
KT_SEALED=""

# --- edit_migrate_credential: the file it reads, a typed value, a unit's value --
KT_MODE=has; kt_fixture stdin
printf 'plain-wrong-pass-8\n' > "$PASSFILE"
touch -t 202001010000 "$PASSFILE"
PASS_BEFORE="$(cat "$PASSFILE") $(mtime "$PASSFILE")"
kt_run edit_migrate_credential ""
check_rc "migrate file, verify fails: rc 1" 1 "$RC"
check "migrate file, verify fails: the refusal names the file" yes \
    "$(has "$OUT" "The passphrase in ${FXB}/etc/telcoin/bls-passphrase does not open the BLS key")"
check "migrate file, verify fails: keytool verify refused the file's value" "verify bad" "$(kt_calls)"
kt_unchanged "migrate file, verify fails"

kt_fixture stdin
printf 'key-pass-correct-1\n' > "$PASSFILE"
kt_run edit_migrate_credential ""
check_rc "migrate file, verify passes: rc 0" 0 "$RC"
check "migrate file, verify passes: verified, then moved" "verify ok|write migrate match" "$(kt_calls)"

KT_MODE=lacks; kt_fixture stdin
kt_run edit_migrate_credential ""
check "migrate file, no verify in the release: moved without a check" "write migrate nomatch" "$(kt_calls)"
check "migrate file, no verify in the release: the log line" yes "$(has "$OUT" "keytool verify is not in this release; skipped")"

KT_MODE=probe4; kt_fixture stdin
kt_run edit_migrate_credential ""
check "migrate file, probe fails: moved without a check" "write migrate nomatch" "$(kt_calls)"
check "migrate file, probe fails: the warning" yes "$(has "$OUT" "to see whether it has keytool verify; skipped")"

# No stored passphrase: the typed one is verified.
KT_MODE=has; kt_fixture stdin
rm -f "$PASSFILE"
PASS_BEFORE=" "
kt_run edit_migrate_credential $'typed-wrong-pass-5\n'
check "migrate typed, verify fails: refused" "1 verify bad" "${RC} $(kt_calls)"
kt_unchanged "migrate typed, verify fails"

# A legacy unit that holds the value, from the menu's move.
for kt in unit-wrong-pass-6 key-pass-correct-1; do
    kt_fixture stdin
    printf '[Service]\nExecStart=/usr/bin/docker run --rm -e TN_BLS_PASSPHRASE=%s img:v1 telcoin node\n' "$kt" > "$TARGET_SERVICE_FILE"
    kt_run edit_bls_passphrase $'y\n'
    if [[ "$kt" == key-pass-correct-1 ]]; then
        check "migrate unit, verify passes: verified, then moved" "verify ok|write embedded match" "$(kt_calls)"
    else
        check "migrate unit, verify fails: the refusal" yes "$(has "$OUT" "The passphrase does not open the BLS key")"
        kt_unchanged "migrate unit, verify fails"
    fi
done

# The passphrase reached keytool on stdin only: never an argument or an
# environment value of anything the actions ran.
check "control: keytool verify ran through docker" yes "$(has "$(cat "$ALL_ARGV")" " keytool verify")"
for v in "${USED_KT[@]}"; do
    check "KEYS: output never holds '${v}'" no "$(has "$(cat "$T/kt.allout")" "$v")"
    check "KEYS: argv never holds '${v}'" no "$(has "$(cat "$ALL_ARGV")" "$v")"
    check "KEYS: environment never holds '${v}'" no "$(has "$(cat "$ENV_LOG")" "$v")"
done
SERVICE_USER="$SU_SAVE"
SERVICE_GROUP="$SG_SAVE"
unset -f tn_launch_runner tn_creds_supported _tn_cred_plain_ok _tn_cred_switch \
    tn_migrate_embedded_passphrase tn_migrate_credential

PATH="$ORIG_PATH"
finish
