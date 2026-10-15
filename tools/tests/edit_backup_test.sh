#!/usr/bin/env bash
# =============================================================================
# tools/tests/edit_backup_test.sh -- edit-config.sh's backups and restores
# (root-only backup directory, sha256 checked on restore), the data-dir writes
# done as the service user (restore and the chain-config refresh copy), the
# shared update lock, the ownership-migration hook in edit_lock, and an older
# install moved to the current start script by an edit that is then abandoned.
#
#   bash tools/tests/edit_backup_test.sh
#   docker run --rm -v "$PWD:/w" -w /w bash:3.2 bash tools/tests/edit_backup_test.sh
#   docker run --rm -v "$PWD:/w" -w /w ubuntu:24.04 bash tools/tests/edit_backup_test.sh
#
# The lock and migration-hook cases run as any user. The backup, restore and
# service-user cases need root, GNU cp/mv and setpriv or runuser with a
# `nobody` account standing in for the service user; elsewhere they print SKIP.
# =============================================================================

set -u

# shellcheck source=tools/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

T="$TN_TEST_TMP"
RB=""
PUB=""
trap 'tn_test_cleanup; if [[ -n "$RB" ]]; then rm -rf "$RB"; fi; if [[ -n "$PUB" ]]; then rm -rf "$PUB"; fi' EXIT

mkdir -p "$T/h"
grep -v '^main "\$@"$' "$TN_TEST_REPO/edit-config.sh" > "$T/h/edit-config.sh"
ln -s "$TN_TEST_REPO/lib" "$T/h/lib"
TN_ROOT_PREFIX="$T/fx"
tn_test_pre_common
# shellcheck source=/dev/null
source "$T/h/edit-config.sh"
tn_test_post_common

run() {
    OUT="$("$@" 2>"$T/.err")"
    RC=$?
    ERR="$(cat "$T/.err")"
}
has() {
    case "$1" in
        *"$2"*) echo yes ;;
        *) echo no ;;
    esac
}
owner_mode() { stat -c '%U %a' -- "$1" 2>/dev/null; }
TN_UPDATE_LOCK_FILE="$T/update.lock"

# -----------------------------------------------------------------------------
# Shared lock and the migration hook (any user)
# -----------------------------------------------------------------------------
# Called directly (not through run): the lock state lives in this shell.
edit_lock
check_rc "edit_lock: taken" 0 "$?"
check "edit_lock: held" "true" "$EDIT_LOCK_HELD"
edit_unlock
check "edit_unlock: released" "" "${TN_UPDATE_LOCK_KIND:-}"
check "edit_release_lock: no lock path of its own" no "$(has "$(declare -f edit_release_lock)" "telcoin-update.lock.d")"

MIGRATE_CALLS=0
MIGRATE_RC=0
MIGRATE_ARG=""
tn_migrate_ownership() { MIGRATE_CALLS=$((MIGRATE_CALLS + 1)); MIGRATE_ARG="${1:-}"; return "$MIGRATE_RC"; }
# The lock taken above already ran the (then absent) migration once for this
# run; start each case as a fresh run.
EDIT_OWNERSHIP_DONE=false
MIGRATE_RC=3
edit_lock 2>/dev/null
RC=$?
check_rc "migration refused (mainnet): edit_lock fails" 1 "$RC"
check "migration refused: lock released" "false" "$EDIT_LOCK_HELD"
check "migration refused: reason kept" yes "$(has "$EDIT_LAST_ERROR" "installed fresh")"
MIGRATE_RC=1
EDIT_OWNERSHIP_DONE=false
edit_lock 2>/dev/null
check "migration refused (symlink found): reason kept" yes "$(has "$EDIT_LAST_ERROR" "migration stopped")"
MIGRATE_RC=0
MIGRATE_CALLS=0
EDIT_OWNERSHIP_DONE=false
edit_lock
check_rc "migration done: edit_lock rc 0" 0 "$?"
check "migration: progress printer passed" "edit_wait_say" "$MIGRATE_ARG"
edit_unlock
edit_lock
edit_unlock
check "migration: runs once per run" "1" "$MIGRATE_CALLS"
unset -f tn_migrate_ownership

# -----------------------------------------------------------------------------
# Root: backups, restores, service-user writes
# -----------------------------------------------------------------------------
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
SU_OK=0
if id nobody >/dev/null 2>&1; then
    NOGROUP="$(id -gn nobody 2>/dev/null)" || NOGROUP=""
    if [[ $IS_ROOT == 1 && -n "$NOGROUP" ]] \
        && SERVICE_USER=nobody SERVICE_GROUP="$NOGROUP" tn_as_service_user true 2>/dev/null; then
        SU_OK=1
    fi
fi
WHY=""
if [[ $IS_ROOT != 1 ]]; then
    WHY="not root"
elif [[ -z "$RB" ]]; then
    WHY="no root-only temp dir under /root"
elif [[ $HAVE_MV_T != 1 || $HAVE_CP_NP != 1 ]]; then
    WHY="GNU mv -T or cp --no-preserve absent"
fi

if [[ -n "$WHY" ]]; then
    for n in "root-dir backup and restore" "tampered backup refused" "new file removed on restore" \
             "symlink refused" "data-dir restore as the service user" "chain-config copy as the service user"; do
        skip "$n" "$WHY"
    done
    finish
fi

TN_ROOT_PREFIX="$RB/fx"
TN_BACKUP_DIR="$RB/backups"
mkdir -p "$RB/fx/etc/telcoin" "$RB/fx/opt"
chmod 0755 "$RB/fx" "$RB/fx/etc" "$RB/fx/etc/telcoin" "$RB/fx/opt"
# The data dir must be reachable by the service user, so it lives under /tmp
# (traversable) rather than under /root.
PUB="$(mktemp -d /tmp/tn-edit-pub.XXXXXX)"
chmod 0755 "$PUB"
DD="$PUB/data"
mkdir -p "$DD"
printf 'DATA_DIR=%s\n' "$DD" > "$RB/fx/etc/telcoin/.node-meta"

LF="$RB/fx/opt/tn-start"
printf 'exec node --http\n' > "$LF"
chmod 0750 "$LF"

edit_reset_backups
edit_backup "$LF"
check_rc "root-dir backup: rc 0" 0 "$?"
check "root-dir backup: copy in the backup dir" yes "$(has "${EDIT_BK_COPIES[0]}" "$RB/backups/")"
check "root-dir backup: sha256 recorded" "$(sha256sum < "$LF" | cut -d' ' -f1)" "${EDIT_BK_SUMS[0]}"
check "root-dir backup: mode and group recorded" "750 root" "${EDIT_BK_MODES[0]}"
check "root-dir backup: nothing beside the file" "" "$(find "$RB/fx/opt" -name '*.bak*')"
NEWF="$RB/fx/etc/telcoin/bootstrap-peers.yaml"
edit_backup "$NEWF"
check "new file: recorded with no copy" "" "${EDIT_BK_COPIES[1]}"
run edit_report_backups
check "report: names file, copy and sha256" yes "$(has "$OUT$ERR" "Backup of ${LF} written: ${EDIT_BK_COPIES[0]} (sha256 ${EDIT_BK_SUMS[0]})")"

printf 'exec node --http --edited\n' > "$LF"
chmod 0644 "$LF"
printf 'peers\n' > "$NEWF"
run edit_restore_backups
check_rc "root-dir restore: rc 0" 0 "$RC"
check "root-dir restore: content back" "exec node --http" "$(cat "$LF")"
check "root-dir restore: mode back, root-owned" "root 750" "$(owner_mode "$LF")"
check "new file removed on restore" no "$([[ -e "$NEWF" ]] && echo yes || echo no)"

edit_reset_backups
edit_backup "$LF"
printf 'exec node --http --edited\n' > "$LF"
printf '# changed\n' >> "${EDIT_BK_COPIES[0]}"
run edit_restore_backups
check_rc "tampered backup: restore reports failure" 1 "$RC"
check "tampered backup: live file unchanged" "exec node --http --edited" "$(cat "$LF")"
check "tampered backup: file named" yes "$(has "$ERR$EDIT_LAST_ERROR" "could not restore ${LF}")"

edit_reset_backups
ln -s "$LF" "$RB/fx/opt/link"
run edit_backup "$RB/fx/opt/link"
check_rc "symlink refused by edit_backup" 1 "$RC"

# An install from before node.env moved to the current start script by an edit
# (launch_current_form), then the edit is abandoned: refused (run_set restores)
# or stopped by TERM (the EXIT trap restores). The start script the move created
# is removed with node.env, and the old launch file and unit are back.
OLDLF="$RB/fx/opt/telcoin/start-telcoin.sh"
NEWLF="$RB/fx/usr/local/libexec/telcoin/tn-start"
UNITF="$RB/fx/etc/systemd/system/telcoin.service"
OLD_UNIT='[Service]
ExecStart=/opt/telcoin/start-telcoin.sh'
old_form() {
    rm -rf "$RB/fx/usr" "$RB/fx/etc/telcoin/node.env"
    mkdir -p "$RB/fx/opt/telcoin" "$RB/fx/etc/systemd/system"
    chmod 0755 "$RB/fx/opt/telcoin" "$RB/fx/etc/systemd" "$RB/fx/etc/systemd/system"
    printf '#!/bin/bash\nexport PRIMARY_LISTENER_MULTIADDR=x\nexec node --http\n' > "$OLDLF"
    chmod 0755 "$OLDLF"
    printf '%s\n' "$OLD_UNIT" > "$UNITF"
    chmod 0644 "$UNITF"
    TARGET_LAUNCH_FILE="$OLDLF"
    TARGET_SERVICE_FILE="$UNITF"
    edit_reset_backups
}
tn_rerender_node_launch() {
    mkdir -p "${NEWLF%/*}"
    printf '#!/bin/bash\nexec node --bls-passphrase-source stdin --http\n' > "$NEWLF"
    printf 'PRIMARY_LISTENER_MULTIADDR=x\n' > "$RB/fx/etc/telcoin/node.env"
    printf '[Service]\nExecStart=/usr/local/libexec/telcoin/tn-start\n' > "$UNITF"
    return 0
}
resolve_launch_file() { TARGET_LAUNCH_FILE="$NEWLF"; }
old_form_back() {
    printf '%s %s %s %s' \
        "$([[ -e "$NEWLF" ]] && echo stray-tn-start || echo no-tn-start)" \
        "$([[ -e "$RB/fx/etc/telcoin/node.env" ]] && echo node.env || echo no-node.env)" \
        "$([[ "$(cat "$UNITF")" == "$OLD_UNIT" ]] && echo unit-back || echo unit-changed)" \
        "$([[ -f "$OLDLF" ]] && echo old-launch || echo no-old-launch)"
}
old_form
# Called directly (not through run): the backup set lives in this shell.
launch_current_form >/dev/null 2>&1
RC=$?
check_rc "old form: moved to the current start script" 0 "$RC"
check "old form: the new start script is in the backup set as new" "yes" \
    "$(i=0; while [[ $i -lt ${#EDIT_BK_FILES[@]} ]]; do [[ "${EDIT_BK_FILES[$i]}" == "$NEWLF" && -z "${EDIT_BK_COPIES[$i]}" ]] && echo yes; i=$((i + 1)); done)"
run edit_restore_backups
check_rc "old form, edit refused: restore rc 0" 0 "$RC"
check "old form, edit refused: no stray tn-start, node.env gone, unit and launch file back" \
    "no-tn-start no-node.env unit-back old-launch" "$(old_form_back)"
old_form
(
    trap edit_on_exit EXIT
    launch_current_form >/dev/null 2>&1
    EDIT_SIGNAL=TERM
    exit 143
) >/dev/null 2>&1
check "old form, stopped by TERM: no stray tn-start, node.env gone, unit and launch file back" \
    "no-tn-start no-node.env unit-back old-launch" "$(old_form_back)"
unset -f tn_rerender_node_launch resolve_launch_file

# A menu edit whose restart the committee check refuses is put back.
old_form
edit_backup "$UNITF"
printf '[Service]\nExecStart=/edited\n' > "$UNITF"
EV=""
systemctl() { EV="${EV}${EV:+ }$1"; return 0; }
confirm() { return 0; }
tn_committee_down_guard() { EV="${EV}${EV:+ }guard"; return 1; }
apply_changes < /dev/null > "$T/apply.out" 2>&1
set +e  # apply_changes ends with set -e
check "menu edit, guard refusal: no restart, unit put back" "no unit-back" \
    "$(has "$EV" restart) $([[ "$(cat "$UNITF")" == "$OLD_UNIT" ]] && echo unit-back || echo unit-changed)"
check "menu edit, guard refusal: says nothing was changed" yes "$(has "$(cat "$T/apply.out")" "nothing was changed")"
check "menu edit, guard refusal: no longer pending" false "$EDIT_PENDING"
unset -f systemctl confirm tn_committee_down_guard

if [[ $SU_OK != 1 ]]; then
    skip "data-dir restore as the service user" "no nobody account usable with setpriv or runuser"
    skip "chain-config copy as the service user" "no nobody account usable with setpriv or runuser"
    finish
fi
SERVICE_USER=nobody
SERVICE_GROUP="$NOGROUP"
chown nobody "$DD"
chmod 0700 "$DD"
PARAMS="$DD/parameters.yaml"
printf 'allow: false\n' > "$PARAMS"
chown nobody "$PARAMS"
chmod 0644 "$PARAMS"

edit_reset_backups
edit_backup "$PARAMS"
check_rc "data-dir backup: rc 0" 0 "$?"
check "data-dir backup: copy is root-only" "root 600" "$(owner_mode "${EDIT_BK_COPIES[0]}")"
printf 'allow: true\n' > "$PARAMS"
run edit_restore_backups
check_rc "data-dir restore: rc 0" 0 "$RC"
check "data-dir restore: content back" "allow: false" "$(cat "$PARAMS")"
check "data-dir restore: written by the service user" "nobody 644" "$(owner_mode "$PARAMS")"
check "data-dir restore: no temp file left" "" "$(find "$DD" -name '.tn.*')"

edit_reset_backups
edit_backup "$PARAMS"
printf 'allow: true\n' > "$PARAMS"
printf 'x' >> "${EDIT_BK_COPIES[0]}"
run edit_restore_backups
check_rc "data-dir tampered backup: refused" 1 "$RC"
check "data-dir tampered backup: file unchanged" "allow: true" "$(cat "$PARAMS")"

# refresh_copy_configs: as the service user, all three or none.
SRC="$PUB/src"
mkdir -p "$SRC"
chmod 0755 "$SRC"
for f in genesis committee parameters; do
    printf '%s: new\n' "$f" > "$SRC/${f}.yaml"
    chmod 0644 "$SRC/${f}.yaml"
done
run refresh_copy_configs "$SRC" "$DD"
check_rc "refresh copy: rc 0" 0 "$RC"
check "refresh copy: genesis" "genesis: new" "$(cat "$DD/genesis/genesis.yaml")"
check "refresh copy: committee" "committee: new" "$(cat "$DD/genesis/committee.yaml")"
check "refresh copy: parameters" "parameters: new" "$(cat "$PARAMS")"
check "refresh copy: files owned by the service user, 0644" "nobody 644" "$(owner_mode "$DD/genesis/genesis.yaml")"
check "refresh copy: nothing in the data dir owned by root" "" "$(find "$DD" -user root)"
check "refresh copy: no temp file left" "" "$(find "$DD" -name '.tn.*')"

printf 'genesis: newer\n' > "$SRC/genesis.yaml"
rm -f "$SRC/committee.yaml"
run refresh_copy_configs "$SRC" "$DD"
check_rc "refresh copy: a missing source stops it" 1 "$RC"
check "refresh copy: nothing renamed when staging failed" "genesis: new" "$(cat "$DD/genesis/genesis.yaml")"
check "refresh copy: staged copies removed" "" "$(find "$DD" -name '.tn.*')"

finish
