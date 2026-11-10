#!/usr/bin/env bash
# =============================================================================
# tools/tests/storage_migration_test.sh -- update-node.sh once a one-way update
# (a storage migration) has started the new release: the pending state records
# the start, and neither a failed post-restart check nor a later --discard puts
# the previous unit, start script and node.env back. The exit trap's done and
# the discard's done say so in --json mode.
#
#   bash tools/tests/storage_migration_test.sh
#   docker run --rm -v "$PWD:/w" -w /w bash:3.2 bash tools/tests/storage_migration_test.sh
#   docker run --rm -v "$PWD:/w" -w /w ubuntu:24.04 bash tools/tests/storage_migration_test.sh
#
# Part B runs first, as root only: the real pending-state writes, backups and
# restores, in a temp dir under /root (the one stock directory whose ancestry
# is root-only). It needs GNU `cp --no-preserve` and `mv -T`; elsewhere it
# prints SKIP. Part A runs as any user, under bash 3.2 and busybox too: the
# pending state is a plain file, and the restores, the health checks and the
# staged-binary cleanup are stubs. Nothing is written under /opt/telcoin. No
# network, no systemd: systemctl is a stub on PATH.
# =============================================================================

set -u

# shellcheck source=tools/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

T="$TN_TEST_TMP"
RB=""
trap 'tn_test_cleanup; if [[ -n "$RB" ]]; then rm -rf "$RB"; fi' EXIT

# A copy of update-node.sh without its trailing main call, next to a lib/ link,
# sourced at the top level (see lib.sh on why not inside a function).
mkdir -p "$T/h" "$T/bin"
grep -v '^main "\$@"$' "$TN_TEST_REPO/update-node.sh" > "$T/h/update-node.sh"
ln -s "$TN_TEST_REPO/lib" "$T/h/lib"
tn_test_pre_common
# shellcheck source=/dev/null
source "$T/h/update-node.sh"
tn_test_post_common

has() {
    case "$1" in
        *"$2"*) echo yes ;;
        *) echo no ;;
    esac
}
# count_of TEXT NEEDLE -- how many lines of TEXT contain NEEDLE.
count_of() { printf '%s\n' "$1" | grep -cF -- "$2"; }
hex64() {
    local s=""
    while [ "${#s}" -lt 64 ]; do s="${s}$1"; done
    printf '%s' "$s"
}

# systemctl on PATH (the undo hints run it through a shell): records its argv;
# is-active answers with the code in $TN_SM_ACTIVE.
CALLS="$T/calls.log"
: > "$CALLS"
printf '0\n' > "$T/sc-active"
TN_SM_CALLS="$CALLS"
TN_SM_ACTIVE="$T/sc-active"
export TN_SM_CALLS TN_SM_ACTIVE
cat > "$T/bin/systemctl" <<'STUB'
#!/bin/sh
printf 'systemctl %s\n' "$*" >> "$TN_SM_CALLS"
if [ "$1" = "is-active" ]; then
    exit "$(cat "$TN_SM_ACTIVE")"
fi
exit 0
STUB
chmod 0755 "$T/bin/systemctl"
PATH="$T/bin:$PATH"

# The exit trap's lock and temp-file cleanup are not under test.
tn_release_update_lock() { return 0; }
tn_remove_inflight_tmp() { return 0; }

SERVICE_NAME=telcoin
CONFIG_DIR=/etc/telcoin
NETWORK=testnet
H_B="$(hex64 b)"
H_U="$(hex64 c)"
H_S="$(hex64 d)"
H_E="$(hex64 e)"
H_I="$(hex64 f)"
IMG_OLD="ghcr.io/telcoin-association/tn-testnet@sha256:$(hex64 1)"
IMG_NEW="ghcr.io/telcoin-association/tn-testnet@sha256:$(hex64 2)"

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

# =============================================================================
# Part B (root): real pending state, real backups, real launch files
# =============================================================================
if [[ -z "$WHY" ]]; then
    TN_ROOT_PREFIX="$RB/fx"
    TN_BACKUP_DIR="$RB/backups"
    TN_RELEASE_STAGING_DIR="$RB/staging"
    for d in "$RB/fx" "$RB/fx/etc" "$RB/fx/etc/telcoin" "$RB/fx/etc/systemd" "$RB/fx/etc/systemd/system" \
        "$RB/fx/usr" "$RB/fx/usr/local" "$RB/fx/usr/local/libexec" "$RB/fx/usr/local/libexec/telcoin" "$RB/staging"; do
        install -d -o root -g root -m 0755 "$d"
    done
    : > "$RB/fx/etc/telcoin/.node-meta"
    LU="$RB/fx/etc/systemd/system/telcoin.service"
    LS="$RB/fx/usr/local/libexec/telcoin/tn-start"
    LD="$RB/fx/usr/local/libexec/telcoin/tn-start-docker"
    LE="$RB/fx/etc/telcoin/node.env"
    P="$(pending_state_path)"
    launch_now() { printf '%s|%s|%s' "$(cat "$LU")" "$(cat "$LS")" "$(cat "$LE" 2>/dev/null || echo absent)"; }
    exists() { if [[ -e "$1" ]]; then echo yes; else echo no; fi; }

    # b_setup -- the old launch files, a prepared release update with a staged
    # binary, the launch backups an apply takes (recorded in the state), then
    # the files as the apply renders them for the new release.
    b_setup() {
        printf 'old-unit\n' > "$LU"; chmod 0644 "$LU"
        printf 'old-start\n' > "$LS"; chmod 0755 "$LS"
        printf 'old-env\n' > "$LE"; chmod 0644 "$LE"
        rm -rf "$RB/staging/bin.t1"
        install -d -o root -g root -m 0700 "$RB/staging/bin.t1"
        printf 'new-binary\n' > "$RB/staging/bin.t1/telcoin-network"
        write_pending_state <<FIX
PHASE=fetch_complete
INSTALL_METHOD=release
OLD_REF=v0.15.0-adiri
NEW_REF=v0.17.0-adiri
BUILT_BINARY=$RB/staging/bin.t1/telcoin-network
FIX
        launch_backup_all 2>/dev/null
        printf 'new-unit\n' > "$LU"
        printf 'new-start\n' > "$LS"
        printf 'new-env\n' > "$LE"
        STORAGE_MIGRATION=true
        STORAGE_MIGRATION_STARTED=false
        DISCARD_KEPT_LAUNCH=false
    }

    # A failed check after the start keeps what the apply wrote.
    b_setup
    storage_migration_mark_started > "$T/out" 2>&1
    check "B mark: key persisted" "true" "$(pending_field "$(read_pending_state)" STORAGE_MIGRATION_STARTED)"
    check "B mark: global set" "true" "$STORAGE_MIGRATION_STARTED"
    check "B mark: state still root 0600" "0 600" "$(stat -c '%u %a' -- "$P")"
    check "B mark: earlier keys kept" "v0.17.0-adiri" "$(pending_field "$(read_pending_state)" NEW_REF)"
    BK_UNIT="$LAUNCH_BK_UNIT"
    storage_migration_verify_failed v0.17.0-adiri "UNDO-CMD" > "$T/out" 2>&1
    RC=$?
    check_rc "B verify failed: rc 1" 1 "$RC"
    check "B verify failed: unit, start script and node.env stay as written" "new-unit|new-start|new-env" "$(launch_now)"
    check "B verify failed: pending state gone" no "$(exists "$P")"
    check "B verify failed: staged binary removed" no "$(exists "$RB/staging/bin.t1")"
    check "B verify failed: backups kept for the way back" yes "$(exists "$BK_UNIT")"
    check "B verify failed: says the launch files stay" yes "$(has "$(cat "$T/out")" "stay as this update wrote them")"

    # A --discard after the start keeps them too; its hint puts them back.
    b_setup
    storage_migration_mark_started > /dev/null 2>&1
    ST="$(read_pending_state)"
    HINT="$(pending_undo_hint "$ST")"
    discard_pending > "$T/out" 2>&1
    check "B discard after start: launch files stay" "new-unit|new-start|new-env" "$(launch_now)"
    check "B discard after start: DISCARD_KEPT_LAUNCH" "true" "$DISCARD_KEPT_LAUNCH"
    check "B discard after start: pending state gone" no "$(exists "$P")"
    check "B discard after start: staged binary removed" no "$(exists "$RB/staging/bin.t1")"
    check "B discard after start: the warning carries the undo hint" yes "$(has "$(cat "$T/out")" "$HINT")"
    : > "$CALLS"
    bash -c "$HINT" > "$T/hint.out" 2>&1
    RC=$?
    check_rc "B undo hint: runs" 0 "$RC"
    check "B undo hint: old launch files back" "old-unit|old-start|old-env" "$(launch_now)"
    check "B undo hint: modes" "0 644|0 755|0 644" \
        "$(stat -c '%u %a' -- "$LU")|$(stat -c '%u %a' -- "$LS")|$(stat -c '%u %a' -- "$LE")"
    check "B undo hint: reloads systemd" "systemctl daemon-reload" "$(cat "$CALLS")"

    # Without the key (an interrupted apply before the start) a discard restores.
    b_setup
    discard_pending > "$T/out" 2>&1
    check "B discard before start: launch files back" "old-unit|old-start|old-env" "$(launch_now)"
    check "B discard before start: DISCARD_KEPT_LAUNCH" "false" "$DISCARD_KEPT_LAUNCH"

    # An apply cut short after the start: the exit trap says so, and the
    # persisted key makes the next --discard keep the launch files.
    b_setup
    storage_migration_mark_started > /dev/null 2>&1
    JSON_MODE=true JSON_ACTION=apply JSON_DONE_SENT=false JSON_LAST_ERROR=""
    exec 3>"$T/json.log"
    update_on_exit > /dev/null 2>&1
    exec 3>&-
    JSON_MODE=false JSON_ACTION=""
    J="$(cat "$T/json.log")"
    check "B interrupted: one done" "1" "$(count_of "$J" '"event":"done"')"
    check "B interrupted: done not rolled back, one way" yes "$(has "$J" '"phase":"apply","rolled_back":false,"storage_migration":true')"
    check "B interrupted: key still in the state" "true" "$(pending_field "$(read_pending_state)" STORAGE_MIGRATION_STARTED)"
    discard_pending > "$T/out" 2>&1
    check "B interrupted then discard: launch files stay" "new-unit|new-start|new-env" "$(launch_now)"

    # Docker, end to end through apply_docker_update with real backups.
    printf 'old-docker-start\n' > "$LD"; chmod 0755 "$LD"
    write_pending_state <<FIX
PHASE=pull_complete
INSTALL_METHOD=docker
OLD_IMAGE=${IMG_OLD}
NEW_IMAGE=${IMG_NEW}
PULLED_IMAGE_ID=sha256:${H_I}
OLD_REF=v0.15.0-adiri
NEW_REF=v0.17.0-adiri
FIX
    docker_launch_file() { printf '%s\n' "$LD"; }
    update_swap_precheck() { return 0; }
    validator_downtime_warning_if_applicable() { return 0; }
    confirm() { return 0; }
    update_epoch_wait() { return 0; }
    wait_for_service_stopped() { return 0; }
    update_swap_image() { printf 'new-docker-start\n' > "$2"; }
    tn_resolve_data_dir() { printf '/var/lib/telcoin\n'; }
    verify_health_after_restart() { UPDATE_HEALTH_OK=false; return 1; }
    verify_running_image_id() { return 1; }
    verify_consensus_participation() { return 1; }
    STORAGE_MIGRATION_STARTED=false
    apply_docker_update > "$T/out" 2>&1
    RC=$?
    check_rc "B docker apply, check failed: rc 1" 1 "$RC"
    check "B docker apply, check failed: start script stays on the new image" "new-docker-start" "$(cat "$LD")"
    check "B docker apply, check failed: pending state gone" no "$(exists "$P")"
    check "B docker apply, check failed: start script backup kept" yes "$(exists "$UNIT_BK_PATH")"
    check "B docker apply, check failed: says the launch files stay" yes "$(has "$(cat "$T/out")" "stay as this update wrote them")"
    unset -f docker_launch_file update_swap_precheck validator_downtime_warning_if_applicable confirm \
        update_epoch_wait wait_for_service_stopped update_swap_image tn_resolve_data_dir \
        verify_health_after_restart verify_running_image_id verify_consensus_participation
    unset -f launch_now exists b_setup
    rm -rf "$RB"
    RB=""
else
    for n in "B mark persists the key" "B verify failed keeps the launch files" \
             "B discard after start keeps the launch files" "B undo hint puts them back" \
             "B discard before start restores" "B interrupted apply then discard" \
             "B docker apply keeps the start script"; do
        skip "$n" "$WHY"
    done
fi

# =============================================================================
# Part A (any user): stubs for every write and restore
# =============================================================================
TN_ROOT_PREFIX=""
SP="$T/state"
WRITE_FAILS=0
pending_state_path() { printf '%s\n' "$SP"; }
read_pending_state() {
    [[ -f "$SP" ]] || return 1
    pending_parse < "$SP"
}
write_pending_state() {
    local s
    s="$(pending_parse)" || return 1
    [[ "$WRITE_FAILS" == 0 ]] || return 1
    printf '%s\n' "$s" > "$SP"
}
tn_write_root_file() { printf 'tn_write_root_file %s\n' "$*" >> "$CALLS"; cat > /dev/null; return 0; }
tn_restore_backup() { printf 'tn_restore_backup %s\n' "$*" >> "$CALLS"; return 0; }
launch_restore_all() { printf 'launch_restore_all\n' >> "$CALLS"; return 0; }
tn_staged_cleanup() { printf 'tn_staged_cleanup %s\n' "${1:-}" >> "$CALLS"; return 0; }
tn_resolve_data_dir() { printf '/var/lib/telcoin\n'; }
record_installed_ref() { printf 'record_installed_ref %s\n' "$*" >> "$CALLS"; }
meta_set() { printf 'meta_set %s\n' "$*" >> "$CALLS"; }
docker_record_meta() { printf 'docker_record_meta %s\n' "$*" >> "$CALLS"; }
start_service() {
    local k
    k="$(pending_field "$(read_pending_state 2>/dev/null)" STORAGE_MIGRATION_STARTED || echo none)"
    printf 'start_service key=%s\n' "$k" >> "$CALLS"
}
verify_health_after_restart() { UPDATE_HEALTH_OK=false; return 1; }
verify_running_image_id() { return 1; }
verify_installed_binary_hash() { return 1; }
verify_consensus_participation() { return 1; }

BUILT="/var/lib/telcoin-staging/bin.Ab12Cd/telcoin-network"
BK_B=/var/backups/telcoin/telcoin-network.B1b1B1
BK_U=/var/backups/telcoin/telcoin.service.U1u1U1
BK_S=/var/backups/telcoin/tn-start.S1s1S1
BK_E=/var/backups/telcoin/node.env.E1e1E1
BK_D=/var/backups/telcoin/tn-start-docker.D1d1D1
NATIVE_STATE="PHASE=fetch_complete
INSTALL_METHOD=release
OLD_REF=v0.15.0-adiri
NEW_REF=v0.17.0-adiri
BUILT_BINARY=${BUILT}
BIN_BACKUP=${BK_B}
BIN_BACKUP_SHA256=${H_B}
UNIT_FILE=/etc/systemd/system/telcoin.service
UNIT_BACKUP=${BK_U}
UNIT_BACKUP_SHA256=${H_U}
START_BACKUP=${BK_S}
START_BACKUP_SHA256=${H_S}
NODEENV_BACKUP=${BK_E}
NODEENV_BACKUP_SHA256=${H_E}"
DOCKER_STATE="PHASE=pull_complete
INSTALL_METHOD=docker
OLD_IMAGE=${IMG_OLD}
NEW_IMAGE=${IMG_NEW}
PULLED_IMAGE_ID=sha256:${H_I}
OLD_REF=v0.15.0-adiri
NEW_REF=v0.17.0-adiri
UNIT_FILE=/usr/local/libexec/telcoin/tn-start-docker
UNIT_BACKUP=${BK_D}
UNIT_BACKUP_SHA256=${H_U}"
PREPARED_STATE="PHASE=fetch_complete
INSTALL_METHOD=release
NEW_REF=v0.17.0-adiri
BUILT_BINARY=${BUILT}"
NATIVE_HINT="echo '${H_B}  ${BK_B}' | sha256sum -c - && install -o root -g root -m 0755 ${BK_B} /opt/telcoin/telcoin-network && echo '${H_U}  ${BK_U}' | sha256sum -c - && install -o root -g root -m 0644 ${BK_U} /etc/systemd/system/telcoin.service && echo '${H_S}  ${BK_S}' | sha256sum -c - && install -o root -g root -m 0755 ${BK_S} /usr/local/libexec/telcoin/tn-start && echo '${H_E}  ${BK_E}' | sha256sum -c - && install -o root -g root -m 0644 ${BK_E} /etc/telcoin/node.env && systemctl daemon-reload"
DOCKER_HINT="echo '${H_U}  ${BK_D}' | sha256sum -c - && install -o root -g root -m 0755 ${BK_D} /usr/local/libexec/telcoin/tn-start-docker && systemctl daemon-reload"

# a_setup STATE [started] -- a pending state file; with "started" the one-way
# start is already recorded in it (the key and the global).
a_setup() {
    printf '%s\n' "$1" > "$SP"
    : > "$CALLS"
    WRITE_FAILS=0
    STORAGE_MIGRATION=true
    STORAGE_MIGRATION_STARTED=false
    DISCARD_KEPT_LAUNCH=false
    UPDATE_PARTICIPATION=""
    UPDATE_HEALTH_OK=false
    JSON_DONE_SENT=false
    JSON_LAST_ERROR=""
    if [[ "${2:-}" == "started" ]]; then
        printf 'STORAGE_MIGRATION_STARTED=true\n' >> "$SP"
        STORAGE_MIGRATION_STARTED=true
    fi
}
state_gone() { if [[ -e "$SP" ]]; then echo no; else echo yes; fi; }
json_on() { JSON_MODE=true; exec 3>"$T/json.log"; }
json_off() { exec 3>&-; JSON_MODE=false; J="$(cat "$T/json.log")"; }

# -----------------------------------------------------------------------------
# The key: only "true"
# -----------------------------------------------------------------------------
pending_key_check STORAGE_MIGRATION_STARTED true
check_rc "key check: true accepted" 0 "$?"
for v in 1 yes TRUE "" "true " false; do
    pending_key_check STORAGE_MIGRATION_STARTED "$v"
    check_rc "key check: '${v}' refused" 1 "$?"
done

# -----------------------------------------------------------------------------
# storage_migration_mark_started
# -----------------------------------------------------------------------------
a_setup "$PREPARED_STATE"
STORAGE_MIGRATION=false
storage_migration_mark_started > "$T/out" 2>&1
check_rc "mark, two-way update: rc 0" 0 "$?"
check "mark, two-way update: no key written" "$PREPARED_STATE" "$(cat "$SP")"
check "mark, two-way update: global stays false" "false" "$STORAGE_MIGRATION_STARTED"

a_setup "$PREPARED_STATE"
storage_migration_mark_started > "$T/out" 2>&1
check_rc "mark, one-way update: rc 0" 0 "$?"
check "mark, one-way update: key written once" "1" "$(grep -c '^STORAGE_MIGRATION_STARTED=true$' "$SP")"
check "mark, one-way update: global true" "true" "$STORAGE_MIGRATION_STARTED"
check "mark, one-way update: earlier keys kept" "$BUILT" "$(pending_field "$(read_pending_state)" BUILT_BINARY)"
check "mark, one-way update: says nothing" "" "$(cat "$T/out")"
storage_migration_mark_started > "$T/out" 2>&1
check "mark twice: still one line" "1" "$(grep -c '^STORAGE_MIGRATION_STARTED=' "$SP")"

a_setup "$PREPARED_STATE"
WRITE_FAILS=1
storage_migration_mark_started > "$T/out" 2>&1
check_rc "mark, write fails: rc 0" 0 "$?"
check "mark, write fails: warns" yes "$(has "$(cat "$T/out")" "Could not record in the pending state that the one-way update started")"
check "mark, write fails: global still true" "true" "$STORAGE_MIGRATION_STARTED"
check "mark, write fails: no key" "0" "$(grep -c '^STORAGE_MIGRATION_STARTED=' "$SP")"

a_setup "$PREPARED_STATE"
WRITE_FAILS=1
json_on
storage_migration_mark_started > /dev/null 2>&1
json_off
check "mark, write fails, --json: one warn event" "1" "$(count_of "$J" '"event":"warn"')"

# -----------------------------------------------------------------------------
# Static checks on the script text
# -----------------------------------------------------------------------------
SRC="$TN_TEST_REPO/update-node.sh"
check "static: four calls of storage_migration_mark_started" "4" \
    "$(grep -c '^[[:space:]]*storage_migration_mark_started[[:space:]]*$' "$SRC")"
check "static: each call is followed by start_service" "4" "$(awk '
    want && NF { if ($1 == "start_service" && NF == 1) n++; want = 0 }
    $1 == "storage_migration_mark_started" && NF == 1 { want = 1 }
    END { print n + 0 }' "$SRC")"
check "static: every first start of the new release marks first" "4 4" "$(awk '
    index($0, "Starting ${SERVICE_NAME} on new") { steps++; left = 3; next }
    left > 0 { if ($1 == "storage_migration_mark_started" && NF == 1) { marked++; left = 0 } else left-- }
    END { print steps + 0, marked + 0 }' "$SRC")"
check "static: no inline STORAGE_MIGRATION_STARTED=true outside the marker" "0" "$(awk '
    index($0, "storage_migration_mark_started() {") == 1 { inf = 1 }
    inf && /^}/ { inf = 0; next }
    !inf && $1 !~ /^#/ && /(^|[; \t])STORAGE_MIGRATION_STARTED=true/ { n++ }
    END { print n + 0 }' "$SRC")"
check "static: storage_migration_verify_failed never calls discard_pending" "0" "$(awk '
    index($0, "storage_migration_verify_failed() {") == 1 { inf = 1; next }
    inf && /^}/ { inf = 0 }
    inf && $1 !~ /^#/ && /discard_pending/ { n++ }
    END { print n + 0 }' "$SRC")"

# -----------------------------------------------------------------------------
# A failed check after the start: nothing restored
# -----------------------------------------------------------------------------
a_setup "$NATIVE_STATE"
storage_migration_mark_started > /dev/null 2>&1
storage_migration_verify_failed v0.17.0-adiri "UNDO-CMD" > "$T/out" 2>&1
RC=$?
OUTV="$(cat "$T/out")"
check_rc "verify failed, native: rc 1" 1 "$RC"
check "verify failed, native: launch_restore_all not called" "0" "$(count_of "$(cat "$CALLS")" launch_restore_all)"
check "verify failed, native: tn_restore_backup not called" "0" "$(count_of "$(cat "$CALLS")" tn_restore_backup)"
check "verify failed, native: pending state cleared" yes "$(state_gone)"
check_has "verify failed, native: staged binary cleaned" "tn_staged_cleanup ${BUILT}" "$(cat "$CALLS")"
check "verify failed, native: says not rolled back" yes "$(has "$OUTV" "Not rolled back: the previous release cannot open the migrated data dir.")"
check "verify failed, native: says the launch files stay" yes "$(has "$OUTV" "The unit, start script and node.env stay as this update wrote them, so a restart of telcoin runs v0.17.0-adiri again.")"
check "verify failed, native: the way back is the caller's" yes "$(has "$OUTV" "restore /var/lib/telcoin from the pre-update snapshot; UNDO-CMD; systemctl start telcoin.")"

a_setup "$DOCKER_STATE"
storage_migration_mark_started > /dev/null 2>&1
storage_migration_verify_failed "$IMG_NEW" "UNDO-CMD" > "$T/out" 2>&1
RC=$?
check_rc "verify failed, docker: rc 1" 1 "$RC"
check "verify failed, docker: nothing restored" "0 0" \
    "$(count_of "$(cat "$CALLS")" launch_restore_all) $(count_of "$(cat "$CALLS")" tn_restore_backup)"
check "verify failed, docker: pending state cleared" yes "$(state_gone)"
check "verify failed, docker: says the launch files stay" yes "$(has "$(cat "$T/out")" "stay as this update wrote them")"

a_setup "$NATIVE_STATE"
storage_migration_mark_started > /dev/null 2>&1
json_on
storage_migration_verify_failed v0.17.0-adiri "UNDO-CMD" > /dev/null 2>&1
json_off
check "verify failed, --json: one error event" "1" "$(count_of "$J" '"event":"error"')"
check "verify failed, --json: one done" "1" "$(count_of "$J" '"event":"done"')"
check "verify failed, --json: done not rolled back, one way" yes "$(has "$J" '"ok":false,"phase":"apply","rolled_back":false,"storage_migration":true')"
check "verify failed, --json: nothing restored" "0 0" \
    "$(count_of "$(cat "$CALLS")" launch_restore_all) $(count_of "$(cat "$CALLS")" tn_restore_backup)"

# The decision is on this run's global: a key that could not be written
# changes nothing.
a_setup "$NATIVE_STATE"
WRITE_FAILS=1
storage_migration_mark_started > /dev/null 2>&1
WRITE_FAILS=0
check "no key persisted (write failed)" "0" "$(grep -c '^STORAGE_MIGRATION_STARTED=' "$SP")"
storage_migration_verify_failed v0.17.0-adiri "UNDO-CMD" > "$T/out" 2>&1
check "verify failed without the key: nothing restored" "0 0" \
    "$(count_of "$(cat "$CALLS")" launch_restore_all) $(count_of "$(cat "$CALLS")" tn_restore_backup)"
check "verify failed without the key: pending state cleared" yes "$(state_gone)"

# -----------------------------------------------------------------------------
# The Docker apply paths, end to end with stubs
# -----------------------------------------------------------------------------
docker_launch_file() { printf '%s\n' /usr/local/libexec/telcoin/tn-start-docker; }
apply_root_dir_refusal() { return 1; }
update_swap_precheck() { return 0; }
validator_downtime_warning_if_applicable() { return 0; }
confirm() { return 0; }
update_epoch_wait() { return 0; }
wait_for_service_stopped() { printf 'stopped\n' >> "$CALLS"; }
update_swap_image() { printf 'swap %s\n' "$1" >> "$CALLS"; return 0; }
backup_unit_file() {
    UNIT_BK_PATH="$BK_D" UNIT_BK_SHA256="$H_U" UNIT_BK_MODE=755 UNIT_BK_GROUP=root
    SWAP_UNIT_BK="" SWAP_ENV_ADDED=""
    pending_state_add "UNIT_FILE=${1}" "UNIT_BACKUP=${UNIT_BK_PATH}" "UNIT_BACKUP_SHA256=${UNIT_BK_SHA256}"
}
DOCKER_PREPARED="$(printf '%s\n' "$DOCKER_STATE" | grep -v '^UNIT_')"

a_setup "$DOCKER_PREPARED"
STORAGE_MIGRATION=false
apply_docker_update > "$T/out" 2>&1
RC=$?
check_rc "docker apply, one way, check failed: rc 1" 1 "$RC"
check_has "docker apply, one way: the key is in the state at the start" "start_service key=true" "$(cat "$CALLS")"
check "docker apply, one way: started once" "1" "$(count_of "$(cat "$CALLS")" start_service)"
check "docker apply, one way: nothing restored" "0 0" \
    "$(count_of "$(cat "$CALLS")" launch_restore_all) $(count_of "$(cat "$CALLS")" tn_restore_backup)"
check "docker apply, one way: pending state cleared" yes "$(state_gone)"
check "docker apply, one way: the way back puts the start script back" yes \
    "$(has "$(cat "$T/out")" "install -o root -g root -m 755 ${BK_D} /usr/local/libexec/telcoin/tn-start-docker && systemctl daemon-reload; systemctl start telcoin.")"

a_setup "$DOCKER_PREPARED"
STORAGE_MIGRATION=false
json_on
json_apply_docker > /dev/null 2>&1
RC=$?
json_off
check_rc "docker --json apply, one way, check failed: rc 1" 1 "$RC"
check_has "docker --json apply, one way: the key is in the state at the start" "start_service key=true" "$(cat "$CALLS")"
check "docker --json apply, one way: done not rolled back, one way" yes "$(has "$J" '"rolled_back":false,"storage_migration":true')"
check "docker --json apply, one way: nothing restored" "0 0" \
    "$(count_of "$(cat "$CALLS")" launch_restore_all) $(count_of "$(cat "$CALLS")" tn_restore_backup)"

# v0.16.0-adiri to v0.17.0-adiri crosses the v0.17.0 floor (MDBX to tndb): one way.
a_setup "$(printf '%s\n' "$DOCKER_PREPARED" | sed 's/^OLD_REF=.*/OLD_REF=v0.16.0-adiri/')"
STORAGE_MIGRATION=false
json_on
json_apply_docker > /dev/null 2>&1
RC=$?
json_off
check_rc "docker --json apply, v0.16.0 to v0.17.0, check failed: rc 1" 1 "$RC"
check_has "docker --json apply, v0.16.0 to v0.17.0: the key is in the state at the start" "start_service key=true" "$(cat "$CALLS")"
check "docker --json apply, v0.16.0 to v0.17.0: done not rolled back, one way" yes "$(has "$J" '"rolled_back":false,"storage_migration":true')"
check "docker --json apply, v0.16.0 to v0.17.0: nothing restored" "0 0" \
    "$(count_of "$(cat "$CALLS")" launch_restore_all) $(count_of "$(cat "$CALLS")" tn_restore_backup)"

a_setup "$(printf '%s\n' "$DOCKER_PREPARED" | sed -e 's/^OLD_REF=.*/OLD_REF=v0.17.0-adiri/' -e 's/^NEW_REF=.*/NEW_REF=v0.17.1-adiri/')"
json_on
json_apply_docker > /dev/null 2>&1
json_off
check_has "docker --json apply, two way: no key at the start" "start_service key=none" "$(cat "$CALLS")"
check "docker --json apply, two way: global stays false" "false" "$STORAGE_MIGRATION_STARTED"
check "docker --json apply, two way: rolls back as before" "1" "$(count_of "$(cat "$CALLS")" tn_restore_backup)"
unset -f docker_launch_file apply_root_dir_refusal update_swap_precheck validator_downtime_warning_if_applicable \
    confirm update_epoch_wait wait_for_service_stopped update_swap_image backup_unit_file

# -----------------------------------------------------------------------------
# --discard after the start keeps the launch files
# -----------------------------------------------------------------------------
LAUNCH_BK_UNIT="caller-sentinel"
pending_undo_hint "$NATIVE_STATE" > "$T/hint"
check "undo hint, native: binary, unit, start script, node.env, reload" "$NATIVE_HINT" "$(cat "$T/hint")"
check "undo hint: leaves the caller's LAUNCH_* globals" "caller-sentinel" "$LAUNCH_BK_UNIT"
check "undo hint, docker: start script then reload" "$DOCKER_HINT" "$(pending_undo_hint "$DOCKER_STATE")"
check "undo hint, prepared only: reload only" "systemctl daemon-reload" "$(pending_undo_hint "$PREPARED_STATE")"

a_setup "$NATIVE_STATE" started
discard_pending > "$T/out" 2>&1
OUTD="$(cat "$T/out")"
check "discard after start, native: DISCARD_KEPT_LAUNCH" "true" "$DISCARD_KEPT_LAUNCH"
check "discard after start, native: launch_restore_all not called" "0" "$(count_of "$(cat "$CALLS")" launch_restore_all)"
check "discard after start, native: no daemon-reload" "0" "$(count_of "$(cat "$CALLS")" daemon-reload)"
check "discard after start, native: pending state cleared" yes "$(state_gone)"
check_has "discard after start, native: staged binary cleaned" "tn_staged_cleanup ${BUILT}" "$(cat "$CALLS")"
check "discard after start, native: nothing was rolled back" yes "$(has "$OUTD" "stay as that apply wrote them (the previous release cannot open the migrated data dir). Nothing was rolled back.")"
check "discard after start, native: the way back with the undo hint" yes \
    "$(has "$OUTD" "To go back: systemctl stop telcoin; restore the data dir from the pre-update snapshot; ${NATIVE_HINT}; systemctl start telcoin.")"

a_setup "$DOCKER_STATE" started
discard_pending > "$T/out" 2>&1
check "discard after start, docker: DISCARD_KEPT_LAUNCH" "true" "$DISCARD_KEPT_LAUNCH"
check "discard after start, docker: launch_restore_all not called" "0" "$(count_of "$(cat "$CALLS")" launch_restore_all)"
check "discard after start, docker: hint ends with daemon-reload" yes \
    "$(has "$(cat "$T/out")" "${DOCKER_HINT}; systemctl start telcoin.")"
check "discard after start, docker: pending state cleared" yes "$(state_gone)"

a_setup "$NATIVE_STATE" started
json_on
json_discard > /dev/null 2>&1
json_off
check "discard after start, --json: one warn event" "1" "$(count_of "$J" '"event":"warn"')"
check "discard after start, --json: the warn says how to go back" yes "$(has "$J" "To go back: systemctl stop telcoin")"
check "discard after start, --json: done" \
    '{"event":"done","ok":true,"phase":"discard","storage_migration":true,"msg":"pending update cleared; the launch files of the started one-way update were kept"}' \
    "$(printf '%s\n' "$J" | grep '"event":"done"')"
check "discard after start, --json: launch_restore_all not called" "0" "$(count_of "$(cat "$CALLS")" launch_restore_all)"

# -----------------------------------------------------------------------------
# --discard without the key: as before
# -----------------------------------------------------------------------------
a_setup "$NATIVE_STATE"
discard_pending > "$T/out" 2>&1
check "discard before start, native: DISCARD_KEPT_LAUNCH" "false" "$DISCARD_KEPT_LAUNCH"
check "discard before start, native: launch_restore_all once" "1" "$(count_of "$(cat "$CALLS")" launch_restore_all)"
check_has "discard before start, native: systemd reloaded" "systemctl daemon-reload" "$(cat "$CALLS")"
check "discard before start, native: says so" yes "$(has "$(cat "$T/out")" "Put the launch files back")"
check "discard before start, native: pending state cleared" yes "$(state_gone)"

a_setup "$DOCKER_STATE"
discard_pending > "$T/out" 2>&1
check "discard before start, docker: launch_restore_all once" "1" "$(count_of "$(cat "$CALLS")" launch_restore_all)"

a_setup "$NATIVE_STATE"
json_on
json_discard > /dev/null 2>&1
json_off
check "discard before start, --json: no warn event" "0" "$(count_of "$J" '"event":"warn"')"
check "discard before start, --json: done as before" '{"event":"done","ok":true,"phase":"discard","msg":"pending update cleared"}' \
    "$(printf '%s\n' "$J" | grep '"event":"done"')"
check "discard before start, --json: launch_restore_all once" "1" "$(count_of "$(cat "$CALLS")" launch_restore_all)"

a_setup "$PREPARED_STATE"
discard_pending > "$T/out" 2>&1
check "discard of a prepared update: nothing restored, nothing said" "0|" \
    "$(count_of "$(cat "$CALLS")" launch_restore_all)|$(cat "$T/out")"
check "discard of a prepared update: DISCARD_KEPT_LAUNCH" "false" "$DISCARD_KEPT_LAUNCH"
check "discard of a prepared update: pending state cleared" yes "$(state_gone)"
check_has "discard of a prepared update: staged binary cleaned" "tn_staged_cleanup ${BUILT}" "$(cat "$CALLS")"

# -----------------------------------------------------------------------------
# An apply cut short after the start, then a discard
# -----------------------------------------------------------------------------
a_setup "$NATIVE_STATE"
storage_migration_mark_started > /dev/null 2>&1
JSON_ACTION=apply
json_on
update_on_exit > /dev/null 2>&1
json_off
JSON_ACTION=""
check "interrupted after start: one done" "1" "$(count_of "$J" '"event":"done"')"
check "interrupted after start: done not rolled back, one way" yes "$(has "$J" '"ok":false,"phase":"apply","rolled_back":false,"storage_migration":true')"
check "interrupted after start: key still in the state" "true" "$(pending_field "$(read_pending_state)" STORAGE_MIGRATION_STARTED)"
discard_pending > "$T/out" 2>&1
check "interrupted after start, then discard: launch files kept" "true 0" \
    "$DISCARD_KEPT_LAUNCH $(count_of "$(cat "$CALLS")" launch_restore_all)"

a_setup "$NATIVE_STATE"
JSON_ACTION=apply
json_on
update_on_exit > /dev/null 2>&1
json_off
JSON_ACTION=""
check "interrupted before start: done without storage_migration" no "$(has "$J" storage_migration)"
discard_pending > "$T/out" 2>&1
check "interrupted before start, then discard: launch files restored" "false 1" \
    "$DISCARD_KEPT_LAUNCH $(count_of "$(cat "$CALLS")" launch_restore_all)"

finish
