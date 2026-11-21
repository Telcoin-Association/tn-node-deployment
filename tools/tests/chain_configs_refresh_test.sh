#!/usr/bin/env bash
# =============================================================================
# tools/tests/chain_configs_refresh_test.sh -- edit-config.sh menu 13,
# refresh_chain_configs. On testnet (a network with a pinned tag) the three
# chain configs are read from that tag into the pinned directory
# (tn_chain_configs_from_tag, the real helper with a git stand-in) and copied
# into the node's data dir from there; the checkout is never pulled and no
# submodule command runs; a data dir that already holds the pinned files is
# left alone (no prompt, no lock, no restart, no git). A refusal or failure of
# the helper changes nothing and releases the lock; with no checkout and no
# pinned files the operator is told what to do. The host baseline is made
# again when pinned files were installed. Mainnet (no tag) runs no git and
# refuses while its pins are empty; devnet still pulls. The chain-id guard and
# a cancelled prompt still stop the refresh. The menu label.
#
#   bash tools/tests/chain_configs_refresh_test.sh
#   docker run --rm -v "$PWD:/w" -w /w bash:3.2 bash tools/tests/chain_configs_refresh_test.sh
#   docker run --rm -v "$PWD:/w" -w /w ubuntu:26.04 bash tools/tests/chain_configs_refresh_test.sh
#
# edit-config.sh is sourced without its main call (as in
# edit_config_resync_test.sh). git is a stand-in that records its argv and
# serves the fixture files of genesis.d/testnet as blobs (as in
# genesis_hash_test.sh); systemctl, confirm, the update lock and the host
# baseline are stand-ins that log to one event file; the copy into the data dir
# and the install into the pinned directory run as the account running the
# test. The cases that stand in for tn_chain_configs_from_tag itself come last.
#
# Maintainer tooling (not updater-tracked, no sidecar). bash 3.2 safe.
# =============================================================================

set -u

# shellcheck source=tools/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

T="$TN_TEST_TMP"
FX="$TN_TEST_DIR/genesis.d/testnet"
REC="$T/rec"
EV="$REC/ev"
export REC
mkdir -p "$T/h" "$T/bin" "$REC" "$T/fx/etc/telcoin" "$T/diverged"
grep -v '^main "\$@"$' "$TN_TEST_REPO/edit-config.sh" > "$T/h/edit-config.sh"
ln -s "$TN_TEST_REPO/lib" "$T/h/lib"
# The git stand-in records its argv. fetch exits GIT_FETCH_RC; rev-parse
# --verify REF succeeds for the refs listed in GIT_REFS; cat-file blob REF:PATH
# prints the file of that name from GIT_BLOBS. Anything else (pull, submodule)
# exits 0.
cat > "$T/bin/git" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$REC/git.argv"
if [ "$1" = -C ]; then shift 2; fi
last=""
for a in "$@"; do last="$a"; done
case "$1" in
    fetch) exit "${GIT_FETCH_RC:-0}" ;;
    rev-parse)
        r="${last%"^{commit}"}"
        case " ${GIT_REFS:-} " in *" $r "*) exit 0 ;; esac
        exit 1
        ;;
    cat-file)
        f="${last##*/}"
        [ -f "${GIT_BLOBS:-/nonexistent}/$f" ] || exit 128
        cat "$GIT_BLOBS/$f"
        exit 0
        ;;
esac
exit 0
EOF
chmod 0755 "$T/bin/git"
PATH="$T/bin:$PATH"

TN_ROOT_PREFIX="$T/fx"
tn_test_pre_common
# shellcheck source=/dev/null
source "$T/h/edit-config.sh"
tn_test_post_common
# Plain text whether or not the test runs on a terminal.
# shellcheck disable=SC2034  # read by the print helpers of lib/common.sh
RED='' GREEN='' YELLOW='' BLUE='' CYAN='' BOLD='' RESET=''

# --- stand-ins ---------------------------------------------------------------------------
tn_migrate_ownership() { return 0; }
edit_legacy_reason() { return 1; }
tn_acquire_update_lock() { printf 'lock\n' >> "$EV"; return 0; }
tn_release_update_lock() { printf 'unlock\n' >> "$EV"; return 0; }
confirm() { printf 'asked: %s\n' "$1" >> "$EV"; return "${CONFIRM_RC:-0}"; }
systemctl() {
    printf 'systemctl %s\n' "$*" >> "$EV"
    case "$1" in
        is-active) return "${ACTIVE_RC:-0}" ;;
    esac
    return 0
}
edit_epoch_wait() { return 0; }
edit_baseline_refresh() { printf 'baseline\n' >> "$EV"; }
sleep() { :; }
# The data dir belongs to the account running the test, and the pinned
# directory is no root-only tree here: the service-user and root writers run
# as that account.
tn_as_service_user() { "$@"; }
_tn_root_layout_dir() { mkdir -p -- "$1"; }
tn_write_root_file() { cat > "$1"; }
# shellcheck disable=SC2034  # read by edit-config.sh
TARGET_SERVICE=telcoin
SERVICE_USER=telcoin
export GIT_FETCH_RC GIT_REFS GIT_BLOBS

TAG="$TESTNET_CHAIN_CONFIGS_TAG"
META="$T/fx/etc/telcoin/.node-meta"
DD="$T/dd"
SRC="${TN_ROOT_PREFIX}${TN_SOURCE_DIR}"
PIN="$(tn_chain_configs_dir testnet)"
cp "$FX"/*.yaml "$T/diverged/"
printf '# changed on the default branch\n' >> "$T/diverged/committee.yaml"
PINNED="$(tn_chain_config_pin testnet genesis.yaml)
$(tn_chain_config_pin testnet committee.yaml)
$(tn_chain_config_pin testnet parameters.yaml)"
ASK="asked: Refresh chain configs for telcoin?"
RESTART="systemctl daemon-reload
asked: Restart the node now to apply changes?
systemctl restart telcoin
systemctl show -p NRestarts --value telcoin
systemctl is-active --quiet telcoin
baseline
unlock"

# --- helpers -----------------------------------------------------------------------------
has() { if grep -qF -- "$2" <<< "$1"; then echo yes; else echo no; fi; }
ev() { cat "$EV" 2>/dev/null; }
argv() { cat "$REC/git.argv" 2>/dev/null; }
# errors -- the [ERROR] lines of the last run, without the prefix.
errors() { sed -n 's/^  \[ERROR\] //p' "$T/out"; }
# verbs -- the git subcommand of each recorded call, in order.
verbs() { awk '{ i = 1; if ($1 == "-C") i = 3; s = s (NR > 1 ? " " : "") $i } END { print s }' "$REC/git.argv"; }
# moving -- the recorded git subcommands that would move a checkout.
moving() { verbs | tr ' ' '\n' | grep -E '^(pull|checkout|switch|reset|merge|rebase|clean|submodule)$'; }
# dsums -- the sha256 of the three files in the data dir, one per line.
dsums() {
    local f got
    for f in genesis/genesis.yaml genesis/committee.yaml parameters.yaml; do
        got="$(sha256sum < "${DD}/${f}" 2>/dev/null)" || got=""
        printf '%s\n' "${got%% *}"
    done
}
# psums -- the same for the pinned directory.
psums() {
    local f got
    for f in genesis.yaml committee.yaml parameters.yaml; do
        got="$(sha256sum < "${PIN}/${f}" 2>/dev/null)" || got=""
        printf '%s\n' "${got%% *}"
    done
}
exists() { if [[ -e "$1" ]]; then echo yes; else echo no; fi; }
islink() { if [[ -L "$1" ]]; then echo yes; else echo no; fi; }
# ends_with TEXT SUFFIX -- yes when TEXT ends with SUFFIX.
ends_with() { if [[ "$1" == *"$2" ]]; then echo yes; else echo no; fi; }
# hint_col N -- the column where the hint of menu item N (10 to 14) starts in
# MENU, 0 when the item is missing or has no hint.
hint_col() {
    local line pre
    line="$(grep -F -- "echo \" ${1}) " <<< "$MENU")"
    pre="${line%%(*}"
    if [[ "$pre" == "$line" ]]; then echo 0; else echo "${#pre}"; fi
}
# node NETWORK [CHAIN_ID] -- .node-meta for NETWORK, and a data dir whose three
# files are stale: a genesis of chain CHAIN_ID (default the testnet's 2017),
# old committee and parameters.
node() {
    printf 'NETWORK=%s\nDATA_DIR=%s\n' "$1" "$DD" > "$META"
    rm -rf "$DD"
    mkdir -p "$DD/genesis"
    printf 'genesis:\n  chainId: %s\n# old\n' "${2:-2017}" > "$DD/genesis/genesis.yaml"
    printf 'committee: old\n' > "$DD/genesis/committee.yaml"
    printf 'parameters: old\n' > "$DD/parameters.yaml"
}
# checkout -- a telcoin-network checkout at SRC whose working tree holds the
# default branch's files (committee.yaml no longer the pinned one); fetch
# works, the fetched ref and the local tag exist, the blobs are the files at
# the tag.
checkout() {
    rm -rf "$SRC"
    mkdir -p "$SRC/.git" "$SRC/chain-configs/testnet"
    cp "$T/diverged"/*.yaml "$SRC/chain-configs/testnet/"
    GIT_FETCH_RC=0 GIT_BLOBS="$FX"
    GIT_REFS="refs/tn-remote-tags/${TAG} refs/tags/${TAG}"
}
nopin() { rm -rf "${PIN%/*}"; }
# refresh -- menu 13 as main_menu runs it (the lock of an earlier edit released
# first), stdin from /dev/null; OUT and RC, the events in EV, git's argv.
refresh() {
    edit_unlock
    edit_reset_backups
    : > "$EV"
    : > "$REC/git.argv"
    refresh_chain_configs < /dev/null > "$T/out" 2>&1
    RC=$?
    set +e
    OUT="$(cat "$T/out")"
}

# --- testnet: stale files in the data dir, the real helper reads the tag --------------------
node testnet
checkout
nopin
refresh
check_rc "stale: rc 0" 0 "$RC"
check "stale: git fetches the tag and reads three blobs, nothing else" \
    "fetch rev-parse cat-file cat-file cat-file" "$(verbs)"
check "stale: no pull, no submodule, nothing that moves the checkout" "" "$(moving)"
check_has "stale: the helper reads the checkout" \
    "-C $SRC fetch --quiet --no-tags origin +refs/tags/${TAG}:refs/tn-remote-tags/${TAG}" "$(argv)"
check "stale: the pinned directory holds the pinned files" "$PINNED" "$(psums)"
check "stale: the data dir holds the pinned files" "$PINNED" "$(dsums)"
check "stale: the checkout's working tree is untouched" "$(cat "$T/diverged/committee.yaml")" \
    "$(cat "$SRC/chain-configs/testnet/committee.yaml")"
check "stale: asked, locked, baseline for the new pinned files, then the restart path" \
    "${ASK}
lock
baseline
${RESTART}" "$(ev)"
check "stale: the lock is released" "false" "$EDIT_LOCK_HELD"
check "stale: intro, the pinned files are installed" yes \
    "$(has "$OUT" "This installs the testnet chain configs this script release pins (genesis,")"
check "stale: intro, the checkout is not moved" yes \
    "$(has "$OUT" "read from that tag; the repository checkout is not pulled or moved.")"
check "stale: intro, new pins come with a signed scripts release" yes \
    "$(has "$OUT" "New pins come with a signed scripts release (update-scripts.sh).")"
check "stale: the helper's messages are shown" "yes yes" \
    "$(has "$OUT" ">>> Fetching ${TAG} from origin for the chain configs...") $(has "$OUT" "Installed the testnet chain configs from ${TAG} into ${PIN}.")"
check "stale: chain id checked against the pinned genesis" yes "$(has "$OUT" "Chain id 2017 matches the node's genesis")"
check "stale: chain configs updated" yes "$(has "$OUT" "Chain configs updated")"
check "stale: no pull message, no error" "no " "$(has "$OUT" "Pulling latest") $(errors)"

# --- testnet: the data dir already holds the pinned files --------------------------------------
refresh
check_rc "current: rc 0" 0 "$RC"
check "current: the full line" yes \
    "$(has "$OUT" "[OK]  Nothing to refresh: the node's data dir already holds the testnet chain configs this script release pins (${TAG}), so telcoin was not restarted.")"
check "current: new pins come with a signed scripts release" yes \
    "$(has "$OUT" "New pins come with a signed scripts release (update-scripts.sh); run this again after one.")"
check "current: no prompt, no lock, no restart, no baseline" "" "$(ev)"
check "current: no git" "" "$(argv)"
check "current: no intro" no "$(has "$OUT" "This installs")"
check "current: the data dir is unchanged" "$PINNED" "$(dsums)"
nopin
rm -rf "$SRC"
refresh
check "current, no pinned directory and no checkout: still nothing to refresh, nothing run" "yes|" \
    "$(has "$OUT" "Nothing to refresh")|$(ev)$(argv)"
check "current, no pinned directory: nothing installed" no "$(exists "$PIN")"
cp "$FX/genesis.yaml" "$FX/committee.yaml" "$DD/genesis/"
printf 'parameters: old\n' > "$DD/parameters.yaml"
checkout
refresh
check "one stale file of three: refreshed" "no yes" \
    "$(has "$OUT" "Nothing to refresh") $(has "$(ev)" "systemctl restart telcoin")"
check "one stale file of three: the data dir holds the pinned files" "$PINNED" "$(dsums)"
rm -f "$DD/parameters.yaml"
ln -s "$PIN/parameters.yaml" "$DD/parameters.yaml"
refresh
check "a symlinked file with the pinned content is not taken as current" "no yes" \
    "$(has "$OUT" "Nothing to refresh") $(has "$(ev)" "systemctl restart telcoin")"
check "the symlink is replaced by a regular file" "no $(tn_chain_config_pin testnet parameters.yaml)" \
    "$(islink "$DD/parameters.yaml") $(sed -n 3p <<< "$(dsums)")"

# --- testnet: the pinned directory holds the files, the data dir does not -------------------
node testnet
checkout
refresh
check_rc "pinned dir in place: rc 0" 0 "$RC"
check "pinned dir in place: no git" "" "$(argv)"
check "pinned dir in place: the helper says so" yes \
    "$(has "$OUT" "The pinned testnet chain configs are already in ${PIN}.")"
check "pinned dir in place: the data dir gets the pinned files" "$PINNED" "$(dsums)"
check "pinned dir in place: no baseline before the restart, one after it" "${ASK}
lock
${RESTART}" "$(ev)"

# --- the helper refuses: the files at the tag do not match the pins (rc 1) --------------------
node testnet
checkout
nopin
GIT_BLOBS="$T/diverged"
before="$(dsums)"
refresh
check_rc "refused: back to the menu, rc 0" 0 "$RC"
check "refused: the error, ending Chain configs unchanged." \
    "The pinned testnet chain configs (${TAG}) were not installed (see above). Chain configs unchanged." "$(errors)"
check "refused: the helper's reason is shown" yes \
    "$(has "$OUT" "The testnet chain configs at ${TAG} do not match the pins; nothing was installed.")"
check "refused: nothing copied" "$before" "$(dsums)"
check "refused: nothing installed" no "$(exists "$PIN")"
check "refused: asked, locked, unlocked; no baseline, no restart" "${ASK}
lock
unlock" "$(ev)"
check "refused: the lock is released" "false" "$EDIT_LOCK_HELD"
check "refused: no pull, no submodule" "" "$(moving)"

# --- the helper fails: the tag neither on origin nor in the checkout (rc 2) -------------------
checkout
GIT_FETCH_RC=1
GIT_REFS=""
refresh
check_rc "failed: back to the menu, rc 0" 0 "$RC"
check "failed: the error, ending Chain configs unchanged." \
    "Could not read the pinned testnet chain configs (${TAG}) from ${SRC} (see above). Chain configs unchanged." "$(errors)"
check "failed: the helper's reason is shown" yes \
    "$(has "$OUT" "Could not fetch tag ${TAG} from origin, and the checkout does not have it.")"
check "failed: nothing copied" "$before" "$(dsums)"
check "failed: asked, locked, unlocked; no baseline, no restart" "${ASK}
lock
unlock" "$(ev)"
check "failed: the lock is released" "false" "$EDIT_LOCK_HELD"
check "failed: no setup hint while there is a checkout" no "$(has "$OUT" "setup-node.sh")"

# --- no checkout and no pinned files (a Docker install that never cloned) ------------------
rm -rf "$SRC"
nopin
refresh
check_rc "no checkout: back to the menu, rc 0" 0 "$RC"
check "no checkout: the error, ending Chain configs unchanged." \
    "There is no repository checkout at ${SRC} to read the pinned testnet chain configs (${TAG}) from, and ${PIN} does not hold them. Chain configs unchanged." \
    "$(errors)"
check "no checkout: what to do" "yes yes yes yes" \
    "$(has "$OUT" "->  Re-run sudo ./setup-node.sh, which offers to clone the repository and reads them, or put") $(has "$OUT" "->  genesis.yaml, committee.yaml and parameters.yaml from") $(has "$OUT" "->    https://github.com/Telcoin-Association/telcoin-network/tree/${TAG}/chain-configs/testnet/") $(has "$OUT" "->  into ${PIN} (owned by root) and run this again.")"
check "no checkout: no git, no clone prompt, no restart" "|${ASK}
lock
unlock" "$(argv)|$(ev)"
check "no checkout: nothing copied" "$before" "$(dsums)"
# The hint holds: the three files put into the pinned directory by hand are found
# in place, with no checkout and no git.
mkdir -p "$PIN"
cp "$FX"/*.yaml "$PIN/"
refresh
check "no checkout, files put in by hand: refreshed with no git" "yes " \
    "$(has "$(ev)" "systemctl restart telcoin") $(argv)"
check "no checkout, files put in by hand: the data dir holds the pinned files" "$PINNED" "$(dsums)"

# --- the chain-id guard still refuses a genesis of another chain ---------------------------
node testnet 999
checkout
nopin
before="$(dsums)"
refresh
check "chain id: refused" \
    "Not refreshing: the node's genesis (${DD}/genesis/genesis.yaml) is chain 999 and ${PIN}/genesis.yaml is chain 2017. Both must be known and equal. Chain configs unchanged." \
    "$(errors)"
check "chain id: nothing copied" "$before" "$(dsums)"
check "chain id: no restart; the baseline taken for the pinned files installed" "${ASK}
lock
baseline" "$(ev)"

# --- a cancelled prompt changes nothing ------------------------------------------------------
node testnet
checkout
nopin
before="$(dsums)"
CONFIRM_RC=1
refresh
CONFIRM_RC=0
check "cancelled: says so" yes "$(has "$OUT" "->  Cancelled.")"
check "cancelled: asked only; no lock, no restart" "$ASK" "$(ev)"
check "cancelled: no git" "" "$(argv)"
check "cancelled: nothing copied, nothing installed" "${before}|no" "$(dsums)|$(exists "$PIN")"

# --- mainnet: no tag, nothing fetched or pulled, the empty pins refuse ------------------------
node mainnet 731
checkout
mkdir -p "$SRC/chain-configs/mainnet"
cp "$FX"/*.yaml "$SRC/chain-configs/mainnet/"
nopin
before="$(dsums)"
refresh
check_rc "mainnet: back to the menu, rc 0" 0 "$RC"
check "mainnet: no git at all" "" "$(argv)"
check "mainnet: used as published" yes "$(has "$OUT" "Mainnet chain configs are used as published (no pull).")"
check "mainnet: the pins are not published yet" yes "$(has "$OUT" "mainnet has no pinned sha256 for genesis.yaml yet")"
check "mainnet: the refusal of before" \
    "The chain configs in ${SRC}/chain-configs/mainnet do not match the mainnet pins (see above). Chain configs unchanged." \
    "$(errors)"
check "mainnet: nothing copied, nothing installed" "${before}|no" "$(dsums)|$(exists "$(tn_chain_configs_dir mainnet)")"
check "mainnet: no restart" no "$(has "$(ev)" "systemctl")"
check "mainnet: no nothing-to-refresh shortcut" no "$(has "$OUT" "Nothing to refresh")"
rm -rf "$SRC"
refresh
check "mainnet, no checkout: no git, the source is not found" "|yes" \
    "$(argv)|$(has "$OUT" "Source directory not found at ${SRC}")"

# --- devnet: still pulls the checkout ------------------------------------------------------
node devnet 32285
checkout
mkdir -p "$SRC/chain-configs/devnet"
printf 'genesis:\n  chainId: 32285\n# devnet\n' > "$SRC/chain-configs/devnet/genesis.yaml"
printf 'committee: devnet\n' > "$SRC/chain-configs/devnet/committee.yaml"
printf 'parameters: devnet\n' > "$SRC/chain-configs/devnet/parameters.yaml"
refresh
check_rc "devnet: rc 0" 0 "$RC"
check "devnet: the checkout is pulled first" "-C $SRC pull" "$(sed -n 1p "$REC/git.argv")"
check "devnet: the submodules are synced" yes "$(has "$(verbs)" "submodule")"
check "devnet: no tag is fetched" no "$(has "$(verbs)" "fetch")"
check "devnet: the checkout's files are copied" "committee: devnet|parameters: devnet" \
    "$(cat "$DD/genesis/committee.yaml")|$(cat "$DD/parameters.yaml")"
check "devnet: restarted" yes "$(has "$(ev)" "systemctl restart telcoin")"
check "devnet: nothing installed in a pinned directory" no "$(exists "$(tn_chain_configs_dir devnet)")"

# --- the menu label ------------------------------------------------------------------------
MENU="$(grep -E '^        echo " 1[0-4]\) ' "$TN_TEST_REPO/edit-config.sh")"
check_has "menu: item 13" '        echo " 13) Refresh chain configs   (pinned genesis/committee/parameters)"' "$MENU"
check "menu: item 13 no longer says pull" no "$(has "$MENU" "pull latest")"
COL12="$(hint_col 12)"
check "menu: item 12 has a hint" yes "$(if [[ "$COL12" -gt 0 ]]; then echo yes; else echo no; fi)"
check "menu: the hints of items 10 to 13 start in one column" "${COL12} ${COL12} ${COL12}" \
    "$(hint_col 10) $(hint_col 11) $(hint_col 13)"

# --- the helper stood in for: its arguments, the pinned directory as the copy source ------
node testnet
checkout
nopin
HRC=0
tn_chain_configs_from_tag() {
    printf 'helper %s\n' "$*" >> "$EV"
    if [[ "$HRC" -eq 0 ]]; then
        mkdir -p "$PIN"
        cp "$FX"/*.yaml "$PIN/"
    fi
    return "$HRC"
}
refresh
check "stub: the helper gets the checkout, the network and the menu's printer, after the prompt and the lock" \
    "${ASK}
lock
helper $SRC testnet edit_wait_say
baseline" "$(sed -n 1,4p "$EV")"
check "stub: the data dir gets the pinned directory's files, not the checkout's" "$PINNED" "$(dsums)"
check "stub: restarted" yes "$(has "$(ev)" "systemctl restart telcoin")"
for HRC in 1 2 3; do
    node testnet
    checkout
    nopin
    before="$(dsums)"
    refresh
    check "stub rc ${HRC}: one error line, ending Chain configs unchanged." "1 yes" \
        "$(errors | wc -l | tr -d ' ') $(ends_with "$(errors)" "Chain configs unchanged.")"
    check "stub rc ${HRC}: nothing copied, no restart, the lock released" "${before}|${ASK}
lock
helper $SRC testnet edit_wait_say
unlock|false" "$(dsums)|$(ev)|${EDIT_LOCK_HELD}"
done
unset -f tn_chain_configs_from_tag

finish
