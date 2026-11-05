#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# tasks/verify-r2/V7-IMG/lib.sh -- shared setup for the V7-IMG harness (round 2,
# per-network image packages). Sourced at the top level of every t_*.sh here.
#
# V7IMG_REPO names the tree under test (default: the worktree that holds this
# file); the mutation runner points it at a scratch copy. The repository's own
# tools/tests/lib.sh of that tree is sourced for check/check_rc/check_has/
# check_lacks/skip/finish and TN_TEST_TMP.
#
# v7_docker_stub DIR writes DIR/docker, a stand-in that never pulls or runs
# anything: every call is appended to $V7_DLOG; `pull` exits $V7_PULL_RC (0);
# `image inspect --format {{range .RepoDigests}}...` prints the image asked for
# unless V7_HOLD=0; `image inspect --format {{.Id}}` prints a fixed id; a `run`
# whose last argument is --version prints $V7_CANNED/<digest> (exit
# $V7_RUN_RC, default 0), or exits 125 when no canned file exists; any other
# `run` exits 0; `ps` prints $V7_PS. v7_timeout_stub DIR writes DIR/timeout,
# which logs and either runs the command or exits $V7_TMO_RC.
#
# bash 3.2 safe.
# =============================================================================

V7_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V7_REPO="${V7IMG_REPO:-$(cd "${V7_DIR}/../../.." && pwd)}"
# shellcheck source=/dev/null
. "${V7_REPO}/tools/tests/lib.sh"
T="$TN_TEST_TMP"
V7_DLOG="$T/docker.log"
V7_CANNED="$T/canned"
V7_PS="$T/ps.txt"
mkdir -p "$T/bin" "$V7_CANNED"
: > "$V7_DLOG"
: > "$V7_PS"
export V7_DLOG V7_CANNED V7_PS

GM="ghcr.io/telcoin-association/tn-mainnet"
GT="ghcr.io/telcoin-association/tn-testnet"
GL="ghcr.io/telcoin-association/telcoin-network"
GD="ghcr.io/telcoin-association/tn-dev"
GAR="us-docker.pkg.dev/telcoin-network/tn-public/adiri"
D64="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

# v7_digest N -- a 64-hex digest made from the number N.
v7_digest() {
    printf '%064d' "$1"
}

# v7_canned DIGEST TEXT -- what `docker run ... <repo>@sha256:DIGEST --version` prints.
v7_canned() {
    printf '%s\n' "$2" > "${V7_CANNED}/$1"
}

# v7_version FEATURES-LINE -- a --version answer shaped as the node prints it.
v7_version() {
    printf 'telcoin-network-cli Version: 1.0.0\nCommit SHA: 0123abcd\nBuild Timestamp: 2026-11-01T00:00:00Z\n%s\nBuild Profile: maxperf' "$1"
}

v7_docker_stub() {
    cat > "$1/docker" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$V7_DLOG"
case "$1" in
    pull) exit "${V7_PULL_RC:-0}" ;;
    ps) cat "$V7_PS"; exit 0 ;;
    image)
        last=""
        for a in "$@"; do last="$a"; done
        case "$*" in
            *RepoDigests*) [ "${V7_HOLD:-1}" = 1 ] && printf '%s\n' "$last"; exit 0 ;;
            *'.Id'*) printf 'sha256:%064d\n' 7; exit 0 ;;
        esac
        exit 0
        ;;
    run)
        prev=""; last=""
        for a in "$@"; do prev="$last"; last="$a"; done
        if [ "$last" = "--version" ]; then
            d="${prev##*@sha256:}"
            if [ -f "$V7_CANNED/$d" ]; then
                cat "$V7_CANNED/$d"
                exit "${V7_RUN_RC:-0}"
            fi
            echo "Unable to find image '$prev' locally" >&2
            exit 125
        fi
        exit 0
        ;;
esac
exit 0
SH
    chmod 0755 "$1/docker"
}

v7_timeout_stub() {
    cat > "$1/timeout" <<'SH'
#!/bin/sh
printf 'timeout %s\n' "$*" >> "$V7_DLOG"
if [ -n "${V7_TMO_RC:-}" ]; then
    exit "$V7_TMO_RC"
fi
shift
exec "$@"
SH
    chmod 0755 "$1/timeout"
}

# v7_log_order WORD... -- rc 0 when the first line of $V7_DLOG matching each
# WORD (an extended regex) appears in the order given, every one present.
v7_log_order() {
    local w n prev=0
    for w in "$@"; do
        n="$(grep -nE -- "$w" "$V7_DLOG" | head -n 1 | cut -d: -f1)"
        [ -n "$n" ] || return 1
        [ "$n" -gt "$prev" ] || return 1
        prev="$n"
    done
    return 0
}

# v7_yes CMD... -- print yes when CMD succeeds, no otherwise.
v7_yes() {
    if "$@"; then echo yes; else echo no; fi
}

# v7_json_tail FILE -- "<n lines> <all JSON 0|1> <event of the line before last> <event of the last> <ok of the last>"
v7_json_tail() {
    local f="$1" n bad last prev ok
    n="$(wc -l < "$f" | tr -d ' ')"
    bad="$(grep -cvE '^\{.*\}$' "$f")" || bad=0
    last="$(tail -n 1 "$f" | sed -n 's/^{"event":"\([a-z_]*\)".*/\1/p')"
    prev="$(tail -n 2 "$f" | head -n 1 | sed -n 's/^{"event":"\([a-z_]*\)".*/\1/p')"
    ok="$(tail -n 1 "$f" | sed -nE 's/.*"ok":(true|false).*/\1/p')"
    if [ "$bad" = 0 ]; then bad=1; else bad=0; fi
    printf '%s %s %s %s %s\n' "$n" "$bad" "${prev:-none}" "${last:-none}" "${ok:-none}"
}

# v7_events FILE -- the event names of FILE's JSON lines, in order, on one line
# (informational: printed as "info" lines, not counted as checks).
v7_events() {
    sed -n 's/^{"event":"\([a-z_]*\)".*/\1/p' "$1" | tr '\n' ' '
}
