#!/usr/bin/env bash
# =============================================================================
# tools/tests/rollback_hash_test.sh -- update-node.sh's backups and rollback:
# backups land in the root-only backup directory with their sha256 recorded
# in the pending update, and a restore refuses a backup that changed since,
# leaving the live file as it is.
#
#   bash tools/tests/rollback_hash_test.sh
#   docker run --rm -v "$PWD:/w" -w /w bash:3.2 bash tools/tests/rollback_hash_test.sh
#   docker run --rm -v "$PWD:/w" -w /w ubuntu:24.04 bash tools/tests/rollback_hash_test.sh
#
# Root only (as a normal user every case prints SKIP): a fixture under /root.
# Needs GNU `cp --no-preserve` and `mv -T` (busybox lacks the first: SKIP).
# The end-to-end source apply writes /opt/telcoin/telcoin-network (a fixed
# path in the script), so it runs only inside a container (/.dockerenv) where
# /opt/telcoin does not exist yet; anywhere else it prints SKIP.
# =============================================================================

set -u

# shellcheck source=tools/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

T="$TN_TEST_TMP"
RB=""
E2E_MADE=""
trap 'tn_test_cleanup; if [[ -n "$RB" ]]; then rm -rf "$RB"; fi; if [[ -n "$E2E_MADE" ]]; then rm -rf /opt/telcoin; fi' EXIT

mkdir -p "$T/h"
grep -v '^main "\$@"$' "$TN_TEST_REPO/update-node.sh" > "$T/h/update-node.sh"
ln -s "$TN_TEST_REPO/lib" "$T/h/lib"
tn_test_pre_common
# shellcheck source=/dev/null
source "$T/h/update-node.sh"
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
sha() { sha256sum < "$1" | cut -d' ' -f1; }
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
WHY=""
if [[ $IS_ROOT != 1 ]]; then
    WHY="not root"
elif [[ -z "$RB" ]]; then
    WHY="no root-only temp dir under /root"
elif [[ $HAVE_MV_T != 1 ]]; then
    WHY="mv -T absent"
elif [[ $HAVE_CP_NP != 1 ]]; then
    WHY="cp --no-preserve absent"
fi

if [[ -n "$WHY" ]]; then
    for n in "binary backup recorded" "tampered binary backup refused" "binary rollback" \
             "unit backup recorded" "tampered unit backup refused" "unit rollback" \
             "end-to-end source apply rollback"; do
        skip "$n" "$WHY"
    done
    finish
fi

# Fixture: config dir with a pending update, a root-owned "install dir", and
# the backup dir, all under $RB.
TN_ROOT_PREFIX="$RB/fx"
TN_BACKUP_DIR="$RB/backups"
mkdir -p "$RB/fx/etc/telcoin" "$RB/opt" "$RB/units"
chmod 0755 "$RB/fx" "$RB/fx/etc" "$RB/fx/etc/telcoin" "$RB/opt" "$RB/units"
: > "$RB/fx/etc/telcoin/.node-meta"
write_pending_state <<'EOF'
PHASE=build_complete
INSTALL_METHOD=source
NEW_REF=v0.16.0-adiri
EOF

BIN="$RB/opt/telcoin-network"
printf 'old-binary\n' > "$BIN"
chmod 0755 "$BIN"
printf 'new-binary\n' > "$T/new-binary"

# -----------------------------------------------------------------------------
# Binary
# -----------------------------------------------------------------------------
backup_installed_binary "$BIN"
check_rc "binary backup: rc 0" 0 "$?"
check "binary backup: in the backup dir" yes "$(has "$BIN_BK_PATH" "$RB/backups/")"
check "binary backup: root 0600" "0 0 600" "$(owner_mode "$BIN_BK_PATH")"
check "binary backup: sha256 is the live file's" "$(sha "$BIN")" "$BIN_BK_SHA256"
STATE="$(read_pending_state)"
check "binary backup: path recorded" "$BIN_BK_PATH" "$(pending_field "$STATE" BIN_BACKUP)"
check "binary backup: sha256 recorded" "$BIN_BK_SHA256" "$(pending_field "$STATE" BIN_BACKUP_SHA256)"
check "binary backup: earlier keys kept" "v0.16.0-adiri" "$(pending_field "$STATE" NEW_REF)"
check "binary backup: nothing beside the live file" "" "$(find "$RB/opt" -name '*.bak*')"

tn_install_root_binary "$T/new-binary" "$BIN"
check "binary install: new binary in place" "new-binary" "$(cat "$BIN")"
check "binary install: root 0755" "0 0 755" "$(owner_mode "$BIN")"

printf 'x' >> "$BIN_BK_PATH"
run restore_installed_binary "$BIN"
check_rc "tampered binary backup: refused" 1 "$RC"
check "tampered binary backup: live binary unchanged" "new-binary" "$(cat "$BIN")"
check "tampered binary backup: says why" yes "$(has "$ERR" "does not match")"
check "tampered binary backup: no temp file left" "" "$(find "$RB/opt" -name '.tn.*')"

printf 'old-binary\n' > "$BIN"
backup_installed_binary "$BIN"
tn_install_root_binary "$T/new-binary" "$BIN"
run restore_installed_binary "$BIN"
check_rc "binary rollback: rc 0" 0 "$RC"
check "binary rollback: old binary back" "old-binary" "$(cat "$BIN")"
check "binary rollback: root 0755" "0 0 755" "$(owner_mode "$BIN")"
check "binary hint: checks the hash before installing" yes "$(has "$(binary_restore_hint "$BIN")" "sha256sum -c - && install -o root -g root -m 0755")"

# -----------------------------------------------------------------------------
# Launch file (unit or start script)
# -----------------------------------------------------------------------------
UNIT="$RB/units/tn-start"
printf '#!/bin/sh\nexec /opt/telcoin/telcoin-network node --observer\n' > "$UNIT"
chmod 0750 "$UNIT"
UNIT_OLD="$(cat "$UNIT")"
backup_unit_file "$UNIT" 2>/dev/null
check_rc "unit backup: rc 0" 0 "$?"
STATE="$(read_pending_state)"
check "unit backup: file recorded" "$UNIT" "$(pending_field "$STATE" UNIT_FILE)"
check "unit backup: path recorded" "$UNIT_BK_PATH" "$(pending_field "$STATE" UNIT_BACKUP)"
check "unit backup: sha256 recorded" "$UNIT_BK_SHA256" "$(pending_field "$STATE" UNIT_BACKUP_SHA256)"
check "unit backup: binary keys still there" "$BIN_BK_SHA256" "$(pending_field "$STATE" BIN_BACKUP_SHA256)"
check "unit backup: mode remembered" "750" "$UNIT_BK_MODE"

printf '#!/bin/sh\nexec /opt/telcoin/telcoin-network node\n' > "$UNIT"
UNIT_NEW="$(cat "$UNIT")"
printf '# extra\n' >> "$UNIT_BK_PATH"
run restore_unit_file "$UNIT"
check_rc "tampered unit backup: refused" 1 "$RC"
check "tampered unit backup: live file unchanged" "$UNIT_NEW" "$(cat "$UNIT")"

printf '%s\n' "$UNIT_OLD" > "$UNIT"
chmod 0750 "$UNIT"
backup_unit_file "$UNIT" 2>/dev/null
printf '%s\n' "$UNIT_NEW" > "$UNIT"
chmod 0644 "$UNIT"
run restore_unit_file "$UNIT"
check_rc "unit rollback: rc 0" 0 "$RC"
check "unit rollback: old content back" "$UNIT_OLD" "$(cat "$UNIT")"
check "unit rollback: old mode back, root-owned" "0 0 750" "$(owner_mode "$UNIT")"
check "unit backup: nothing beside the live file" "" "$(find "$RB/units" -name '*.bak*')"

ln -s "$UNIT" "$RB/units/link"
run backup_unit_file "$RB/units/link"
check_rc "unit backup: a symlink is refused" 1 "$RC"

# -----------------------------------------------------------------------------
# End to end: apply_source_update rolls back, and refuses a changed backup
# -----------------------------------------------------------------------------
if [[ -f /.dockerenv && ! -e /opt/telcoin ]]; then
    E2E_MADE=1
    mkdir -p /opt/telcoin
    chmod 0755 /opt /opt/telcoin
    INST=/opt/telcoin/telcoin-network
    BUILT_DIR="$RB/build"
    mkdir -p "$BUILT_DIR"
    chmod 0755 "$BUILT_DIR"
    cp "$T/new-binary" "$BUILT_DIR/telcoin-network"

    storage_migration_begin() { STORAGE_MIGRATION=false; return 0; }
    validator_downtime_warning_if_applicable() { return 0; }
    update_epoch_wait() { :; }
    observer_strip_needed() { return 1; }
    tn_node_launch_target() { return 1; }
    write_source_version_marker() { :; }
    confirm() { return 0; }
    STOPS=0
    STARTS=0
    VERIFIES=0
    TAMPER=no
    wait_for_service_stopped() {
        STOPS=$((STOPS + 1))
        if [[ $STOPS -eq 2 && "$TAMPER" == "yes" ]]; then
            printf 'x' >> "$BIN_BK_PATH"
        fi
    }
    start_service() { STARTS=$((STARTS + 1)); }
    # The first health check (new binary) fails, the second (rollback) passes.
    verify_health_after_restart() { VERIFIES=$((VERIFIES + 1)); [[ $VERIFIES -ge 2 ]]; }

    e2e_setup() {
        printf 'old-binary\n' > "$INST"
        chmod 0755 "$INST"
        write_pending_state <<EOF
PHASE=build_complete
INSTALL_METHOD=source
OLD_REF=v0.15.0-adiri
NEW_REF=v0.15.1-adiri
NEW_VERSION=telcoin-network 0.1.0
BUILT_BINARY=${BUILT_DIR}/telcoin-network
BUILT_HASH=$(sha "$BUILT_DIR/telcoin-network")
PREPARED_AT=2026-10-15T00:00:00Z
EOF
        STOPS=0
        STARTS=0
        VERIFIES=0
    }

    e2e_setup
    TAMPER=no
    apply_source_update > "$T/e2e.out" 2>&1
    check "e2e rollback: old binary back" "old-binary" "$(cat "$INST")"
    check "e2e rollback: root 0755" "0 0 755" "$(owner_mode "$INST")"
    check "e2e rollback: started twice (new, then rolled back)" "2" "$STARTS"
    check "e2e rollback: says rolled back" yes "$(has "$(cat "$T/e2e.out")" "Rolled back to previous binary")"
    check "e2e rollback: no .bak beside the binary" "" "$(find /opt/telcoin -name '*.bak*')"

    e2e_setup
    TAMPER=yes
    apply_source_update > "$T/e2e.out" 2>&1
    RC=$?
    check_rc "e2e tampered backup: apply fails" 1 "$RC"
    check "e2e tampered backup: live binary unchanged (still the new one)" "new-binary" "$(cat "$INST")"
    check "e2e tampered backup: node left stopped (no second start)" "1" "$STARTS"
    check "e2e tampered backup: says the restore failed" yes "$(has "$(cat "$T/e2e.out")" "Backup restore failed")"
    check "e2e tampered backup: manual line checks the hash" yes "$(has "$(cat "$T/e2e.out")" "sha256sum -c -")"

    e2e_setup
    TAMPER=yes
    exec 3>"$T/json.log"
    JSON_MODE=true
    json_apply_source > "$T/e2e.out" 2>&1
    RC=$?
    JSON_MODE=false
    exec 3>&-
    check_rc "e2e --json tampered backup: apply fails" 1 "$RC"
    check "e2e --json tampered backup: live binary unchanged" "new-binary" "$(cat "$INST")"
    check "e2e --json tampered backup: done says not rolled back" yes "$(has "$(cat "$T/json.log")" '"rolled_back":false')"
    check "e2e --json tampered backup: node left stopped" "1" "$STARTS"
else
    skip "end-to-end source apply rollback" "writes /opt/telcoin: container only, and only when it does not exist"
fi

finish
