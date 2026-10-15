#!/usr/bin/env bash
# =============================================================================
# tools/tests/inflight_tmp_test.sh -- a signal mid-write leaves no root-owned
# temp file: tn_write_root_file and tn_install_root_binary record their temp
# file in TN_INFLIGHT_TMP, the EXIT traps of setup-node, update-node and
# edit-config remove it (tn_remove_inflight_tmp), and tn_install_root_binary
# removes a DEST.new.<pid> an earlier killed run left behind.
#
#   bash tools/tests/inflight_tmp_test.sh
#   docker run --rm -v "$PWD:/w" -w /w bash:3.2 bash tools/tests/inflight_tmp_test.sh
#   docker run --rm -v "$PWD:/w" -w /w ubuntu:24.04 bash tools/tests/inflight_tmp_test.sh
#
# The exit-handler cases run anywhere. The install and write cases need root (a
# root-only temp dir under /root) and GNU mv -T; a stub install or chown on PATH
# stops in the middle of the write until the driver gets SIGTERM. bash 3.2 safe.
# =============================================================================

set -u

# shellcheck source=tools/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

T="$TN_TEST_TMP"
RB=""
trap 'tn_test_cleanup; if [[ -n "$RB" ]]; then rm -rf "$RB"; fi' EXIT
REPO="$TN_TEST_REPO"

# ---- each script's EXIT handler removes TN_INFLIGHT_TMP -----------------------------
mkdir -p "$T/h"
ln -s "$REPO/lib" "$T/h/lib"
for pair in setup-node:json_on_exit update-node:update_on_exit edit-config:edit_on_exit; do
    script="${pair%%:*}"
    fn="${pair##*:}"
    grep -v '^main "\$@"$' "$REPO/${script}.sh" > "$T/h/${script}.sh"
    : > "$T/inflight.${script}"
    # shellcheck disable=SC2016
    TN_UPDATE_LOCK_FILE="$T/update.lock" "$BASH" -c '
        source "$1" > /dev/null 2>&1
        set +eu
        JSON_MODE=false
        TN_INFLIGHT_TMP="$2"
        "$3" > /dev/null 2>&1
        exit 0' _ "$T/h/${script}.sh" "$T/inflight.${script}" "$fn"
    check "${script} ${fn} removes the in-flight temp file" "removed" \
        "$([[ -e "$T/inflight.${script}" ]] && echo kept || echo removed)"
done

# ---- the library cases (root) -------------------------------------------------------
eval "$(tn_test_source_common)"
: > "$T/probe1"
HAVE_MV_T=0
mv -f -T -- "$T/probe1" "$T/probe2" 2>/dev/null && HAVE_MV_T=1
if [[ "$(id -u)" == 0 && -d /root ]]; then
    RB="$(mktemp -d /root/tn_inflight.XXXXXX 2>/dev/null)" || RB=""
fi
if [[ -z "$RB" ]] || ! tn_root_dir_ok "$RB"; then
    skip "install: a stale .new file is removed first" "needs root and a root-only dir under /root"
    skip "install: SIGTERM mid-install leaves no .new file" "needs root and a root-only dir under /root"
    skip "write: SIGTERM mid-write leaves no temp file" "needs root and a root-only dir under /root"
    finish
fi
if [[ $HAVE_MV_T == 0 ]]; then
    skip "install and write cases" "mv -T absent"
    finish
fi
chmod 0755 "$RB"
mkdir -p "$RB/bin" "$RB/etc" "$RB/stub"
printf 'old\n' > "$RB/bin/tn"
printf 'new\n' > "$T/tn.src"

: > "$RB/bin/tn.new.4242"
TN_INFLIGHT_TMP=""
tn_install_root_binary "$T/tn.src" "$RB/bin/tn" 2>/dev/null
check_rc "install: rc 0" 0 "$?"
check "install: a stale .new file is removed first" "absent new" \
    "$([[ -e "$RB/bin/tn.new.4242" ]] && echo present || echo absent) $(cat "$RB/bin/tn")"
check "install: TN_INFLIGHT_TMP is empty after the rename" "" "$TN_INFLIGHT_TMP"
printf 'old\n' > "$RB/bin/tn"

# stub TOOL -- a PATH stub for TOOL that runs the real one, then records its PID
# in $RB/stub/pid, signals $RB/stub/ready and sleeps until it is killed.
stub() {
    local real
    real="$(type -P "$1")"
    printf '#!/bin/sh\n%s "$@"\necho $$ > "%s/stub/pid"\n: > "%s/stub/ready"\nexec sleep 30\n' \
        "$real" "$RB" "$RB" > "$RB/stub/$1"
    chmod 0755 "$RB/stub/$1"
}

# term_mid CMD -- run CMD in a driver bash with the library, an EXIT trap that
# calls tn_remove_inflight_tmp, and the stubs first on PATH; SIGTERM the driver
# once a stub is reached, then end the stub.
term_mid() {
    local drv n=0
    rm -f "$RB/stub/ready" "$RB/stub/pid"
    TN_STUBS="$RB/stub" "$BASH" -c '
        source "$1/lib/common.sh" > /dev/null 2>&1
        set +e
        trap tn_remove_inflight_tmp EXIT
        PATH="$TN_STUBS:$PATH"
        eval "$2"' _ "$REPO" "$1" > /dev/null 2>&1 &
    drv=$!
    while [[ ! -e "$RB/stub/ready" && $n -lt 100 ]]; do
        n=$((n + 1))
        sleep 0.1 2>/dev/null || sleep 1
    done
    kill -TERM "$drv" 2>/dev/null
    wait "$drv" 2>/dev/null
    kill "$(cat "$RB/stub/pid" 2>/dev/null)" 2>/dev/null
    [[ -e "$RB/stub/ready" ]] && echo reached || echo not-reached
}

stub install
check "install: the stub was reached" "reached" "$(term_mid "tn_install_root_binary $T/tn.src $RB/bin/tn")"
check "install: SIGTERM mid-install leaves no .new file" "" "$(cd "$RB/bin" && ls -A | grep -F 'tn.new.' || true)"
check "install: the binary is unchanged" "old" "$(cat "$RB/bin/tn")"
rm -f "$RB/stub/install"

printf 'old\n' > "$RB/etc/f"
stub chown
check "write: the stub was reached" "reached" "$(term_mid "tn_write_root_file $RB/etc/f 0644 <<< changed")"
check "write: SIGTERM mid-write leaves no temp file" "" "$(cd "$RB/etc" && ls -A | grep -F '.tn.' || true)"
check "write: the file is unchanged" "old" "$(cat "$RB/etc/f")"

finish
