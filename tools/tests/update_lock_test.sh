#!/usr/bin/env bash
# =============================================================================
# tools/tests/update_lock_test.sh -- the update lock file's mode
# (tn_acquire_update_lock in lib/common.sh): a missing lock file is created
# 0600, a root-owned one with a looser mode is set to 0600, one owned by
# another account is refused, and once the file is 0600 an account other than
# root cannot open it to hold the lock.
#
#   bash tools/tests/update_lock_test.sh
#   docker run --rm -v "$PWD:/w" -w /w bash:3.2 bash tools/tests/update_lock_test.sh
#   docker run --rm -v "$PWD:/w" -w /w ubuntu:24.04 bash tools/tests/update_lock_test.sh
#
# The override cases (TN_UPDATE_LOCK_FILE in the temp dir) run everywhere flock
# exists. The default lock (/run/telcoin/update.lock) runs only as root inside
# a container that has no /run/telcoin yet, and needs setpriv for the
# unprivileged probe. bash 3.2 safe.
# =============================================================================

set -u

# shellcheck source=tools/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
eval "$(tn_test_source_common)"

T="$TN_TEST_TMP"
MADE_RUN=0
trap 'tn_test_cleanup; [[ $MADE_RUN == 0 ]] || rm -rf /run/telcoin' EXIT
umask 022

# acquire -- take the lock in a subshell and release it; prints the rc, then the
# lock file's "<uid> <mode>" (or "absent"). Messages go to $T/.err.
acquire() {
    (
        TN_EXIT_TRAP_OWNED=1
        rc=0
        tn_acquire_update_lock >"$T/.err" 2>&1 || rc=$?
        tn_release_update_lock
        printf '%s ' "$rc"
        stat -c '%u %a' -- "$(tn_update_lock_path)" 2>/dev/null || echo absent
    )
}

# err_has TEXT -- yes when the last acquire's messages contain TEXT.
err_has() {
    if grep -qF -- "$1" "$T/.err"; then echo yes; else echo no; fi
}

if ! command -v flock >/dev/null 2>&1; then
    skip "lock: a missing lock file is created 0600 (override)" "flock absent"
    skip "lock: the default lock file" "flock absent"
    finish
fi

TN_UPDATE_LOCK_FILE="$T/update.lock"
check "lock: a missing lock file is created 0600 (override)" "0 $(id -u) 600" "$(acquire)"
TN_UPDATE_LOCK_FILE="$T/sub/update.lock"
mkdir -p "$T/sub"
ln -s "$T/update.lock" "$T/sub/update.lock"
out="$(acquire)"
check "lock: a symlinked lock file is refused (override)" "1 yes" "${out%% *} $(err_has "is a symlink")"
check "lock: the symlink's target is unchanged" "$(id -u) 600" "$(stat -L -c '%u %a' -- "$T/sub/update.lock")"
unset TN_UPDATE_LOCK_FILE

as_nobody() {
    setpriv --reuid 65534 --regid 65534 --clear-groups "$@"
}
if [[ "$(id -u)" != 0 || ! -e /.dockerenv || -e /run/telcoin ]]; then
    skip "lock: the default lock file" "needs root inside a container with no /run/telcoin"
elif ! as_nobody true 2>/dev/null; then
    skip "lock: the default lock file" "setpriv --reuid absent"
else
    MADE_RUN=1
    L=/run/telcoin/update.lock
    check "lock: the default lock file is created root 0600" "0 0 600" "$(acquire)"
    as_nobody flock -n "$L" true 2>/dev/null
    rc=$?
    [[ $rc -ne 0 ]] && rc=refused
    check "lock: another account cannot open the 0600 lock file" "refused" "$rc"
    check "lock: root takes it after that attempt" "0 0 600" "$(acquire)"

    chmod 0644 "$L"
    check "lock: a root-owned 0644 lock file is set to 0600" "0 0 600" "$(acquire)"
    as_nobody flock -n "$L" true 2>/dev/null
    rc=$?
    [[ $rc -ne 0 ]] && rc=refused
    check "lock: after the repair another account cannot open it" "refused" "$rc"
    chmod 0666 "$L"
    check "lock: a root-owned 0666 lock file is set to 0600" "0 0 600" "$(acquire)"

    # A holder that opened the file while it was 0644 keeps its descriptor:
    # the repair narrows new opens only. The holder blocks the next run until
    # it exits; the refusal names the PID in the file.
    chmod 0644 "$L"
    setpriv --reuid 65534 --regid 65534 --clear-groups flock -n -o "$L" sleep 30 &
    HOLDER=$!
    n=0
    while ! grep -q " FLOCK " /proc/locks 2>/dev/null && [[ $n -lt 50 ]]; do
        n=$((n + 1))
        sleep 0.1 2>/dev/null || sleep 1
    done
    out="$(acquire)"
    check "lock: a holder from before the repair still blocks that run" "1 yes" \
        "${out%% *} $(err_has "Another update is already running")"
    check "lock: the file is 0600 after that run" "0 600" "$(stat -c '%u %a' -- "$L")"
    pkill -P "$HOLDER" 2>/dev/null
    kill "$HOLDER" 2>/dev/null
    wait "$HOLDER" 2>/dev/null
    check "lock: free again once that holder exits" "0 0 600" "$(acquire)"

    chown 65534 "$L"
    chmod 0644 "$L"
    out="$(acquire)"
    check "lock: a lock file owned by another account is refused" "1 65534 644" "$out"
    check "lock: the refusal names the owner" "yes" "$(err_has "Refusing the lock file ${L}: it is not owned by root.")"
    rm -f "$L"
fi

finish
