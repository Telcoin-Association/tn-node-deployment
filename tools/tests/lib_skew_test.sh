#!/usr/bin/env bash
# =============================================================================
# tools/tests/lib_skew_test.sh -- the scripts against an older lib/common.sh:
# setup-node, update-node, edit-config and prepare-stake refuse up front with one
# message (and a --json error plus done event), and check-node warns once about
# the hardening checks the older library turns off.
#
#   bash tools/tests/lib_skew_test.sh
#
# The older library is lib/ at 037c810 (COMMON_VERSION 1.6.1, the release
# before the hardening round), read with git. Without git or that commit (a
# container, a shallow clone) the test prints SKIP. bash 3.2 safe.
# =============================================================================

set -u

# shellcheck source=tools/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

T="$TN_TEST_TMP"
REPO="$TN_TEST_REPO"
OLD=037c810

if ! command -v git >/dev/null 2>&1 \
    || ! git -C "$REPO" cat-file -e "${OLD}^{commit}" 2>/dev/null; then
    skip "scripts against the ${OLD} library" "git or commit ${OLD} not available"
    finish
fi
mkdir -p "$T/old"
git -C "$REPO" archive "$OLD" lib | tar -x -C "$T/old"
for s in setup-node update-node edit-config prepare-stake check-node; do
    cp "$REPO/${s}.sh" "$T/old/${s}.sh"
done
check "old library is 1.6.1" "1.6.1" "$(sed -n 's/^readonly COMMON_VERSION="\(.*\)"$/\1/p' "$T/old/lib/common.sh")"

for s in setup-node update-node edit-config prepare-stake; do
    msg="lib/common.sh 1.6.1 is older than this ${s}.sh: run update-scripts.sh and try again."
    rc=0
    "$BASH" "$T/old/${s}.sh" --help > "$T/out" 2> "$T/err" < /dev/null || rc=$?
    check_rc "${s}: refused (rc 1)" 1 "$rc"
    check "${s}: one message on stderr" "[ERROR] ${msg}" "$(cat "$T/err")"
    check "${s}: nothing on stdout" "" "$(cat "$T/out")"
    rc=0
    "$BASH" "$T/old/${s}.sh" --json > "$T/out" 2> "$T/err" < /dev/null || rc=$?
    check_rc "${s} --json: refused (rc 1)" 1 "$rc"
    check "${s} --json: an error and a done event" \
        "$(printf '{"event":"error","msg":"%s"}\n{"event":"done","ok":false,"msg":"%s"}' "$msg" "$msg")" \
        "$(cat "$T/out")"
done

# check-node: the hardening checks, cut out as check_node_hardening_test does,
# run over the old library; the ones it turns off are named in one warning.
CN="$T/old/check-node.sh"
{
    sed -n '/^have_fns() {/,/^}/p' "$CN"
    awk '/^# HARDENING CHECKS/ { f = 1 } /^# REPORT HEADER/ { f = 0 } f' "$CN"
    # The loop and the warning, as at the top level of check-node.sh.
    sed -n '/^for _hc in check_bls_cleartext/,/^cn_report_skipped$/p' "$CN"
} > "$T/cn.sh"
mkdir -p "$T/fx"
out="$( TN_ROOT_PREFIX="$T/fx"
        # shellcheck source=/dev/null
        source "$T/old/lib/common.sh" > /dev/null 2>&1
        set +eu
        HEALTH_ISSUES=0
        # shellcheck source=/dev/null
        source "$T/cn.sh" 2>&1 )"
check "check-node: one warning about skipped checks" "1" "$(printf '%s\n' "$out" | grep -c 'older than this check-node.sh')"
check_has "check-node: the warning names the checks" "yes" \
    "$(printf '%s\n' "$out" | grep -q 'skipped: check_update_lock check_ownership_layout check_healthcheck_on_mainnet\.' && echo yes)"

finish
