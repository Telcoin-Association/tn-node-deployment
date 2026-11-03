#!/usr/bin/env bash
# =============================================================================
# tasks/verify-fup/V1/mutate.sh -- the mutation run: for each line of the table
# below, copy the tree, revert or break one behaviour with sed, check that the
# file changed, and run v1_test.sh on the copy (V1_REPO). A mutation is caught
# when the harness exits 1; the FAIL lines it printed go to records/mutants/.
#
#   bash tasks/verify-fup/V1/mutate.sh            # every mutation, 6 at a time
#   bash tasks/verify-fup/V1/mutate.sh M08 M13    # only those
# Host bash only (each run copies the tree to a temp dir). Prints one line per
# mutation and "N/M caught"; exit 1 when any mutation survives.
# =============================================================================
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
out="$here/records/mutants"
mkdir -p "$out"
work="$(mktemp -d "${TMPDIR:-/tmp}/v1_mut.XXXXXX")" || exit 1
trap 'rm -rf "${work:?}"' EXIT

# ID~FILE~SED SCRIPT~WHAT (~ separates: the sed scripts hold |)
table() {
cat <<'TBL'
M01~lib/common.sh~s/^    \[\[ "\$TN_MAINNET_ENABLED" == "1" \]\]$/    true/~tn_mainnet_enabled always rc 0
M02~lib/common.sh~/^                if tn_mainnet_enabled; then$/,/^                fi$/d~select_network option 2 never takes mainnet (LIB-A 2 reverted)
M03~setup-node.sh~/^            tn_mainnet_enabled \\$/,/Mainnet is not enabled in this script release/d~json_set_network refusal removed (LIB-A 3 reverted)
M04~ui/telcoin-ui-helper.sh~/if \[\[ "\$net_rule" == mainnet \]\] && ! _lib_call tn_mainnet_enabled/,/^    fi$/d~helper cmd_setup gate removed (LIB-A 4 reverted)
M05~ui/telcoin-ui-helper.sh~s/&& ! _lib_call tn_mainnet_enabled >\/dev\/null 2>&1; then/\&\& { _lib_call tn_mainnet_enabled >\/dev\/null 2>\&1; [[ $? -eq 1 ]]; }; then/~helper takes rc 127 (no function) as enabled
M06~setup-node.sh~s/ tn_release_tag_grammar tn_mainnet_enabled >\/dev\/null/ tn_release_tag_grammar >\/dev\/null/~setup-node gate no longer needs tn_mainnet_enabled
M07~update-node.sh~/^    update_floor_check "\$tag" "\$net" || return 1$/d~binary_prepare floor call removed (4 sites)
M08~update-node.sh~/^    docker_floor_check "\$arg" "\$net" || return 1$/d~update-node Docker floor calls removed (2 sites)
M09~edit-config.sh~/^    edit_floor_check "\$value" "\$net" || return 1$/d~set_docker_image floor call removed
M10~edit-config.sh~s/^    if ! edit_floor_check "\$input" "\$net"; then$/    if false; then/~edit_docker_image floor call removed
M11~update-node.sh~s/^        1) update_fail "\${msg} Nothing was changed."; return 1 ;;$/        1) update_wait_say warn "$msg" ;;/~update_floor_check rc 1 only warns
M12~update-node.sh~s/^        ref="\$(tn_docker_recorded_tag "\$ref" 2>\/dev\/null)" || return 0$/        return 0/~docker_floor_check ignores the recorded release of a digest
M13~lib/common.sh~/^        if \[\[ -z "\$tag" && "\$net" == "mainnet" \]\]; then$/,/^        fi$/d~mainnet digest rule removed (LIB-A 6 reverted)
M14~lib/common.sh~s/^        tn_release_tag_ok "\$net" "\$tag" || tag=""$/        :/~digest arm takes any recorded tag
M15~lib/common.sh~s/^    read -r margin msrc settle ssrc <<<"\$(_tn_epoch_timing "\$dur")"$/    msrc=default; ssrc=default/~derivation removed (LIB-B 1 reverted)
M16~lib/common.sh~/^    if (( margin > 900 )); then margin=900; fi$/d~margin upper clamp removed
M17~lib/common.sh~/^    if \[\[ "\${TN_EPOCH_MARGIN:-}" =/,/^    fi$/d~explicit TN_EPOCH_MARGIN ignored by the derivation
M18~lib/common.sh~/^    if (( cap < need )); then$/,/^    fi$/d~cap raise removed (LIB-B 2 reverted)
M19~lib/common.sh~s/^    need=\$(( margin + settle + 2 \* poll ))$/    need=$(( margin + settle ))/~cap raise without the two polls
M20~lib/common.sh~s/^        mainnet) rpc="\$MAINNET_RPC_URL" ;;$/        mainnet) rpc="$TESTNET_RPC_URL" ;;/~check_internet probes testnet on mainnet
M21~lib/common.sh~/Cannot check internet connectivity: NETWORK must be/{n;s/exit 1/rpc="$TESTNET_RPC_URL"/;}~check_internet fails open on an unknown NETWORK
M22~setup-node.sh~/^    # After the network is chosen: check_internet probes/{N;d;};s/^    # Core node ports + the ports/    check_internet\n&/~setup-node checks connectivity before the network is chosen
M23~check-node.sh~s/^        NETWORK_RPC="\$(network_rpc_url "\$NODE_NETWORK")"$/        NETWORK_RPC="$(network_rpc_url "$NODE_NETWORK")"; NETWORK_RPC="${NETWORK_RPC:-$TESTNET_RPC_URL}"/~check-node falls back to the testnet RPC again
M24~check-node.sh~s/^        NETWORK_RPC_LABEL="\${NETWORK_RPC} (\${NODE_NETWORK} public RPC)"$/        NETWORK_RPC_LABEL="${NETWORK_RPC}"/~check-node label without its network
M25~setup-node.sh~/^        mainnet)$/,/^            ;;$/d~_setup_image_example mainnet arm removed (LIB-B 5 reverted)
M26~lib/common.sh~s/^            _tn_wait_blind "\$fn" "\$margin" "\$settle" "\$cap" "\$poll" "\$out"$/            _tn_wait_blind "$fn" "$margin" "$settle" 1800 "$poll" "$out"/~blind wait ignores the cap
M27~lib/common.sh~s/^        if \[\[ -n "\$must_wait" \]\]; then$/        if true; then/~keytool pin broken: a voting node with unreadable epoch info waits blind
M28~lib/common.sh~s/^readonly TN_MAINNET_ENABLED=0$/readonly TN_MAINNET_ENABLED=1/~shipped with mainnet enabled
TBL
}

one() {  # one ID FILE SED WHAT
    local id="$1" f="$2" sx="$3" what="$4" d="$work/$1" rc fails
    mkdir -p "$d/tree/ui"
    cp -R "$repo/lib" "$d/tree/lib"
    cp "$repo"/*.sh "$d/tree/"
    cp "$repo/ui/telcoin-ui-helper.sh" "$repo/ui/server.py" "$d/tree/ui/"
    sed -e "$sx" "$d/tree/$f" > "$d/new" && cat "$d/new" > "$d/tree/$f"
    if cmp -s "$repo/$f" "$d/tree/$f"; then
        printf '%s NOT-APPLIED  %s (%s)\n' "$id" "$what" "$f" > "$d/result"
        return 0
    fi
    diff "$repo/$f" "$d/tree/$f" > "$out/$id.diff"
    V1_REPO="$d/tree" bash "$here/v1_test.sh" > "$d/log" 2>&1
    rc=$?
    grep '^FAIL' "$d/log" > "$out/$id.fails"
    fails="$(wc -l < "$out/$id.fails" | tr -d ' ')"
    if [[ $rc -ne 0 ]]; then
        printf '%s caught       %-3s FAIL  %s (%s)\n' "$id" "$fails" "$what" "$f" > "$d/result"
    else
        printf '%s SURVIVED     %s (%s)\n' "$id" "$what" "$f" > "$d/result"
    fi
}

want=" $* "
n=0
while IFS='~' read -r id f sx what; do
    [[ -n "$id" ]] || continue
    [[ "$want" == "  " || "$want" == *" $id "* ]] || continue
    one "$id" "$f" "$sx" "$what" &
    n=$((n + 1))
    if (( n % 6 == 0 )); then wait; fi
done < <(table)
wait
total=0
caught=0
for r in "$work"/M*/result; do
    [[ -f "$r" ]] || continue
    cat "$r"
    total=$((total + 1))
    grep -q ' caught ' "$r" && caught=$((caught + 1))
done
printf '%s/%s caught\n' "$caught" "$total"
[[ $caught -eq $total ]]
