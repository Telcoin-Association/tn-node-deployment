#!/usr/bin/env bash
# shellcheck shell=bash
# V8 harness library: paths and the expect helper. Sourced by every t*.sh.
TN=${TN:-/home/drtnarg/coding/telcoin/tn-r2-packages}
REL=$TN/etc/release.sh
V8_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export SCRATCH=${SCRATCH:-/tmp/claude-1000/-home-drtnarg-coding-telcoin-tn-node-deployment/a63179cc-f715-4653-8076-ca7024820f15/scratchpad/V8}
OUT=$SCRATCH/out
mkdir -p "$OUT"
PASS=0
FAIL=0

# expect NAME WANT_RC WANT_SUBSTR [NOT_SUBSTR] -- CMD...: runs CMD with stdin from /dev/null,
# keeps its stdout+stderr in $OUT/NAME.txt, and checks the exit code and that the output holds
# WANT_SUBSTR (empty: no check) and not NOT_SUBSTR (empty: no check).
expect() {
    local name=$1 want_rc=$2 want=$3 not='' rc
    shift 3
    if [ "$1" != -- ]; then
        not=$1
        shift
    fi
    shift
    rc=0
    "$@" </dev/null >"$OUT/$name.txt" 2>&1 || rc=$?
    if [ "$rc" = "$want_rc" ] &&
        { [ -z "$want" ] || grep -qF -- "$want" "$OUT/$name.txt"; } &&
        { [ -z "$not" ] || ! grep -qF -- "$not" "$OUT/$name.txt"; }; then
        PASS=$((PASS + 1))
        printf 'PASS %-34s rc=%s\n' "$name" "$rc"
    else
        FAIL=$((FAIL + 1))
        printf 'FAIL %-34s rc=%s (want rc=%s, want "%s", not "%s")\n' "$name" "$rc" "$want_rc" "$want" "$not"
        sed 's/^/     | /' "$OUT/$name.txt" | tail -n 8
    fi
}

# show NAME: the last error line of a case, for the matrix.
show() {
    grep -E '^(error|warning):' "$OUT/$1.txt" | tail -n 1
}

summary() {
    printf '%s: %s passed, %s failed\n' "$1" "$PASS" "$FAIL"
    [ "$FAIL" = 0 ]
}
