#!/usr/bin/env bash
# =============================================================================
# tools/tests/lib_skew_test.sh -- the scripts against an older lib/common.sh:
# setup-node, update-node, edit-config, prepare-stake, migrate-node-naming and
# remove-node refuse up front with one message (and a --json error plus done
# event) when COMMON_VERSION is below 2.0.0, when the library has no
# tn_require_fns, or when one of the helpers the script names to tn_require_fns
# is missing, before they stop a node or pull an image. check-node warns once
# about the hardening checks the older library turns off.
#
#   bash tools/tests/lib_skew_test.sh
#   docker run --rm -v "$PWD:/w" -w /w bash:3.2 bash tools/tests/lib_skew_test.sh
#
# First tn_require_fns itself, then each script's own list (read from the
# script): a copy of the current library without one of its helpers makes that
# script refuse. Then the library at 037c810 (COMMON_VERSION 1.6.1, the release
# before the hardening round), read with git; without git or that commit (a
# container, a shallow clone) that part prints SKIP. bash 3.2 safe.
# =============================================================================

set -u

# shellcheck source=tools/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

T="$TN_TEST_TMP"
REPO="$TN_TEST_REPO"
OLD=037c810
SCRIPTS=(setup-node update-node edit-config prepare-stake migrate-node-naming remove-node)

# required_of SCRIPT -- the helper names SCRIPT passes to tn_require_fns.
required_of() {
    awk '/\|\| ! tn_require_fns/ { f = 1 } f { print } f && />\/dev\/null; then/ { exit }' "$REPO/${1}.sh" \
        | tr -d '\\\n' | sed 's/.*tn_require_fns//; s/>\/dev\/null.*//'
}
# refuses DIR SCRIPT -- "yes" when DIR/SCRIPT.sh --help exits 1 with the one message.
refuses() {
    local rc=0
    "$BASH" "$1/${2}.sh" --help > /dev/null 2> "$T/err" < /dev/null || rc=$?
    if [[ $rc -eq 1 ]] && grep -q "is older than this ${2}.sh: run update-scripts.sh" "$T/err"; then
        echo yes
    else
        echo "no (rc ${rc})"
    fi
}

# ---- tn_require_fns ------------------------------------------------------------------
# In a child shell, so this one keeps none of the library's functions (the
# check-node part below must see only the old library's).
# shellcheck disable=SC2016
req_run() { "$BASH" -c 'source "$1/lib/common.sh" >/dev/null 2>&1; set +e; shift; o="$(tn_require_fns "$@")"; echo "$? $o"' _ "$REPO" "$@"; }
check "tn_require_fns: all defined" "0 " "$(req_run version_gte tn_require_fns)"
check "tn_require_fns: names the missing ones" "1 tn_no_such_a tn_no_such_b" \
    "$(req_run version_gte tn_no_such_a tn_no_such_b)"

# ---- each script's own list: without one of its helpers, the script refuses ------------
mkdir -p "$T/cur"
cp -R "$REPO/lib" "$T/cur/lib"
for s in "${SCRIPTS[@]}"; do
    cp "$REPO/${s}.sh" "$T/cur/${s}.sh"
    req="$(required_of "$s")"
    check "${s}: names its helpers to tn_require_fns" yes "$([[ -n "${req// /}" ]] && echo yes || echo no)"
    for fn in $req; do
        sed "s/^${fn}() {/${fn}_absent_here() {/" "$REPO/lib/common.sh" > "$T/cur/lib/common.sh"
        if ! grep -q "^${fn}_absent_here() {" "$T/cur/lib/common.sh"; then
            check "${s}: ${fn} defined in lib/common.sh" "yes" "no"
            continue
        fi
        check "${s} without ${fn}: refused" yes "$(refuses "$T/cur" "$s")"
    done
done
# A library below 2.0.0, or one without tn_require_fns, is refused by every script.
sed 's/^readonly COMMON_VERSION=.*/readonly COMMON_VERSION="1.9.9"/' "$REPO/lib/common.sh" > "$T/cur/lib/common.sh"
for s in "${SCRIPTS[@]}"; do
    check "${s} with COMMON_VERSION 1.9.9: refused" yes "$(refuses "$T/cur" "$s")"
done
sed 's/^tn_require_fns() {/tn_require_fns_absent_here() {/' "$REPO/lib/common.sh" > "$T/cur/lib/common.sh"
for s in "${SCRIPTS[@]}"; do
    check "${s} without tn_require_fns: refused" yes "$(refuses "$T/cur" "$s")"
done
cp "$REPO/lib/common.sh" "$T/cur/lib/common.sh"
for s in "${SCRIPTS[@]}"; do
    check "${s} with its own library: not refused" "" "$("$BASH" "$T/cur/${s}.sh" --help 2>&1 < /dev/null | grep 'is older than this')"
done

if ! command -v git >/dev/null 2>&1 \
    || ! git -C "$REPO" cat-file -e "${OLD}^{commit}" 2>/dev/null; then
    skip "scripts against the ${OLD} library" "git or commit ${OLD} not available"
    finish
fi
mkdir -p "$T/old"
git -C "$REPO" archive "$OLD" lib | tar -x -C "$T/old"
for s in "${SCRIPTS[@]}" check-node; do
    cp "$REPO/${s}.sh" "$T/old/${s}.sh"
done
check "old library is 1.6.1" "1.6.1" "$(sed -n 's/^readonly COMMON_VERSION="\(.*\)"$/\1/p' "$T/old/lib/common.sh")"

for s in "${SCRIPTS[@]}"; do
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

# The node-changing paths refuse before anything runs: no systemctl, docker or curl.
mkdir -p "$T/bin" "$T/rec"
for t in systemctl docker curl; do
    printf '#!/bin/sh\necho "%s $*" >> "%s/rec/calls"\n' "$t" "$T" > "$T/bin/$t"
    chmod 0755 "$T/bin/$t"
done
skew_run() {
    local rc=0
    : > "$T/rec/calls"
    PATH="$T/bin:$PATH" "$BASH" "$@" > "$T/out" 2> "$T/err" < /dev/null || rc=$?
    printf '%s %s\n' "$rc" "$(wc -l < "$T/rec/calls" | tr -d ' ')"
}
check "update-node --json --apply: refused, nothing run" "1 0" "$(skew_run "$T/old/update-node.sh" --json --apply)"
check "edit-config --json --set docker_image: refused, nothing run" "1 0" \
    "$(skew_run "$T/old/edit-config.sh" --json --set docker_image=example.org/other/image:latest)"
check "edit-config --json --set verbosity: refused, nothing run" "1 0" \
    "$(skew_run "$T/old/edit-config.sh" --json --set verbosity=-vv)"

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
