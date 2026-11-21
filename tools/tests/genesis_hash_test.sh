#!/usr/bin/env bash
# =============================================================================
# tools/tests/genesis_hash_test.sh -- chain configs pinned to a hash and read
# from a pinned tag: tn_chain_configs_check, tn_chain_configs_tag,
# tn_chain_configs_dir, tn_chain_configs_from_tag,
# ensure_chain_configs_available and setup-node.sh's step_write_config. The
# testnet fixture files (genesis.d/testnet) are the repository's
# chain-configs/testnet at the pinned tag and must match the TESTNET_*_SHA256
# constants; a changed, missing or symlinked file is refused before anything
# is copied; the files are read from the fetched tag into the root-owned
# chain-configs directory and the checkout is never moved; mainnet refuses
# while its tag and pins are empty; the working directory is never searched.
# git is a stand-in that records argv and serves the fixture files as blobs.
#
#   bash tools/tests/genesis_hash_test.sh
#
# Maintainer tooling: not tracked by update-scripts.sh, no .sha256 sidecar.
# bash 3.2 safe.
# =============================================================================
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
T="$TN_TEST_TMP"
FX="$TN_TEST_DIR/genesis.d/testnet"
REC="$T/rec"
mkdir -p "$T/bin" "$T/sn" "$REC" "$T/good" "$T/bad" "$T/bad2" "$T/two" "$T/data" "$T/tmp" "$T/notgit" \
    "$T/cwd/chain-configs/testnet" "$T/stg"
chmod 0700 "$T/stg"
export REC
# The git stand-in records its argv, and for fetch and clone the protocols
# GIT_ALLOW_PROTOCOL allows (git.proto); git.env gets one line per call with
# the subcommand, the variables the library sets or clears for git and whether
# fd 9 is open. fetch and clone exit GIT_FETCH_RC and GIT_CLONE_RC (a failing
# fetch prints GIT_FETCH_ERR on stderr; a clone that works makes DIR/.git);
# rev-parse exits GIT_RP_RC with GIT_RP_ERR on stderr when GIT_RP_RC is set,
# else --verify REF succeeds for the refs listed in GIT_REFS; cat-file blob
# REF:PATH prints the file of that name from GIT_BLOBS (while the file
# GIT_HOLD exists it first waits, with "held" and "released" in REC around the
# wait). Anything else exits 0.
cat > "$T/bin/git" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$REC/git.argv"
if [ "$1" = -C ]; then shift 2; fi
last=""
for a in "$@"; do last="$a"; done
fd9=closed
if ( true >&9 ) 2>/dev/null; then fd9=open; fi
printf '%s gap=%s lazy=%s gitdir=%s worktree=%s index=%s common=%s fd9=%s\n' "$1" \
    "${GIT_ALLOW_PROTOCOL-unset}" "${GIT_NO_LAZY_FETCH-unset}" "${GIT_DIR-unset}" \
    "${GIT_WORK_TREE-unset}" "${GIT_INDEX_FILE-unset}" "${GIT_COMMON_DIR-unset}" "$fd9" >> "$REC/git.env"
case "$1" in
    fetch|clone) printf '%s %s\n' "$1" "${GIT_ALLOW_PROTOCOL:-any}" >> "$REC/git.proto" ;;
esac
case "$1" in
    fetch)
        [ "${GIT_FETCH_RC:-0}" = 0 ] || [ -z "${GIT_FETCH_ERR:-}" ] || printf '%s\n' "$GIT_FETCH_ERR" >&2
        exit "${GIT_FETCH_RC:-0}"
        ;;
    clone)
        [ "${GIT_CLONE_RC:-0}" = 0 ] || exit "$GIT_CLONE_RC"
        mkdir -p "$last/.git"
        exit 0
        ;;
    rev-parse)
        if [ -n "${GIT_RP_RC:-}" ]; then
            printf '%s\n' "${GIT_RP_ERR:-}" >&2
            exit "$GIT_RP_RC"
        fi
        r="${last%"^{commit}"}"
        case " ${GIT_REFS:-} " in *" $r "*) exit 0 ;; esac
        exit 1
        ;;
    cat-file)
        if [ -n "${GIT_HOLD:-}" ] && [ -e "$GIT_HOLD" ]; then
            : > "$REC/held"
            while [ -e "$GIT_HOLD" ]; do sleep 0.1; done
            : > "$REC/released"
        fi
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
grep -v '^main "\$@"$' "$TN_TEST_REPO/setup-node.sh" > "$T/sn/setup-node.sh"
ln -s "$TN_TEST_REPO/lib" "$T/sn/lib"
TN_ROOT_PREFIX="$T/root"
tn_test_pre_common
source "$T/sn/setup-node.sh"
set +e

cp "$FX"/*.yaml "$T/good/"
cp "$FX"/*.yaml "$T/bad/"
printf '# changed\n' >> "$T/bad/genesis.yaml"
cp "$FX"/*.yaml "$T/bad2/"
printf '# changed\n' >> "$T/bad2/committee.yaml"
cp "$FX/genesis.yaml" "$FX/committee.yaml" "$T/two/"

chk() {
    local rc=0
    tn_chain_configs_check "$1" "$2" > "$T/out" 2>&1 || rc=$?
    printf '%s\n' "$rc"
}
has() { grep -qF -- "$1" "$T/out" && echo yes || echo no; }

# ---- the pins and the fixture files -----------------------------------------------------
check "pins: testnet tag recorded" "v0.16.0-adiri" "$TESTNET_CHAIN_CONFIGS_TAG"
for f in genesis committee parameters; do
    got="$(sha256sum < "$FX/${f}.yaml" | cut -d' ' -f1)"
    check "fixture ${f}.yaml has the pinned hash" "$(tn_chain_config_pin testnet "${f}.yaml")" "$got"
done
check "mainnet genesis pin empty until the ceremony" "" "$MAINNET_GENESIS_SHA256"
check "mainnet chain-config tag empty until the ceremony" "" "$MAINNET_CHAIN_CONFIGS_TAG"

# ---- tn_chain_configs_check ---------------------------------------------------------------
check_rc "testnet fixture passes" 0 "$(chk "$T/good" testnet)"
check_rc "changed genesis refused" 1 "$(chk "$T/bad" testnet)"
check "changed genesis: expected value printed" yes "$(has "expected ${TESTNET_GENESIS_SHA256}")"
check "changed genesis: actual value printed" yes "$(has "sha256 $(sha256sum < "$T/bad/genesis.yaml" | cut -d' ' -f1)")"
mkdir -p "$T/link"
cp "$FX/committee.yaml" "$FX/parameters.yaml" "$T/link/"
ln -s "$FX/genesis.yaml" "$T/link/genesis.yaml"
check_rc "symlinked genesis refused" 1 "$(chk "$T/link" testnet)"
mkdir -p "$T/missing"
cp "$FX/genesis.yaml" "$FX/committee.yaml" "$T/missing/"
check_rc "missing parameters refused" 1 "$(chk "$T/missing" testnet)"
check_rc "mainnet refused while its pins are empty" 1 "$(chk "$T/good" mainnet)"
check "mainnet: says the pins are not published" yes "$(has "no pinned sha256")"
check_rc "devnet: no pins, warned, rc 0" 0 "$(chk "$T/good" devnet)"
check_rc "unknown network refused" 1 "$(chk "$T/good" foo)"
check_rc "empty network refused" 1 "$(chk "$T/good" "")"

# ---- tn_chain_configs_tag, tn_chain_configs_dir -------------------------------------------
TAG="$TESTNET_CHAIN_CONFIGS_TAG"
check "tag: testnet" "$TAG" "$(tn_chain_configs_tag testnet)"
check "tag: mainnet has none yet" "" "$(tn_chain_configs_tag mainnet)"
check "tag: devnet has none" "" "$(tn_chain_configs_tag devnet)"
check "tag: unknown network has none" "" "$(tn_chain_configs_tag foo)"
CC="$T/root/etc/telcoin/chain-configs"
DEST="$CC/testnet"
check "dir: testnet, under TN_ROOT_PREFIX" "$DEST" "$(tn_chain_configs_dir testnet)"
check "dir: mainnet, under TN_ROOT_PREFIX" "$CC/mainnet" "$(tn_chain_configs_dir mainnet)"
check "dir: CONFIG_DIR is followed" "$T/root/srv/tn/chain-configs/testnet" "$(CONFIG_DIR=/srv/tn; tn_chain_configs_dir testnet)"
check "dir: DEFAULT_CONFIG_DIR without CONFIG_DIR" "$DEST" "$(unset CONFIG_DIR; tn_chain_configs_dir testnet)"
check "dir: no prefix on a host" "/etc/telcoin/chain-configs/testnet" "$(TN_ROOT_PREFIX=""; tn_chain_configs_dir testnet)"

# ---- tn_chain_configs_from_tag ------------------------------------------------------------
# The test runs as any user and TN_TEST_TMP is no root-only tree, so the two
# root writers are stand-ins that record their arguments and set the modes the
# real ones set (the owner is the account running the test).
_tn_root_layout_dir() { printf '%s\n' "$*" >> "$REC/layout"; mkdir -p -- "$1" && chmod "$3" "$1"; }
tn_write_root_file() { printf '%s %s\n' "$1" "$2" >> "$REC/rootw"; cat > "$1" && chmod "$2" "$1"; }
confirm() { printf 'asked\n' >> "$REC/confirm"; [[ "${CONFIRM:-no}" == yes ]]; }
export GIT_FETCH_RC GIT_CLONE_RC GIT_REFS GIT_BLOBS GIT_FETCH_ERR GIT_RP_RC GIT_RP_ERR GIT_HOLD
SRC="${TN_ROOT_PREFIX}${TN_SOURCE_DIR}"
mkdir -p "$SRC/.git"
# Staging goes to the release staging directory (tn_staging_dir), here $T/stg.
# shellcheck disable=SC2034  # read by tn_staging_dir and tn_staging_sweep
TN_RELEASE_STAGING_DIR="$T/stg"
# fresh -- forget the recordings and the installed files; fetch and clone work,
# the fetched ref and a local tag of the same name exist, the blobs are the
# fixture files.
fresh() {
    : > "$REC/git.argv"; : > "$REC/git.proto"; : > "$REC/git.env"; : > "$REC/layout"; : > "$REC/rootw"
    : > "$REC/confirm"; : > "$REC/pf"
    GIT_FETCH_RC=0 GIT_CLONE_RC=0 GIT_BLOBS="$FX" GIT_FETCH_ERR="" GIT_RP_RC="" GIT_RP_ERR="" GIT_HOLD=""
    GIT_REFS="refs/tn-remote-tags/${TAG} refs/tags/${TAG}"
    CONFIRM=no
    rm -rf "${CC:?}"
}
# ft DIR NETWORK [progress-fn] -- tn_chain_configs_from_tag with TMPDIR $T/tmp
# and fd 9 open (the update lock a caller holds); the output goes to $T/out,
# the rc is printed.
ft() {
    ( export TMPDIR="$T/tmp"; tn_chain_configs_from_tag "$@" ) > "$T/out" 2>&1 9> "$T/lock9"
    printf '%s\n' "$?"
}
# pf KIND MSG -- a progress fn: "KIND|MSG" lines in $REC/pf.
pf() { printf '%s|%s\n' "$1" "$2" >> "$REC/pf"; }
# staged -- what the staging directories hold (empty when the helper cleaned up).
staged() {
    local e
    for e in "$T/stg"/* "$T/stg"/.[!.]* "$T/tmp"/* "$T/tmp"/.[!.]*; do
        if [[ -e "$e" || -L "$e" ]]; then printf '%s\n' "${e##*/}"; fi
    done
    return 0
}
# envs VERB -- the git.env lines of VERB, without the verb.
envs() { sed -n "s/^$1 //p" "$REC/git.env" | sort -u; }
# mode_of PATH -- "<mode> <uid>".
mode_of() { stat -c '%a %u' -- "$1" 2>/dev/null; }
# verbs -- the git subcommand of each recorded call, in order.
verbs() { awk '{ i = 1; if ($1 == "-C") i = 3; s = s (NR > 1 ? " " : "") $i } END { print s }' "$REC/git.argv"; }
# moving -- the recorded git subcommands that would move a checkout or a ref.
moving() { verbs | tr ' ' '\n' | grep -E '^(pull|checkout|switch|reset|merge|rebase|clean|submodule|update-ref|tag)$'; }
argv() { cat "$REC/git.argv"; }
sums() { (cd "$1" 2>/dev/null && sha256sum genesis.yaml committee.yaml parameters.yaml 2>&1); }

fresh
check_rc "from_tag: the pinned tag is fetched and read" 0 "$(ft "$SRC" testnet)"
check "from_tag: git runs fetch, one ref check and three blob reads" "fetch rev-parse cat-file cat-file cat-file" "$(verbs)"
check "from_tag: the fetch allows https only" "fetch https" "$(cat "$REC/git.proto")"
check_has "from_tag: the tag is fetched into refs/tn-remote-tags" \
    "-C $SRC fetch --quiet --no-tags origin +refs/tags/${TAG}:refs/tn-remote-tags/${TAG}" "$(argv)"
check_has "from_tag: the files come from the fetched ref, not the local tag" \
    "-C $SRC cat-file blob refs/tn-remote-tags/${TAG}:chain-configs/testnet/committee.yaml" "$(argv)"
check "from_tag: the installed files are the pinned ones" "$(sums "$FX")" "$(sums "$DEST")"
check "from_tag: both directories root 0755" "$CC root 0755
$DEST root 0755" "$(cat "$REC/layout")"
check "from_tag: each file root 0644" "$DEST/genesis.yaml 0644
$DEST/committee.yaml 0644
$DEST/parameters.yaml 0644" "$(cat "$REC/rootw")"
check "from_tag: says what it installed" yes "$(has "Installed the testnet chain configs from ${TAG} into ${DEST}.")"
check "from_tag: the staging directory is removed" "" "$(staged)"

: > "$REC/git.argv"
check_rc "from_tag: files already in place" 0 "$(ft "$T/no-checkout" testnet)"
check "from_tag: in place, no git runs" "" "$(argv)"
check "from_tag: in place, says so" yes "$(has "The pinned testnet chain configs are already in ${DEST}.")"

fresh; GIT_FETCH_RC=1
check_rc "from_tag: offline, the earlier fetch is read" 0 "$(ft "$SRC" testnet)"
check "from_tag: offline, warned" yes \
    "$(has "Could not fetch ${TAG} from origin; reading the testnet chain configs from the local copy of ${TAG}.")"
check_has "from_tag: offline, read from refs/tn-remote-tags" \
    "-C $SRC cat-file blob refs/tn-remote-tags/${TAG}:chain-configs/testnet/genesis.yaml" "$(argv)"
fresh; GIT_FETCH_RC=1; GIT_REFS="refs/tags/${TAG}"
check_rc "from_tag: offline, no earlier fetch: the local tag is read" 0 "$(ft "$SRC" testnet)"
check_has "from_tag: offline, read from refs/tags" \
    "-C $SRC cat-file blob refs/tags/${TAG}:chain-configs/testnet/parameters.yaml" "$(argv)"
check "from_tag: offline, the local tag is read and not moved" "" "$(moving)"
fresh; GIT_FETCH_RC=1; GIT_REFS=""
check_rc "from_tag: offline and no copy of the tag" 2 "$(ft "$SRC" testnet)"
check "from_tag: no copy, says so" yes "$(has "Could not fetch tag ${TAG} from origin, and the checkout does not have it.")"
check "from_tag: no copy, nothing installed" "no" "$([[ -e "$DEST" ]] && echo yes || echo no)"

fresh; mkdir -p "$DEST"; cp "$T/bad"/*.yaml "$DEST/"; GIT_BLOBS="$T/bad2"
check_rc "from_tag: files at the tag that do not match the pins are refused" 1 "$(ft "$SRC" testnet)"
check "from_tag: mismatch, says nothing was installed" yes \
    "$(has "The testnet chain configs at ${TAG} do not match the pins; nothing was installed.")"
check "from_tag: mismatch, the destination is untouched" "$(sums "$T/bad")" "$(sums "$DEST")"
check "from_tag: mismatch, nothing written" "" "$(cat "$REC/layout" "$REC/rootw")"
check "from_tag: mismatch, the staging directory is removed" "" "$(staged)"
fresh; GIT_BLOBS="$T/two"
check_rc "from_tag: a file missing at the tag" 2 "$(ft "$SRC" testnet)"
check "from_tag: missing file named" yes "$(has "${TAG} has no chain-configs/testnet/parameters.yaml.")"
check "from_tag: missing file, nothing written" "" "$(cat "$REC/layout" "$REC/rootw")"

fresh
check_rc "from_tag: not a git checkout" 2 "$(ft "$T/notgit" testnet)"
check "from_tag: not a checkout, says so" yes \
    "$(has "$T/notgit is not a git checkout; the testnet chain configs at ${TAG} cannot be read from it.")"
ln -s "$SRC" "$T/srclink"
check_rc "from_tag: a symlinked checkout is refused" 1 "$(ft "$T/srclink/" testnet)"
check "from_tag: symlink, says so" yes \
    "$(has "$T/srclink must be a directory owned by $(id -un) (not a symlink); nothing was fetched.")"
check "from_tag: refusals run no git" "" "$(argv)"
if [[ "$(id -u)" == 0 ]]; then
    mkdir -p "$T/other/.git"
    chown 65534 "$T/other"
    check_rc "from_tag: another account's checkout is refused" 1 "$(ft "$T/other" testnet)"
    check "from_tag: another account's checkout, no git" "" "$(argv)"
else
    skip "from_tag: another account's checkout is refused" "needs root to chown the fixture"
fi
check_rc "from_tag: mainnet has no tag yet" 1 "$(ft "$SRC" mainnet)"
check "from_tag: mainnet, says so" yes "$(has "mainnet has no pinned chain-config tag; nothing was read.")"
check_rc "from_tag: devnet has no tag" 1 "$(ft "$SRC" devnet)"
check "from_tag: no tag, no git" "" "$(argv)"

# ---- from_tag after verification (V-FIX-S) --------------------------------------------------
# Every git child runs over https only, with fd 9 closed and without the
# caller's GIT_DIR, GIT_WORK_TREE, GIT_INDEX_FILE and GIT_COMMON_DIR; the
# read-only ones without lazy fetch (V-FIX-S-03, -10).
fresh
export GIT_DIR="$T/elsewhere.git" GIT_WORK_TREE="$T" GIT_INDEX_FILE="$T/index" GIT_COMMON_DIR="$T/common"
check_rc "git env: a stray GIT_DIR and friends in the caller's environment: rc 0" 0 "$(ft "$SRC" testnet)"
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
check "git env: fetch: https, nothing inherited, fd 9 closed" \
    "gap=https lazy=unset gitdir=unset worktree=unset index=unset common=unset fd9=closed" "$(envs fetch)"
check "git env: rev-parse: https, no lazy fetch, nothing inherited, fd 9 closed" \
    "gap=https lazy=1 gitdir=unset worktree=unset index=unset common=unset fd9=closed" "$(envs rev-parse)"
check "git env: cat-file: https, no lazy fetch, nothing inherited, fd 9 closed" \
    "gap=https lazy=1 gitdir=unset worktree=unset index=unset common=unset fd9=closed" "$(envs cat-file)"

# The fetch's own reason is in the warning (V-FIX-S-03).
fresh; GIT_FETCH_RC=128; GIT_FETCH_ERR="fatal: couldn't find remote ref refs/tags/${TAG}"
check_rc "fetch reason: origin does not have the tag, the local copy is read" 0 "$(ft "$SRC" testnet pf)"
check "fetch reason: git's reason, not 'Could not reach origin'" \
    "warn|Could not fetch ${TAG} from origin (fatal: couldn't find remote ref refs/tags/${TAG}); reading the testnet chain configs from the local copy of ${TAG}." \
    "$(grep '^warn|' "$REC/pf")"
fresh; GIT_FETCH_RC=128; GIT_REFS=""
GIT_FETCH_ERR="hint: a line before
fatal: unable to access '${TN_REPO}/': Could not resolve host: github.com
Please make sure you have the correct access rights"
check_rc "fetch reason: no copy of the tag" 2 "$(ft "$SRC" testnet pf)"
check "fetch reason: no copy, git's first fatal line in the warning" \
    "warn|Could not fetch tag ${TAG} from origin (fatal: unable to access '${TN_REPO}/': Could not resolve host: github.com), and the checkout does not have it." \
    "$(grep '^warn|' "$REC/pf")"

# git refuses the repository (another account's .git): refused with git's reason.
fresh; GIT_FETCH_RC=128; GIT_RP_RC=128
GIT_FETCH_ERR="fatal: detected dubious ownership in repository at '${SRC}'"
GIT_RP_ERR="fatal: detected dubious ownership in repository at '${SRC}'
To add an exception for this directory, call:

    git config --global --add safe.directory ${SRC}"
check_rc "git cannot read the checkout: refused (rc 1)" 1 "$(ft "$SRC" testnet pf)"
check "git cannot read the checkout: git's reason" \
    "warn|Git cannot read the repository in ${SRC} (fatal: detected dubious ownership in repository at '${SRC}'); nothing was installed." \
    "$(grep '^warn|' "$REC/pf")"
check "git cannot read the checkout: no blob read, nothing written" "fetch rev-parse||" \
    "$(verbs)|$(cat "$REC/layout")|$(cat "$REC/rootw")"

# A mismatch names the file at the tag, not the staging path (V-FIX-S-07).
fresh; GIT_BLOBS="$T/bad2"
check_rc "mismatch named by tag: rc 1" 1 "$(ft "$SRC" testnet pf)"
check "mismatch named by tag: the line" \
    "warn|chain-configs/testnet/committee.yaml at ${TAG}: sha256 $(sha256sum < "$T/bad2/committee.yaml" | cut -d' ' -f1), expected ${TESTNET_COMMITTEE_SHA256} (testnet)." \
    "$(grep -F 'committee.yaml' "$REC/pf")"
check_lacks "mismatch named by tag: no staging path" "$T/stg" "$(cat "$REC/pf" "$T/out")"
check_lacks "mismatch named by tag: no temp path" "$T/tmp" "$(cat "$REC/pf" "$T/out")"
check "tn_chain_configs_check on a directory still names the path" yes \
    "$(tn_chain_configs_check "$T/bad2" testnet pf; grep -qF "warn|$T/bad2/committee.yaml: sha256 " "$REC/pf" && echo yes || echo no)"

# The right files with another mode: reinstalled from there, no git (V-FIX-S-05).
fresh; mkdir -p "$DEST"; cp "$FX"/*.yaml "$DEST/"; chmod 0700 "$CC" "$DEST"; chmod 0600 "$DEST"/*.yaml
check_rc "modes: the pinned files in 0700 directories, 0600 files: rc 0" 0 "$(ft "$T/no-checkout" testnet pf)"
check "modes: no git" "" "$(argv)"
check "modes: reinstalled through the root writers" "$CC root 0755
$DEST root 0755|$DEST/genesis.yaml 0644
$DEST/committee.yaml 0644
$DEST/parameters.yaml 0644" "$(cat "$REC/layout")|$(cat "$REC/rootw")"
check "modes: now 0755 and 0644" "755|755|644|644|644" \
    "$(mode_of "$CC" | cut -d' ' -f1)|$(mode_of "$DEST" | cut -d' ' -f1)|$(mode_of "$DEST/genesis.yaml" | cut -d' ' -f1)|$(mode_of "$DEST/committee.yaml" | cut -d' ' -f1)|$(mode_of "$DEST/parameters.yaml" | cut -d' ' -f1)"
check "modes: the messages" "log|The pinned testnet chain configs are already in ${DEST}.
log|Reinstalled the testnet chain configs in ${DEST} root-owned, directories 0755 and files 0644: their owner or modes were not the ones the install sets." \
    "$(cat "$REC/pf")"
check "modes: still the pinned files, staging removed" "$(sums "$FX")|" "$(sums "$DEST")|$(staged)"
: > "$REC/layout"; : > "$REC/rootw"; : > "$REC/pf"
check_rc "modes: the next run" 0 "$(ft "$T/no-checkout" testnet pf)"
check "modes: the next run finds them in place, writes nothing" \
    "log|The pinned testnet chain configs are already in ${DEST}.||" "$(cat "$REC/pf")|$(cat "$REC/layout")|$(cat "$REC/rootw")"
fresh; mkdir -p "$DEST"; cp "$FX"/*.yaml "$DEST/"; chmod 0775 "$DEST"
check_rc "modes: a group-writable destination with the pinned files: rc 0" 0 "$(ft "$T/no-checkout" testnet)"
check "modes: group-writable, reinstalled 0755" "755 yes" "$(mode_of "$DEST" | cut -d' ' -f1) $(has "Reinstalled the testnet chain configs in ${DEST}")"

# A symlinked destination is refused, not followed (V-FIX-S-05).
fresh; mkdir -p "$CC" "$T/elsewhere"; cp "$FX"/*.yaml "$T/elsewhere/"; ln -s "$T/elsewhere" "$DEST"
check_rc "symlinked destination holding the pinned files: refused (rc 1)" 1 "$(ft "$SRC" testnet pf)"
check "symlinked destination: no git, nothing written, still the symlink" "|||yes" \
    "$(argv)|$(cat "$REC/layout")|$(cat "$REC/rootw")|$([[ -L "$DEST" ]] && echo yes || echo no)"
check "symlinked destination: the message" \
    "warn|${DEST} must be a directory, not a symlink or a file; nothing was installed. Remove it and run again." "$(cat "$REC/pf")"
rm -f "$DEST"
fresh; mkdir -p "$T/root/etc/telcoin" "$T/elsewhere2"; ln -s "$T/elsewhere2" "$CC"
check_rc "symlinked chain-configs directory: refused (rc 1)" 1 "$(ft "$SRC" testnet pf)"
check "symlinked chain-configs directory: no git, the message" \
    "|warn|${CC} must be a directory, not a symlink or a file; nothing was installed. Remove it and run again." \
    "$(argv)|$(cat "$REC/pf")"
rm -f "$CC"

# An entry no install can replace: refused before the first write (V-FIX-S-04).
fresh; mkdir -p "$DEST/committee.yaml"
check_rc "a directory named committee.yaml in the destination: rc 2" 2 "$(ft "$SRC" testnet pf)"
check "entry in the way: no git, nothing written, the destination as it was" "|||committee.yaml" \
    "$(argv)|$(cat "$REC/layout")|$(cat "$REC/rootw")|$(ls -A "$DEST")"
check "entry in the way: the message" \
    "warn|${DEST}/committee.yaml is a symlink or not a regular file; nothing was installed. Remove it and run again." \
    "$(cat "$REC/pf")"

# A git worktree checkout (.git is a file) is read like any checkout (V-FIX-S-08).
fresh; mkdir -p "$T/wt"; printf 'gitdir: %s/.git/worktrees/wt\n' "$SRC" > "$T/wt/.git"
check_rc "worktree: a checkout whose .git is a file is read" 0 "$(ft "$T/wt" testnet)"
check "worktree: fetch and read through git -C" "fetch rev-parse cat-file cat-file cat-file|$(sums "$FX")" \
    "$(verbs)|$(sums "$DEST")"

# The staging directory is tag.<pid>.XXXXXX under the release staging directory,
# so a run killed during the read leaves it where tn_staging_sweep (the EXIT
# traps, or the next run's stale sweep) removes it (V-FIX-S-09).
# waitfor FILE -- wait up to 30 s for FILE to exist.
waitfor() { local n=0; while [[ ! -e "$1" && $n -lt 300 ]]; do sleep 0.1; n=$((n + 1)); done; }
fresh; GIT_HOLD="$REC/hold"; : > "$GIT_HOLD"; rm -f "$REC/held" "$REC/released"
( export TMPDIR="$T/tmp"; tn_chain_configs_from_tag "$SRC" testnet ) > "$T/out" 2>&1 &
kpid=$!
waitfor "$REC/held"
kill -TERM "$kpid" 2>/dev/null
krc=0; wait "$kpid" || krc=$?
left="$(ls -A "$T/stg")"
rm -f "$GIT_HOLD"; GIT_HOLD=""
waitfor "$REC/released"
check_rc "kill: a SIGTERM to the shell running the helper during the read ends it" 143 "$krc"
check "kill: what is left is tag.<pid>.* in the release staging directory" yes \
    "$(if [[ "$left" == "tag.$$."* ]]; then echo yes; else echo "no: stg [${left}] tmp [$(ls -A "$T/tmp")]"; fi)"
tn_staging_sweep
check "kill: tn_staging_sweep removes it" "" "$(ls -A "$T/stg")"
rm -rf "${T:?}/tmp"; mkdir -p "$T/tmp"
fresh; chmod 0755 "$T/stg"
check_rc "staging: the release staging directory unusable (not 0700): mktemp -d instead, rc 0" 0 "$(ft "$SRC" testnet)"
chmod 0700 "$T/stg"
check "staging: unusable release staging directory, nothing left" "" "$(staged)"
fresh
VLS0="$([[ -e /var/lib/telcoin-staging ]] && echo present || echo absent)"
# shellcheck disable=SC2034  # read by _tn_chain_configs_stage
check_rc "staging under TN_ROOT_PREFIX without TN_RELEASE_STAGING_DIR: rc 0" 0 "$(TN_RELEASE_STAGING_DIR=""; ft "$SRC" testnet)"
check "staging under TN_ROOT_PREFIX: nothing made outside the prefix, nothing left" "${VLS0}|" \
    "$([[ -e /var/lib/telcoin-staging ]] && echo present || echo absent)|$(staged)"

# ---- ensure_chain_configs_available -------------------------------------------------------
# en NETWORK [GENESIS_DIR] [progress-fn] -- ensure_chain_configs_available in a
# subshell; the rc is printed only when it returned (an exit prints nothing).
en() {
    : > "$REC/ensure"
    ( export TMPDIR="$T/tmp"
      TN_GENESIS_DIR="${2:-}" ensure_chain_configs_available "$1" "${3:-}"; printf '%s\n' "$?" > "$REC/ensure" ) > "$T/out" 2>&1
    cat "$REC/ensure"
}

fresh
check_rc "ensure: testnet with a checkout gets the files at the tag" 0 "$(en testnet)"
check "ensure: the checkout is not moved" "" "$(moving)"
check "ensure: testnet installs the pinned files" "$(sums "$FX")" "$(sums "$DEST")"
check "ensure: says the pinned directory matches" yes "$(has "Chain configs in ${DEST} match the testnet pins")"
check "ensure: no prompt with a checkout" "" "$(cat "$REC/confirm")"
: > "$REC/git.argv"
check_rc "ensure: second run" 0 "$(en testnet)"
check "ensure: second run, no git" "" "$(argv)"
mv "$SRC" "$T/src.away"
check_rc "ensure: no checkout, files in place" 0 "$(en testnet)"
check "ensure: no checkout, files in place: no prompt" "" "$(cat "$REC/confirm")"
check "ensure: no checkout, files in place: no git" "" "$(argv)"

fresh
check_rc "ensure: no checkout, clone declined" 0 "$(en testnet)"
check "ensure: declined, asked once" "asked" "$(cat "$REC/confirm")"
check "ensure: declined, the skip is said" yes "$(has "Skipped. You will need to provide chain-config files manually")"
check "ensure: declined, no git" "" "$(argv)"
fresh; CONFIRM=yes; GIT_CLONE_RC=128
check_rc "ensure: a failed clone returns 2 (no exit)" 2 "$(en testnet)"
check "ensure: failed clone, says so" yes "$(has "Clone failed. Check your internet connection.")"
check "ensure: failed clone, the manual command" yes "$(has "Manual clone: git clone --branch ${TAG} ${TN_REPO} ${SRC}")"
check "ensure: the clone is https, at the tag, without submodules" \
    "clone --quiet --branch ${TAG} -- ${TN_REPO} ${SRC}" "$(argv)"
fresh; CONFIRM=yes
check_rc "ensure: no checkout, clone accepted" 0 "$(en testnet)"
check "ensure: clone, then fetch and read" "clone fetch rev-parse cat-file cat-file cat-file" "$(verbs)"
check "ensure: the clone and the fetch allow https only" "clone https
fetch https" "$(cat "$REC/git.proto")"
check "ensure: cloned, the pinned files installed" "$(sums "$FX")" "$(sums "$DEST")"
rm -rf "${SRC:?}"
mv "$T/src.away" "$SRC"

fresh; GIT_BLOBS="$T/bad2"
check_rc "ensure: files at the tag that do not match are refused" 1 "$(en testnet)"
fresh; GIT_FETCH_RC=1; GIT_REFS=""
check_rc "ensure: the tag cannot be had" 2 "$(en testnet)"
fresh
check_rc "ensure: a --genesis-dir that does not match is refused" 1 "$(en testnet "$T/bad")"
check_rc "ensure: a pinned --genesis-dir passes" 0 "$(en testnet "$T/good")"
check "ensure: --genesis-dir, no git" "" "$(argv)"
check "ensure: --genesis-dir, nothing installed" "no" "$([[ -e "$DEST" ]] && echo yes || echo no)"
fresh
check_rc "ensure: mainnet refused while unpinned" 1 "$(en mainnet)"
check "ensure: mainnet runs no git" "" "$(argv)"
check "ensure: mainnet, the checkout is used as published" yes \
    "$(has "Repository present; mainnet chain configs are used as published (no pull).")"
check "ensure: mainnet, no prompt" "" "$(cat "$REC/confirm")"
fresh
check_rc "ensure: devnet with a checkout" 0 "$(en devnet)"
check "ensure: devnet still pulls --ff-only" yes "$(grep -q "^-C $SRC pull --ff-only\$" "$REC/git.argv" && echo yes || echo no)"
check_rc "ensure: unknown network refused" 1 "$(en foo)"

# ---- ensure after verification (V-FIX-S) --------------------------------------------------
mv "$SRC" "$T/src.keep"
# A failed clone's reason reaches the progress fn (--json), V-FIX-S-01.
fresh; CONFIRM=yes; GIT_CLONE_RC=128
check_rc "ensure with a progress fn: a failed clone returns 2" 2 "$(en testnet "" pf)"
check "ensure with a progress fn: the reason and the manual command reach it" \
    "warn|Clone failed. Check your internet connection.
warn|Manual clone: git clone --branch ${TAG} ${TN_REPO} ${SRC}" "$(grep '^warn|' "$REC/pf")"
fresh; CONFIRM=yes; GIT_CLONE_RC=128
check_rc "ensure devnet with a progress fn: a failed clone returns 2" 2 "$(en devnet "" pf)"
check "ensure devnet with a progress fn: the manual command reaches it" yes \
    "$(grep -qxF "warn|Manual clone: git clone ${TN_REPO} ${SRC}" "$REC/pf" && echo yes || echo no)"
fresh; CONFIRM=yes; GIT_CLONE_RC=128
check_rc "ensure without a progress fn: a failed clone returns 2" 2 "$(en testnet)"
check "ensure without a progress fn: printed as an error, as before" "yes yes" \
    "$(has "[ERROR]") $(has "->  Manual clone: git clone --branch ${TAG} ${TN_REPO} ${SRC}")"
# A source directory in the way is refused before the question (V-FIX-S-08).
fresh; CONFIRM=yes; mkdir -p "$SRC"; printf 'x\n' > "$SRC/README"
check_rc "ensure: a non-empty source directory without .git: rc 1" 1 "$(en testnet "" pf)"
check "ensure: not a checkout: no prompt, no git" "|" "$(cat "$REC/confirm")|$(argv)"
check "ensure: not a checkout: the message" \
    "warn|${SRC} exists but is not a git checkout; move it aside first." "$(grep '^warn|' "$REC/pf")"
fresh; CONFIRM=yes
check_rc "ensure devnet: a non-empty source directory without .git: rc 1, no prompt" "1 " "$(en devnet "" pf) $(cat "$REC/confirm")"
rm -rf "${SRC:?}"; mkdir -p "$SRC"
fresh; CONFIRM=yes
check_rc "ensure: an empty source directory is cloned into" 0 "$(en testnet)"
check "ensure: empty source directory: asked, cloned, read" "asked|clone fetch rev-parse cat-file cat-file cat-file" \
    "$(cat "$REC/confirm")|$(verbs)"
rm -rf "${SRC:?}"; mkdir -p "$SRC"; printf 'gitdir: %s/.git/worktrees/src\n' "$T/src.keep" > "$SRC/.git"
fresh; CONFIRM=yes
check_rc "ensure: a worktree checkout (.git a file) is read, not cloned" 0 "$(en testnet)"
check "ensure: worktree: no prompt, fetch and read" "|fetch rev-parse cat-file cat-file cat-file" \
    "$(cat "$REC/confirm")|$(verbs)"
# An entry in the way of the install is refused before the question (V-FIX-S-04).
rm -rf "${SRC:?}"
fresh; CONFIRM=yes; mkdir -p "$DEST/committee.yaml"
check_rc "ensure: an entry in the destination, no checkout: rc 2" 2 "$(en testnet "" pf)"
check "ensure: entry in the way: no prompt, no git" "|" "$(cat "$REC/confirm")|$(argv)"
mv "$T/src.keep" "$SRC"
fresh

# ---- step_write_config: check before copy, no working-directory search ------------------
tn_as_service_user() { printf '%s\n' "$*" >> "$REC/as_user"; "$@"; }
write_advertised_name() { :; }
SERVICE_USER="$(id -un)"
DATA_DIR="$T/data"
CONFIG_DIR="$T/conf"
NETWORK=testnet
JSON_MODE=true
json_setup_fds() { :; }
exec 3>/dev/null
# write RUNDIR GENESIS_DIR -- run step_write_config in a subshell from RUNDIR.
write() {
    rm -rf "${T:?}/data/genesis" "$T/data/parameters.yaml"
    : > "$REC/as_user"
    ( cd "$1" && TN_GENESIS_DIR="$2" step_write_config ) > "$T/out" 2>&1
    printf '%s\n' "$?"
}
rm -rf "$SRC/chain-configs"

check_rc "write: a tampered --genesis-dir stops setup" 1 "$(write "$T" "$T/bad")"
check "write: tampered, nothing copied" "no" "$([[ -e "$T/data/genesis/genesis.yaml" ]] && echo yes || echo no)"
check "write: tampered, no cp ran" "" "$(grep '^cp ' "$REC/as_user")"
check_rc "write: the pinned files are copied" 0 "$(write "$T" "$T/good")"
check "write: genesis copied" "$TESTNET_GENESIS_SHA256" "$(sha256sum < "$T/data/genesis/genesis.yaml" | cut -d' ' -f1)"
check "write: parameters copied" "$TESTNET_PARAMETERS_SHA256" "$(sha256sum < "$T/data/parameters.yaml" | cut -d' ' -f1)"
cp "$FX"/*.yaml "$T/cwd/chain-configs/testnet/"
check_rc "write: ./chain-configs in the working directory is not used" 1 "$(write "$T/cwd" "")"
check "write: cwd files not copied" "no" "$([[ -e "$T/data/genesis/genesis.yaml" ]] && echo yes || echo no)"

# ---- step_write_config: the pinned chain-config directory ---------------------------------
# CONFIG_DIR is $T/conf here, and the pinned directory follows it. step_write_config
# searches the checkout at TN_SOURCE_DIR without TN_ROOT_PREFIX; swc is the same
# function with those entries under the prefix, so the checkout it searches is $SRC,
# the one ensure_chain_configs_available reads.
PIN="$T/root$T/conf/chain-configs/testnet"
CHK="$SRC/chain-configs/testnet"
check "write: the pinned directory follows CONFIG_DIR" "$PIN" "$(tn_chain_configs_dir testnet)"
eval "$(declare -f step_write_config | sed -e '1s/^step_write_config /swc /' \
    -e 's|"\${TN_SOURCE_DIR}/chain-configs/|"${TN_ROOT_PREFIX}${TN_SOURCE_DIR}/chain-configs/|' \
    -e 's|"/opt/telcoin-source/chain-configs/|"${TN_ROOT_PREFIX}/opt/telcoin-source/chain-configs/|')"
# wr GENESIS_DIR -- swc in a subshell from $T; the rc is printed.
wr() {
    rm -rf "${T:?}/data/genesis" "$T/data/parameters.yaml"
    : > "$REC/as_user"
    ( cd "$T" && TN_GENESIS_DIR="$1" swc ) > "$T/out" 2>&1
    printf '%s\n' "$?"
}
# copied -- the sha256 of the three files step_write_config put in the data dir.
copied() {
    local f got
    for f in "$T/data/genesis/genesis.yaml" "$T/data/genesis/committee.yaml" "$T/data/parameters.yaml"; do
        got="$(sha256sum < "$f" 2>/dev/null)" || got="missing"
        printf '%s\n' "${got%% *}"
    done
}
PINS="$TESTNET_GENESIS_SHA256
$TESTNET_COMMITTEE_SHA256
$TESTNET_PARAMETERS_SHA256"

# The bug: the checkout is on a default branch whose committee.yaml moved on.
fresh
mkdir -p "$CHK"
cp "$T/bad2"/*.yaml "$CHK/"
check_rc "write: no pinned files, the diverged checkout is refused" 1 "$(wr "")"
check "write: diverged checkout, refused before the copy" yes \
    "$(has "The chain configs in ${CHK} do not match the testnet pins")"
check_rc "write: ensure reads the files at the tag into the pinned directory" 0 "$(en testnet)"
check "write: ensure, the pinned files installed" "$(sums "$FX")" "$(sums "$PIN")"
check "write: ensure, the checkout's files are left as they are" "$(sums "$T/bad2")" "$(sums "$CHK")"
check_rc "write: the pinned directory wins over the diverged checkout" 0 "$(wr "")"
check "write: diverged checkout, found in the pinned directory" yes "$(has "Found chain-configs at: ${PIN}")"
check "write: the copies in the data dir have the pinned hashes" "$PINS" "$(copied)"
rm -rf "${SRC:?}/chain-configs"
check_rc "write: the pinned directory is used when no --genesis-dir is given" 0 "$(wr "")"
check "write: no --genesis-dir, found in the pinned directory" yes "$(has "Found chain-configs at: ${PIN}")"
check "write: no --genesis-dir, the copies have the pinned hashes" "$PINS" "$(copied)"
check_rc "write: a tampered --genesis-dir wins over the pinned directory" 1 "$(wr "$T/bad")"
check "write: tampered --genesis-dir, it is what was checked" yes \
    "$(has "The chain configs in $T/bad do not match the testnet pins")"
check "write: tampered --genesis-dir, nothing copied" "no" "$([[ -e "$T/data/genesis/genesis.yaml" ]] && echo yes || echo no)"
check_rc "write: a pinned --genesis-dir with the pinned directory present" 0 "$(wr "$T/good")"
check "write: --genesis-dir comes first" yes "$(has "Found chain-configs at: $T/good")"

# Nothing anywhere: the --json run stops, and the hint names the tag to copy from.
rm -rf "${T:?}/root$T/conf/chain-configs"
check_rc "write: nothing found stops a --json run" 1 "$(wr "")"
check "write: nothing found, no prompt" yes "$(has "Chain config files missing and cannot prompt in non-interactive mode.")"
check "write: nothing found, the hint names the pinned tag" yes \
    "$(has "https://github.com/Telcoin-Association/telcoin-network/tree/${TAG}/chain-configs/testnet/")"
check_lacks "write: nothing found, the testnet hint does not name main" "tree/main" "$(cat "$T/out")"
# hint -- the four lines under the not-found warning.
hint() { grep -A 4 -F -- "Chain config files not found automatically." "$T/out" | tail -n 4; }
check "write: nothing found, the hint names the tag, the reader and --genesis-dir <dir>" \
"  ->  genesis.yaml, committee.yaml and parameters.yaml are in chain-configs/testnet/ at ${TAG}:
  ->    https://github.com/Telcoin-Association/telcoin-network/tree/${TAG}/chain-configs/testnet/
  ->  Copy the three raw files, readable by ${SERVICE_USER}, into $T/conf/chain-configs/testnet/,
  ->  or run setup again with --genesis-dir <dir>, any directory that holds them." "$(hint)"
NETWORK=mainnet
check_rc "write: mainnet, nothing found" 1 "$(wr "")"
check "write: mainnet has no tag, the hint names main" yes \
    "$(has "https://github.com/Telcoin-Association/telcoin-network/tree/main/chain-configs/mainnet/")"
check "write: mainnet has no tag, the files are at main" yes \
    "$(has "genesis.yaml, committee.yaml and parameters.yaml are in chain-configs/mainnet/ at main:")"
# Devnet has no tag: its chain-configs directory is not put ahead of the checkout.
NETWORK=devnet
DEVPIN="$(tn_chain_configs_dir devnet)"
mkdir -p "$DEVPIN" "$SRC/chain-configs/devnet"
cp "$FX"/*.yaml "$DEVPIN/"
cp "$FX"/*.yaml "$SRC/chain-configs/devnet/"
check_rc "write: devnet copies" 0 "$(wr "")"
check "write: devnet, the checkout comes before the chain-configs directory" yes \
    "$(has "Found chain-configs at: $SRC/chain-configs/devnet")"
rm -rf "${T:?}/root$T/conf/chain-configs" "${SRC:?}/chain-configs"
NETWORK=testnet

# Nothing anywhere in a plain run: the prompt reads no answer, and setup stops naming
# each directory it searched once, in search order.
rm -rf "${T:?}/conf/chain-configs"
r="$( (cd "$T" || exit; JSON_MODE=false; TN_GENESIS_DIR="$T/conf/chain-configs/testnet" swc) < /dev/null > "$T/out" 2>&1; echo "$?")"
check "write: plain run, nothing found: rc 1, each directory named once, in search order" "1 yes" \
    "$r $(has "Chain config files not found in $T/conf/chain-configs/testnet ${PIN} ${CHK}.")"
# As on a host: no prefix, so the pinned directory is CONFIG_DIR/chain-configs/testnet,
# and TN_SOURCE_DIR is /opt/telcoin-source.
if [[ -e /opt/telcoin-source ]]; then
    skip "write: host paths, each directory named once" "/opt/telcoin-source exists on this machine"
else
    ( cd "$T" || exit; JSON_MODE=false; TN_ROOT_PREFIX=""; TN_GENESIS_DIR="" step_write_config ) < /dev/null > "$T/out" 2>&1
    check "write: host paths, each directory named once" yes \
        "$(has "Chain config files not found in $T/conf/chain-configs/testnet /opt/telcoin-source/chain-configs/testnet.")"
fi

NETWORK=foo
check_rc "write: unknown network stops setup" 1 "$(write "$T" "$T/good")"
check "write: unknown network message" yes "$(has "no chain-configs for network foo")"
NETWORK=testnet

# ---- step_create_infrastructure: a chain-config failure, worded by its rc ---------------
# The steps before the chain configs are stand-ins. infra [GENESIS_DIR] runs the step
# as a --json run from $T: stdout and stderr go to $T/out, the JSON stream (fd 3) to
# $T/json; the rc is printed.
infra() {
    : > "$T/json"
    rm -rf "${T:?}/root$T/conf/chain-configs"
    ( export TMPDIR="$T/tmp"
      tn_service_user_ok() { return 0; }
      tn_testnet_addons_present() { return 1; }
      rm() { case "$*" in *.pwd.lock*) return 0 ;; esac; command rm "$@"; }
      create_service_user() { :; }
      create_directories() { return 0; }
      tn_install_logrotate() { return 0; }
      write_node_meta() { :; }
      write_node_meta_runner() { :; }
      verify_binary() { :; }
      prepare_node_extra_flags() { :; }
      exec 3> "$T/json"
      cd "$T" || exit
      TN_GENESIS_DIR="${1:-}" step_create_infrastructure ) > "$T/out" 2>&1
    printf '%s\n' "$?"
}
# ends RC MSG -- how a --json run that setup_fail stopped ends: RC, then the error and
# the done event, both with MSG. last -- infra's RC and the stream's last two lines.
ends() { printf '%s\n{"event":"error","msg":"%s"}\n{"event":"done","ok":false,"msg":"%s"}\n' "$1" "$2" "$2"; }
last() { printf '%s\n' "$1"; tail -n 2 "$T/json"; }
# before CAUSE LINE -- yes when the JSON stream has a log event holding CAUSE above the
# first line holding LINE.
before() {
    local line n=0 ia=0 ib=0
    while IFS= read -r line; do
        n=$((n + 1))
        if [[ $ia -eq 0 && "$line" == *'"event":"log"'* && "$line" == *"$1"* ]]; then ia=$n; fi
        if [[ $ib -eq 0 && "$line" == *"$2"* ]]; then ib=$n; fi
    done < "$T/json"
    [[ $ia -gt 0 && $ib -gt 0 && $ia -lt $ib ]] && echo yes || echo no
}
REFUSED="The testnet chain configs were refused (see above); nothing was copied."
REFUSED_EV="{\"event\":\"error\",\"msg\":\"${REFUSED}\"}"

fresh
mv "$SRC" "$T/src.real"
ln -s "$T/src.real" "$SRC"
check "infra: a symlinked checkout ends the run as refused" "$(ends 1 "$REFUSED")" "$(last "$(infra)")"
check "infra: symlinked checkout, the cause is a log event before the error" yes \
    "$(before "WARNING: ${SRC} must be a directory owned by $(id -un) (not a symlink); nothing was fetched." "$REFUSED_EV")"
check_lacks "infra: symlinked checkout, no claim that files were compared" "not the pinned ones" "$(cat "$T/out" "$T/json")"
rm -f "$SRC"
mv "$T/src.real" "$SRC"
if [[ "$(id -u)" == 0 ]]; then
    fresh
    chown 65534 "$SRC"
    check "infra: another account's checkout ends the run as refused" "$(ends 1 "$REFUSED")" "$(last "$(infra)")"
    check "infra: another account's checkout, the cause is a log event before the error" yes \
        "$(before "WARNING: ${SRC} must be a directory owned by $(id -un) (not a symlink); nothing was fetched." "$REFUSED_EV")"
    chown "$(id -u)" "$SRC"
else
    skip "infra: another account's checkout ends the run as refused" "needs root to chown the fixture"
fi
fresh; GIT_BLOBS="$T/bad2"
check "infra: files at the tag that do not match end the run as refused" "$(ends 1 "$REFUSED")" "$(last "$(infra)")"
check "infra: mismatch, the cause is a log event before the error" yes \
    "$(before "WARNING: The testnet chain configs at ${TAG} do not match the pins; nothing was installed." "$REFUSED_EV")"
fresh
check "infra: a --genesis-dir that does not match ends the run as refused" "$(ends 1 "$REFUSED")" "$(last "$(infra "$T/bad")")"
check "infra: --genesis-dir, the cause is a log event before the error" yes \
    "$(before "WARNING: $T/bad/genesis.yaml: sha256 " "$REFUSED_EV")"
fresh; NETWORK=mainnet
MN_REFUSED="The mainnet chain configs were refused (see above); nothing was copied."
check "infra: mainnet without pins ends the run as refused" "$(ends 1 "$MN_REFUSED")" "$(last "$(infra)")"
check "infra: mainnet, the cause is a log event before the error" yes \
    "$(before "WARNING: mainnet has no pinned sha256 for genesis.yaml yet" "{\"event\":\"error\",\"msg\":\"${MN_REFUSED}\"}")"
NETWORK=testnet
# rc 2 keeps its line.
fresh; GIT_FETCH_RC=1; GIT_REFS=""
NOGET="Could not get the testnet chain configs (see above)."
check "infra: the tag cannot be had: the rc-2 line" "$(ends 1 "$NOGET")" "$(last "$(infra)")"
check "infra: the tag cannot be had, the cause is a log event before the error" yes \
    "$(before "WARNING: Could not fetch tag ${TAG} from origin, and the checkout does not have it." "{\"event\":\"error\",\"msg\":\"${NOGET}\"}")"
fresh
finish
