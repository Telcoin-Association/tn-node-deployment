#!/usr/bin/env bash
# V-RANGE repro: edit-config.sh menu 13 against a git worktree checkout and a
# pinned directory whose files are right but whose modes are not.
#
#   bash tasks/verify-req/V-RANGE/vr_menu13_worktree.sh
#
# Real git (a local bare origin, a worktree as the checkout), the stand-ins of
# tools/tests/chain_configs_refresh_test.sh for the lock, confirm, systemctl,
# the epoch wait, the host baseline and the root writers. Writes only under
# the test's temp dir. bash 3.2 safe; skips without git.
#
# Reading the result at adf7ee0: the checks of cases 2, 3 and 5 assert the
# defective behaviour (their "ok" shows VR-1 and VR-3 present); the one check of
# case 4 asserts the intended behaviour (its FAIL shows VR-2). Expected today:
# 14 checks, 1 failure.
set -u
W="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=tools/tests/lib.sh
. "$W/tools/tests/lib.sh"
command -v git >/dev/null 2>&1 || { skip "menu 13 worktree repro" "git absent"; finish; }

T="$TN_TEST_TMP"
FX="$W/tools/tests/genesis.d/testnet"
EV="$T/ev"
mkdir -p "$T/h" "$T/fx/etc/telcoin" "$T/fx/opt"
grep -v '^main "\$@"$' "$W/edit-config.sh" > "$T/h/edit-config.sh"
ln -s "$W/lib" "$T/h/lib"

TN_ROOT_PREFIX="$T/fx"
tn_test_pre_common
# shellcheck source=/dev/null
source "$T/h/edit-config.sh"
tn_test_post_common
# shellcheck disable=SC2034
RED='' GREEN='' YELLOW='' BLUE='' CYAN='' BOLD='' RESET=''

tn_migrate_ownership() { return 0; }
edit_legacy_reason() { return 1; }
tn_acquire_update_lock() { printf 'lock\n' >> "$EV"; return 0; }
tn_release_update_lock() { printf 'unlock\n' >> "$EV"; return 0; }
confirm() {
    local a="${CONFIRM_RC:-0}"
    printf 'asked: %s\n' "$1" >> "$EV"
    if [[ -n "${ANSWERS:-}" ]]; then
        a="${ANSWERS%% *}"
        if [[ "$ANSWERS" == *" "* ]]; then ANSWERS="${ANSWERS#* }"; else ANSWERS=""; fi
    fi
    return "$a"
}
read() { case "$*" in *"Press Enter"*) printf 'enter\n' >> "$EV" ;; esac; builtin read "$@"; }
systemctl() { printf 'systemctl %s\n' "$*" >> "$EV"; return 0; }
edit_epoch_wait() { return "${EPOCH_RC:-0}"; }
edit_baseline_refresh() { printf 'baseline\n' >> "$EV"; }
sleep() { :; }
tn_as_service_user() { "$@"; }
# The root writers as the test's account, with the modes the real ones set.
_tn_root_layout_dir() { mkdir -p -- "$1" && chmod 0755 "$1"; }
tn_write_root_file() { cat > "$1" && chmod "$2" "$1"; }
# shellcheck disable=SC2034
TARGET_SERVICE=telcoin
SERVICE_USER=telcoin
TAG="$TESTNET_CHAIN_CONFIGS_TAG"
META="$T/fx/etc/telcoin/.node-meta"
DD="$T/dd"
SRC="${TN_ROOT_PREFIX}${TN_SOURCE_DIR}"
PIN="$(tn_chain_configs_dir testnet)"

# A bare origin with the tag, a primary clone, and SRC as a worktree of it at the
# tag (its .git a file).
g() { git -c user.name=t -c user.email=t@t -c init.defaultBranch=main -c advice.detachedHead=false "$@"; }
mkdir -p "$T/seed/chain-configs/testnet"
cp "$FX"/*.yaml "$T/seed/chain-configs/testnet/"
g -C "$T/seed" init -q && g -C "$T/seed" add -A && g -C "$T/seed" commit -qm tag && g -C "$T/seed" tag "$TAG"
g clone -q --bare "$T/seed" "$T/origin.git"
g clone -q "$T/origin.git" "$T/primary"
g -C "$T/primary" fetch -q --tags
mkdir -p "${SRC%/*}"
g -C "$T/primary" worktree add -q --detach "$SRC" "$TAG" 2>/dev/null
check "fixture: SRC/.git is a file (a worktree)" "yes" "$([[ -f "$SRC/.git" ]] && echo yes || echo no)"

# hasstr TEXT NEEDLE -- yes when TEXT contains NEEDLE.
hasstr() { if grep -qF -- "$2" <<< "$1"; then echo yes; else echo no; fi; }
node() {
    printf 'NETWORK=testnet\nDATA_DIR=%s\n' "$DD" > "$META"
    rm -rf "$DD" "${PIN%/*}"
    mkdir -p "$DD/genesis"
    printf 'genesis:\n  chainId: 2017\n# old\n' > "$DD/genesis/genesis.yaml"
    printf 'committee: old\n' > "$DD/genesis/committee.yaml"
    printf 'parameters: old\n' > "$DD/parameters.yaml"
    : > "$EV"
}

# 1. The library reads the worktree.
node
rc=0
tn_chain_configs_from_tag "$SRC" testnet > "$T/lib.out" 2>&1 || rc=$?
check "library: tn_chain_configs_from_tag reads the worktree (rc 0)" "0" "$rc"
check "library: the pinned directory then holds the files" "yes" "$([[ -f "$PIN/committee.yaml" ]] && echo yes || echo no)"

# 2. Menu 13, same host state (no pinned files yet): refresh yes, clone no.
node
ANSWERS="0 1"
refresh_chain_configs > "$T/m1.out" 2>&1 < /dev/null
printf -- '--- menu 13 (refresh yes, clone no) ---\n'; cat "$T/m1.out"; printf -- '--- events ---\n'; cat "$EV"
check "menu: offers a clone although SRC is a checkout the library reads" yes "$(hasstr "$(cat "$EV")" "asked: Clone the repository at ${TAG}")"
check "menu: the files are never installed" no "$(hasstr "$(cat "$T/m1.out")" "Chain configs updated")"

# 3. Menu 13: refresh yes, clone yes: the clone into the worktree fails.
node
ANSWERS="0 0"
refresh_chain_configs > "$T/m2.out" 2>&1 < /dev/null
printf -- '--- menu 13 (refresh yes, clone yes) ---\n'; cat "$T/m2.out"
check "menu: clone into the worktree fails" yes "$(hasstr "$(cat "$T/m2.out")" "Clone failed. Check your internet connection.")"

# 4. Pinned files right, modes wrong (0700/0600), data dir stale, restart later:
# the library reinstalls them (owner or modes change under /etc/telcoin) and
# the menu does not refresh the host baseline.
node
mkdir -p "$PIN"
cp "$FX"/*.yaml "$PIN/"
chmod 0600 "$PIN"/*.yaml
chmod 0700 "$PIN"
ANSWERS="0 1"
refresh_chain_configs > "$T/m3.out" 2>&1 < /dev/null
set +e  # apply_changes ends with set -e
printf -- '--- menu 13 (pinned files 0600, restart later) ---\n'; cat "$T/m3.out"; printf -- '--- events ---\n'; cat "$EV"
check "menu: the library reinstalled the pinned files" yes "$(hasstr "$(cat "$T/m3.out")" "Reinstalled the testnet chain configs")"
check "menu: host baseline refreshed after that reinstall (count)" "1" "$(grep -c '^baseline$' "$EV" || true)"

# 5. No checkout at all; the pinned files are right but 0600, and their
# reinstall fails (here: the layout writer refuses, as it does when the config
# dir fails tn_root_dir_ok). The menu words the rc 2 by "no .git": it says the
# pinned directory does not hold them and that a re-run offers a clone; a
# re-run offers none and ends the same way.
rm -rf "$SRC"
_tn_root_layout_dir() { return 1; }
for run in 1 2; do
    node
    mkdir -p "$PIN"
    cp "$FX"/*.yaml "$PIN/"
    chmod 0600 "$PIN"/*.yaml
    ANSWERS="0 0"
    refresh_chain_configs > "$T/m5.$run.out" 2>&1 < /dev/null
    set +e
    printf -- '--- menu 13 run %s (no checkout, reinstall fails) ---\n' "$run"
    grep -E 'ERROR|WARN|Run this again|Reinstall|reinstall' "$T/m5.$run.out"
    printf -- '--- events ---\n'; cat "$EV"
    check "run ${run}: no clone question" no "$(hasstr "$(cat "$EV")" "asked: Clone the repository")"
    check "run ${run}: says ${PIN} does not hold them" yes "$(hasstr "$(cat "$T/m5.$run.out")" "does not hold them. Chain configs unchanged.")"
    check "run ${run}: promises a clone offer on a re-run" yes "$(hasstr "$(cat "$T/m5.$run.out")" "Run this again to be offered a clone")"
done
finish
