#!/usr/bin/env bash
# =============================================================================
# tools/tests/p2p_reason_text_test.sh -- firewall-setup.sh and check-node.sh
# say rpc-method-missing in the same words
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
# README.md, OPERATOR.md and the release note quote it.
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

finish
