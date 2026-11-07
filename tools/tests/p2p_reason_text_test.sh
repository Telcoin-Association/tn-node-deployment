#!/usr/bin/env bash
# =============================================================================
# tools/tests/p2p_reason_text_test.sh -- firewall-setup.sh and check-node.sh
# say rpc-method-missing, a failed sync and a failed run of the sync unit in the
# same words
#
#   bash tools/tests/p2p_reason_text_test.sh
#   docker run --rm -v "$PWD:/w" -w /w bash:3.2 bash tools/tests/p2p_reason_text_test.sh
#   docker run --rm -v "$PWD:/w" -w /w ubuntu:24.04 bash tools/tests/p2p_reason_text_test.sh
#
# firewall-setup.sh words a tn-p2p-allow-sync reason with fw_allow_reason_text
# (the `on` refusal and the `--p2p-committee status` warning); check-node.sh
# writes its own rpc-method-missing warning. The test loads fw_allow_reason_text
# alone (it calls printf only), as p2p_committee_mode_test.sh loads
# fw_baseline_refresh, and checks byte for byte that check-node.sh's warning
# holds the same text, right after its "(rpc-method-missing): " prefix, so the
# two never drift. The firewall-setup.sh text itself is pinned too, since
# README.md, OPERATOR.md and the release note quote it. The status screen's
# failed-sync and failed-unit warnings carry check-node.sh's sentences byte for
# byte, and fw_allow_unit_why (fw_allow_kv and printf only) words systemd's
# verdict as check-node.sh does, with the same success set.
#
# Maintainer tooling (not updater-tracked, no sidecar). bash 3.2 safe.
# =============================================================================
set -u

# shellcheck source=tools/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
FW="${TN_TEST_REPO}/firewall-setup.sh"
CN="${TN_TEST_REPO}/check-node.sh"

src="$(sed -n '/^fw_allow_reason_text() {$/,/^}$/p' "$FW")"
rc=0
[[ -n "$src" ]] || rc=1
check_rc "firewall-setup.sh defines fw_allow_reason_text" 0 "$rc"
eval "$src"

want='this node release lacks tn_admissionSnapshot, or tn is not in its --http.api; update the node or add tn to --http.api'
text="$(fw_allow_reason_text rpc-method-missing 2>&1)"
check "firewall-setup.sh: fw_allow_reason_text rpc-method-missing" "$want" "$text"

# The same bytes in check-node.sh, once, on its rpc-method-missing warning.
n="$(grep -cF -- "$text" "$CN")" || n=0
check "check-node.sh holds the text once" "1" "$n"
n="$(grep -cF -- "print_warn \"P2P committee allowlist (rpc-method-missing): ${text}. " "$CN")" || n=0
check "check-node.sh: the rpc-method-missing warning carries it" "1" "$n"

# The words it replaced are gone from both scripts.
check_lacks "firewall-setup.sh: the old text is gone" "lacks tn_admissionSnapshot; update the node first" "$(cat "$FW")"
check_lacks "check-node.sh: the old text is gone" "has no tn_admissionSnapshot RPC method" "$(cat "$CN")"

# --- a failed sync and a failed run of the sync unit ---------------------------
# The sentences, as source text, once in each script's warning.
for frag in \
    'P2P committee allowlist: its last sync failed${why:+ (${why})}, so it keeps its last-good set until a sync succeeds' \
    'failed (${why}), so the allowlist keeps its last-good set until a sync succeeds' \
    ':*|success:*|exit-code:0|exit-code:3|exit-code:4)' \
    'signal|core-dump)'; do
    for f in "$FW" "$CN"; do
        n="$(grep -cF -- "$frag" "$f")" || n=0
        check "${f##*/} holds once: ${frag}" "1" "$n"
    done
done
src="$(sed -n '/^fw_allow_kv() {$/,/^}$/p;/^fw_allow_unit_why() {$/,/^}$/p' "$FW")"
rc=0
[[ "$src" == *"fw_allow_unit_why() {"* ]] || rc=1
check_rc "firewall-setup.sh defines fw_allow_unit_why" 0 "$rc"
eval "$src"
# check-node.sh's words for each verdict, which fw_allow_unit_why prints.
for row in \
    'Result=exit-code ExecMainStatus=2|it exited with status|it exited with status 2' \
    'Result=signal ExecMainStatus=9|it was killed by signal|it was killed by signal 9' \
    'Result=core-dump ExecMainStatus=6|it was killed by signal|it was killed by signal 6' \
    'Result=timeout ExecMainStatus=0|systemd result|systemd result timeout'; do
    show="${row%%|*}"; rest="${row#*|}"; word="${rest%%|*}"; want="${rest#*|}"
    show="${show% *}"$'\n'"${show#* }"
    check "fw_allow_unit_why: ${want}" "$want" "$(fw_allow_unit_why "$show")"
    n="$(grep -cF -- "why=\"${word} \${" "$CN")" || n=0
    check "check-node.sh says it the same: ${word}" "1" "$n"
done
for show in 'Result=exit-code ExecMainStatus=3' 'Result=exit-code ExecMainStatus=4' 'Result=success ExecMainStatus=0' 'ExecMainStatus=1' ''; do
    rc=0
    out="$(fw_allow_unit_why "${show% *}"$'\n'"${show#* }")" || rc=$?
    check "fw_allow_unit_why: no failure for '${show}'" "1:" "${rc}:${out}"
done

finish
