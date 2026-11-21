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
    "$T/cwd/chain-configs/testnet"
export REC
# The git stand-in records its argv, and for fetch and clone the protocols
# GIT_ALLOW_PROTOCOL allows (git.proto). fetch and clone exit GIT_FETCH_RC and
# GIT_CLONE_RC (a clone that works makes DIR/.git); rev-parse --verify REF
# succeeds for the refs listed in GIT_REFS; cat-file blob REF:PATH prints the
# file of that name from GIT_BLOBS. Anything else exits 0.
cat > "$T/bin/git" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$REC/git.argv"
if [ "$1" = -C ]; then shift 2; fi
last=""
for a in "$@"; do last="$a"; done
case "$1" in
    fetch|clone) printf '%s %s\n' "$1" "${GIT_ALLOW_PROTOCOL:-any}" >> "$REC/git.proto" ;;
esac
case "$1" in
    fetch) exit "${GIT_FETCH_RC:-0}" ;;
    clone)
        [ "${GIT_CLONE_RC:-0}" = 0 ] || exit "$GIT_CLONE_RC"
        mkdir -p "$last/.git"
        exit 0
        ;;
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
# root writers are stand-ins that record their arguments.
_tn_root_layout_dir() { printf '%s\n' "$*" >> "$REC/layout"; mkdir -p -- "$1"; }
tn_write_root_file() { printf '%s %s\n' "$1" "$2" >> "$REC/rootw"; cat > "$1"; }
confirm() { printf 'asked\n' >> "$REC/confirm"; [[ "${CONFIRM:-no}" == yes ]]; }
export GIT_FETCH_RC GIT_CLONE_RC GIT_REFS GIT_BLOBS
SRC="${TN_ROOT_PREFIX}${TN_SOURCE_DIR}"
mkdir -p "$SRC/.git"
# fresh -- forget the recordings and the installed files; fetch and clone work,
# the fetched ref and a local tag of the same name exist, the blobs are the
# fixture files.
fresh() {
    : > "$REC/git.argv"; : > "$REC/git.proto"; : > "$REC/layout"; : > "$REC/rootw"; : > "$REC/confirm"
    GIT_FETCH_RC=0 GIT_CLONE_RC=0 GIT_BLOBS="$FX"
    GIT_REFS="refs/tn-remote-tags/${TAG} refs/tags/${TAG}"
    CONFIRM=no
    rm -rf "${CC:?}"
}
# ft DIR NETWORK -- tn_chain_configs_from_tag with staging under $T/tmp; the
# output goes to $T/out, the rc is printed.
ft() {
    ( export TMPDIR="$T/tmp"; tn_chain_configs_from_tag "$@" ) > "$T/out" 2>&1
    printf '%s\n' "$?"
}
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
check "from_tag: the staging directory is removed" "" "$(ls -A "$T/tmp")"

: > "$REC/git.argv"
check_rc "from_tag: files already in place" 0 "$(ft "$T/no-checkout" testnet)"
check "from_tag: in place, no git runs" "" "$(argv)"
check "from_tag: in place, says so" yes "$(has "The pinned testnet chain configs are already in ${DEST}.")"

fresh; GIT_FETCH_RC=1
check_rc "from_tag: offline, the earlier fetch is read" 0 "$(ft "$SRC" testnet)"
check "from_tag: offline, warned" yes \
    "$(has "Could not reach origin; reading the testnet chain configs from the local copy of ${TAG}.")"
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
check "from_tag: mismatch, the staging directory is removed" "" "$(ls -A "$T/tmp")"
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

# ---- ensure_chain_configs_available -------------------------------------------------------
# en NETWORK [GENESIS_DIR] -- ensure_chain_configs_available in a subshell; the
# rc is printed only when it returned (an exit prints nothing).
en() {
    : > "$REC/ensure"
    ( export TMPDIR="$T/tmp"
      TN_GENESIS_DIR="${2:-}" ensure_chain_configs_available "$1"; printf '%s\n' "$?" > "$REC/ensure" ) > "$T/out" 2>&1
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
NETWORK=mainnet
check_rc "write: mainnet, nothing found" 1 "$(wr "")"
check "write: mainnet has no tag, the hint names main" yes \
    "$(has "https://github.com/Telcoin-Association/telcoin-network/tree/main/chain-configs/mainnet/")"
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

NETWORK=foo
check_rc "write: unknown network stops setup" 1 "$(write "$T" "$T/good")"
check "write: unknown network message" yes "$(has "no chain-configs for network foo")"
finish
