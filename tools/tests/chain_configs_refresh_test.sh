#!/usr/bin/env bash
# =============================================================================
# tools/tests/chain_configs_refresh_test.sh -- edit-config.sh menu 13,
# refresh_chain_configs. On testnet (a network with a pinned tag) the three
# chain configs are read from that tag into the pinned directory
# (tn_chain_configs_from_tag, the real helper with a git stand-in) and copied
# into the node's data dir from there; the checkout is never pulled and no
# submodule command runs; a data dir that already holds the pinned files
# (hashed by the service user) is left alone (no prompt, no lock, no restart,
# no git) with a pointer to 14) Restart node. A refusal or failure of the
# helper changes nothing; a failure (rc 2) is one neutral line, with the hint
# that a re-run offers a clone only when one would. A git worktree (its .git a
# file) is a checkout and is read, on devnet pulled. With no checkout and no
# pinned files the menu first runs the library's own checks, as
# ensure_chain_configs_available does: a pinned directory with an entry in the
# way or a symlink, and a source path that is not a checkout, are refused with
# the library's wording before any clone question; otherwise it offers the
# clone at the tag (_tn_chain_configs_clone), asked with the lock free, or
# prints how to get the files by hand. The host baseline is made again
# whenever the helper wrote under the config dir: pinned files installed, or
# the right ones reinstalled because their modes were not the install's (on
# every way the refresh ends), and not when they were in place. Every way back
# to the menu after the lock releases it before the "Press Enter" prompt.
# Mainnet (neither a tag nor pins) is refused before any prompt, lock or git;
# devnet still pulls. The chain-id guard and a cancelled prompt still stop the
# refresh. The menu label.
#
#   bash tools/tests/chain_configs_refresh_test.sh
#   docker run --rm -v "$PWD:/w" -w /w bash:3.2 bash tools/tests/chain_configs_refresh_test.sh
#   docker run --rm -v "$PWD:/w" -w /w ubuntu:26.04 bash tools/tests/chain_configs_refresh_test.sh
#
# edit-config.sh is sourced without its main call (as in
# edit_config_resync_test.sh). git is a stand-in that records its argv and
# serves the fixture files of genesis.d/testnet as blobs (as in
# genesis_hash_test.sh); a clone makes the destination's .git. systemctl,
# confirm, the update lock and the host baseline are stand-ins that log to one
# event file, and so is every "Press Enter" prompt (a read wrapper), so the
# order of unlock and prompt is read from that log. The service-user runner
# records its calls; it and the install into the pinned directory run as the
# account running the test, and the root writers set the modes they are given,
# as the real ones do, so the results are the same under any umask. The cases
# that stand in for tn_chain_configs_from_tag itself come last.
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
# prints the file of that name from GIT_BLOBS; clone logs "git clone" to the
# event file and GIT_ALLOW_PROTOCOL to clone.gap, then exits GIT_CLONE_RC or
# makes DEST/.git; pull exits GIT_PULL_RC. Anything else (submodule) exits 0.
cat > "$T/bin/git" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$REC/git.argv"
if [ "$1" = -C ]; then shift 2; fi
last=""
for a in "$@"; do last="$a"; done
case "$1" in
    clone)
        printf 'git clone\n' >> "$REC/ev"
        printf '%s\n' "${GIT_ALLOW_PROTOCOL:-}" > "$REC/clone.gap"
        [ "${GIT_CLONE_RC:-0}" -eq 0 ] || exit "$GIT_CLONE_RC"
        mkdir -p "$last/.git"
        exit 0
        ;;
    pull) exit "${GIT_PULL_RC:-0}" ;;
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
# confirm -- the answers in ANSWERS, one per question in order (0 yes, 1 no),
# else CONFIRM_RC for every question.
confirm() {
    local a="${CONFIRM_RC:-0}"
    printf 'asked: %s\n' "$1" >> "$EV"
    if [[ -n "${ANSWERS:-}" ]]; then
        a="${ANSWERS%% *}"
        if [[ "$ANSWERS" == *" "* ]]; then ANSWERS="${ANSWERS#* }"; else ANSWERS=""; fi
    fi
    return "$a"
}
# read -- the builtin, after logging each "Press Enter" prompt as "enter".
read() {
    case "$*" in
        *"Press Enter"*) printf 'enter\n' >> "$EV" ;;
    esac
    builtin read "$@"
}
systemctl() {
    printf 'systemctl %s\n' "$*" >> "$EV"
    case "$1" in
        is-active) return "${ACTIVE_RC:-0}" ;;
    esac
    return 0
}
edit_epoch_wait() { return "${EPOCH_RC:-0}"; }
edit_baseline_refresh() { printf 'baseline\n' >> "$EV"; }
sleep() { :; }
# The data dir belongs to the account running the test, and the pinned
# directory is no root-only tree here: the service-user and root writers run
# as that account. The service-user runner records "<command>|<last argument>";
# AS_USER_FAIL=mktemp fails each mktemp, AS_USER_FAIL=all refuses every call
# (rc 126, as for an unusable service user).
tn_as_service_user() {
    local a last=""
    for a in "$@"; do last="$a"; done
    printf '%s|%s\n' "$1" "$last" >> "$REC/asuser"
    case "${AS_USER_FAIL:-}:$1" in
        all:*) return 126 ;;
        mktemp:mktemp) return 1 ;;
    esac
    "$@"
}
# The root writers set the modes they are given (as the real ones do), so a
# pinned directory they made is in place under any umask. LAYOUT_FAIL=1 makes
# the directory writer refuse, as the real one does when the config dir fails
# tn_root_dir_ok.
_tn_root_layout_dir() { [[ -z "${LAYOUT_FAIL:-}" ]] || return 1; mkdir -p -- "$1" && chmod "$3" "$1"; }
tn_write_root_file() { cat > "$1" && chmod "$2" "$1"; }
# shellcheck disable=SC2034  # read by edit-config.sh
TARGET_SERVICE=telcoin
SERVICE_USER=telcoin
export GIT_FETCH_RC GIT_REFS GIT_BLOBS GIT_CLONE_RC GIT_PULL_RC

TAG="$TESTNET_CHAIN_CONFIGS_TAG"
META="$T/fx/etc/telcoin/.node-meta"
DD="$T/dd"
SRC="${TN_ROOT_PREFIX}${TN_SOURCE_DIR}"
PIN="$(tn_chain_configs_dir testnet)"
cp "$FX"/*.yaml "$T/diverged/"
printf '# changed on the default branch\n' >> "$T/diverged/committee.yaml"
# The files menu 13 installs: the first pinned hash of each, the file at the tag.
PINNED="$(tn_chain_config_pin testnet genesis.yaml | cut -d' ' -f1)
$(tn_chain_config_pin testnet committee.yaml | cut -d' ' -f1)
$(tn_chain_config_pin testnet parameters.yaml | cut -d' ' -f1)"
ASK="asked: Refresh chain configs for telcoin?"
ASK_CLONE="asked: Clone the repository at ${TAG} into ${SRC} now?"
APPLY="systemctl daemon-reload
asked: Restart the node now to apply changes?"
RESTART="${APPLY}
systemctl restart telcoin
systemctl show -p NRestarts --value telcoin
systemctl is-active --quiet telcoin
baseline
unlock
enter"
# Back to the menu after the lock: released, then the prompt.
BACK="unlock
enter"
HELD_TOTAL=0

# --- helpers -----------------------------------------------------------------------------
has() { if grep -qF -- "$2" <<< "$1"; then echo yes; else echo no; fi; }
ev() { cat "$EV" 2>/dev/null; }
argv() { cat "$REC/git.argv" 2>/dev/null; }
asuser() { cat "$REC/asuser" 2>/dev/null; }
# errors -- the [ERROR] lines of the last run, without the prefix.
errors() { sed -n 's/^  \[ERROR\] //p' "$T/out"; }
# verbs -- the git subcommand of each recorded call, in order.
verbs() { awk '{ i = 1; if ($1 == "-C") i = 3; s = s (NR > 1 ? " " : "") $i } END { print s }' "$REC/git.argv"; }
# moving -- the recorded git subcommands that would move a checkout.
moving() { verbs | tr ' ' '\n' | grep -E '^(pull|checkout|switch|reset|merge|rebase|clean|submodule)$'; }
# bcount -- how often the last run made the host baseline again.
bcount() { grep -c '^baseline$' "$EV" || true; }
# held_at_enter -- the "Press Enter" prompts of the last run reached while the
# update lock was held (a lock event not yet followed by an unlock).
held_at_enter() { awk '$0 == "lock" { h = 1 } $0 == "unlock" { h = 0 } $0 == "enter" && h { n++ } END { print n + 0 }' "$EV"; }
# manual -- the lines that say how to get the pinned files by hand; shown --
# the same block as the last run printed it.
manual() {
    local f
    printf '  ->  Clone the repository at that tag (as root), then run this again:\n'
    printf '  ->    sudo git clone --branch %s %s %s\n' "$TAG" "$TN_REPO" "$SRC"
    printf '  ->  or put the three files of that tag into %s (root, 0644):\n' "$PIN"
    for f in genesis committee parameters; do
        printf '  ->    https://raw.githubusercontent.com/Telcoin-Association/telcoin-network/%s/chain-configs/testnet/%s.yaml\n' "$TAG" "$f"
    done
}
shown() { sed -n '/Clone the repository at that tag/,/parameters\.yaml$/p' "$T/out"; }
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
# origin -- what the git stand-in serves: fetch works, the fetched ref and the
# local tag exist, the blobs are the files at the tag.
origin() {
    GIT_FETCH_RC=0 GIT_BLOBS="$FX" GIT_CLONE_RC=0
    GIT_REFS="refs/tn-remote-tags/${TAG} refs/tags/${TAG}"
}
# checkout -- a telcoin-network checkout at SRC whose working tree holds the
# default branch's files (committee.yaml no longer the pinned one), and origin.
checkout() {
    rm -rf "$SRC"
    mkdir -p "$SRC/.git" "$SRC/chain-configs/testnet"
    cp "$T/diverged"/*.yaml "$SRC/chain-configs/testnet/"
    origin
}
nopin() { rm -rf "${PIN%/*}"; }
# worktree -- the same checkout as a git worktree: its .git is a file that
# names the gitdir of the primary checkout.
worktree() {
    checkout
    rm -rf "$SRC/.git"
    printf 'gitdir: %s/primary/.git/worktrees/telcoin-source\n' "$T" > "$SRC/.git"
}
# loose_pin -- the pinned files with the pinned contents, made by hand under a
# restrictive umask: the directory 0700, the files 0600 (its parent 0755).
loose_pin() {
    nopin
    mkdir -p "$PIN"
    cp "$FX"/*.yaml "$PIN/"
    chmod 0600 "$PIN"/*.yaml
    chmod 0700 "$PIN"
    chmod 0755 "${PIN%/*}"
}
# exact_pin -- the pinned files as the install leaves them: 0755 directories,
# 0644 files.
exact_pin() {
    loose_pin
    chmod 0644 "$PIN"/*.yaml
    chmod 0755 "$PIN"
}
# pmodes -- the modes of the pinned directory's parent, the directory and its
# three files, on one line.
pmodes() {
    stat -c '%a' -- "${PIN%/*}" "$PIN" "$PIN/genesis.yaml" "$PIN/committee.yaml" "$PIN/parameters.yaml" \
        | tr '\n' ' '
}
# refresh -- menu 13 as main_menu runs it (the lock of an earlier edit released
# first), stdin from /dev/null; OUT and RC, the events in EV, git's argv, the
# service-user calls. Counts the prompts reached with the lock held.
refresh() {
    edit_unlock
    edit_reset_backups
    : > "$EV"
    : > "$REC/git.argv"
    : > "$REC/asuser"
    rm -f "$REC/clone.gap"
    refresh_chain_configs < /dev/null > "$T/out" 2>&1
    RC=$?
    set +e
    OUT="$(cat "$T/out")"
    ANSWERS=""
    HELD_TOTAL=$((HELD_TOTAL + $(held_at_enter)))
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
# The baseline is made for the pinned files right after their install, and
# again by apply_changes after the successful restart (it does so after every
# one; only a change to apply_changes can drop the second).
check "stale: asked, locked, baseline for the new pinned files, then the restart path" \
    "${ASK}
lock
baseline
${RESTART}" "$(ev)"
check "stale: the lock is released" "false" "$EDIT_LOCK_HELD"
check "stale: no clone offered while there is a checkout" no "$(has "$OUT" "Clone the repository")"
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
check_has "current: a restart the operator put off is pointed at 14) Restart node" \
    "  ->  If telcoin has not been restarted since these files were copied, use 14) Restart node." "$OUT"
check "current: the restart hint comes right after the line" \
    "  ->  If telcoin has not been restarted since these files were copied, use 14) Restart node." \
    "$(awk '/Nothing to refresh/ { getline; print; exit }' "$T/out")"
check "current: new pins come with a signed scripts release" yes \
    "$(has "$OUT" "New pins come with a signed scripts release (update-scripts.sh); run this again after one.")"
check "current: no prompt, no lock, no restart, no baseline: only the Press Enter" "enter" "$(ev)"
check "current: no baseline" 0 "$(bcount)"
check "current: no git" "" "$(argv)"
check "current: the three files are tested and hashed by the service user" "sh|${DD}/genesis/genesis.yaml
sh|${DD}/genesis/committee.yaml
sh|${DD}/parameters.yaml" "$(asuser)"
check "current: no intro" no "$(has "$OUT" "This installs")"
check "current: the data dir is unchanged" "$PINNED" "$(dsums)"
# Root never reads the data dir itself: with the service user unusable, the
# files cannot be hashed, so the node is not taken as current.
AS_USER_FAIL=all
CONFIRM_RC=1
refresh
AS_USER_FAIL="" CONFIRM_RC=0
check "current, the service user unusable: not taken as current, the prompt asked" "no|${ASK}
enter" "$(has "$OUT" "Nothing to refresh")|$(ev)"
nopin
rm -rf "$SRC"
refresh
check "current, no pinned directory and no checkout: still nothing to refresh, nothing run" "yes|enter" \
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
# The same, the restart put off: nothing was written under the config dir, so
# no baseline at all.
node testnet
checkout
exact_pin
ANSWERS="0 1"
refresh
check "pinned dir in place with the install's modes, restart later: copied, no git, no baseline" \
    "${PINNED}||0|755 755 644 644 644 " "$(dsums)|$(argv)|$(bcount)|$(pmodes)"

# --- a git worktree as the checkout (its .git a file): read, no clone offered -------------
node testnet
worktree
nopin
refresh
check_rc "worktree: rc 0" 0 "$RC"
check "worktree: no clone question, no clone; the helper reads the tag from it" \
    "no|fetch rev-parse cat-file cat-file cat-file" "$(has "$(ev)" "asked: Clone")|$(verbs)"
check "worktree: the pinned files installed and copied, the baseline, the restart path" "${PINNED}|${PINNED}|${ASK}
lock
baseline
${RESTART}" "$(psums)|$(dsums)|$(ev)"
check "worktree: still a worktree, its tree untouched" "yes|$(cat "$T/diverged/committee.yaml")" \
    "$([[ -f "$SRC/.git" ]] && echo yes || echo no)|$(cat "$SRC/chain-configs/testnet/committee.yaml")"
# The read fails (the tag neither on origin nor in it): the neutral line and no
# promise of a clone, since there is a checkout.
node testnet
worktree
nopin
GIT_FETCH_RC=1
GIT_REFS=""
refresh
check "worktree, the read fails: the neutral error, no clone question or hint" \
    "The pinned testnet chain configs (${TAG}) could not be installed (see above). Chain configs unchanged.|no|no" \
    "$(errors)|$(has "$(ev)" "asked: Clone")|$(has "$OUT" "offered a clone")"
check "worktree, the read fails: the helper's reason, unlocked before the prompt" "yes|${ASK}
lock
${BACK}" "$(has "$OUT" "Could not fetch tag ${TAG} from origin, and the checkout does not have it.")|$(ev)"

# --- the restart put off, refused or failed: the baseline once, for the installed files ----
node testnet
checkout
nopin
ANSWERS="0 1"
refresh
check "restart later: the files copied, the baseline once, no restart" "${PINNED}|${ASK}
lock
baseline
${APPLY}
${BACK}" "$(dsums)|$(ev)"
check "restart later: baseline count" 1 "$(bcount)"
node testnet
checkout
nopin
EPOCH_RC=1
refresh
EPOCH_RC=0
check "restart refused by the committee check: the baseline once, no restart" "${ASK}
lock
baseline
${APPLY}
${BACK}" "$(ev)"
node testnet
checkout
nopin
ACTIVE_RC=1
refresh
ACTIVE_RC=0
check "restart failed: the baseline once" "${ASK}
lock
baseline
${APPLY}
systemctl restart telcoin
systemctl show -p NRestarts --value telcoin
systemctl is-active --quiet telcoin
${BACK}" "$(ev)"
check "restart failed: says so" yes "$(has "$OUT" "Node failed to restart. Check logs:")"

# --- the pinned files right, their modes not the install's: reinstalled, the baseline once --
# The helper rewrites them under the config dir (0755 and 0644) with no git, so
# the baseline is made again on every way the refresh ends, not only after a
# successful restart.
REINSTALLED="Reinstalled the testnet chain configs in ${PIN} root-owned, directories 0755 and files 0644: their owner or modes were not the ones the install sets."
node testnet
checkout
loose_pin
ANSWERS="0 1"
refresh
check "0600 pinned files, restart later: reinstalled with no git, the install's modes" \
    "yes||755 755 644 644 644 " "$(has "$OUT" "$REINSTALLED")|$(argv)|$(pmodes)"
check "0600 pinned files, restart later: copied, the baseline once, no restart" "${PINNED}|${ASK}
lock
baseline
${APPLY}
${BACK}|1" "$(dsums)|$(ev)|$(bcount)"
node testnet
checkout
loose_pin
EPOCH_RC=1
refresh
EPOCH_RC=0
check "0600 pinned files, restart refused by the committee check: reinstalled, the baseline once" "yes|${ASK}
lock
baseline
${APPLY}
${BACK}|1" "$(has "$OUT" "$REINSTALLED")|$(ev)|$(bcount)"
node testnet 999
checkout
loose_pin
before="$(dsums)"
refresh
check "0600 pinned files, the chain-id guard refuses: reinstalled, the baseline once, nothing copied" \
    "yes|${before}|${ASK}
lock
baseline
${BACK}|1" "$(has "$OUT" "$REINSTALLED")|$(dsums)|$(ev)|$(bcount)"

# --- the copy into the data dir fails after the install -------------------------------------
node testnet
checkout
nopin
before="$(dsums)"
AS_USER_FAIL=mktemp
refresh
AS_USER_FAIL=""
check "failed copy: the error" \
    "Could not copy the chain configs into ${DD} as telcoin. Chain configs unchanged." "$(errors)"
check "failed copy: nothing copied; the baseline once for the installed files; unlocked before the prompt" \
    "${before}|${ASK}
lock
baseline
${BACK}" "$(dsums)|$(ev)"

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
check "refused: asked, locked, unlocked before the prompt; no baseline, no restart" "${ASK}
lock
${BACK}" "$(ev)"
check "refused: nothing installed, no baseline" 0 "$(bcount)"
check "refused: the lock is released" "false" "$EDIT_LOCK_HELD"
check "refused: no pull, no submodule" "" "$(moving)"

# --- the helper fails: the tag neither on origin nor in the checkout (rc 2) -------------------
checkout
GIT_FETCH_RC=1
GIT_REFS=""
refresh
check_rc "failed: back to the menu, rc 0" 0 "$RC"
check "failed: the neutral error, ending Chain configs unchanged." \
    "The pinned testnet chain configs (${TAG}) could not be installed (see above). Chain configs unchanged." "$(errors)"
check "failed: the helper's reason is shown" yes \
    "$(has "$OUT" "Could not fetch tag ${TAG} from origin, and the checkout does not have it.")"
check "failed: nothing copied" "$before" "$(dsums)"
check "failed: asked, locked, unlocked before the prompt; no baseline, no restart" "${ASK}
lock
${BACK}" "$(ev)"
check "failed: the lock is released" "false" "$EDIT_LOCK_HELD"
check "failed: no clone offered or promised while there is a checkout" "no no" \
    "$(has "$OUT" "Clone the repository") $(has "$OUT" "offered a clone")"

# --- no checkout and no pinned files (a Docker install that never cloned) ------------------
# Declined: what is missing, the clone named, then how to get the files by hand.
node testnet
rm -rf "$SRC"
nopin
origin
before="$(dsums)"
ANSWERS="0 1"
refresh
check_rc "no checkout, clone declined: back to the menu, rc 0" 0 "$RC"
check "no checkout: says what is missing" yes \
    "$(has "$OUT" "[WARN] There is no repository checkout at ${SRC} to read the pinned testnet chain configs (${TAG}) from, and ${PIN} does not hold them.")"
check "no checkout: the clone is named before the question" "yes yes yes yes" \
    "$(has "$OUT" "->  They can be read from a clone of the repository at that tag, the one setup makes:") $(has "$OUT" "->  Tag: ${TAG}") $(has "$OUT" "->  Repository: ${TN_REPO}") $(has "$OUT" "->  Clone destination: ${SRC}")"
check "no checkout, clone declined: asked twice, never locked, no git" "${ASK}
${ASK_CLONE}
enter|" "$(ev)|$(argv)"
check "no checkout, clone declined: not cloned, nothing changed" yes \
    "$(has "$OUT" "->  Not cloned. Chain configs unchanged.")"
check "no checkout, clone declined: how to get the files by hand" "$(manual)" "$(shown)"
check_lacks "no checkout, clone declined: no setup-node.sh" "setup-node" "$OUT"
check "no checkout, clone declined: no error" "" "$(errors)"
check "no checkout, clone declined: nothing copied, installed or cloned" "${before}|no|no" \
    "$(dsums)|$(exists "$PIN")|$(exists "$SRC")"
check "no checkout, clone declined: the lock is free" "false" "$EDIT_LOCK_HELD"
# Accepted: the clone helper at the tag into the source dir, under the lock,
# then the pinned files are read from it and the refresh goes on.
node testnet
rm -rf "$SRC"
nopin
origin
ANSWERS="0 0 0"
refresh
check_rc "clone accepted: rc 0" 0 "$RC"
check "clone accepted: the clone at the tag into the source dir, without submodules" \
    "clone --quiet --branch ${TAG} -- ${TN_REPO} ${SRC}" "$(sed -n 1p "$REC/git.argv")"
check "clone accepted: over https only" "https" "$(cat "$REC/clone.gap" 2>/dev/null)"
check "clone accepted: then the tag fetched and read from the clone" \
    "clone fetch rev-parse cat-file cat-file cat-file" "$(verbs)"
check "clone accepted: asked with the lock free, locked for the clone, then the restart path" "${ASK}
${ASK_CLONE}
lock
git clone
baseline
${RESTART}" "$(ev)"
check "clone accepted: the helper says so" yes "$(has "$OUT" "[OK]  Repository cloned to: ${SRC}")"
check "clone accepted: the pinned files installed and copied" "${PINNED}|${PINNED}" "$(psums)|$(dsums)"
check "clone accepted: no manual lines, no setup-node.sh" "no no" \
    "$(has "$OUT" "Clone the repository at that tag") $(has "$OUT" "setup-node")"
check "clone accepted: the lock is released" "false" "$EDIT_LOCK_HELD"
# The clone fails: the helper's message, an error, the lines by hand, unlocked.
node testnet
rm -rf "$SRC"
nopin
origin
before="$(dsums)"
GIT_CLONE_RC=128
ANSWERS="0 0"
refresh
check_rc "clone fails: back to the menu, rc 0" 0 "$RC"
check "clone fails: the clone's error, then one ending Chain configs unchanged." \
    "Clone failed. Check your internet connection.
Could not clone the repository into ${SRC} (see above). Chain configs unchanged." "$(errors)"
check "clone fails: locked for the clone, unlocked before the prompt; no fetch" "${ASK}
${ASK_CLONE}
lock
git clone
${BACK}|clone" "$(ev)|$(verbs)"
check "clone fails: how to get the files by hand" "$(manual)" "$(shown)"
check_lacks "clone fails: no setup-node.sh" "setup-node" "$OUT"
check "clone fails: nothing copied or installed" "${before}|no" "$(dsums)|$(exists "$PIN")"
# The clone works, the read from it fails: an error, unlocked.
node testnet
rm -rf "$SRC"
nopin
origin
GIT_FETCH_RC=1
GIT_REFS=""
ANSWERS="0 0"
refresh
check "cloned, the read fails: the neutral error, no promise of another clone" \
    "The pinned testnet chain configs (${TAG}) could not be installed (see above). Chain configs unchanged.|no" \
    "$(errors)|$(has "$OUT" "offered a clone")"
check "cloned, the read fails: unlocked before the prompt" "${ASK}
${ASK_CLONE}
lock
git clone
${BACK}" "$(ev)"
check "cloned, the read fails: nothing copied" "$before" "$(dsums)"
# The second way by hand holds: the three files put into the pinned directory
# are found in place, with no checkout, no clone question and no git.
rm -rf "$SRC"
mkdir -p "$PIN"
cp "$FX"/*.yaml "$PIN/"
refresh
check "no checkout, files put in by hand: refreshed with no git, no clone question" "yes no " \
    "$(has "$(ev)" "systemctl restart telcoin") $(has "$(ev)" "asked: Clone") $(argv)"
check "no checkout, files put in by hand: the data dir holds the pinned files" "$PINNED" "$(dsums)"

# --- no checkout: the library's checks run before the clone question -------------------------
# A source path that exists and is not a checkout: the library's refusal
# (_tn_chain_configs_clone_target), no clone offered, nothing locked or run.
node testnet
rm -rf "$SRC"
mkdir -p "$SRC/chain-configs/testnet"
cp "$T/diverged"/*.yaml "$SRC/chain-configs/testnet/"
nopin
origin
before="$(dsums)"
ANSWERS="0 0"
refresh
check_rc "a source path that is not a checkout: back to the menu, rc 0" 0 "$RC"
check "a source path that is not a checkout: the library's wording, then the refusal" \
    "yes|The pinned testnet chain configs (${TAG}) were not installed (see above). Chain configs unchanged." \
    "$(has "$OUT" "[WARN] ${SRC} exists but is not a git checkout; move it aside first.")|$(errors)"
check "a source path that is not a checkout: no clone offered, no lock, no git" "no|${ASK}
enter|" "$(has "$OUT" "There is no repository checkout")|$(ev)|$(argv)"
check "a source path that is not a checkout: nothing copied or installed, the path as it was" \
    "${before}|no|no|$(cat "$T/diverged/committee.yaml")" \
    "$(dsums)|$(exists "$PIN")|$(exists "$SRC/.git")|$(cat "$SRC/chain-configs/testnet/committee.yaml")"
# An entry in the way in the pinned directory (_tn_chain_configs_dest_ok, rc
# 2): refused before the clone question, so no clone is made for nothing.
node testnet
rm -rf "$SRC"
nopin
mkdir -p "$PIN/committee.yaml"
origin
before="$(dsums)"
ANSWERS="0 0"
refresh
check "an entry in the way: the library's wording, then the neutral error" \
    "yes|The pinned testnet chain configs (${TAG}) could not be installed (see above). Chain configs unchanged." \
    "$(has "$OUT" "[WARN] ${PIN}/committee.yaml is a symlink or not a regular file; nothing was installed. Remove it and run again.")|$(errors)"
check "an entry in the way: refused before any clone question; no lock, no git, no clone made" "${ASK}
enter||no" "$(ev)|$(argv)|$(exists "$SRC")"
check "an entry in the way: no clone promised, nothing copied" "no|${before}" \
    "$(has "$OUT" "offered a clone")|$(dsums)"
# The pinned directory a symlink (rc 1): the same, worded as a refusal.
node testnet
rm -rf "$SRC"
nopin
mkdir -p "${PIN%/*}" "$T/elsewhere"
ln -s "$T/elsewhere" "$PIN"
ANSWERS="0 0"
refresh
check "a symlinked pinned directory: the library's wording, the refusal, before any clone question" \
    "yes|The pinned testnet chain configs (${TAG}) were not installed (see above). Chain configs unchanged.|${ASK}
enter||no" \
    "$(has "$OUT" "[WARN] ${PIN} must be a directory, not a symlink or a file; nothing was installed. Remove it and run again.")|$(errors)|$(ev)|$(argv)|$(exists "$SRC")"
rm -f "$PIN"

# --- no checkout, the right files 0600 and their reinstall fails: no clone promised -------
# Run twice: the second run asks no clone question either (the files are
# there), so neither may promise one.
for run in 1 2; do
    node testnet
    rm -rf "$SRC"
    loose_pin
    before="$(dsums)"
    LAYOUT_FAIL=1
    ANSWERS="0 0"
    refresh
    LAYOUT_FAIL=""
    check "reinstall fails, run ${run}: the library's reason, then the neutral error" \
        "yes|The pinned testnet chain configs (${TAG}) could not be installed (see above). Chain configs unchanged." \
        "$(has "$OUT" "[WARN] Could not reinstall the testnet chain configs in ${PIN} root-owned, directories 0755 and files 0644 (see above).")|$(errors)"
    check "reinstall fails, run ${run}: no clone question, none promised; nothing copied; unlocked before the prompt" \
        "no|no|${before}|${ASK}
lock
${BACK}" "$(has "$(ev)" "asked: Clone")|$(has "$OUT" "offered a clone")|$(dsums)|$(ev)"
    check "reinstall fails, run ${run}: no claim that the pinned directory lacks the files" no \
        "$(has "$OUT" "does not hold them")"
done

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
check "chain id: no restart; the baseline once for the pinned files installed; unlocked before the prompt" "${ASK}
lock
baseline
${BACK}" "$(ev)"
# main_menu releases the lock again after every item: after this return that is
# a no-op (no second unlock, no error), and the session goes on.
nopin
printf '13\n\n15\n' > "$T/menu.in"
edit_unlock
: > "$EV"
( show_current_config() { :; }; main_menu ) < "$T/menu.in" > "$T/out" 2>&1
RC=$?
check_rc "main_menu 13 then 15: exits 0" 0 "$RC"
check "main_menu: one lock and one unlock, before the prompt; its own release afterwards does nothing" "${ASK}
lock
baseline
${BACK}" "$(ev)"
HELD_TOTAL=$((HELD_TOTAL + $(held_at_enter)))

# --- a cancelled prompt changes nothing ------------------------------------------------------
node testnet
checkout
nopin
before="$(dsums)"
CONFIRM_RC=1
refresh
CONFIRM_RC=0
check "cancelled: says so" yes "$(has "$OUT" "->  Cancelled.")"
check "cancelled: asked only; no lock, no restart" "${ASK}
enter" "$(ev)"
check "cancelled: no git" "" "$(argv)"
check "cancelled: nothing copied, nothing installed" "${before}|no" "$(dsums)|$(exists "$PIN")"

# --- mainnet: neither a tag nor pins: refused before any prompt, lock or git ----------------
node mainnet 731
checkout
mkdir -p "$SRC/chain-configs/mainnet"
cp "$FX"/*.yaml "$SRC/chain-configs/mainnet/"
nopin
before="$(dsums)"
refresh
check_rc "mainnet: back to the menu, rc 0" 0 "$RC"
check "mainnet: refused up front" \
    "This script release pins no mainnet chain configs yet, so there is nothing to install. Chain configs unchanged." \
    "$(errors)"
check_has "mainnet: where the pins come from" \
    "  ->  They come with a signed scripts release (update-scripts.sh); run this again after one." "$OUT"
check "mainnet: no prompt, no lock, no restart: only the Press Enter" "enter" "$(ev)"
check "mainnet: no git at all" "" "$(argv)"
check "mainnet: no intro, no restart warning" "no no" \
    "$(has "$OUT" "This copies") $(has "$OUT" "will be restarted")"
check "mainnet: nothing copied, nothing installed" "${before}|no" "$(dsums)|$(exists "$(tn_chain_configs_dir mainnet)")"
check "mainnet: no nothing-to-refresh shortcut" no "$(has "$OUT" "Nothing to refresh")"
rm -rf "$SRC"
refresh
check "mainnet, no checkout: the same refusal, no prompt, no git" \
    "This script release pins no mainnet chain configs yet, so there is nothing to install. Chain configs unchanged.|enter|" \
    "$(errors)|$(ev)|$(argv)"

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
# Each way back to the menu after the lock releases it before the prompt.
GIT_PULL_RC=1
refresh
GIT_PULL_RC=0
check "devnet, the pull fails: the error; unlocked before the prompt" "git pull failed in ${SRC}. Chain configs unchanged.|${ASK}
lock
${BACK}" "$(errors)|$(ev)"
rm -f "$SRC/chain-configs/devnet/parameters.yaml"
refresh
check "devnet, a file missing: says which; unlocked before the prompt" "yes|${ASK}
lock
${BACK}" "$(has "$OUT" "Missing chain config files at ${SRC}/chain-configs/devnet:")|$(ev)"
rm -rf "$SRC/chain-configs/devnet"
refresh
check "devnet, no chain-config directory: says so; unlocked before the prompt" "yes|${ASK}
lock
${BACK}" "$(has "$OUT" "Chain config directory not found at ${SRC}/chain-configs/devnet")|$(ev)"
rm -rf "$SRC"
refresh
check "devnet, no checkout: says so, no clone offered; unlocked before the prompt" "yes|no|${ASK}
lock
${BACK}" "$(has "$OUT" "Source directory not found at ${SRC}")|$(has "$OUT" "asked: Clone")|$(ev)"
# A git worktree is a checkout on devnet too: pulled, its files copied.
node devnet 32285
worktree
mkdir -p "$SRC/chain-configs/devnet"
printf 'genesis:\n  chainId: 32285\n# devnet\n' > "$SRC/chain-configs/devnet/genesis.yaml"
printf 'committee: devnet\n' > "$SRC/chain-configs/devnet/committee.yaml"
printf 'parameters: devnet\n' > "$SRC/chain-configs/devnet/parameters.yaml"
refresh
check "devnet, a worktree: pulled, its files copied, restarted" \
    "-C $SRC pull|committee: devnet|yes|no" \
    "$(sed -n 1p "$REC/git.argv")|$(cat "$DD/genesis/committee.yaml")|$(has "$(ev)" "systemctl restart telcoin")|$(has "$OUT" "Source directory not found")"

# --- the menu label ------------------------------------------------------------------------
MENU="$(grep -E '^        echo " 1[0-4]\) ' "$TN_TEST_REPO/edit-config.sh")"
check_has "menu: item 13" '        echo " 13) Refresh chain configs   (pinned genesis/committee/parameters)"' "$MENU"
check_has "menu: item 14, the one the restart hint names" '        echo " 14) Restart node"' "$MENU"
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
    elif [[ -n "${HGONE:-}" ]]; then
        # The pinned files went away while it ran.
        rm -rf "$PIN"
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
    check "stub rc ${HRC}: nothing copied, no restart, unlocked before the prompt" "${before}|${ASK}
lock
helper $SRC testnet edit_wait_say
${BACK}|false" "$(dsums)|$(ev)|${EDIT_LOCK_HELD}"
    want="The pinned testnet chain configs (${TAG}) could not be installed (see above). Chain configs unchanged."
    [[ "$HRC" -ne 1 ]] || want="The pinned testnet chain configs (${TAG}) were not installed (see above). Chain configs unchanged."
    check "stub rc ${HRC}, a checkout: the line for that rc, no clone promised" "${want}|no" \
        "$(errors)|$(has "$OUT" "offered a clone")"
done
# No checkout, the pinned files in place before and after the helper failed:
# a re-run asks no clone question, so none is promised.
node testnet
rm -rf "$SRC"
exact_pin
HRC=2
refresh
check "stub rc 2, no checkout, the pinned files still there: the neutral error, no clone promised; unlocked before the prompt" \
    "The pinned testnet chain configs (${TAG}) could not be installed (see above). Chain configs unchanged.|no|no|${ASK}
lock
helper $SRC testnet edit_wait_say
${BACK}" \
    "$(errors)|$(has "$OUT" "offered a clone")|$(has "$OUT" "setup-node")|$(ev)"
# No checkout, and the pinned files gone while the helper ran: the neutral
# error, then the hint, which the next run bears out.
node testnet
rm -rf "$SRC"
exact_pin
HGONE=1
refresh
HGONE=""
check "stub rc 2, no checkout, the pinned files gone: the neutral error, run this again for the clone; unlocked before the prompt" \
    "The pinned testnet chain configs (${TAG}) could not be installed (see above). Chain configs unchanged.|yes|no|${ASK}
lock
helper $SRC testnet edit_wait_say
${BACK}" \
    "$(errors)|$(has "$OUT" "->  Run this again to be offered a clone of the repository at ${TAG}.")|$(has "$OUT" "setup-node")|$(ev)"
ANSWERS="0 1"
refresh
check "stub rc 2, the pinned files gone: the next run offers the clone" yes "$(has "$(ev)" "$ASK_CLONE")"
# The pins refuse the copy source after the helper (a check that fails): an
# error, the baseline for the installed files, unlocked before the prompt.
node testnet
checkout
nopin
HRC=0
edit_unlock
edit_reset_backups
: > "$EV"
( tn_chain_configs_check() { return 1; }; refresh_chain_configs < /dev/null > "$T/out" 2>&1 )
check "stub, the pins refuse the copy source: the error" \
    "The chain configs in ${PIN} do not match the testnet pins (see above). Chain configs unchanged." "$(errors)"
check "stub, the pins refuse the copy source: unlocked before the prompt" "${ASK}
lock
helper $SRC testnet edit_wait_say
baseline
${BACK}" "$(ev)"
HELD_TOTAL=$((HELD_TOTAL + $(held_at_enter)))
unset -f tn_chain_configs_from_tag

check "no run waited at Press Enter with the update lock held" 0 "$HELD_TOTAL"

finish
