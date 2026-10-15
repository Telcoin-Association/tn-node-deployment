#!/usr/bin/env bash
# =============================================================================
# tools/tests/pending_state_test.sh -- update-node.sh's pending-update file:
# the strict parser, the root-only reader and writer, and the apply paths'
# refusal of a state that does not parse.
#
#   bash tools/tests/pending_state_test.sh
#   docker run --rm -v "$PWD:/w" -w /w bash:3.2 bash tools/tests/pending_state_test.sh
#   docker run --rm -v "$PWD:/w" -w /w ubuntu:24.04 bash tools/tests/pending_state_test.sh
#
# The parser cases and the symlink and owner refusals run as any user. The
# write/read round trip and the planted-state apply run as root only, in a temp
# dir under /root (the one stock directory whose ancestry is root-only); as a
# normal user they print SKIP. A host without `mv -T` (busybox) skips the
# root writes. No network, no systemd: systemctl, perl and docker are stubs.
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

# run CMD [ARG...] -- OUT, ERR and RC get the command's stdout, stderr and rc.
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
owner_mode() { stat -c '%u %a' -- "$1" 2>/dev/null; }

# Stubs on PATH: each records its argv; perl and docker also leave a marker,
# so a test can tell whether the apply ever reached the image swap.
for c in systemctl perl docker; do
    printf '#!/bin/sh\nprintf "%%s\\n" "%s $*" >> "%s/argv.log"\n' "$c" "$T" > "$T/bin/$c"
    chmod 0755 "$T/bin/$c"
done
printf 'touch "%s/perl-ran"\n' "$T" >> "$T/bin/perl"
printf 'touch "%s/docker-ran"\n' "$T" >> "$T/bin/docker"
PATH="$T/bin:$PATH"

IS_ROOT=0
[[ "$(id -u)" == 0 ]] && IS_ROOT=1
if [[ $IS_ROOT == 1 ]]; then
    RB="$(mktemp -d /root/.tn-test.XXXXXX 2>/dev/null)" || RB=""
    if [[ -n "$RB" ]]; then
        chmod 0700 "$RB"
        if ! tn_root_dir_ok "$RB"; then
            rm -rf "$RB"
            RB=""
        fi
    fi
fi
: > "$T/probe1"
HAVE_MV_T=0
mv -f -T -- "$T/probe1" "$T/probe2" 2>/dev/null && HAVE_MV_T=1
ROOT_OK=0
ROOT_WHY="not root"
if [[ $IS_ROOT == 1 && -n "$RB" && $HAVE_MV_T == 1 ]]; then
    ROOT_OK=1
elif [[ $IS_ROOT == 1 && $HAVE_MV_T == 0 ]]; then
    ROOT_WHY="mv -T absent"
elif [[ $IS_ROOT == 1 ]]; then
    ROOT_WHY="no root-only temp dir under /root"
fi

GOOD_STATE="PHASE=build_complete
INSTALL_METHOD=source
OLD_REF=v0.15.0-adiri-2-gabc1234-dirty
NEW_REF=feature/x=y
NEW_VERSION=telcoin-network 0.1.0 (a=b/c d)
BUILT_BINARY=/opt/telcoin-source/target/release/telcoin-network
BUILT_HASH=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
PREPARED_AT=2026-10-15T10:00:00Z"

# -----------------------------------------------------------------------------
# pending_parse: data only, strict keys, per-key values
# -----------------------------------------------------------------------------
run pending_parse <<< "$GOOD_STATE"
check_rc "parse: good state rc 0" 0 "$RC"
check "parse: values with = and / come back unchanged" "$GOOD_STATE" "$OUT"
check "parse: good state, no warnings" "" "$ERR"

run pending_parse <<< "PHASE=pull_complete
FOO_BAR=1
INSTALL_METHOD=docker"
check_rc "parse: unknown key rc 0" 0 "$RC"
check "parse: unknown key dropped" "PHASE=pull_complete
INSTALL_METHOD=docker" "$OUT"
check "parse: unknown key named in a warning" yes "$(has "$ERR" "ignoring unknown key FOO_BAR")"

run pending_parse <<< "PHASE=pull_complete
not a key line
lower=case
INSTALL_METHOD=docker"
check_rc "parse: malformed lines rc 0" 0 "$RC"
check "parse: malformed lines skipped" "PHASE=pull_complete
INSTALL_METHOD=docker" "$OUT"
check "parse: malformed line warned" yes "$(has "$ERR" "not KEY=value")"

run pending_parse < <(printf 'PHASE=pull_complete\r\nINSTALL_METHOD=docker\r\n')
check "parse: one trailing CR per line dropped" "PHASE=pull_complete
INSTALL_METHOD=docker" "$OUT"

run pending_parse <<< "PHASE=pull_complete
PHASE=build_complete"
check_rc "parse: duplicate key refused" 1 "$RC"
check "parse: duplicate key, nothing printed" "" "$OUT"
check "parse: duplicate key named" yes "$(has "$ERR" "PHASE is listed more than once")"

# A value shaped like an interpolation, in each field an apply passes on.
for bad in 'NEW_IMAGE=x@{[MARKER]}' 'OLD_IMAGE=a/b:1 c' 'NEW_IMAGE=-x/y:1' \
           'PULLED_IMAGE_ID=sha256:xyz' 'BUILT_HASH=abc' 'BUILT_BINARY=relative/path' \
           'BUILT_BINARY=/a/$(b)' 'NEW_REF=-x' 'PHASE=other' 'INSTALL_METHOD=binary' \
           'UNIT_BACKUP_SHA256=0' 'BIN_BACKUP=/x y'; do
    run pending_parse <<< "PHASE=pull_complete
${bad}"
    check_rc "parse: refused ${bad}" 1 "$RC"
    check "parse: refused ${bad}, nothing printed" "" "$OUT"
done
check "parse: the refusal names the key, not the value" no "$(has "$ERR" "BIN_BACKUP=/x y")"

run pending_field "$GOOD_STATE" NEW_VERSION
check "pending_field: value with = and /" "telcoin-network 0.1.0 (a=b/c d)" "$OUT"
run pending_field "$GOOD_STATE" NOPE
check_rc "pending_field: absent key rc 1" 1 "$RC"

# -----------------------------------------------------------------------------
# read_pending_state: file checks (any user)
# -----------------------------------------------------------------------------
TN_ROOT_PREFIX="$T/fx"
mkdir -p "$T/fx/etc/telcoin"
: > "$T/fx/etc/telcoin/.node-meta"
P="$(pending_state_path)"
check "pending_state_path under the fixture" "$T/fx/etc/telcoin/.pending-update" "$P"

run read_pending_state
check_rc "read: no file rc 1" 1 "$RC"
check "read: no file, no message" "" "$ERR"

printf '%s\n' "$GOOD_STATE" > "$T/target-state"
ln -s "$T/target-state" "$P"
run read_pending_state
check_rc "read: symlink refused" 1 "$RC"
check "read: symlink, nothing printed" "" "$OUT"
check "read: symlink named in the refusal" yes "$(has "$ERR" "symlink")"
rm -f "$P"
ln -s "$T/nowhere" "$P"
run read_pending_state
check_rc "read: dangling symlink refused" 1 "$RC"
clear_pending_state
check "clear: removes the symlink" no "$([[ -e "$P" || -L "$P" ]] && echo yes || echo no)"
ln -s "$T/target-state" "$P"
clear_pending_state
check "clear: leaves the symlink target alone" "$GOOD_STATE" "$(cat "$T/target-state")"

mkdir "$P"
run read_pending_state
check_rc "read: directory refused" 1 "$RC"
rmdir "$P"

printf '%s\n' "$GOOD_STATE" > "$P"
if [[ $IS_ROOT == 1 ]]; then
    chown nobody "$P" 2>/dev/null || chown 65534 "$P"
fi
run read_pending_state
check_rc "read: file not owned by root refused" 1 "$RC"
check "read: wrong owner, nothing printed" "" "$OUT"
check "read: wrong owner explained" yes "$(has "$ERR" "owned by root")"
rm -f "$P"

run write_pending_state <<< "$GOOD_STATE"
check "write: refused in a directory that fails tn_root_dir_ok" yes "$([[ $RC -ne 0 ]] && echo yes || echo no)"
check "write: nothing created there" no "$([[ -e "$P" ]] && echo yes || echo no)"

# -----------------------------------------------------------------------------
# root: write/read round trip, symlink in place, pending_state_add
# -----------------------------------------------------------------------------
if [[ $ROOT_OK == 1 ]]; then
    TN_ROOT_PREFIX="$RB/fx"
    mkdir -p "$RB/fx/etc/telcoin"
    chmod 0755 "$RB/fx" "$RB/fx/etc" "$RB/fx/etc/telcoin"
    : > "$RB/fx/etc/telcoin/.node-meta"
    P="$(pending_state_path)"

    run write_pending_state <<< "$GOOD_STATE"
    check_rc "root write: rc 0" 0 "$RC"
    check "root write: root 0600" "0 600" "$(owner_mode "$P")"
    run read_pending_state
    check_rc "root read: rc 0" 0 "$RC"
    check "root round trip keeps = and /" "$GOOD_STATE" "$OUT"

    run pending_state_add "BIN_BACKUP=/var/backups/telcoin/telcoin-network.Ab12Cd" \
        "BIN_BACKUP_SHA256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    check_rc "root add: rc 0" 0 "$RC"
    run pending_state_add "BIN_BACKUP_SHA256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    run read_pending_state
    check "root add: earlier keys kept" "build_complete" "$(pending_field "$OUT" PHASE)"
    check "root add: new key recorded" "/var/backups/telcoin/telcoin-network.Ab12Cd" "$(pending_field "$OUT" BIN_BACKUP)"
    check "root add: a key set again is replaced" "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" "$(pending_field "$OUT" BIN_BACKUP_SHA256)"
    check "root add: no duplicate line" "1" "$(grep -c '^BIN_BACKUP_SHA256=' "$P")"

    run write_pending_state <<< "PHASE=pull_complete
NEW_IMAGE=x@{[MARKER]}"
    check "root write: a value the reader would refuse is not written" yes "$([[ $RC -ne 0 ]] && echo yes || echo no)"
    check "root write: the earlier state is unchanged" "build_complete" "$(pending_field "$(read_pending_state)" PHASE)"

    rm -f "$P"
    printf 'canary\n' > "$RB/canary"
    ln -s "$RB/canary" "$P"
    run write_pending_state <<< "$GOOD_STATE"
    check "root write: a symlink in place is refused" yes "$([[ $RC -ne 0 ]] && echo yes || echo no)"
    check "root write: the symlink target is unchanged" "canary" "$(cat "$RB/canary")"
    check "root write: the symlink is still a symlink" yes "$([[ -L "$P" ]] && echo yes || echo no)"
    rm -f "$P"

    run read_pending_state
    printf '%s\n' "$GOOD_STATE" > "$P"
    chmod 0606 "$P"
    run read_pending_state
    check_rc "root read: other-writable file refused" 1 "$RC"
    chmod 0600 "$P"
    chmod 0775 "$RB/fx/etc/telcoin"
    run read_pending_state
    check_rc "root read: group-writable directory refused" 1 "$RC"
    chmod 0755 "$RB/fx/etc/telcoin"
    rm -f "$P"
else
    for n in "root write/read round trip" "root pending_state_add" \
             "root write refuses a value the reader refuses" "root write refuses a symlink in place" \
             "root read refuses loose modes"; do
        skip "$n" "$ROOT_WHY"
    done
fi

# -----------------------------------------------------------------------------
# A planted state with an interpolation-shaped image never reaches the swap
# -----------------------------------------------------------------------------
if [[ $ROOT_OK == 1 ]]; then
    FX="$RB/fx"
else
    FX="$T/fx"
fi
TN_ROOT_PREFIX="$FX"
P="$(pending_state_path)"
printf 'exec docker run --rm us-docker.pkg.dev/a/b:v0.16.0-adiri telcoin node\n' > "$FX/launch"
LAUNCH_BEFORE="$(cat "$FX/launch")"
# Written raw, as an attacker or a hand edit would, not through write_pending_state.
printf 'PHASE=pull_complete\nINSTALL_METHOD=docker\nOLD_IMAGE=us-docker.pkg.dev/a/b:v0.16.0-adiri\nNEW_IMAGE=x@{[MARKER]}\nPULLED_IMAGE_ID=\n' > "$P"
chmod 0600 "$P"
docker_launch_file() { printf '%s\n' "$FX/launch"; }
storage_migration_begin() { printf 'storage_migration_begin\n' >> "$T/argv.log"; return 0; }
validator_downtime_warning_if_applicable() { return 0; }
update_epoch_wait() { printf 'update_epoch_wait\n' >> "$T/argv.log"; }
wait_for_service_stopped() { printf 'stopped\n' >> "$T/argv.log"; }
start_service() { printf 'started\n' >> "$T/argv.log"; }
: > "$T/argv.log"
ls -A "$FX" > "$T/before.ls"

run apply_docker_update
check_rc "planted state: interactive apply refused" 1 "$RC"
check "planted state: perl never ran" no "$([[ -e "$T/perl-ran" ]] && echo yes || echo no)"
check "planted state: nothing stopped, nothing started" "" "$(cat "$T/argv.log")"
check "planted state: launch file unchanged" "$LAUNCH_BEFORE" "$(cat "$FX/launch")"
check "planted state: no file created in the fixture" "$(cat "$T/before.ls")" "$(ls -A "$FX")"
if [[ $ROOT_OK == 1 ]]; then
    check "planted state: refused for the image value" yes "$(has "$ERR" "NEW_IMAGE has a malformed value")"
else
    skip "planted state: refused for the image value (not just the owner)" "$ROOT_WHY"
fi

exec 3>"$T/json.log"
JSON_MODE=true
run json_apply_docker
JSON_MODE=false
exec 3>&-
check_rc "planted state: --json apply refused" 1 "$RC"
check "planted state: --json perl never ran" no "$([[ -e "$T/perl-ran" ]] && echo yes || echo no)"
check "planted state: --json error event" yes "$(has "$(cat "$T/json.log")" '"event":"error"')"
check "planted state: --json launch file unchanged" "$LAUNCH_BEFORE" "$(cat "$FX/launch")"
check "planted state: --json nothing stopped" "" "$(cat "$T/argv.log")"
rm -f "$P"

# -----------------------------------------------------------------------------
# The ownership migration hook that runs right after the update lock
# -----------------------------------------------------------------------------
run update_migrate_ownership
check_rc "migration hook: helper absent, nothing to do" 0 "$RC"
MIG_ARG=""
MIG_RC=0
tn_migrate_ownership() { MIG_ARG="${1:-}"; return "$MIG_RC"; }
update_migrate_ownership
check_rc "migration hook: done" 0 "$?"
check "migration hook: progress printer passed" "update_wait_say" "$MIG_ARG"
MIG_RC=3
run update_migrate_ownership
check_rc "migration hook: mainnet refusal stops the run" 1 "$RC"
check "migration hook: mainnet refusal explained" yes "$(has "$OUT$ERR" "must be installed fresh")"
MIG_RC=1
run update_migrate_ownership
check_rc "migration hook: symlink or owner refusal stops the run" 1 "$RC"
exec 3>"$T/json.log"
JSON_MODE=true
run update_migrate_ownership
JSON_MODE=false
exec 3>&-
check "migration hook: --json error event" yes "$(has "$(cat "$T/json.log")" '"event":"error"')"
unset -f tn_migrate_ownership

finish
