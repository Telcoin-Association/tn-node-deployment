#!/usr/bin/env bash
# tools/tests/logrotate_test.sh -- tn_install_logrotate and tn_precreate_log_files.
# As a normal user the writes are refused (the temp dir is not root-owned) and
# only the template, size and group rules run; as root the writes run too, in a
# temp dir under /root. Maintainer tooling (not updater-tracked). bash 3.2 safe.
# shellcheck source=tools/tests/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
eval "$(tn_test_source_common)"
T="$TN_TEST_TMP"

# The group lookup is the only system dependency; a function shadows getent.
HAVE_GROUP=1
getent() {
    if [[ "${1:-}" == "group" && "${2:-}" == "telcoin-log" ]]; then
        [[ "$HAVE_GROUP" == 1 ]] && { echo "telcoin-log:x:999:"; return 0; }
        return 2
    fi
    command getent "$@"
}

EXPECTED='# Managed by tn-node-deployment (tn_install_logrotate). Node logs rotate when they reach '"'"'size'"'"'.
/var/log/telcoin/*.log {
    su root telcoin-log
    size 100M
    maxsize 1G
    rotate 5
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
}'
check "logrotate: template at 100M" "$EXPECTED" "$(_tn_logrotate_text 100M)"
check_has "logrotate: size follows the argument" "    size 2G" "$(_tn_logrotate_text 2G)"

for bad in 1X 100 M 1.5G -1G "1G x" ""; do
    [[ -z "$bad" ]] && continue
    rc=0; TN_LOGROTATE_FILE="$T/lr" tn_install_logrotate "$bad" 2>/dev/null || rc=$?
    check_rc "logrotate: size '$bad' refused" 1 "$rc"
done
check "logrotate: refused size wrote nothing" "no" "$([[ -e "$T/lr" ]] && echo yes || echo no)"

HAVE_GROUP=0
rc=0; TN_LOGROTATE_FILE="$T/lr" tn_install_logrotate 1G 2>/dev/null || rc=$?
check_rc "logrotate: missing telcoin-log group refused" 1 "$rc"
HAVE_GROUP=1

RB=""
if [[ "$(id -u)" == 0 ]]; then
    RB="$(mktemp -d /root/.tn-lr.XXXXXX 2>/dev/null)" || RB=""
    [[ -n "$RB" ]] && ! tn_root_dir_ok "$RB" && { rm -rf "$RB"; RB=""; }
fi
: > "$T/p1"
HAVE_MV_T=0
mv -f -T -- "$T/p1" "$T/p2" 2>/dev/null && HAVE_MV_T=1

if [[ -z "$RB" ]]; then
    rc=0; TN_LOGROTATE_FILE="$T/lr" tn_install_logrotate 2>/dev/null || rc=$?
    check_rc "logrotate: write into a non-root dir refused" 1 "$rc"
    skip "logrotate: root write, keep, rewrite" "not root"
    skip "precreate_log_files: create, keep, replace symlink" "not root"
elif [[ "$HAVE_MV_T" != 1 ]]; then
    skip "logrotate: root write, keep, rewrite" "mv -T absent"
    skip "precreate_log_files: create, keep, replace symlink" "mv -T absent"
else
    F="$RB/logrotate.d/telcoin"
    mkdir -m 0755 "$RB/logrotate.d"
    rc=0; TN_LOGROTATE_FILE="$F" tn_install_logrotate || rc=$?
    check_rc "logrotate: written" 0 "$rc"
    check "logrotate: content" "$EXPECTED" "$(cat "$F")"
    check "logrotate: root 0644" "0 0 644" "$(stat -c '%u %g %a' "$F")"
    printf 'size 7G\n' > "$F"
    TN_LOGROTATE_FILE="$F" tn_install_logrotate
    check "logrotate: no SIZE keeps an existing file" "size 7G" "$(cat "$F")"
    TN_LOGROTATE_FILE="$F" tn_install_logrotate 500M
    check_has "logrotate: SIZE rewrites" "    size 500M" "$(cat "$F")"
    rm -f "$F"; ln -s "$RB/canary" "$F"; printf 'keep\n' > "$RB/canary"
    rc=0; TN_LOGROTATE_FILE="$F" tn_install_logrotate 1G 2>/dev/null || rc=$?
    check_rc "logrotate: symlink at the destination refused" 1 "$rc"
    check "logrotate: symlink target untouched" "keep" "$(cat "$RB/canary")"

    if command getent group telcoin-log >/dev/null 2>&1 || groupadd --system telcoin-log 2>/dev/null; then
        L="$RB/log"
        mkdir -m 0750 "$L"
        chown root:telcoin-log "$L"
        printf 'old\n' > "$L/telcoin.log"
        ln -s "$RB/canary" "$L/telcoin-error.log"
        rc=0; tn_precreate_log_files "$L" telcoin 2>"$T/err" || rc=$?
        check_rc "precreate_log_files: rc" 0 "$rc"
        check "precreate_log_files: existing log kept" "old" "$(cat "$L/telcoin.log")"
        check "precreate_log_files: owner and mode" "root telcoin-log 640" "$(stat -c '%U %G %a' "$L/telcoin.log")"
        check "precreate_log_files: symlink replaced by a file" "file 0" "$([[ -L "$L/telcoin-error.log" ]] && echo link || echo file) $(stat -c %s "$L/telcoin-error.log")"
        check "precreate_log_files: symlink target untouched" "keep" "$(cat "$RB/canary")"
        check_has "precreate_log_files: replacement reported" "yes" "$(grep -q 'Replacing' "$T/err" && echo yes)"
        rm -f "$L/telcoin.log"; ln "$L/telcoin-error.log" "$L/telcoin.log"
        tn_precreate_log_files "$L" telcoin 2>/dev/null
        check "precreate_log_files: hard link replaced" "1" "$(stat -c %h "$L/telcoin.log")"
        chmod 0777 "$L"
        rc=0; tn_precreate_log_files "$L" telcoin 2>/dev/null || rc=$?
        check_rc "precreate_log_files: writable log dir refused" 1 "$rc"
    else
        skip "precreate_log_files: create, keep, replace symlink" "cannot create group telcoin-log"
    fi
    rm -rf "$RB"
fi

finish
