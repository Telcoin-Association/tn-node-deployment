#!/usr/bin/env bash
# tools/tests/preflight_existing_test.sh -- setup-node.sh's existing-binary
# preflight (binary_path_ok, run by _preflight_existing and by finalize) refuses
# a --binary-path that the start-script writer would refuse (_tn_root_binary_ok)
# or that the service account cannot read and run (tn_service_user_can_run),
# before anything is written and before the binary is run.
#
# A copy of setup-node.sh without its last line is sourced at the top level.
# Maintainer tooling (not updater-tracked). bash 3.2 safe.
# shellcheck source=tools/tests/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
T="$TN_TEST_TMP"
mkdir -p "$T/sn" "$T/root" "$T/d"
grep -v '^main "\$@"$' "$TN_TEST_REPO/setup-node.sh" > "$T/sn/setup-node.sh"
ln -s "$TN_TEST_REPO/lib" "$T/sn/lib"
TN_ROOT_PREFIX="$T/root"
tn_test_pre_common
# shellcheck source=/dev/null
source "$T/sn/setup-node.sh"
set +e  # setup-node.sh makes SERVICE_NAME readonly

has() {
    case "$1" in
        *"$2"*) echo yes ;;
        *) echo no ;;
    esac
}

# The permission-bit form (no such account yet).
SERVICE_USER=tn-no-such-user-xyz
chmod 0755 "$T"  # mktemp -d made it 0700
printf '#!/bin/sh\n' > "$T/d/bin"
chmod 0755 "$T/d/bin"
# The permission-bit form walks every directory above the file, as below; macOS
# keeps TMPDIR in a directory only its owner can search (0700).
tmp_searchable=yes
d="${T%/*}"
while [[ -n "$d" ]]; do
    m="$(stat -c %a -- "$d" 2>/dev/null)" || m=""
    [[ "$m" =~ ^[0-7]+$ ]] && (( (8#$m & 1) == 1 )) || tmp_searchable=no
    d="${d%/*}"
done
if [[ "$tmp_searchable" == yes ]]; then
    rc=0; tn_service_user_can_run "$T/d/bin" || rc=$?
    check_rc "service account: 0755 file in searchable dirs" 0 "$rc"
else
    skip "service account: 0755 file in searchable dirs" "a directory above ${T} is not searchable by others"
fi
chmod 0750 "$T/d/bin"
rc=0; tn_service_user_can_run "$T/d/bin" || rc=$?
check_rc "service account: 0750 file refused" 1 "$rc"
chmod 0711 "$T/d/bin"
rc=0; tn_service_user_can_run "$T/d/bin" || rc=$?
check_rc "service account: 0711 file (not readable) refused" 1 "$rc"
chmod 0755 "$T/d/bin"
chmod 0750 "$T/d"
rc=0; tn_service_user_can_run "$T/d/bin" || rc=$?
check_rc "service account: a directory above it not searchable" 1 "$rc"
chmod 0755 "$T/d"
rc=0; tn_service_user_can_run relative/bin || rc=$?
check_rc "service account: relative path refused" 1 "$rc"

# binary_path_ok: a system binary (root's all the way) passes; a file in a temp
# dir (not a root-owned directory chain) is refused with the writer's message.
SYS="$(type -P env)"
BINARY_PATH="$SYS"
rc=0; out="$(binary_path_ok)" || rc=$?
check "system binary accepted" "0 " "$rc $out"
BINARY_PATH="$T/d/bin"
rc=0; out="$(binary_path_ok)" || rc=$?
check_rc "a binary outside root-owned directories: refused" 1 "$rc"
check "refusal is the start-script writer's" yes \
    "$(has "$out" "the node binary must be a root-owned file, not group- or other-writable, in root-owned directories")"

# The service-account check runs on the resolved binary.
_tn_root_binary_ok() { TN_ROOT_BINARY_REAL="$1"; return 0; }
chmod 0750 "$T/d/bin"
rc=0; out="$(binary_path_ok)" || rc=$?
check_rc "root-owned but unreadable for the service account: refused" 1 "$rc"
check "unreadable: says which account" yes "$(has "$out" "the service account tn-no-such-user-xyz cannot read and run")"
chmod 0755 "$T/d/bin"

# _preflight_existing stops in preflight, before verify_binary runs the file.
_tn_root_binary_ok() { return 1; }
verify_binary() { printf 'ran\n' >> "$T/ran"; return 0; }
: > "$T/ran"
rc=0
( BINARY_PATH="$T/d/bin"; _preflight_existing ) > "$T/out" 2>&1 || rc=$?
check_rc "preflight refuses the binary" 1 "$rc"
check "preflight says why" yes "$(has "$(cat "$T/out")" "the node binary must be a root-owned file")"
check "the binary was not run" "" "$(cat "$T/ran")"
finish
