#!/usr/bin/env bash
# =============================================================================
# tools/tests/root_dir_rule_test.sh -- tn_root_dir_ok and group-writable
# directories: a root-owned directory above the ones the scripts own may be
# group-writable when its group is a system group (gid below 1000), as stock
# Ubuntu's /var/log is (root:syslog 0775); never other-writable, never with a
# group of gid 1000 or more; and no group write at all from the scripts' own
# directories (/var/log/telcoin, /etc/telcoin, ...) down.
#
#   bash tools/tests/root_dir_rule_test.sh
#   docker run --rm -v "$PWD:/w" -w /w bash:3.2 bash tools/tests/root_dir_rule_test.sh
#   docker run --rm -v "$PWD:/w" -w /w ubuntu:24.04 bash tools/tests/root_dir_rule_test.sh
#
# The fixture tree (TN_ROOT_PREFIX under a root-only dir in /root) needs root.
# The real /var/log case (root:syslog 0775, a syslog group added when absent)
# runs only inside a container, which is thrown away afterwards; /var/log's
# group and mode are put back all the same. bash 3.2 safe.
# =============================================================================

set -u

# shellcheck source=tools/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
eval "$(tn_test_source_common)"

T="$TN_TEST_TMP"
RB=""
VL_SAVED=""
restore_var_log() {
    if [[ -n "$VL_SAVED" ]]; then
        chgrp "${VL_SAVED%% *}" /var/log 2>/dev/null
        chmod "${VL_SAVED##* }" /var/log 2>/dev/null
    fi
}
trap 'restore_var_log; tn_test_cleanup; if [[ -n "$RB" ]]; then rm -rf "$RB"; fi' EXIT

# ok DIR -- tn_root_dir_ok's rc for DIR.
ok() {
    local rc=0
    tn_root_dir_ok "$1" || rc=$?
    printf '%s\n' "$rc"
}

if [[ "$(id -u)" == 0 && -d /root ]]; then
    RB="$(mktemp -d /root/tn_rootdir.XXXXXX 2>/dev/null)" || RB=""
fi
if [[ -z "$RB" ]] || ! tn_root_dir_ok "$RB"; then
    skip "group-writable parents" "needs root and a root-only dir under /root"
    finish
fi
chmod 0755 "$RB"

# ---- a fixture tree under TN_ROOT_PREFIX ------------------------------------------------
TN_ROOT_PREFIX="$RB"
mkdir -p "$RB/var/log/telcoin" "$RB/etc/telcoin" "$RB/srv/data"
chmod 0755 "$RB/var" "$RB/var/log" "$RB/etc" "$RB/etc/telcoin" "$RB/srv" "$RB/srv/data"
chmod 0750 "$RB/var/log/telcoin"
SYS_GID=104
HIGH_GID=1500

chgrp "$SYS_GID" "$RB/var/log"
chmod 0775 "$RB/var/log"
check "var/log root:<system group> 0775 passes" "0" "$(ok "$RB/var/log")"
check "var/log/telcoin below it passes" "0" "$(ok "$RB/var/log/telcoin")"
chmod 2775 "$RB/var/log"
check "var/log with setgid (2775) passes" "0" "$(ok "$RB/var/log/telcoin")"
chmod 0777 "$RB/var/log"
check "var/log other-writable (0777) refused" "1" "$(ok "$RB/var/log/telcoin")"
chmod 0775 "$RB/var/log"
chgrp "$HIGH_GID" "$RB/var/log"
check "var/log root:<gid 1500> 0775 refused" "1" "$(ok "$RB/var/log")"
check "var/log/telcoin below a gid-1500 0775 parent refused" "1" "$(ok "$RB/var/log/telcoin")"
chgrp "$SYS_GID" "$RB/var/log"

chgrp "$SYS_GID" "$RB/var/log/telcoin"
chmod 0770 "$RB/var/log/telcoin"
check "var/log/telcoin group-writable (system group) refused: the scripts own it" "1" "$(ok "$RB/var/log/telcoin")"
chmod 0750 "$RB/var/log/telcoin"
chgrp 0 "$RB/var/log/telcoin"

chgrp "$SYS_GID" "$RB/etc"
chmod 0775 "$RB/etc"
check "etc root:<system group> 0775 passes" "0" "$(ok "$RB/etc/telcoin")"
chgrp "$SYS_GID" "$RB/etc/telcoin"
chmod 0775 "$RB/etc/telcoin"
check "etc/telcoin group-writable refused" "1" "$(ok "$RB/etc/telcoin")"
chmod 0755 "$RB/etc/telcoin" "$RB/etc"

chgrp "$SYS_GID" "$RB/srv/data"
chmod 0775 "$RB/srv/data"
check "a system path root:<system group> 0775 passes" "0" "$(ok "$RB/srv/data")"
chgrp "$HIGH_GID" "$RB/srv/data"
check "a system path root:<gid 1500> 0775 refused" "1" "$(ok "$RB/srv/data")"
unset TN_ROOT_PREFIX

# ---- the real /var/log, root:syslog 0775 (in a container only) ---------------------------
if [[ ! -e /.dockerenv ]]; then
    skip "real /var/log root:syslog 0775" "runs only inside a container"
    finish
fi
if ! getent group syslog >/dev/null 2>&1; then
    groupadd -r syslog >/dev/null 2>&1 || addgroup -S syslog >/dev/null 2>&1
fi
sg="$(getent group syslog 2>/dev/null | cut -d: -f3)"
if [[ -z "$sg" ]]; then
    skip "real /var/log root:syslog 0775" "no syslog group and no groupadd"
    finish
fi
VL_SAVED="$(stat -c '%g %a' /var/log)"
chgrp syslog /var/log
chmod 0775 /var/log
check "syslog is a system group" "yes" "$( (( sg < 1000 )) && echo yes || echo no)"
check "/var/log root:syslog 0775 passes" "0" "$(ok /var/log)"
# The log dir as create_directories makes it (its parent check first).
LD=/var/log/telcoin
[[ ! -e "$LD" ]] || LD="/var/log/tn-test-$$"
rc=0
_tn_parent_ready "$LD" > /dev/null 2>&1 || rc=$?
check "the log dir may be created under it (_tn_parent_ready)" "0" "$rc"
install -d -o root -g root -m 0750 "$LD"
check "the root 0750 log dir under it passes" "0" "$(ok "$LD")"
rm -rf "$LD"
groupadd -g "$HIGH_GID" tnhigh >/dev/null 2>&1 || addgroup -g "$HIGH_GID" tnhigh >/dev/null 2>&1
chgrp "$HIGH_GID" /var/log
check "/var/log root:<gid 1500> 0775 refused" "1" "$(ok /var/log)"
restore_var_log
VL_SAVED=""

finish
