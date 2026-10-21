#!/usr/bin/env bash
# =============================================================================
# tools/tests/node_log_dir_test.sh -- a binary node can write its JSON logs into
# NODE_LOG_DIR and a telcoin-log member can read them. The layout comes from the
# library (_tn_root_layout_dir for the log dir root:telcoin-log 0750,
# tn_node_log_dir_prepare for the node log dir) and the service account runs with
# the supplementary group and the UMask= of the unit the library renders, so a
# change to any of the three shows here.
#
#   bash tools/tests/node_log_dir_test.sh
#   docker run --rm -v "$PWD:/w" -w /w ubuntu:24.04 bash tools/tests/node_log_dir_test.sh
#
# The rendering checks run anywhere. The access cases need root, setpriv,
# useradd and groupadd (throwaway system accounts and the telcoin-log group), so
# they run in the ubuntu container and are skipped elsewhere. Maintainer tooling
# (not updater-tracked). bash 3.2 safe.
# =============================================================================

set -u

# shellcheck source=tools/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
T="$TN_TEST_TMP"
TN_ROOT_PREFIX="$T/empty"
mkdir -p "$TN_ROOT_PREFIX"
eval "$(tn_test_source_common)"

# shellcheck disable=SC2034  # read by the library renderers
NETWORK=testnet
DATA_DIR=/var/lib/telcoin
PASSPHRASE_METHOD=stdin
LOG_TARGET=file

unit_value() {  # unit_value KEY UNIT-TEXT -> the value of the first KEY= line
    printf '%s\n' "$2" | sed -n "s/^$1=//p" | head -n 1
}

UNIT="$(NODE_LOG_DIR=/var/log/telcoin/node _tn_node_unit_text source 2>/dev/null)"
check "unit: UMask" "0027" "$(unit_value UMask "$UNIT")"
check "unit: the node joins the log group" "telcoin-log" "$(unit_value SupplementaryGroups "$UNIT")"
check "unit: NODE_LOG_DIR writable" "/var/lib/telcoin /var/log/telcoin/node" "$(unit_value ReadWritePaths "$UNIT")"

REAL=no
if [[ "$(id -u)" == "0" ]] && command -v useradd >/dev/null 2>&1 && command -v groupadd >/dev/null 2>&1 \
    && setpriv --help 2>&1 | grep -q -- '--clear-groups'; then
    REAL=yes
fi
if [[ "$REAL" != yes ]]; then
    skip "service account writes NODE_LOG_DIR, a telcoin-log member reads it" "needs root, setpriv, useradd (ubuntu container)"
    finish
fi

SVC=tnlogsvc RDR=tnlogrdr OTH=tnlogoth
_tn_log_group_ensure || { printf 'FAIL  telcoin-log group could not be created\n'; exit 1; }
id -u "$SVC" >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin "$SVC"
id -u "$RDR" >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin -G telcoin-log "$RDR"
id -u "$OTH" >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin "$OTH"

# A root-owned fixture root the accounts can traverse (TN_TEST_TMP is root 0700).
F="$(mktemp -d /run/tn_logdir.XXXXXX)"
chmod 0755 "$F"
trap 'rm -rf "$F"; tn_test_cleanup' EXIT
LOGD="$F/log"
NLD="$LOGD/node"
_tn_root_layout_dir "$LOGD" telcoin-log 0750; check_rc "log dir root:telcoin-log 0750" 0 $?
tn_node_log_dir_prepare "$NLD" "$SVC"; check_rc "node log dir prepared" 0 $?
check "node log dir: service account, telcoin-log, setgid 2750" "${SVC}:telcoin-log 2750" "$(stat -c '%U:%G %a' "$NLD")"
mkdir -m 0700 "$F/stale"; chown "$SVC" "$F/stale"
tn_node_log_dir_prepare "$F/stale" "$SVC"; check_rc "an existing dir is re-moded" 0 $?
check "existing dir: setgid 2750" "${SVC}:telcoin-log 2750" "$(stat -c '%U:%G %a' "$F/stale")"
ln -s "$NLD" "$F/link"
tn_node_log_dir_prepare "$F/link" "$SVC"; check_rc "a symlink is refused" 1 $?

UNIT="$(NODE_LOG_DIR="$NLD" _tn_node_unit_text source 2>/dev/null)"
GROUPS_U="$(unit_value SupplementaryGroups "$UNIT")"
UMASK_U="$(unit_value UMask "$UNIT")"
# As the node runs: the service account, its own group, the unit's supplementary
# group and umask; reth makes telcoin-network-logs/ and reth.log in NODE_LOG_DIR.
setpriv --reuid "$SVC" --regid "$SVC" --groups "$GROUPS_U" sh -c \
    "umask $UMASK_U && mkdir -p '$NLD/telcoin-network-logs' && printf 'line\n' > '$NLD/telcoin-network-logs/reth.log'" 2>"$T/err"
check_rc "the service account writes its JSON log" 0 $?
check "log subdir takes the group and stays group-readable" "${SVC}:telcoin-log 2750" \
    "$(stat -c '%U:%G %a' "$NLD/telcoin-network-logs")"
check "log file: group telcoin-log, 0640" "${SVC}:telcoin-log 640" "$(stat -c '%U:%G %a' "$NLD/telcoin-network-logs/reth.log")"
check "a telcoin-log member reads it" "line" \
    "$(setpriv --reuid "$RDR" --regid "$RDR" --init-groups cat "$NLD/telcoin-network-logs/reth.log" 2>/dev/null)"
check "another account cannot" "" \
    "$(setpriv --reuid "$OTH" --regid "$OTH" --init-groups cat "$NLD/telcoin-network-logs/reth.log" 2>/dev/null)"
# Without the unit's group the account cannot even reach the dir.
setpriv --reuid "$SVC" --regid "$SVC" --clear-groups sh -c "mkdir '$NLD/x'" 2>/dev/null
check_rc "without SupplementaryGroups= the dir is out of reach" 1 $?

finish
