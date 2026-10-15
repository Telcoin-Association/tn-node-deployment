#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# tools/tests/lib.sh -- shared helpers for the fixture tests in tools/tests/
#
# Every tools/tests/*_test.sh sources this file at its top level, runs its
# checks, and calls finish last. tools/tests/run.sh runs them all under the bash
# that invokes it, so the same tests run under bash 5 and under bash 3.2.
#
#   check NAME EXPECTED ACTUAL       ACTUAL equals EXPECTED (diff on failure)
#   check_has NAME LINE TEXT         TEXT contains LINE as a whole line
#   check_lacks NAME STRING TEXT     STRING appears nowhere in TEXT
#   check_rc NAME EXPECTED ACTUAL    two exit codes are equal
#   skip NAME REASON                 record a check that cannot run here
#   finish                           print the counts; exit 1 on any failure
#
# check, check_has and check_lacks behave exactly like their namesakes in
# ui/tests/helper_test.sh. Each prints "ok    NAME" or "FAIL  NAME" plus detail
# and returns 0 or 1; a failure never stops the test.
#
# Sourcing lib/common.sh: run this line at the TOP LEVEL of the test, never
# inside a function (bash 3.2 makes a `readonly NAME=(...)` array that runs
# inside a function local to it, so fallback.sh's TN_LEGACY_NAMES would vanish):
#
#   eval "$(tn_test_source_common)"
#
# Set TN_ROOT_PREFIX before that line to point fallback.sh's probes at a fixture
# tree. common.sh turns on `set -e` and assigns SERVICE_USER and SERVICE_GROUP;
# the line turns -e back off (a failing check must not end the test), keeps a
# SERVICE_USER or SERVICE_GROUP the test set before it, and sets SERVICE_NAME to
# "telcoin" when it is unset. Source common.sh once per test: its readonly
# constants refuse a second assignment.
#
# TN_TEST_TMP is a private temp dir, removed on exit by the EXIT trap set here.
# A test that sets its own EXIT trap calls tn_test_cleanup from it.
#
# Maintainer tooling: update-scripts.sh does not track tools/ and these files
# have no .sha256 sidecar. bash 3.2 safe.
# =============================================================================

TN_TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TN_TEST_REPO="$(cd "${TN_TEST_DIR}/../.." && pwd)"

CHECKS=0
FAILS=0
SKIPS=0

TN_TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/tn_test.XXXXXX")" || {
    echo "tools/tests/lib.sh: mktemp failed" >&2
    exit 1
}

tn_test_cleanup() {
    if [[ -n "${TN_TEST_TMP:-}" && -d "$TN_TEST_TMP" ]]; then
        rm -rf "$TN_TEST_TMP"
    fi
}
trap tn_test_cleanup EXIT

# check <name> <expected> <actual>
check() {
    CHECKS=$((CHECKS + 1))
    if [[ "$2" == "$3" ]]; then
        printf 'ok    %s\n' "$1"
        return 0
    fi
    FAILS=$((FAILS + 1))
    printf 'FAIL  %s\n      expected (<) vs actual (>):\n' "$1"
    printf '%s\n' "$2" > "$TN_TEST_TMP/expected"
    printf '%s\n' "$3" > "$TN_TEST_TMP/actual"
    diff "$TN_TEST_TMP/expected" "$TN_TEST_TMP/actual" | sed 's/^/      /'
    return 1
}

# check_has <name> <line> <text> -- <text> contains <line> as a whole line.
check_has() {
    CHECKS=$((CHECKS + 1))
    if printf '%s\n' "$3" | grep -qxF -- "$2"; then
        printf 'ok    %s\n' "$1"
        return 0
    fi
    FAILS=$((FAILS + 1))
    printf 'FAIL  %s\n      missing line: %s\n      in:\n' "$1" "$2"
    printf '%s\n' "$3" | sed 's/^/        /'
    return 1
}

# check_lacks <name> <string> <text> -- <string> appears nowhere in <text>.
check_lacks() {
    CHECKS=$((CHECKS + 1))
    if ! printf '%s\n' "$3" | grep -qF -- "$2"; then
        printf 'ok    %s\n' "$1"
        return 0
    fi
    FAILS=$((FAILS + 1))
    printf 'FAIL  %s\n      unexpected: %s\n      in:\n' "$1" "$2"
    printf '%s\n' "$3" | sed 's/^/        /'
    return 1
}

# check_rc <name> <expected-rc> <actual-rc>
check_rc() {
    CHECKS=$((CHECKS + 1))
    if [[ "$2" == "$3" ]]; then
        printf 'ok    %s\n' "$1"
        return 0
    fi
    FAILS=$((FAILS + 1))
    printf 'FAIL  %s\n      expected rc %s, got rc %s\n' "$1" "$2" "$3"
    return 1
}

# skip <name> <reason> -- a check this host cannot run (a missing tool, not root).
skip() {
    SKIPS=$((SKIPS + 1))
    printf 'SKIP  %s (%s)\n' "$1" "$2"
    return 0
}

# finish -- print "<n> checks, <f> failures, <s> skipped" and exit (1 on any failure).
finish() {
    printf '\n%s checks, %s failures, %s skipped\n' "$CHECKS" "$FAILS" "$SKIPS"
    if [[ $FAILS -ne 0 ]]; then
        exit 1
    fi
    exit 0
}

# tn_test_source_common -- print the commands that source lib/common.sh; the
# test runs them with eval at its top level (see the header for why).
tn_test_source_common() {
    printf '%s\n' "tn_test_pre_common; source $(printf '%q' "${TN_TEST_REPO}/lib/common.sh"); tn_test_post_common"
}

# tn_test_pre_common / tn_test_post_common -- the halves around that source line.
tn_test_pre_common() {
    : "${TN_ROOT_PREFIX:=}"
    _TN_TEST_SU_SET="${SERVICE_USER+1}"
    _TN_TEST_SU="${SERVICE_USER-}"
    _TN_TEST_SG_SET="${SERVICE_GROUP+1}"
    _TN_TEST_SG="${SERVICE_GROUP-}"
}
tn_test_post_common() {
    set +e
    if [[ -n "$_TN_TEST_SU_SET" ]]; then SERVICE_USER="$_TN_TEST_SU"; fi
    if [[ -n "$_TN_TEST_SG_SET" ]]; then SERVICE_GROUP="$_TN_TEST_SG"; fi
    SERVICE_USER="${SERVICE_USER:-telcoin}"
    SERVICE_GROUP="${SERVICE_GROUP:-telcoin}"
    SERVICE_NAME="${SERVICE_NAME:-telcoin}"
}
