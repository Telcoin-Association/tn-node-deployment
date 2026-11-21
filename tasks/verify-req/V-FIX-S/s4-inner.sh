#!/usr/bin/env bash
# =============================================================================
# s4-inner.sh -- V-FIX-S S4: remove-node.sh after an install that created
# /etc/telcoin/chain-configs (root in a disposable ubuntu:26.04 container,
# through vrun.sh). The install is s2-case.sh infra + write (clone at the tag
# from GitHub, the pinned files installed, the copies in the data dir). Then
# a copy of remove-node.sh without its last line is sourced (the
# tools/tests/remove_test.sh pattern) and remove_keys (typed DELETE, the same
# shred_key_files + _rm_config_dir pair json_remove's keys scope runs) and
# remove_leftovers run against the real paths.
# =============================================================================
set -u
# shellcheck source=tasks/verify-req/V-FIX-S/vcommon.sh
. /h/vcommon.sh
v_setup

install_node() {
    run_case "$1-infra" infra plain '\n\ny\n'
    run_case "$1-write" write plain ''
    say "[$1] /etc/telcoin/chain-configs: $(find /etc/telcoin/chain-configs 2>/dev/null | tr '\n' ' ')"
}

# rm_call LABEL FUNCTION STDIN-TEXT -- the function of a sourced remove-node.sh
# copy, in a fresh process.
rm_call() {
    local rc=0
    printf '%b' "$3" > "${OUT}/$1.in"
    env -i PATH="$BASEPATH" HOME=/root TERM=dumb TN_ASSUME_YES=true bash -c '
        mkdir -p /tmp/rm-copy
        grep -v "^main \"\\\$@\"\$" /s/remove-node.sh > /tmp/rm-copy/remove-node.sh
        ln -sfn /s/lib /tmp/rm-copy/lib
        source /tmp/rm-copy/remove-node.sh
        set +e
        "$1"
        echo "RM_RC=$?"' _ "$2" < "${OUT}/$1.in" > "${OUT}/$1.log" 2>&1 || rc=$?
    say "[$1] $2 process rc=${rc} $(grep -m1 '^RM_RC=' "${OUT}/$1.log")"
    grep -E 'Removed|removed|Keys|kept|ERROR|leftover' "${OUT}/$1.log" | sed "s/^/[$1]   | /" >> "$DEC"
}

say "== S4a: install, then remove_keys (DELETE) =="
install_node s4a
rm_call s4a-remove-keys remove_keys 'DELETE\n'
say "[s4a] /etc/telcoin after: $(find /etc/telcoin 2>/dev/null | wc -l) entries; chain-configs: $([[ -e /etc/telcoin/chain-configs ]] && echo PRESENT || echo gone)"

say "== S4b: install again (checkout kept), then remove_leftovers (confirm yes) =="
install_node s4b
rm_call s4b-leftovers remove_leftovers ''
say "[s4b] /etc/telcoin: $([[ -e /etc/telcoin ]] && echo PRESENT || echo gone); /opt/telcoin-source: $([[ -e /opt/telcoin-source ]] && echo PRESENT || echo gone)"

say "== S4c: legacy config dir /etc/telcoin/validator beside /etc/telcoin/chain-configs, remove_keys (DELETE) =="
install_node s4c
mkdir -p /etc/telcoin/validator
mv /etc/telcoin/.node-meta /etc/telcoin/validator/.node-meta
rm_call s4c-remove-keys remove_keys 'DELETE\n'
say "[s4c] /etc/telcoin after: $(find /etc/telcoin 2>/dev/null | tr '\n' ' ')"
rm_call s4c-leftovers-present rm_leftovers_present ''

chown -R 1000:1000 "$OUT" 2>/dev/null || true
exit 0
