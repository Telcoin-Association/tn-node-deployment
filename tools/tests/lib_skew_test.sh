#!/usr/bin/env bash
# =============================================================================
# tools/tests/lib_skew_test.sh -- the scripts against an older lib/common.sh:
# setup-node, update-node, edit-config and prepare-stake refuse up front with one
# message (and a --json error plus done event), before they stop a node or pull
# an image, and check-node warns once about the hardening checks the older
# library turns off.
#
#   bash tools/tests/lib_skew_test.sh
#   docker run --rm -v "$PWD:/w" -w /w bash:3.2 bash tools/tests/lib_skew_test.sh
#
# First, each required helper on its own: a copy of the current library without
# it makes every one of the four scripts refuse. Then the library at 037c810
# (COMMON_VERSION 1.6.1, the release before the hardening round), read with
# git; without git or that commit (a container, a shallow clone) that part
# prints SKIP. bash 3.2 safe.
# =============================================================================

set -u

# shellcheck source=tools/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

T="$TN_TEST_TMP"
REPO="$TN_TEST_REPO"
OLD=037c810
SCRIPTS=(setup-node update-node edit-config prepare-stake)
REQUIRED=(tn_migrate_ownership tn_passphrase_ok tn_update_lock_path tn_write_root_file
          tn_detect_network tn_write_node_unit tn_remove_inflight_tmp tn_committee_down_guard
          tn_docker_image_allowed tn_rerender_node_launch
          tn_has_embedded_passphrase _tn_unit_pass_read _tn_unit_runs_node_inline
          tn_migrate_credential tn_migrate_embedded_passphrase tn_creds_supported
          tn_credential_key tn_pcrs_ok tn_store_credential _tn_cred_switch
          tn_chain_configs_check)
# The credential helpers migrate-node-naming.sh also requires (its own message).
MIGRATE_REQUIRED=(tn_remove_inflight_tmp tn_has_embedded_passphrase _tn_unit_pass_read
          tn_store_credential tn_creds_supported tn_credential_key _tn_cred_old_copies)

# ---- each required helper: without it, every script refuses ---------------------------
mkdir -p "$T/cur"
cp -R "$REPO/lib" "$T/cur/lib"
for s in "${SCRIPTS[@]}"; do
    cp "$REPO/${s}.sh" "$T/cur/${s}.sh"
done
for fn in "${REQUIRED[@]}"; do
    sed "s/^${fn}() {/${fn}_absent_here() {/" "$REPO/lib/common.sh" > "$T/cur/lib/common.sh"
    if ! grep -q "^${fn}_absent_here() {" "$T/cur/lib/common.sh"; then
        check "${fn}: defined in lib/common.sh" "yes" "no"
        continue
    fi
    got=""
    for s in "${SCRIPTS[@]}"; do
        rc=0
        "$BASH" "$T/cur/${s}.sh" --help > /dev/null 2> "$T/err" < /dev/null || rc=$?
        if [[ $rc -eq 1 ]] && grep -q "is older than this ${s}.sh: run update-scripts.sh" "$T/err"; then
            got="${got} ${s}"
        fi
    done
    check "without ${fn}: every script refuses" " ${SCRIPTS[*]}" "$got"
done
cp "$REPO/migrate-node-naming.sh" "$T/cur/migrate-node-naming.sh"
for fn in "${MIGRATE_REQUIRED[@]}"; do
    sed "s/^${fn}() {/${fn}_absent_here() {/" "$REPO/lib/common.sh" > "$T/cur/lib/common.sh"
    rc=0
    "$BASH" "$T/cur/migrate-node-naming.sh" --help > /dev/null 2> "$T/err" < /dev/null || rc=$?
    check "without ${fn}: migrate-node-naming refuses" "1 yes" \
        "${rc} $(grep -q "has no ${fn}\. Run update-scripts.sh" "$T/err" && echo yes)"
done
cp "$REPO/lib/common.sh" "$T/cur/lib/common.sh"

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
