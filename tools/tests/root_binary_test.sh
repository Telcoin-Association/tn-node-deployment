#!/usr/bin/env bash
# =============================================================================
# tools/tests/root_binary_test.sh -- _tn_root_binary_ok follows a symlink chain
# one link at a time: every link must be root-owned, every directory on the way
# must pass tn_root_dir_ok, and the file must be root-owned and not group- or
# other-writable. TN_ROOT_BINARY_REAL names the resolved file, and
# tn_launch_runner prints that path.
#
#   bash tools/tests/root_binary_test.sh
#   docker run --rm -v "$PWD:/w" -w /w bash:3.2 bash tools/tests/root_binary_test.sh
#   docker run --rm -v "$PWD:/w" -w /w ubuntu:24.04 bash tools/tests/root_binary_test.sh
#
# The fixture needs root (a root-only temp dir under /root, files given to uid
# 65534); as a normal user only the relative-path refusal runs. bash 3.2 safe.
# =============================================================================

set -u

# shellcheck source=tools/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
eval "$(tn_test_source_common)"

T="$TN_TEST_TMP"
RB=""
trap 'tn_test_cleanup; if [[ -n "$RB" ]]; then rm -rf "$RB"; fi' EXIT

# ok PATH -- "<rc> <TN_ROOT_BINARY_REAL>" for _tn_root_binary_ok PATH.
ok() {
    local rc=0
    _tn_root_binary_ok "$1" || rc=$?
    printf '%s %s\n' "$rc" "$TN_ROOT_BINARY_REAL"
}

check "relative path refused" "1 " "$(ok relative/bin)"

if [[ "$(id -u)" == 0 && -d /root ]]; then
    RB="$(mktemp -d /root/tn_rootbin.XXXXXX 2>/dev/null)" || RB=""
fi
if [[ -z "$RB" ]] || ! tn_root_dir_ok "$RB" || ! chown -h 65534 "$RB" 2>/dev/null; then
    skip "symlink chains" "needs root, a root-only dir under /root and chown -h"
    finish
fi
chown -h 0 "$RB"
chmod 0755 "$RB"
R="$RB/r"
U="$RB/u"
mkdir -p "$R" "$U"
chmod 0755 "$R" "$U"
chown 65534 "$U"
printf '#!/bin/sh\necho real\n' > "$R/bin"
chmod 0755 "$R/bin"

check "a root binary passes, real path recorded" "0 $R/bin" "$(ok "$R/bin")"
ln -s bin "$R/tn1"
check "a relative root link passes" "0 $R/bin" "$(ok "$R/tn1")"
ln -s "$R/tn1" "$R/tn2"
check "two root links pass" "0 $R/bin" "$(ok "$R/tn2")"

# The three-hop chain: a root link into a directory another account owns, whose
# link (owned by that account) leads back to the root binary.
ln -s "$R/bin" "$U/hop"
chown -h 65534 "$U/hop"
ln -s "$U/hop" "$R/tn"
check "three hops through an account's directory refused" "1 " "$(ok "$R/tn")"
chown -h 0 "$U/hop"
check "a root link in an account's directory refused" "1 " "$(ok "$R/tn")"

ln -s bin "$R/theirs"
chown -h 65534 "$R/theirs"
check "a link owned by another account refused (root directory)" "1 " "$(ok "$R/theirs")"

cp "$R/bin" "$U/file"
ln -s "$U/file" "$R/tn3"
check "a link to a root file in an account's directory refused" "1 " "$(ok "$R/tn3")"

ln -s loop "$R/loop"
check "a link loop refused" "1 " "$(ok "$R/loop")"

cp "$R/bin" "$R/gw"
chmod 0775 "$R/gw"
check "a group-writable binary refused" "1 " "$(ok "$R/gw")"
cp "$R/bin" "$R/theirbin"
chown 65534 "$R/theirbin"
check "a binary owned by another account refused" "1 " "$(ok "$R/theirbin")"

# tn_launch_runner prints the resolved file; a refused chain is rc 5.
printf '#!/bin/bash\nexec %s node --http --http.addr 127.0.0.1 --datadir /var/lib/telcoin\n' "$R/tn2" > "$T/launch"
check "tn_launch_runner prints the resolved binary" "binary:$R/bin" "$(tn_launch_runner "$T/launch" 2>/dev/null)"
printf '#!/bin/bash\nexec %s node --http --http.addr 127.0.0.1 --datadir /var/lib/telcoin\n' "$R/tn" > "$T/launch"
tn_launch_runner "$T/launch" > /dev/null 2>&1
check_rc "tn_launch_runner refuses the three-hop chain (rc 5)" 5 "$?"

finish
