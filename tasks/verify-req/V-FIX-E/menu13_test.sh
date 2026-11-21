#!/usr/bin/env bash
# =============================================================================
# tasks/verify-req/V-FIX-E/menu13_test.sh -- independent harness for
# edit-config.sh menu 13 (refresh_chain_configs), verifier V-FIX-E.
#
#   bash tasks/verify-req/V-FIX-E/menu13_test.sh [main|cmp|oldscript]
#   V_TREE=<dir holding edit-config.sh and lib/>   (default: this worktree)
#
# edit-config.sh is sourced without its main call (as edit_config_resync_test.sh
# does). Real git runs against a local bare origin: a tag v0.16.0-adiri whose
# chain-configs/testnet holds the pinned fixture files and a main whose
# committee.yaml diverged. A git wrapper on PATH logs every argv, whether fd 9
# is open and GIT_ALLOW_PROTOCOL, then drops GIT_ALLOW_PROTOCOL so the
# library's https-only fetch reaches the local path. systemctl, the host
# baseline refresh, the committee guard and confirm are stubs that log.
# As root (ubuntu:26.04) the real root writes and tn_as_service_user (nobody)
# run; TMPDIR must then be a root-owned 0755 directory. As another user the
# root writes and tn_as_service_user are stand-ins.
#
# Suites: main (E1-E5, E8), cmp (E6 transcript of the apply path, for a diff
# against the script at 01664cc; root only), oldscript (E7: edit-config.sh of
# 01664cc with the current library; root only). Each case gets its own
# TN_ROOT_PREFIX that does not exist yet; nothing is deleted here.
# bash 3.2 syntax; git is required (skips without it).
# =============================================================================

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WT="$(cd "${HERE}/../../.." && pwd)"
# shellcheck source=tools/tests/lib.sh
. "${WT}/tools/tests/lib.sh"

V_TREE="${V_TREE:-$WT}"
SUITE="${1:-main}"
T="$TN_TEST_TMP"
FIXT="${WT}/tools/tests/genesis.d/testnet"
IS_ROOT=no
if [[ "$(id -u)" == 0 ]]; then
    IS_ROOT=yes
    chmod 0755 "$T"
fi
REAL_GIT="$(command -v git 2>/dev/null || true)"
REAL_SLEEP="$(type -P sleep)"
if [[ -z "$REAL_GIT" ]]; then
    skip "menu 13 suites" "git absent"
    finish
fi
if [[ "$SUITE" != main && "$IS_ROOT" != yes ]]; then
    skip "suite ${SUITE}" "needs root: the 01664cc script reads /opt/telcoin-source"
    finish
fi

# --- stubs on PATH ---------------------------------------------------------------
mkdir -p "$T/bin" "$T/h"
cat > "$T/bin/git" <<SHIM
#!/bin/sh
fd9=closed
if { true >&9; } 2>/dev/null; then fd9=open; fi
printf '%s|fd9=%s|gap=%s\n' "\$*" "\$fd9" "\${GIT_ALLOW_PROTOCOL:-}" >> "\${V_LOG:-/dev/null}/git.log"
unset GIT_ALLOW_PROTOCOL
exec "${REAL_GIT}" "\$@"
SHIM
cat > "$T/bin/systemctl" <<'SHIM'
#!/bin/sh
printf '%s\n' "$*" >> "${V_LOG:-/dev/null}/systemctl.log"
case "${1:-}" in
    is-active) exit "${SYSTEMCTL_ACTIVE_RC:-0}" ;;
    show) echo 0 ;;
esac
exit 0
SHIM
chmod 0755 "$T/bin/git" "$T/bin/systemctl"
PATH="$T/bin:$PATH"
export PATH

grep -v '^main "\$@"$' "$V_TREE/edit-config.sh" > "$T/h/edit-config.sh"
ln -s "$V_TREE/lib" "$T/h/lib"
cat > "$T/h/firewall-setup.sh" <<'FWS'
#!/bin/sh
printf 'fw %s\n' "$*" >> "${V_LOG:-/dev/null}/fw.log"
exit 0
FWS
chmod 0755 "$T/h/firewall-setup.sh"

TN_UPDATE_LOCK_FILE="$T/update.lock"
export TN_UPDATE_LOCK_FILE
if [[ "$IS_ROOT" == yes ]]; then
    SERVICE_USER=nobody
    SERVICE_GROUP="$(id -gn nobody)"
else
    SERVICE_USER="$(id -un)"
    SERVICE_GROUP="$(id -gn)"
fi
TN_ROOT_PREFIX="$T/c0"
mkdir -p "$TN_ROOT_PREFIX/etc/telcoin"
tn_test_pre_common
# shellcheck source=/dev/null
source "$T/h/edit-config.sh"
tn_test_post_common

# --- function stubs and wrappers -------------------------------------------------
tn_migrate_ownership() { return 0; }
edit_legacy_reason() { return 1; }
sleep() { :; }
tn_local_rpc_url() { echo "http://127.0.0.1:1"; }
GUARD_RC=0
tn_committee_down_guard() { return "$GUARD_RC"; }
tn_host_baseline_refresh() { echo baseline >> "$V_LOG/baseline.log"; return 0; }
NO_EPOCH_WAIT=true
TARGET_SERVICE=telcoin
ANSWERS=""
confirm() {
    local a
    printf '%s\n' "$1" >> "$V_LOG/confirm.log"
    a="${ANSWERS%% *}"
    if [[ "$ANSWERS" == *" "* ]]; then ANSWERS="${ANSWERS#* }"; else ANSWERS=""; fi
    [[ "$a" == y ]]
}
lock_free() {
    if flock -n "$TN_UPDATE_LOCK_FILE" true 2>/dev/null; then echo free; else echo held; fi
}
eval "v_orig_acquire() $(declare -f tn_acquire_update_lock | sed '1d')"
tn_acquire_update_lock() { echo acquire >> "$V_LOG/lock.log"; v_orig_acquire "$@"; }
if declare -F tn_chain_configs_from_tag >/dev/null 2>&1; then
    eval "v_orig_from_tag() $(declare -f tn_chain_configs_from_tag | sed '1d')"
    tn_chain_configs_from_tag() {
        local hrc=0
        echo "helper held=${EDIT_LOCK_HELD} probe=$(lock_free)" >> "$V_LOG/helper.log"
        v_orig_from_tag "$@" || hrc=$?
        echo "helper rc=${hrc}" >> "$V_LOG/helper.log"
        return "$hrc"
    }
fi
if [[ "$IS_ROOT" != yes ]]; then
    tn_as_service_user() { "$@" 9>&-; }
    _tn_root_layout_dir() { mkdir -p -- "$1"; echo "layout $1" >> "$V_LOG/rootw.log"; }
    tn_write_root_file() { cat > "$1" && chmod "$2" "$1"; }
fi

# --- helpers ---------------------------------------------------------------------
has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }
lines() { if [[ -f "$1" ]]; then grep -c -- "$2" "$1" 2>/dev/null || true; else echo 0; fi; }
logf() { cat "$V_LOG/$1" 2>/dev/null; }
G() { "$REAL_GIT" -c user.email=t@example.invalid -c user.name=t -c advice.detachedHead=false -c init.defaultBranch=main "$@"; }
yesno() { if "$@"; then echo yes; else echo no; fi; }
printf '\n%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 > "$T/enters"

# The origin: tag v0.16.0-adiri = the pinned files; main then diverges in
# committee.yaml. chain-configs/mainnet (chain 731) on both.
O="$T/origin.git"
WK="$T/work"
G init -q --bare "$O"
G init -q "$WK"
mkdir -p "$WK/chain-configs/testnet" "$WK/chain-configs/mainnet"
cp "$FIXT/genesis.yaml" "$FIXT/committee.yaml" "$FIXT/parameters.yaml" "$WK/chain-configs/testnet/"
printf 'genesis:\n  chainId: 731\n' > "$WK/chain-configs/mainnet/genesis.yaml"
printf 'committee: mainnet\n' > "$WK/chain-configs/mainnet/committee.yaml"
printf 'parameters: mainnet\n' > "$WK/chain-configs/mainnet/parameters.yaml"
printf 'readme\n' > "$WK/README"
G -C "$WK" add -A
G -C "$WK" commit -qm pinned
G -C "$WK" tag -a v0.16.0-adiri -m t16
TAGC="$(G -C "$WK" rev-parse 'v0.16.0-adiri^{commit}')"
printf 'diverged: true\n' >> "$WK/chain-configs/testnet/committee.yaml"
G -C "$WK" commit -qam diverged
G -C "$WK" push -q "$O" HEAD:refs/heads/main refs/tags/v0.16.0-adiri 2>/dev/null
G --git-dir="$O" symbolic-ref HEAD refs/heads/main
DIVERGED="$T/committee.diverged"
cp "$WK/chain-configs/testnet/committee.yaml" "$DIVERGED"
# The same origin without the divergence (cmp suite: the 01664cc pull then gets
# the pinned files too).
O2="$T/origin-flat.git"
G init -q --bare "$O2"
G -C "$WK" push -q "$O2" "${TAGC}:refs/heads/main" refs/tags/v0.16.0-adiri 2>/dev/null
G --git-dir="$O2" symbolic-ref HEAD refs/heads/main

NC=0
# new_case NETWORK [DD-NAME] -- a fresh TN_ROOT_PREFIX (P) with .node-meta, an
# empty data dir DD, the paths SRC and PIN, and empty logs (V_LOG).
new_case() {
    NC=$((NC + 1))
    P="$T/c${NC}"
    TN_ROOT_PREFIX="$P"
    mkdir -p "$P/etc/telcoin" "$P/opt" "$P/var/lib" "$P/log"
    V_LOG="$P/log"
    export V_LOG
    DD="$P/var/lib/${2:-telcoin}"
    mkdir -p "$DD/genesis"
    SRC="$P/opt/telcoin-source"
    PIN="$P/etc/telcoin/chain-configs/$1"
    META="$P/etc/telcoin/.node-meta"
    printf 'NETWORK=%s\nDATA_DIR=%s\nP2P_COMMITTEE=on\n' "$1" "$DD" > "$META"
    edit_unlock
    edit_reset_backups
    EDIT_LAST_ERROR=""
    ANSWERS=""
    GUARD_RC=0
}
# fill_dd stale|pinned -- the three files in DD.
fill_dd() {
    cp "$FIXT/genesis.yaml" "$DD/genesis/genesis.yaml"
    if [[ "$1" == pinned ]]; then
        cp "$FIXT/committee.yaml" "$DD/genesis/committee.yaml"
        cp "$FIXT/parameters.yaml" "$DD/parameters.yaml"
    else
        cp "$DIVERGED" "$DD/genesis/committee.yaml"
        printf 'stale: true\n' > "$DD/parameters.yaml"
    fi
}
own_dd() {
    if [[ "$IS_ROOT" == yes ]]; then
        chown -R "${SERVICE_USER}:${SERVICE_GROUP}" "$DD"
        chmod 0700 "$DD"
    fi
}
# mk_src main|tag|symlink|offline [ORIGIN] -- the checkout at SRC.
mk_src() {
    local origin="${2:-$O}"
    case "$1" in
        main)
            G clone -q "$origin" "$SRC" 2>/dev/null
            printf 'local edit\n' >> "$SRC/README"
            printf 'x\n' > "$SRC/untracked.txt"
            ;;
        tag) G clone -q --branch v0.16.0-adiri "$origin" "$SRC" 2>/dev/null ;;
        symlink)
            G clone -q "$origin" "$P/opt/real-source" 2>/dev/null
            ln -s real-source "$SRC"
            ;;
        offline)
            G clone -q --no-tags "$origin" "$SRC" 2>/dev/null
            G -C "$SRC" remote set-url origin "$T/nowhere.git"
            ;;
    esac
    if [[ "${V_OLD_SRC:-}" == 1 ]]; then
        ln -sfn "$SRC" /opt/telcoin-source
    fi
}
src_state() {
    G -C "$1" rev-parse HEAD 2>/dev/null
    G -C "$1" symbolic-ref -q --short HEAD 2>/dev/null || echo detached
    G -C "$1" status --porcelain --untracked-files=all 2>/dev/null
    G -C "$1" for-each-ref --format='%(refname) %(objectname)' refs/heads refs/tags refs/remotes 2>/dev/null
}
dd_pinned() {
    cmp -s "$FIXT/genesis.yaml" "$DD/genesis/genesis.yaml" \
        && cmp -s "$FIXT/committee.yaml" "$DD/genesis/committee.yaml" \
        && cmp -s "$FIXT/parameters.yaml" "$DD/parameters.yaml" \
        && [[ ! -L "$DD/genesis/committee.yaml" && ! -L "$DD/parameters.yaml" ]]
}
dd_sums() { cat "$DD/genesis/genesis.yaml" "$DD/genesis/committee.yaml" "$DD/parameters.yaml" 2>/dev/null | cksum; }
pin_full() {
    cmp -s "$FIXT/genesis.yaml" "$PIN/genesis.yaml" && cmp -s "$FIXT/committee.yaml" "$PIN/committee.yaml" \
        && cmp -s "$FIXT/parameters.yaml" "$PIN/parameters.yaml"
}
git_bad() { grep -E '(^| )(pull|checkout|reset|merge|submodule|switch|rebase|stash|clean|clone)( |\||$)' "$V_LOG/git.log" 2>/dev/null; }
restarts() { lines "$V_LOG/systemctl.log" '^restart telcoin$'; }
# run13 ANSWERS -- menu 13 in this shell (errexit off, as the tests run it); OUT, RC.
run13() {
    ANSWERS="$1"
    refresh_chain_configs < "$T/enters" > "$V_LOG/out" 2>&1
    RC=$?
    set +e
    OUT="$(cat "$V_LOG/out")"
}
# run13_strict ANSWERS -- in a subshell under set -euo pipefail, as the real script
# runs it; V_END is printed only when the function returned. State changes stay
# in the subshell.
run13_strict() {
    ANSWERS="$1"
    ( set -euo pipefail; refresh_chain_configs; echo "V_END rc=$?" ) < "$T/enters" > "$V_LOG/out" 2>&1
    RC=$?
    OUT="$(cat "$V_LOG/out")"
}
norm() { sed -e "s#${P}#<P>#g" -e $'s/\033\\[[0-9;]*m//g'; }

# =============================================================================
suite_main() {
    local s0 s1 h0 n

    # --- E1 testnet reads the pinned tag ------------------------------------------
    new_case testnet; fill_dd stale; own_dd; mk_src main
    s0="$(src_state "$SRC")"
    run13 "y y"
    check_rc "E1: rc 0" 0 "$RC"
    check "E1: data dir holds the pinned files" yes "$(yesno dd_pinned)"
    check "E1: pinned dir holds the tag's files" yes "$(yesno pin_full)"
    check "E1: checkout HEAD/branch/status/refs unchanged" "$s0" "$(src_state "$SRC")"
    check "E1: no pull/checkout/reset/merge/submodule/clone" "" "$(git_bad)"
    check "E1: one fetch of the tag, https only" 1 "$(lines "$V_LOG/git.log" '^-C .* fetch --quiet --no-tags origin +refs/tags/v0.16.0-adiri:refs/tn-remote-tags/v0.16.0-adiri|fd9=closed|gap=https$')"
    check "E1: restart ran once" 1 "$(restarts)"
    check "E1: both prompts asked" "Refresh chain configs for telcoin?
Restart the node now to apply changes?" "$(logf confirm.log)"
    check "E1: committee resync once" "fw --p2p-committee sync" "$(logf fw.log)"
    check "E1: host baseline refreshed (count; open item says twice)" 2 "$(lines "$V_LOG/baseline.log" baseline)"
    check "E1: lock held while the helper ran" "helper held=true probe=held
helper rc=0" "$(logf helper.log)"
    check "E1: lock released at the end" "false free" "${EDIT_LOCK_HELD} $(lock_free)"
    check "E1: fd 9 open in rev-parse and the three cat-file calls only (F7, known)" "4 0" \
        "$(lines "$V_LOG/git.log" 'fd9=open') $(grep 'fd9=open' "$V_LOG/git.log" | grep -c -v ' rev-parse \| cat-file ')"
    printf '      git argv: %s\n' "$(norm < "$V_LOG/git.log" | tr '\n' ';')"
    if [[ "$IS_ROOT" == yes ]]; then
        check "E1: pinned files root 644, dir root 755" "root 644 root 755" "$(stat -c '%U %a' "$PIN/committee.yaml") $(stat -c '%U %a' "$PIN")"
        check "E1: data-dir files owned by the service user" "" "$(find "$DD" ! -user "$SERVICE_USER")"
    fi
    new_case testnet; fill_dd stale; own_dd; mk_src main
    run13_strict "y y"
    check "E1 strict: set -euo pipefail reaches the end" yes "$(has "$OUT" "V_END rc=0")"
    check "E1 strict: data dir pinned" yes "$(yesno dd_pinned)"

    # --- E2 nothing to refresh ----------------------------------------------------
    new_case testnet; fill_dd pinned; own_dd; mk_src main
    run13 ""
    check "E2a: says Nothing to refresh" yes "$(has "$OUT" "Nothing to refresh")"
    check "E2a: no prompt, no lock, no git, no systemctl, no baseline, no resync" "|||||" \
        "$(logf confirm.log)|$(logf lock.log)|$(logf git.log)|$(logf systemctl.log)|$(logf baseline.log)|$(logf fw.log)"
    check "E2a: lock not held" "false free" "${EDIT_LOCK_HELD} $(lock_free)"
    check "E2a: pinned dir not created" no "$([[ -e "$P/etc/telcoin/chain-configs" ]] && echo yes || echo no)"
    printf '      E2a text: %s\n' "$(grep -E 'Nothing|New pins' <<< "$OUT" | norm | tr '\n' ' ')"
    new_case testnet; fill_dd pinned; own_dd; mk_src main
    run13_strict ""
    check "E2a strict: reaches the end" yes "$(has "$OUT" "V_END rc=0")"

    new_case testnet; fill_dd pinned; printf 'x: 1\n' >> "$DD/parameters.yaml"; own_dd; mk_src main
    run13 "n"
    check "E2b one stale file: prompt asked, cancelled, no lock" "yes|" "$(has "$(logf confirm.log)" "Refresh chain")|$(logf lock.log)"
    check "E2b: data dir unchanged by the cancel" no "$(yesno dd_pinned)"

    new_case testnet; fill_dd pinned; rm -f "$DD/parameters.yaml"
    cp "$FIXT/parameters.yaml" "$P/params.real"; ln -s "$P/params.real" "$DD/parameters.yaml"; own_dd; mk_src main
    run13 "y y"
    check "E2c symlink to a pinned file: refreshed, not Nothing" "no 0" "$(has "$OUT" "Nothing to refresh") $RC"
    check "E2c: the symlink replaced by a regular pinned file" yes "$(yesno dd_pinned)"

    new_case testnet; fill_dd pinned; rm -f "$DD/parameters.yaml"; own_dd; mk_src main
    run13 "y y"
    check "E2d parameters.yaml missing: refreshed" "no 0 yes" "$(has "$OUT" "Nothing to refresh") $RC $(yesno dd_pinned)"

    new_case testnet "tel coin"; fill_dd pinned; own_dd; mk_src main
    run13 ""
    check "E2e data dir with a space: Nothing to refresh, no prompt" "yes|" "$(has "$OUT" "Nothing to refresh")|$(logf confirm.log)"
    new_case testnet "tel coin"; fill_dd stale; own_dd; mk_src main
    run13 "y y"
    check "E2e data dir with a space, stale: refreshed" "0 yes 1" "$RC $(yesno dd_pinned) $(restarts)"

    new_case testnet; fill_dd stale; own_dd; mk_src main
    run13 "y n"
    check "E2f restart later: files in place, no restart" "yes 0" "$(yesno dd_pinned) $(restarts)"
    printf '      E2f later text: %s\n' "$(grep -E 'Changes saved|systemctl restart' <<< "$OUT" | norm | tr '\n' ' ')"
    edit_unlock; edit_reset_backups
    : > "$V_LOG/confirm.log"
    run13 ""
    check "E2f second run: Nothing to refresh, no prompt" "yes|" "$(has "$OUT" "Nothing to refresh")|$(logf confirm.log)"
    check "E2f second run: says nothing of a pending restart" no "$(has "$OUT" "Restart node")"
    edit_unlock; edit_reset_backups
    ANSWERS="y"
    restart_node < "$T/enters" > "$V_LOG/out14" 2>&1
    set +e
    check "E2f menu 14 restarts and resyncs" "1 fw --p2p-committee sync" "$(restarts) $(logf fw.log)"

    # --- E3 mainnet fetches nothing -----------------------------------------------
    new_case mainnet; printf 'genesis:\n  chainId: 731\n' > "$DD/genesis/genesis.yaml"
    printf 'c: old\n' > "$DD/genesis/committee.yaml"; printf 'p: old\n' > "$DD/parameters.yaml"; own_dd; mk_src main
    s0="$(dd_sums)"
    run13 "y y"
    check "E3a mainnet, checkout: no git" "" "$(logf git.log)"
    check "E3a: refused by the empty pins" "yes yes" "$(has "$OUT" "no pinned sha256") $(has "$OUT" "do not match the mainnet pins")"
    check "E3a: data dir unchanged, no restart" "$s0 0" "$(dd_sums) $(restarts)"
    printf '      E3a text: %s\n' "$(grep -E 'ERROR|WARN|->' <<< "$OUT" | norm | tr '\n' ' ' | cut -c1-600)"
    new_case mainnet; printf 'genesis:\n  chainId: 731\n' > "$DD/genesis/genesis.yaml"; own_dd
    run13 "y"
    check "E3b mainnet, no checkout: no git, refused" "|yes|0" "$(logf git.log)|$(has "$OUT" "Source directory not found")|$(restarts)"
    new_case mainnet; printf 'genesis:\n  chainId: 731\n' > "$DD/genesis/genesis.yaml"; own_dd; mk_src main
    mkdir -p "$PIN"; cp "$WK/chain-configs/mainnet/"*.yaml "$PIN/"
    run13 "y y"
    check "E3c mainnet, pinned dir hand-filled: no git, still refused" "|yes|0" "$(logf git.log)|$(has "$OUT" "do not match the mainnet pins")|$(restarts)"
    new_case mainnet; printf 'genesis:\n  chainId: 731\n' > "$DD/genesis/genesis.yaml"; own_dd
    mkdir -p "$PIN"; cp "$WK/chain-configs/mainnet/"*.yaml "$PIN/"
    run13 "y"
    check "E3d mainnet, hand-filled, no checkout: no git, refused" "|0" "$(logf git.log)|$(restarts)"

    # --- E4 the chain-id guard ------------------------------------------------------
    new_case testnet; printf 'genesis:\n  chainId: 32285\n' > "$DD/genesis/genesis.yaml"
    printf 'c: other\n' > "$DD/genesis/committee.yaml"; printf 'p: other\n' > "$DD/parameters.yaml"; own_dd; mk_src main
    s0="$(dd_sums)"
    run13 "y y"
    check "E4a other chain: refused, data dir unchanged, no restart" "yes $s0 0" "$(has "$OUT" "Not refreshing: the node's genesis") $(dd_sums) $(restarts)"
    check "E4a: pinned dir was filled anyway (side effect)" yes "$(yesno pin_full)"
    check "E4a: baseline refreshed on a refused run (count)" 1 "$(lines "$V_LOG/baseline.log" baseline)"
    check "E4a: lock still held after the return (main_menu releases)" "true held" "${EDIT_LOCK_HELD} $(lock_free)"
    new_case testnet; printf 'c: other\n' > "$DD/genesis/committee.yaml"; own_dd; mk_src main
    run13 "y y"
    check "E4b node genesis missing: refused (chain unknown)" "yes 0" "$(has "$OUT" "is chain unknown") $(restarts)"
    new_case testnet; printf 'genesis:\n  name: x\n' > "$DD/genesis/genesis.yaml"; own_dd; mk_src main
    run13 "y y"
    check "E4b node genesis without a chain id: refused" "yes 0" "$(has "$OUT" "is chain unknown") $(restarts)"
    new_case testnet; printf 'genesis:\n  chainId: 731\n' > "$DD/genesis/genesis.yaml"; own_dd; mk_src main
    s0="$(dd_sums)"
    run13 "y y"
    check "E4c NETWORK=testnet, node genesis 731: refused" "yes $s0 0" "$(has "$OUT" "is chain 731 and") $(dd_sums) $(restarts)"
    new_case mainnet; fill_dd stale; own_dd; mk_src main
    s0="$(dd_sums)"
    run13 "y y"
    check "E4d NETWORK=mainnet, node genesis 2017: refused, no git" "yes|$s0|" "$(has "$OUT" "do not match the mainnet pins")|$(dd_sums)|$(logf git.log)"

    # --- E5 the lock ------------------------------------------------------------------
    new_case testnet; fill_dd stale; own_dd; mk_src symlink
    run13 "y"
    check "E5 helper rc 1 (symlinked checkout): message, lock released" "yes false free" "$(has "$OUT" "were not installed") ${EDIT_LOCK_HELD} $(lock_free)"
    check "E5 rc 1: helper saw the lock held" "helper held=true probe=held
helper rc=1" "$(logf helper.log)"
    new_case testnet; fill_dd stale; own_dd
    run13 "y"
    check "E5 helper rc 2 (no checkout): lock released, no git" "false free|" "${EDIT_LOCK_HELD} $(lock_free)|$(logf git.log)"
    printf '      E5/E8 no-checkout hint: %s\n' "$(grep -E 'ERROR|->' <<< "$OUT" | grep -v 'This installs\|committee and parameters at\|read from that tag\|New pins' | norm | tr '\n' ' ')"
    new_case testnet; fill_dd stale; own_dd; mk_src offline
    run13 "y"
    check "E5 helper rc 2 (offline, no tag): could-not-read message, lock released" "yes false free" "$(has "$OUT" "Could not read the pinned") ${EDIT_LOCK_HELD} $(lock_free)"
    new_case testnet; fill_dd stale; own_dd; mk_src main
    chmod 0555 "$DD/genesis"
    run13 "y y"
    chmod 0755 "$DD/genesis"
    check "E5 failed copy: message, no restart" "yes 0" "$(has "$OUT" "Could not copy the chain configs") $(restarts)"
    check "E5 failed copy: lock still held after the return" "true held" "${EDIT_LOCK_HELD} $(lock_free)"
    new_case testnet; fill_dd stale; own_dd; mk_src main
    run13 "n"
    check "E5 cancelled: lock never taken, no git" "|false free|" "$(logf lock.log)|${EDIT_LOCK_HELD} $(lock_free)|$(logf git.log)"

    # A second process holds the lock.
    new_case testnet; fill_dd stale; own_dd; mk_src main
    ( exec 8>>"$TN_UPDATE_LOCK_FILE"; flock 8; exec "$REAL_SLEEP" 30 ) &
    h0=$!
    n=0
    while [[ "$(lock_free)" == free && $n -lt 50 ]]; do "$REAL_SLEEP" 0.1; n=$((n + 1)); done
    printf '%s\n' "$h0" > "$TN_UPDATE_LOCK_FILE"
    run13 "y"
    kill "$h0" 2>/dev/null
    wait "$h0" 2>/dev/null
    check "E5 lock held elsewhere: refused before any git, data dir stale" "yes||no" "$(has "$OUT" "an update is in progress")|$(logf git.log)|$(yesno dd_pinned)"
    printf '      E5 busy text: %s\n' "$(grep -E 'ERROR|->' <<< "$OUT" | grep -i 'update\|wait' | norm | tr '\n' ' ')"

    # Two menu actions in one session, through main_menu, after an early return
    # that leaves the lock held (the chain-id refusal), as the real script runs.
    new_case testnet; printf 'genesis:\n  chainId: 32285\n' > "$DD/genesis/genesis.yaml"; own_dd; mk_src main
    ANSWERS="y y y"
    printf '13\n\n13\n\n14\n\n15\n' > "$P/menu.in"
    ( set -euo pipefail; show_current_config() { :; }; main_menu ) < "$P/menu.in" > "$V_LOG/menu.out" 2>&1
    RC=$?
    check "E5 session 13,13,14,15: exits 0 (no deadlock)" 0 "$RC"
    check "E5 session: the lock taken three times, never refused" "3 no" "$(lines "$V_LOG/lock.log" acquire) $(has "$(cat "$V_LOG/menu.out")" "an update is in progress")"
    check "E5 session: menu 14 restarted once" 1 "$(restarts)"
    check "E5 session: lock free afterwards" free "$(lock_free)"

    # --- E8 replacement hints and pinned-dir states -------------------------------------
    new_case testnet; fill_dd stale; own_dd
    G clone -q --branch v0.16.0-adiri "$O" "$SRC" 2>/dev/null
    run13 "y y"
    check "E8 hint A (git clone --branch TAG into the source dir): works" "0 yes 1" "$RC $(yesno dd_pinned) $(restarts)"
    new_case testnet; fill_dd stale; own_dd
    G clone -q --depth 1 --branch v0.16.0-adiri "file://$O" "$SRC" 2>/dev/null
    run13 "y y"
    check "E8 hint A shallow (--depth 1): works" "0 yes" "$RC $(yesno dd_pinned)"
    if [[ "$IS_ROOT" == yes ]]; then
        new_case testnet; fill_dd stale; own_dd
        G clone -q --branch v0.16.0-adiri "$O" "$SRC" 2>/dev/null
        chown -R nobody "$SRC"
        run13 "y"
        check "E8 hint A cloned as another user: refused (owner), no git" "yes|" "$(has "$OUT" "must be a directory owned by root")|$(logf git.log)"
    else
        skip "E8 hint A cloned as another user" "needs root to chown"
    fi
    new_case testnet; fill_dd stale; own_dd
    mkdir -p "$PIN"; chmod 0755 "$PIN"
    cp "$FIXT/genesis.yaml" "$FIXT/committee.yaml" "$FIXT/parameters.yaml" "$PIN/"; chmod 0644 "$PIN/"*.yaml
    run13 "y y"
    check "E8 hint B (three files copied into the pinned dir): works, no git" "0 yes 1|" "$RC $(yesno dd_pinned) $(restarts)|$(logf git.log)"
    check "E8 hint B: baseline refreshed only by the restart" 1 "$(lines "$V_LOG/baseline.log" baseline)"
    new_case testnet; fill_dd stale; own_dd
    mkdir -p "$PIN"; printf '<html>github tree page</html>\n' > "$PIN/genesis.yaml"
    cp "$FIXT/committee.yaml" "$FIXT/parameters.yaml" "$PIN/"
    run13 "y"
    check "E8 hint B with a wrong file (an HTML page): refused, data dir stale" "no 0" "$(yesno dd_pinned) $(restarts)"
    new_case testnet; fill_dd stale; own_dd; mk_src main
    mkdir -p "$PIN"; cp "$FIXT/genesis.yaml" "$FIXT/parameters.yaml" "$PIN/"; cp "$DIVERGED" "$PIN/committee.yaml"
    run13 "y y"
    check "E8 pinned dir from an older release (other pins): replaced from the tag" "0 yes yes" "$RC $(yesno pin_full) $(yesno dd_pinned)"
    new_case testnet; fill_dd stale; own_dd; mk_src main
    mkdir -p "$PIN"; cp "$FIXT/genesis.yaml" "$FIXT/committee.yaml" "$FIXT/parameters.yaml" "$PIN/"
    s1="$(src_state "$SRC")"
    run13 "y y"
    check "E8 pinned dir current, checkout on diverged main: no git, refreshed" "|0 yes" "$(logf git.log)|$RC $(yesno dd_pinned)"
    check "E8: checkout unchanged" "$s1" "$(src_state "$SRC")"
}

# =============================================================================
# cmp: the apply path of one refresh, normalised, for a diff between trees.
suite_cmp() {
    local name ans g
    for name in refused later ok; do
        new_case testnet; fill_dd stale; own_dd; mk_src main "$O2"
        case "$name" in
            refused) ans="y y"; g=1 ;;
            later)   ans="y n"; g=0 ;;
            ok)      ans="y y"; g=0 ;;
        esac
        GUARD_RC="$g"
        run13 "$ans"
        echo "=== ${name}"
        sed -n '/Copying chain configs/,$p' "$V_LOG/out" | norm
        echo "--- rc=${RC} pending=${EDIT_PENDING} lock=${EDIT_LOCK_HELD}/$(lock_free) dd_pinned=$(yesno dd_pinned)"
        echo "--- systemctl: $(grep -v '^is-active\|^show' "$V_LOG/systemctl.log" 2>/dev/null | tr '\n' ';')"
        echo "--- fw: $(logf fw.log | tr '\n' ';') baseline=$(lines "$V_LOG/baseline.log" baseline)"
        echo "--- prompts: $(logf confirm.log | tr '\n' ';')"
    done
    check "cmp suite ran" yes yes
}

# oldscript: the edit-config.sh of 01664cc with this library, on testnet.
suite_oldscript() {
    local s0 h1
    new_case testnet; fill_dd stale; own_dd; mk_src tag
    G -C "$SRC" checkout -q -B main "$TAGC"
    G -C "$SRC" branch -q --set-upstream-to=origin/main main
    s0="$(G -C "$SRC" rev-parse HEAD)"
    run13 "y y"
    h1="$(G -C "$SRC" rev-parse HEAD)"
    echo "--- old script + new lib: rc=${RC} head_moved=$([[ "$s0" != "$h1" ]] && echo yes || echo no) dd_pinned=$(yesno dd_pinned) restarts=$(restarts)"
    echo "--- git: $(norm < "$V_LOG/git.log" | tr '\n' ';')"
    norm < "$V_LOG/out" | grep -E 'ERROR|WARN|OK|STEP|==>|Pulling|pull' | head -20
    check "oldscript: the checkout was pulled (moved)" yes "$([[ "$s0" != "$h1" ]] && echo yes || echo no)"
    check "oldscript: refused by the pins, data dir not refreshed" "no 0" "$(yesno dd_pinned) $(restarts)"
}

case "$SUITE" in
    main) suite_main ;;
    cmp) suite_cmp ;;
    oldscript) suite_oldscript ;;
    *) echo "unknown suite ${SUITE}" >&2; exit 2 ;;
esac
finish
