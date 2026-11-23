#!/usr/bin/env bash
# =============================================================================
# tools/tests/chain_configs_tag_test.sh -- the chain configs at the pinned tag,
# with real git: tn_chain_configs_from_tag and ensure_chain_configs_available
# against a local bare origin whose tag (TESTNET_CHAIN_CONFIGS_TAG) holds the
# fixture files of genesis.d/testnet under chain-configs/testnet while its main
# has moved on with another committee.yaml (the shape of the 2026-11-14 break).
# The three files are read from the tag into tn_chain_configs_dir and the
# checkout (on main, dirty, detached at another tag) is never moved; a second
# run, a network without a tag and --genesis-dir run no git; an unreachable
# origin falls back to the local copy of the tag; a tag whose files differ from
# the pins installs nothing; the clone ensure makes is at the tag, without
# submodules, and a failed clone returns 2 instead of exiting. After
# verification (V-FIX-S): git's own reason in the warnings, a repository git
# cannot read refused, a stray GIT_DIR ignored, every git child with https only,
# fd 9 closed and (read-only) no lazy fetch, a destination with the right files
# but another owner or mode reinstalled, a symlinked destination refused, an
# entry in the way refused before any write, a mismatch named by tag, a git
# worktree read, a source path in the way refused before the clone question,
# and staging under the release staging directory.
#
# A git wrapper on PATH logs every call (GIT_ALLOW_PROTOCOL, whether fd 9 is
# open, argv), drops GIT_ALLOW_PROTOCOL so the file transport works (the library
# allows https only) and points TN_REPO at the local origin (url.insteadOf).
# As root with GNU mv -T the files go through the real root writers under a
# root-only directory in /root; elsewhere recording stand-ins write them and
# the owner and mode checks are skipped. Without git the cases that need it
# are skipped (the bash:3.2 image).
#
#   bash tools/tests/chain_configs_tag_test.sh
#
# Maintainer tooling: not tracked by update-scripts.sh, no .sha256 sidecar.
# bash 3.2 safe.
# =============================================================================
# shellcheck source=tools/tests/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
T="$TN_TEST_TMP"
RB=""
FX="$TN_TEST_DIR/genesis.d/testnet"
umask 022
mkdir -p "$T/bin" "$T/stg" "$T/pfx" "$T/notgit" "$T/bad"
chmod 0700 "$T/stg"
TN_ROOT_PREFIX="$T/pfx"
eval "$(tn_test_source_common)"
# The helpers stage under the release staging directory (tn_staging_dir).
# shellcheck disable=SC2034  # read by tn_staging_dir
TN_RELEASE_STAGING_DIR="$T/stg"
trap 'tn_test_cleanup; if [[ -n "$RB" ]]; then rm -rf "${RB:?}"; fi' EXIT
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX CONFIG_DIR TN_GENESIS_DIR TN_ASSUME_YES

# --- the real root writers where this run can use them -----------------------------
IS_ROOT=0
[[ "$(id -u)" == 0 ]] && IS_ROOT=1
: > "$T/probe1"
HAVE_MV_T=0
"$(type -P mv)" -f -T -- "$T/probe1" "$T/probe2" 2>/dev/null && HAVE_MV_T=1
ROOT_OK=0
if [[ $IS_ROOT == 1 && $HAVE_MV_T == 1 ]]; then
    RB="$(mktemp -d /root/.tn-cctag.XXXXXX 2>/dev/null)" || RB=""
    if [[ -n "$RB" ]]; then
        chmod 0700 "$RB"
        if tn_root_dir_ok "$RB"; then
            ROOT_OK=1
        else
            rm -rf "${RB:?}"
            RB=""
        fi
    fi
fi
NO_REAL_WHY="not root"
[[ $IS_ROOT == 1 ]] && NO_REAL_WHY="no mv -T, or no root-only temp dir under /root"
if [[ $ROOT_OK == 1 ]]; then
    TN_ROOT_PREFIX="$RB/pfx"
    mkdir -p "$TN_ROOT_PREFIX"
    printf 'note: the real root writers run (prefix %s)\n' "$TN_ROOT_PREFIX"
else
    printf 'note: recording stand-ins replace the root writers (%s)\n' "$NO_REAL_WHY"
fi
PFX="$TN_ROOT_PREFIX"
TAG="$TESTNET_CHAIN_CONFIGS_TAG"
D="$(tn_chain_configs_dir testnet)"
CC="${D%/*}"

# The writers record each call ("layout DIR GROUP MODE", "write DEST MODE file|pipe")
# in $WL, then run the real one (ROOT_OK) or a stand-in that writes as this
# account. T_FAIL_WRITE=<file name> makes that file's write fail (rc 2).
WL="$T/wr.log"
T_FAIL_WRITE=""
eval "$(declare -f tn_write_root_file | sed '1s/^tn_write_root_file /_t_real_write_root_file /')"
eval "$(declare -f _tn_root_layout_dir | sed '1s/^_tn_root_layout_dir /_t_real_root_layout_dir /')"
tn_write_root_file() {
    local how=file tmp
    [[ -p /dev/stdin ]] && how=pipe
    printf 'write %s %s %s\n' "${1:-}" "${2:-}" "$how" >> "$WL"
    if [[ -n "$T_FAIL_WRITE" && "${1:-}" == */"$T_FAIL_WRITE" ]]; then
        cat > /dev/null
        return 2
    fi
    if [[ $ROOT_OK == 1 ]]; then
        _t_real_write_root_file "$@"
        return
    fi
    if [[ -L "$1" || -d "$1" ]]; then
        return 1
    fi
    tmp="$(mktemp "${1%/*}/.tn.XXXXXX")" || return 2
    if ! cat > "$tmp" || ! chmod "$2" "$tmp" || ! mv -f "$tmp" "$1"; then
        rm -f -- "$tmp"
        return 2
    fi
    return 0
}
_tn_root_layout_dir() {
    printf 'layout %s %s %s\n' "${1:-}" "${2:-}" "${3:-}" >> "$WL"
    if [[ $ROOT_OK == 1 ]]; then
        _t_real_root_layout_dir "$@"
        return
    fi
    [[ -L "$1" ]] && return 1
    mkdir -p -- "$1" && chmod "$3" "$1"
}

# --- git on PATH: a logger in front of the real git ---------------------------------
REAL_GIT="$(command -v git 2>/dev/null || true)"
ORIG_PATH="$PATH"
GL="$T/git.log"
GE="$T/git.env"
O="$T/origin.git"
cat > "$T/bin/git" <<SHIM
#!/bin/sh
fd9=closed
if ( true >&9 ) 2>/dev/null; then fd9=open; fi
printf '%s\n' "gap=\${GIT_ALLOW_PROTOCOL-unset} fd9=\$fd9 \$*" >> "$GL"
v="\$1"
[ "\$v" = -C ] && v="\$3"
printf '%s gap=%s lazy=%s gitdir=%s worktree=%s fd9=%s\n' "\$v" "\${GIT_ALLOW_PROTOCOL-unset}" \
    "\${GIT_NO_LAZY_FETCH-unset}" "\${GIT_DIR-unset}" "\${GIT_WORK_TREE-unset}" "\$fd9" >> "$GE"
unset GIT_ALLOW_PROTOCOL
exec "${REAL_GIT:-/nonexistent/git}" -c "url.${O}.insteadOf=${TN_REPO}" -c http.proxy=http://127.0.0.1:9 "\$@"
SHIM
chmod 0755 "$T/bin/git"
PATH="$T/bin:$PATH"
: > "$T/gitconfig"
GIT_CONFIG_GLOBAL="$T/gitconfig"
GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM
# fd 9 stands for the update lock a caller holds; git children must not get it.
exec 9> "$T/lock9"

PF="$T/pf.log"
CL="$T/confirm.log"
# pf KIND MSG -- the progress fn. With PF_SNOOP=1 it also notes how many
# entries the staging area holds while the helper runs.
PF_SNOOP=0
pf() {
    printf '%s|%s\n' "$1" "$2" >> "$PF"
    if [[ $PF_SNOOP == 1 ]]; then
        printf 'stg %s\n' "$(ls -A "$T/stg" | wc -l | tr -d ' ')" >> "$T/snoop"
        ls -A "$T/stg" >> "$T/snoop.names"
    fi
}
CONFIRM_ANSWER=no
confirm() {
    printf '%s\n' "$1" >> "$CL"
    [[ "$CONFIRM_ANSWER" == yes ]]
}
has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }
ran_git() { [[ -s "$GL" ]] && echo yes || echo no; }
asked() { [[ -s "$CL" ]] && echo yes || echo no; }
stg_empty() { [[ -z "$(ls -A "$T/stg" 2>/dev/null)" ]] && echo yes || echo no; }
reset_logs() { : > "$PF"; : > "$GL"; : > "$GE"; : > "$WL"; : > "$CL"; }
# genv VERB -- the distinct git.env lines of VERB, without the verb.
genv() { sed -n "s/^$1 //p" "$GE" | LC_ALL=C sort -u; }
# ft DIR NET [fn] -- tn_chain_configs_from_tag in a subshell (TMPDIR=$T/stg):
# FT_RC its rc ("exit N" when it did not return), FT_OUT stdout+stderr, PFL the
# progress-fn lines.
ft() {
    local rc=0
    reset_logs
    ( TMPDIR="$T/stg" tn_chain_configs_from_tag "$@"; printf 'returned %s\n' "$?" ) > "$T/out" 2>&1 || rc=$?
    FT_RC="$(sed -n 's/^returned //p' "$T/out")"
    [[ -n "$FT_RC" ]] || FT_RC="exit $rc"
    FT_OUT="$(grep -v '^returned ' "$T/out")"
    PFL="$(cat "$PF")"
}
# en [NET] [fn] -- ensure_chain_configs_available the same way: EN_RC, EN_OUT.
en() {
    local rc=0
    reset_logs
    ( TMPDIR="$T/stg" ensure_chain_configs_available "$@"; printf 'returned %s\n' "$?" ) > "$T/out" 2>&1 || rc=$?
    EN_RC="$(sed -n 's/^returned //p' "$T/out")"
    [[ -n "$EN_RC" ]] || EN_RC="exit $rc"
    EN_OUT="$(grep -v '^returned ' "$T/out"; cat "$PF")"
}
installed_in() {  # installed_in DIR -- yes when DIR holds the three fixture files byte for byte
    local f r=yes
    for f in genesis.yaml committee.yaml parameters.yaml; do
        cmp -s "$FX/$f" "$1/$f" 2>/dev/null || r=no
    done
    echo "$r"
}
installed() { installed_in "$D"; }
listing() { ls -A "$1" 2>/dev/null | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//'; }
dest_clear() { rm -f -- "$D/genesis.yaml" "$D/committee.yaml" "$D/parameters.yaml"; }
dest_state() {
    local f
    if [[ ! -d "$D" ]]; then
        echo absent
        return 0
    fi
    ls -A "$D"
    for f in genesis.yaml committee.yaml parameters.yaml; do
        if [[ -f "$D/$f" ]]; then cksum < "$D/$f"; else echo "no $f"; fi
    done
}
mode_of() { stat -c '%a %u %g' -- "$1" 2>/dev/null; }
MOVES=' (pull|checkout|switch|reset|merge|rebase|restore|submodule|stash|clean|worktree|tag)( |$)'
moved_git() { grep -qE -- "$MOVES" "$GL" && echo yes || echo no; }

# Nothing outside the temp area: these host paths look the same at the end.
outside_state() {
    local p
    for p in /etc/telcoin/chain-configs /opt/telcoin-source; do
        if [[ -e "$p" || -L "$p" ]]; then echo "$p present"; else echo "$p absent"; fi
    done
}
OUTSIDE0="$(outside_state)"

# --- the printers --------------------------------------------------------------------
check "tag: testnet is the pinned constant" "v0.16.0-adiri" "$(tn_chain_configs_tag testnet)"
for n in mainnet devnet garbage ""; do
    rc=0; out="$(tn_chain_configs_tag "$n")" || rc=$?
    check "tag: '${n}' has none (rc 0)" "0 " "$rc $out"
done
check "dir: testnet under TN_ROOT_PREFIX" "${PFX}/etc/telcoin/chain-configs/testnet" "$D"
for n in mainnet devnet garbage; do
    rc=0; out="$(tn_chain_configs_dir "$n")" || rc=$?
    check "dir: ${n} (rc 0)" "0 ${PFX}/etc/telcoin/chain-configs/${n}" "$rc $out"
done
check "dir: CONFIG_DIR honoured" "${PFX}/etc/alt/chain-configs/testnet" "$(CONFIG_DIR=/etc/alt tn_chain_configs_dir testnet)"
check "dir: no prefix" "/etc/telcoin/chain-configs/testnet" "$(TN_ROOT_PREFIX='' tn_chain_configs_dir testnet)"

# --- cases that run no git (every environment) ---------------------------------------
for n in mainnet devnet garbage; do
    ft "$T/nowhere" "$n" pf
    check "from_tag ${n}: rc 1, no git" "1 no" "$FT_RC $(ran_git)"
    check "from_tag ${n}: the message" "warn|${n} has no pinned chain-config tag; nothing was read." "$PFL"
done
ft "$T/notgit" testnet pf
check "from_tag, a directory that is no checkout: rc 2, no git" "2 no" "$FT_RC $(ran_git)"
check "from_tag, no checkout: the message" \
    "warn|${T}/notgit is not a git checkout; the testnet chain configs at ${TAG} cannot be read from it." "$PFL"
ft "$T/nowhere" testnet pf
check "from_tag, a path that does not exist: rc 2, no git" "2 no" "$FT_RC $(ran_git)"
check "from_tag, no checkout: nothing installed" "absent" "$(dest_state)"
ft "$T/notgit" testnet
check "from_tag without a progress fn: rc 2, the message on stderr" "2 yes" \
    "$FT_RC $(has "$FT_OUT" "${T}/notgit is not a git checkout")"

en garbage
check "ensure garbage: rc 1, no git" "1 no" "$EN_RC $(ran_git)"
TN_GENESIS_DIR="$FX"
en testnet
check "ensure --genesis-dir: rc 0, no git, no prompt" "0 no no" "$EN_RC $(ran_git) $(asked)"
check "ensure --genesis-dir: the ok line names it" yes "$(has "$EN_OUT" "Chain configs in ${FX} match the testnet pins")"
cp "$FX"/*.yaml "$T/bad/"
printf '# changed\n' >> "$T/bad/committee.yaml"
# shellcheck disable=SC2034  # read by ensure_chain_configs_available
TN_GENESIS_DIR="$T/bad"
en testnet
check "ensure --genesis-dir, a changed file: rc 1, no git" "1 no" "$EN_RC $(ran_git)"
check "ensure --genesis-dir, a changed file: the refusal" yes \
    "$(has "$EN_OUT" "The chain configs in ${T}/bad do not match the testnet pins (see above); nothing was copied.")"
unset TN_GENESIS_DIR
CONFIRM_ANSWER=yes
en mainnet
check "ensure mainnet, no checkout: rc 1, no git" "1 no" "$EN_RC $(ran_git)"
check "ensure mainnet, no checkout: no clone prompt" no "$(asked)"
CONFIRM_ANSWER=no
en testnet
check "ensure testnet, no checkout, clone declined: rc 0, no git" "0 no" "$EN_RC $(ran_git)"
check "ensure, clone declined: the question" "Clone the repository now to get the chain-config files?" "$(cat "$CL")"
check "ensure, clone declined: the Skipped warning" yes \
    "$(has "$EN_OUT" "Skipped. You will need to provide chain-config files manually in the next step.")"
check "ensure, clone declined: nothing cloned" no "$([[ -e "${PFX}${TN_SOURCE_DIR}" ]] && echo yes || echo no)"
# A source directory that is no checkout: refused before the question (V-FIX-S-08).
mkdir -p "${PFX}${TN_SOURCE_DIR}"
printf 'x\n' > "${PFX}${TN_SOURCE_DIR}/README"
CONFIRM_ANSWER=yes
en testnet pf
check "ensure, a non-empty source directory without .git: rc 1, no prompt, no git" "1 no no" "$EN_RC $(asked) $(ran_git)"
check "ensure, not a checkout: the message" yes \
    "$(has "$EN_OUT" "warn|${PFX}${TN_SOURCE_DIR} exists but is not a git checkout; move it aside first.")"
CONFIRM_ANSWER=no
rm -f "${PFX}${TN_SOURCE_DIR}/README"
rmdir "${PFX}${TN_SOURCE_DIR}"

# A pinned directory that already holds the files (CONFIG_DIR elsewhere, so the
# real install below starts from an empty layout).
CONFIG_DIR=/etc/tn-pre
DP="$(tn_chain_configs_dir testnet)"
mkdir -p "$DP"
cp "$FX"/*.yaml "$DP/"
ft "$T/nowhere" testnet pf
check "from_tag, already installed: rc 0 without a checkout, no git" "0 no" "$FT_RC $(ran_git)"
check "from_tag, already installed: the log line" "log|The pinned testnet chain configs are already in ${DP}." "$PFL"
CONFIRM_ANSWER=yes
en testnet
check "ensure testnet, already installed: rc 0, no git, no prompt" "0 no no" "$EN_RC $(ran_git) $(asked)"
CONFIRM_ANSWER=no
unset CONFIG_DIR
check "no-git cases leave nothing in staging" yes "$(stg_empty)"

if [[ -z "$REAL_GIT" ]]; then
    skip "real-git cases" "git absent"
    finish
fi

# --- the repositories ----------------------------------------------------------------
# W: README + submodule (v0.15.0-adiri), + chain-configs/testnet = fixtures (TAG),
# then main changes committee.yaml; a side commit drops parameters.yaml.
G() {
    "$REAL_GIT" -c user.email=t@example.invalid -c user.name=t -c advice.detachedHead=false \
        -c init.defaultBranch=main -c protocol.file.allow=always "$@"
}
W="$T/work"; SUBO="$T/sub.git"; OB="$T/origin-b.git"
G init -q --bare "$SUBO"
G init -q "$T/subw"
printf 's\n' > "$T/subw/s"
G -C "$T/subw" add s
G -C "$T/subw" commit -qm s
G -C "$T/subw" push -q "$SUBO" HEAD:refs/heads/main 2>/dev/null
G init -q --bare "$O"
G init -q "$W"
printf 'node\n' > "$W/README"
G -C "$W" add README
G -C "$W" submodule add -q "$SUBO" sub >/dev/null 2>&1
G -C "$W" commit -qm r15
G -C "$W" tag -a v0.15.0-adiri -m r15
mkdir -p "$W/chain-configs/testnet"
cp "$FX"/*.yaml "$W/chain-configs/testnet/"
G -C "$W" add chain-configs
G -C "$W" commit -qm r16
G -C "$W" tag -a "$TAG" -m r16
C_TAG="$(G -C "$W" rev-parse HEAD)"
printf '# main moved on\n' >> "$W/chain-configs/testnet/committee.yaml"
G -C "$W" commit -qam main
C_MAIN="$(G -C "$W" rev-parse HEAD)"
G -C "$W" checkout -q -b missing "$C_TAG"
G -C "$W" rm -q chain-configs/testnet/parameters.yaml
G -C "$W" commit -qm missing
C_MISS="$(G -C "$W" rev-parse HEAD)"
G -C "$W" checkout -q main
G -C "$W" push -q "$O" main:refs/heads/main --tags 2>/dev/null
G --git-dir="$O" symbolic-ref HEAD refs/heads/main
check "fixture: the submodule is recorded" yes "$(has "$(G -C "$W" submodule status 2>&1)" " sub")"
check "fixture: main's committee.yaml differs from the pinned one" no \
    "$(cmp -s "$FX/committee.yaml" "$W/chain-configs/testnet/committee.yaml" && echo yes || echo no)"

# snap DIR -- what must not change in a checkout (real git, not the logger).
snap() {
    ( PATH="$ORIG_PATH"
      cd "$1" || exit 1
      "$REAL_GIT" rev-parse HEAD
      "$REAL_GIT" symbolic-ref -q HEAD || echo detached
      "$REAL_GIT" status --porcelain --untracked-files=all
      "$REAL_GIT" stash list
      "$REAL_GIT" submodule status
      "$REAL_GIT" diff
      "$REAL_GIT" diff --cached
      "$REAL_GIT" for-each-ref refs/heads refs/tags
    ) 2>&1
}
ref_of() { G -C "$1" rev-parse -q --verify "$2^{commit}" 2>/dev/null; }

# --- origin B: its tag holds main's committee.yaml (a pin mismatch) -------------------
G init -q --bare "$OB"
G -C "$W" push -q "$OB" "${C_TAG}:refs/heads/main" "${C_MAIN}:refs/tags/${TAG}" 2>/dev/null
G --git-dir="$OB" symbolic-ref HEAD refs/heads/main
L="$T/lab"
G clone -q "$OB" "$L" 2>/dev/null
PF_SNOOP=1
ft "$L" testnet pf
PF_SNOOP=0
check "mismatch: rc 1" 1 "$FT_RC"
check "mismatch: the refusal" yes \
    "$(has "$PFL" "warn|The testnet chain configs at ${TAG} do not match the pins; nothing was installed.")"
check "mismatch, nothing there before: nothing created" "absent absent" \
    "$(dest_state) $([[ -e "$CC" ]] && echo present || echo absent)"
check "mismatch: no write" "" "$(cat "$WL")"
check "mismatch: staging removed" yes "$(stg_empty)"
check "mismatch: the staging directory was made under TMPDIR while it ran" yes \
    "$(grep -qxF 'stg 1' "$T/snoop" && echo yes || echo no)"
check "mismatch: the fetch ran with https only and fd 9 closed" yes \
    "$(grep -qxF -- "gap=https fd9=closed -C ${L} fetch --quiet --no-tags origin +refs/tags/${TAG}:refs/tn-remote-tags/${TAG}" "$GL" && echo yes || echo no)"
check "mismatch: every git child over https, fd 9 closed, no GIT_DIR; the read-only ones without lazy fetch" \
    "fetch gap=https lazy=unset gitdir=unset worktree=unset fd9=closed|rev-parse gap=https lazy=1 gitdir=unset worktree=unset fd9=closed|cat-file gap=https lazy=1 gitdir=unset worktree=unset fd9=closed" \
    "fetch $(genv fetch)|rev-parse $(genv rev-parse)|cat-file $(genv cat-file)"
MAIN_COMMITTEE_SHA="$(sha256sum < "$W/chain-configs/testnet/committee.yaml")"
check "mismatch: the line names the file at the tag" \
    "warn|chain-configs/testnet/committee.yaml at ${TAG}: sha256 ${MAIN_COMMITTEE_SHA%% *}, expected ${TESTNET_COMMITTEE_SHA256// / or } (testnet)." \
    "$(grep -F 'committee.yaml' <<< "$PFL")"
check_lacks "mismatch: no staging path in the warnings" "$T/stg" "$PFL"
check "mismatch: the staging directory is tag.<pid>.* (the sweep after a kill finds it)" yes \
    "$(grep -q "^tag\.$$\." "$T/snoop.names" && echo yes || echo no)"
# The destination holds two good files and a stale one, in 0700 directories.
mkdir -p "$D"
chmod 0700 "$CC" "$D"
cp "$FX/genesis.yaml" "$FX/parameters.yaml" "$D/"
printf 'stale\n' > "$D/committee.yaml"
S0="$(dest_state)"
ft "$L" testnet pf
check "mismatch, files there before: rc 1, byte-identical" "1 yes" "$FT_RC $([[ "$(dest_state)" == "$S0" ]] && echo yes || echo no)"
check "mismatch: staging removed (2)" yes "$(stg_empty)"
# The tag loses parameters.yaml.
G -C "$W" push -q -f "$OB" "${C_MISS}:refs/tags/${TAG}" 2>/dev/null
ft "$L" testnet pf
check "missing blob: rc 2" 2 "$FT_RC"
check "missing blob: the message" yes "$(has "$PFL" "warn|${TAG} has no chain-configs/testnet/parameters.yaml.")"
check "missing blob: destination untouched, staging removed" "yes yes" \
    "$([[ "$(dest_state)" == "$S0" ]] && echo yes || echo no) $(stg_empty)"
# origin B's tag now right; the lab's own tag still points at main's commit.
G -C "$W" push -q -f "$OB" "${C_TAG}:refs/tags/${TAG}" 2>/dev/null
LT0="$(ref_of "$L" "refs/tags/${TAG}")"
ft "$L" testnet pf
check "local tag elsewhere, origin right: rc 0, the pinned files" "0 yes" "$FT_RC $(installed)"
check "a stale committee.yaml next to two good files: replaced" yes "$(cmp -s "$FX/committee.yaml" "$D/committee.yaml" && echo yes || echo no)"
# The tag stays v0.16.0-adiri when the pins take v0.18.0-adiri's committee.yaml too:
# an install gets the file that names the five bootstrap servers (ten multiaddrs).
check "install: committee.yaml is the file at the tag, with the bootstrap servers" \
    "009b6d7b568f7d04734b657080d55621eed70f68ecefe1284dd8cdd0f42f15ce 10" \
    "$(sha256sum < "$D/committee.yaml" | cut -d' ' -f1) $(grep -c '/quic-v1/p2p/' "$D/committee.yaml")"
check "local tag elsewhere: not moved" "$C_MAIN $C_MAIN" "$LT0 $(ref_of "$L" "refs/tags/${TAG}")"
check "install: the messages" \
    "step|Fetching ${TAG} from origin for the chain configs...
log|Installed the testnet chain configs from ${TAG} into ${D}." "$PFL"
check "install: the writers" \
    "layout ${CC} root 0755
layout ${D} root 0755
write ${D}/committee.yaml 0644 file
write ${D}/genesis.yaml 0644 file
write ${D}/parameters.yaml 0644 file" "$(LC_ALL=C sort "$WL")"
check "install: no temp file left in the destination" "committee.yaml genesis.yaml parameters.yaml" "$(listing "$D")"
if [[ $ROOT_OK == 1 ]]; then
    check "install (real writers): chain-configs 0755 root:root" "755 0 0" "$(mode_of "$CC")"
    check "install (real writers): testnet 0755 root:root" "755 0 0" "$(mode_of "$D")"
    for f in genesis.yaml committee.yaml parameters.yaml; do
        check "install (real writers): ${f} 0644 root:root" "644 0 0" "$(mode_of "$D/$f")"
    done
else
    skip "install: owners and modes of the real root writers" "$NO_REAL_WHY"
fi
# origin B force-moves the tag to main's commit after that good install.
dest_clear
G -C "$W" push -q -f "$OB" "${C_MAIN}:refs/tags/${TAG}" 2>/dev/null
ft "$L" testnet pf
check "force-moved upstream tag: rc 1, nothing installed" "1 no no no" \
    "$FT_RC $([[ -e "$D/genesis.yaml" ]] && echo yes || echo no) $([[ -e "$D/committee.yaml" ]] && echo yes || echo no) $([[ -e "$D/parameters.yaml" ]] && echo yes || echo no)"

# --- the source checkout, on main that moved on ----------------------------------------
SRC="${PFX}${TN_SOURCE_DIR}"
mkdir -p "${SRC%/*}"
G clone -q "$O" "$SRC" 2>/dev/null
printf 'stashed\n' >> "$SRC/README"
G -C "$SRC" stash -q
S1="$(snap "$SRC")"
ft "$SRC" testnet pf
check "checkout on main: rc 0, the pinned files" "0 yes" "$FT_RC $(installed)"
check "checkout on main: HEAD, branch, status, stash, submodules unchanged" "$S1" "$(snap "$SRC")"
check "checkout on main: on main still" "$C_MAIN" "$(ref_of "$SRC" HEAD)"
check "checkout on main: the working tree keeps main's committee.yaml" yes \
    "$(cmp -s "$W/chain-configs/testnet/committee.yaml" "$SRC/chain-configs/testnet/committee.yaml" && echo yes || echo no)"
check "checkout on main: no git command that moves a checkout" no "$(moved_git)"
check "checkout on main: the submodule is not initialised" "-" "$(snap "$SRC" | grep ' sub' | cut -c1)"
check "checkout on main: staging removed" yes "$(stg_empty)"
ft "$SRC" testnet pf
check "second run: rc 0, no git" "0 no" "$FT_RC $(ran_git)"
check "second run: the log line" "log|The pinned testnet chain configs are already in ${D}." "$PFL"

# A dirty checkout: a changed tracked file, a staged change, an untracked file.
dest_clear
printf 'local edit\n' >> "$SRC/chain-configs/testnet/genesis.yaml"
printf 'staged\n' >> "$SRC/README"
G -C "$SRC" add README
printf 'untracked\n' > "$SRC/chain-configs/testnet/extra.yaml"
S2="$(snap "$SRC")"
ft "$SRC" testnet pf
check "dirty checkout: rc 0, the pinned files" "0 yes" "$FT_RC $(installed)"
check "dirty checkout: unchanged" "$S2" "$(snap "$SRC")"
check "dirty checkout: the edit, the staged change and the untracked file are there" "local edit|staged|untracked" \
    "$(tail -n 1 "$SRC/chain-configs/testnet/genesis.yaml")|$(tail -n 1 "$SRC/README")|$(cat "$SRC/chain-configs/testnet/extra.yaml")"
check "dirty checkout: no git command that moves a checkout" no "$(moved_git)"

# A checkout detached at another tag (its tree has no chain-configs at all).
S3D="$T/src3"
G clone -q "$O" "$S3D" 2>/dev/null
G -C "$S3D" checkout -q --detach v0.15.0-adiri
dest_clear
S3="$(snap "$S3D")"
ft "$S3D" testnet pf
check "detached at another tag: rc 0, the pinned files" "0 yes" "$FT_RC $(installed)"
check "detached at another tag: unchanged" "$S3" "$(snap "$S3D")"
check "detached at another tag: still no chain-configs in the tree" no "$([[ -e "$S3D/chain-configs" ]] && echo yes || echo no)"
# The same checkout with its own tag of that name on main's commit.
G -C "$S3D" tag -f "$TAG" "$C_MAIN" >/dev/null 2>&1
dest_clear
ft "$S3D" testnet pf
check "local tag on another commit: rc 0 from origin's tag, the pinned files" "0 yes" "$FT_RC $(installed)"
check "local tag on another commit: not moved" "$C_MAIN" "$(ref_of "$S3D" "refs/tags/${TAG}")"

# --- origin unreachable ------------------------------------------------------------------
S4D="$T/src4"; S5D="$T/src5"; S6D="$T/src6"
G clone -q "$O" "$S4D" 2>/dev/null                       # refs/tags only
G clone -q "$O" "$S5D" 2>/dev/null                       # fetched copy wrong, local tag right
G -C "$S5D" update-ref "refs/tn-remote-tags/${TAG}" "$C_MAIN"
G clone -q "$O" "$S6D" 2>/dev/null                       # neither
G -C "$S6D" tag -d "$TAG" >/dev/null 2>&1
mv "$O" "$O.away"
# git's reason names the origin's path, so the library's cut at 200 characters
# applies to it under a long TMPDIR: the expected texts cut it the same way.
OFFWHY="fatal: '${O}' does not appear to be a git repository"
OFFWHY="${OFFWHY:0:200}"
OFFLINE="warn|Could not fetch ${TAG} from origin (${OFFWHY}); reading the testnet chain configs from the local copy of ${TAG}."
dest_clear
ft "$SRC" testnet pf
check "offline, an earlier fetch: rc 0, the pinned files" "0 yes" "$FT_RC $(installed)"
check "offline: the warning" yes "$(has "$PFL" "$OFFLINE")"
dest_clear
ft "$S3D" testnet pf
check "offline, fetched copy right and local tag wrong: the fetched copy wins (rc 0)" "0 yes" "$FT_RC $(installed)"
dest_clear
ft "$S4D" testnet pf
check "offline, only the local tag: rc 0 from it" "0 yes" "$FT_RC $(installed)"
check "offline, only the local tag: the warning" yes "$(has "$PFL" "$OFFLINE")"
dest_clear
ft "$S5D" testnet pf
check "offline, fetched copy wrong and local tag right: the fetched copy wins (rc 1)" 1 "$FT_RC"
dest_clear
ft "$S6D" testnet pf
check "offline, no copy of the tag: rc 2" 2 "$FT_RC"
check "offline, no copy: the message" yes \
    "$(has "$PFL" "warn|Could not fetch tag ${TAG} from origin (${OFFWHY}), and the checkout does not have it.")"
check "offline, no copy: nothing installed" "no" "$([[ -e "$D/genesis.yaml" ]] && echo yes || echo no)"
mv "$O.away" "$O"
check "offline cases: staging removed" yes "$(stg_empty)"

# --- checkouts that are refused ---------------------------------------------------------
ln -s "$SRC" "$T/srclink"
dest_clear
ft "$T/srclink" testnet pf
check "symlinked checkout: rc 1, no git" "1 no" "$FT_RC $(ran_git)"
check "symlinked checkout: the message" \
    "warn|${T}/srclink must be a directory owned by $(id -un) (not a symlink); nothing was fetched." "$PFL"
if [[ $IS_ROOT == 1 ]]; then
    S7D="$T/src7"
    G clone -q "$O" "$S7D" 2>/dev/null
    chown -R 65534:65534 "$S7D"
    ft "$S7D" testnet pf
    check "checkout owned by another account: rc 1, no git" "1 no" "$FT_RC $(ran_git)"
    check "checkout owned by another account: the message" \
        "warn|${S7D} must be a directory owned by root (not a symlink); nothing was fetched." "$PFL"
else
    skip "checkout owned by another account" "not root"
fi

# --- ensure_chain_configs_available end to end -----------------------------------------
dest_clear
S8="$(snap "$SRC")"
en testnet
check "ensure, checkout on main: rc 0, the pinned files" "0 yes" "$EN_RC $(installed)"
check "ensure, checkout on main: not moved" "$S8" "$(snap "$SRC")"
check "ensure, checkout on main: no pull, checkout, reset, merge or submodule" no "$(moved_git)"
check "ensure, checkout on main: no prompt" no "$(asked)"
check "ensure, checkout on main: the ok line names the pinned directory" yes \
    "$(has "$EN_OUT" "Chain configs in ${D} match the testnet pins")"
en testnet
check "ensure, second run: rc 0, no git, no prompt" "0 no no" "$EN_RC $(ran_git) $(asked)"
dest_clear
# shellcheck disable=SC2034  # read by ensure_chain_configs_available
TN_GENESIS_DIR="$FX"
en testnet
unset TN_GENESIS_DIR
check "ensure --genesis-dir with a checkout present: rc 0, no git, nothing installed" "0 no no" \
    "$EN_RC $(ran_git) $([[ -e "$D/genesis.yaml" ]] && echo yes || echo no)"
CONFIRM_ANSWER=yes
en mainnet
check "ensure mainnet with a checkout: rc 1, no git, no prompt" "1 no no" "$EN_RC $(ran_git) $(asked)"
check "ensure mainnet with a checkout: published as is" yes \
    "$(has "$EN_OUT" "Repository present; mainnet chain configs are used as published (no pull).")"
mv "$SRC" "$T/src-aside"
dest_clear
CONFIRM_ANSWER=no
en testnet
check "ensure, no checkout, declined: rc 0, Skipped, no git" "0 yes no" \
    "$EN_RC $(has "$EN_OUT" "Skipped. You will need to provide chain-config files manually") $(ran_git)"
mv "$O" "$O.away"
CONFIRM_ANSWER=yes
en testnet
check "ensure, failing clone: returns 2 (no exit)" 2 "$EN_RC"
check "ensure, failing clone: the message" yes "$(has "$EN_OUT" "Clone failed. Check your internet connection.")"
check "ensure, failing clone: the manual command names the repository" yes "$(has "$EN_OUT" "$TN_REPO")"
check "ensure, failing clone: nothing installed" no "$([[ -e "$D/genesis.yaml" ]] && echo yes || echo no)"
en testnet pf
check "ensure, failing clone with a progress fn: rc 2, the reason and the manual command reach it (V-FIX-S-01)" \
    "2|warn|Clone failed. Check your internet connection.
warn|Manual clone: git clone --branch ${TAG} ${TN_REPO} ${SRC}" "$EN_RC|$(grep '^warn|' "$PF")"
mv "$O.away" "$O"
en testnet
check "ensure, clone accepted: rc 0, the pinned files" "0 yes" "$EN_RC $(installed)"
check "ensure, clone accepted: the question" "Clone the repository now to get the chain-config files?" "$(cat "$CL")"
check "ensure, clone accepted: at the tag, https only, fd 9 closed" yes \
    "$(grep -qxF -- "gap=https fd9=closed clone --quiet --branch ${TAG} -- ${TN_REPO} ${SRC}" "$GL" && echo yes || echo no)"
check "ensure, clone accepted: HEAD is the tag's commit" "$C_TAG" "$(ref_of "$SRC" HEAD)"
check "ensure, clone accepted: no submodule initialised" "-" "$(snap "$SRC" | grep ' sub' | cut -c1)"
check "ensure, clone accepted: no submodule command, no pull" no "$(moved_git)"
check_lacks "ensure, clone accepted: no --recurse-submodules" "recurse-submodules" "$(cat "$GL")"
en testnet
check "ensure after the clone, second run: rc 0, no git" "0 no" "$EN_RC $(ran_git)"
mv "$SRC" "$T/src-cloned"
mkdir "$SRC"
dest_clear
en testnet
check "ensure, an empty source directory: asked, cloned into, rc 0, the pinned files" "0 yes yes" \
    "$EN_RC $(asked) $(installed)"
check "ensure, an empty source directory: HEAD is the tag's commit" "$C_TAG" "$(ref_of "$SRC" HEAD)"
mv "$SRC" "$T/src-cloned2"
mv "$T/src-aside" "$SRC"

# --- attacks -----------------------------------------------------------------------------
for n in 'testnet;x' '../testnet' 'testnet '; do
    ft "$SRC" "$n" pf
    check "odd network '${n}': rc 1, no git" "1 no" "$FT_RC $(ran_git)"
done
# Spaces in the checkout path and in the config dir.
mkdir -p "$T/with space"
G clone -q "$O" "$T/with space/src" 2>/dev/null
# shellcheck disable=SC2034  # read by tn_chain_configs_dir
CONFIG_DIR="/etc/odd dir"
DS="$(tn_chain_configs_dir testnet)"
ft "$T/with space/src" testnet pf
check "spaces in the checkout path and the config dir: rc 0, the pinned files" "0 yes" "$FT_RC $(installed_in "$DS")"
unset CONFIG_DIR
# The caller runs with set -euo pipefail (the subshell is not in a condition, so
# its set -e is live).
dest_clear
( set -euo pipefail; TMPDIR="$T/stg" tn_chain_configs_from_tag "$SRC" testnet; echo "after $?" ) > "$T/sete.out" 2>&1
rc=$?
check "caller with set -euo pipefail, no progress fn: completes, rc 0" "0 after 0 yes" "$rc $(tail -n 1 "$T/sete.out") $(installed)"
dest_clear
( set -euo pipefail; TMPDIR="$T/stg" tn_chain_configs_from_tag "$L" testnet; echo "after $?" ) > "$T/sete.out" 2>&1
rc=$?
check "caller with set -e, a mismatch: returns 1 after its cleanup" "1 no yes yes" \
    "$rc $(has "$(cat "$T/sete.out")" after) $(has "$(cat "$T/sete.out")" "do not match the pins; nothing was installed.") $(stg_empty)"
dest_clear
( set -euo pipefail; TMPDIR="$T/stg" ensure_chain_configs_available testnet; echo "after $?" ) > "$T/sete.out" 2>&1
rc=$?
check "caller with set -euo pipefail: ensure completes, rc 0" "0 after 0 yes" "$rc $(tail -n 1 "$T/sete.out") $(installed)"
# A symlinked checkout named with a trailing slash.
dest_clear
ft "$T/srclink/" testnet pf
check "symlinked checkout with a trailing slash: rc 1, no git" "1 no" "$FT_RC $(ran_git)"
# The destination directory is a symlink.
dest_clear
rmdir "$D"
mkdir -p "$T/elsewhere"
ln -s "$T/elsewhere" "$D"
ft "$SRC" testnet pf
check "destination a symlink to an empty directory: refused (rc 1), no git, nothing written through it" "1 no " \
    "$FT_RC $(ran_git) $(listing "$T/elsewhere")"
check "destination a symlink: the message" \
    "warn|${D} must be a directory, not a symlink or a file; nothing was installed. Remove it and run again." "$PFL"
check "destination a symlink: still the symlink, staging removed" "yes yes" "$([[ -L "$D" ]] && echo yes || echo no) $(stg_empty)"
cp "$FX"/*.yaml "$T/elsewhere/"
ft "$SRC" testnet pf
check "destination a symlink to a directory holding the pinned files: refused (rc 1), no git" "1 no" "$FT_RC $(ran_git)"
rm -f -- "$D" "$T/elsewhere/genesis.yaml" "$T/elsewhere/committee.yaml" "$T/elsewhere/parameters.yaml"
ft "$SRC" testnet pf
check "destination back to normal: rc 0" "0 yes" "$FT_RC $(installed)"
# A symlinked file in the destination (pointing at a copy of the pinned file).
cp "$FX/committee.yaml" "$T/pinned-copy"
rm -f -- "$D/committee.yaml"
ln -s "$T/pinned-copy" "$D/committee.yaml"
ft "$SRC" testnet pf
check "a symlinked file in the destination: rc 2, the link and its target kept" "2 yes yes" \
    "$FT_RC $([[ -L "$D/committee.yaml" ]] && echo yes || echo no) $(cmp -s "$FX/committee.yaml" "$T/pinned-copy" && echo yes || echo no)"
check "a symlinked file: the message, no git, no temp file left, staging removed" "yes no committee.yaml genesis.yaml parameters.yaml yes" \
    "$(has "$PFL" "warn|${D}/committee.yaml is a symlink or not a regular file; nothing was installed. Remove it and run again.") $(ran_git) $(listing "$D") $(stg_empty)"
rm -f -- "$D/committee.yaml"
# The second of the three writes fails.
dest_clear
T_FAIL_WRITE=committee.yaml
ft "$SRC" testnet pf
T_FAIL_WRITE=""
check "a write fails: rc 2, the message, staging removed" "2 yes yes" \
    "$FT_RC $(has "$PFL" "warn|Could not install the testnet chain configs from ${TAG} into ${D} (see above).") $(stg_empty)"
printf 'note: after a failed second write the destination holds: %s\n' "$(listing "$D")"
check "a write fails: the destination does not pass the pins" 1 "$(tn_chain_configs_check "$D" testnet 2>/dev/null; echo $?)"
ft "$SRC" testnet pf
check "after a failed write, the next run completes the install" "0 yes" "$FT_RC $(installed)"
# Three runs at once.
dest_clear
: > "$T/conc"
for i in 1 2 3; do
    ( rc=0; TMPDIR="$T/stg" tn_chain_configs_from_tag "$SRC" testnet > "$T/conc.$i" 2>&1 || rc=$?; printf '%s\n' "$rc" >> "$T/conc" ) &
done
wait
check "three concurrent runs: each rc 0" "0 0 0" "$(LC_ALL=C sort "$T/conc" | tr '\n' ' ' | sed 's/ $//')"
check "three concurrent runs: the pinned files, no temp file, staging removed" "yes committee.yaml genesis.yaml parameters.yaml yes" \
    "$(installed) $(listing "$D") $(stg_empty)"
# Origin reachable but the tag deleted there: the local copy, with the warning.
G --git-dir="$O" update-ref -d "refs/tags/${TAG}"
dest_clear
ft "$SRC" testnet pf
check "tag deleted upstream: rc 0 from the local copy, the warning names git's reason" "0 yes yes" \
    "$FT_RC $(installed) $(has "$PFL" "warn|Could not fetch ${TAG} from origin (fatal: couldn't find remote ref refs/tags/${TAG}); reading the testnet chain configs from the local copy of ${TAG}.")"
G -C "$W" push -q "$O" "refs/tags/${TAG}" 2>/dev/null
# --- after verification (V-FIX-S) -------------------------------------------------------
# The pinned files in a directory made by hand under umask 077 (0700, 0600):
# installed again from there, with no git (V-FIX-S-05).
dest_clear
cp "$FX"/*.yaml "$D/"
chmod 0700 "$CC" "$D"
chmod 0600 "$D"/*.yaml
ft "$T/nowhere" testnet pf
check "modes 0700/0600 with the pinned files: rc 0, no git, the pinned files" "0 no yes" "$FT_RC $(ran_git) $(installed)"
check "modes 0700/0600: installed again through the root writers" "layout ${CC} root 0755
layout ${D} root 0755
write ${D}/committee.yaml 0644 file
write ${D}/genesis.yaml 0644 file
write ${D}/parameters.yaml 0644 file" "$(LC_ALL=C sort "$WL")"
check "modes 0700/0600: the messages" "log|The pinned testnet chain configs are already in ${D}.
log|Reinstalled the testnet chain configs in ${D} root-owned, directories 0755 and files 0644: their owner or modes were not the ones the install sets." "$PFL"
if [[ $ROOT_OK == 1 ]]; then
    check "modes 0700/0600: now root:root 0755 and 0644 (real writers)" "755 0 0|755 0 0|644 0 0" \
        "$(mode_of "$CC")|$(mode_of "$D")|$(mode_of "$D/committee.yaml")"
else
    check "modes 0700/0600: now 0755 and 0644 (stand-ins)" "755|755|644" \
        "$(mode_of "$CC" | cut -d' ' -f1)|$(mode_of "$D" | cut -d' ' -f1)|$(mode_of "$D/committee.yaml" | cut -d' ' -f1)"
fi
ft "$T/nowhere" testnet pf
check "after the reinstall: in place, nothing written" "0 no |log|The pinned testnet chain configs are already in ${D}." \
    "$FT_RC $(ran_git) $(cat "$WL")|$PFL"
if [[ $ROOT_OK == 1 ]]; then
    chown 65534:65534 "$CC" "$D" "$D"/*.yaml
    ft "$T/nowhere" testnet pf
    check "another account's directory with the pinned files: installed again root:root, no git" "0 no 755 0 0 644 0 0" \
        "$FT_RC $(ran_git) $(mode_of "$D") $(mode_of "$D/committee.yaml")"
else
    skip "another account's directory with the pinned files: installed again root:root" "$NO_REAL_WHY"
fi
# An entry no install can replace: refused before the first write (V-FIX-S-04).
dest_clear
mkdir "$D/committee.yaml"
S9="$(dest_state)"
ft "$SRC" testnet pf
check "a directory named committee.yaml: rc 2, no git, nothing written, the destination as it was" "2 no  yes" \
    "$FT_RC $(ran_git) $(cat "$WL") $([[ "$(dest_state)" == "$S9" ]] && echo yes || echo no)"
check "a directory named committee.yaml: the message" \
    "warn|${D}/committee.yaml is a symlink or not a regular file; nothing was installed. Remove it and run again." "$PFL"
rmdir "$D/committee.yaml"
# A stray GIT_DIR and GIT_WORK_TREE do not redirect the helper's git (V-FIX-S-03).
dest_clear
export GIT_DIR="$T/nowhere.git" GIT_WORK_TREE="$T"
ft "$SRC" testnet pf
unset GIT_DIR GIT_WORK_TREE
check "a stray GIT_DIR and GIT_WORK_TREE: ignored, rc 0, the pinned files" "0 yes" "$FT_RC $(installed)"
check "a stray GIT_DIR: every git child without it, over https, fd 9 closed" \
    "fetch gap=https lazy=unset gitdir=unset worktree=unset fd9=closed|rev-parse gap=https lazy=1 gitdir=unset worktree=unset fd9=closed|cat-file gap=https lazy=1 gitdir=unset worktree=unset fd9=closed" \
    "fetch $(genv fetch)|rev-parse $(genv rev-parse)|cat-file $(genv cat-file)"
# A .git that git cannot read: refused with git's reason (V-FIX-S-03).
mkdir -p "$T/broken"
printf 'gitdir: %s/no-such-gitdir\n' "$T" > "$T/broken/.git"
dest_clear
ft "$T/broken" testnet pf
check "a .git git cannot read: refused (rc 1), nothing installed" "1 no" \
    "$FT_RC $([[ -e "$D/genesis.yaml" ]] && echo yes || echo no)"
# Git words this differently from version to version ("fatal: not a git repository:
# <gitdir>", "fatal: gitfile does not point to a valid repository: <dir>/.git"), so the
# check is that git's own fatal line is carried (without it the library says "git
# exited <n>"), and a failure prints the line that came.
GW="$(grep -F "warn|Git cannot read the repository in ${T}/broken (" <<< "$PFL" || true)"
case "$GW" in
    *"${T}/broken (fatal: "*"); nothing was installed.") GWR=yes ;;
    *) GWR="no: ${GW:-no such warning}" ;;
esac
check "a .git git cannot read: git's reason" yes "$GWR"
if [[ $IS_ROOT == 1 ]]; then
    S10="$T/src10"
    G clone -q "$O" "$S10" 2>/dev/null
    chown -R 65534:65534 "$S10/.git"
    dest_clear
    ft "$S10" testnet pf
    check "another account's .git (dubious ownership): refused (rc 1), nothing installed" "1 no" \
        "$FT_RC $([[ -e "$D/genesis.yaml" ]] && echo yes || echo no)"
    check "dubious ownership: git's reason" yes \
        "$(has "$PFL" "warn|Git cannot read the repository in ${S10} (fatal: detected dubious ownership in repository at ")"
else
    skip "another account's .git (dubious ownership)" "not root"
fi
# A partial clone: no blob is fetched behind the helper's back (V-FIX-S-10).
G --git-dir="$O" config uploadpack.allowFilter true
G clone -q --filter=blob:none --no-checkout "file://$O" "$T/partial" 2>/dev/null
dest_clear
ft "$T/partial" testnet pf
check "a partial clone: rc 2, nothing installed, no lazy fetch" "2 no" \
    "$FT_RC $([[ -e "$D/genesis.yaml" ]] && echo yes || echo no)"
check "a partial clone: the blob is named unreadable, not missing" yes \
    "$(has "$PFL" "warn|Could not read chain-configs/testnet/genesis.yaml at ${TAG} (fatal: ")"
# A git worktree (.git is a file) is read like any checkout (V-FIX-S-08).
G -C "$SRC" worktree add -q --detach "$T/wt" "$C_MAIN" 2>/dev/null
dest_clear
WT0="$(snap "$T/wt")"
ft "$T/wt" testnet pf
check "a git worktree: rc 0, the pinned files" "0 yes" "$FT_RC $(installed)"
check "a git worktree: unchanged, nothing that moves a checkout" "yes no" \
    "$([[ "$(snap "$T/wt")" == "$WT0" ]] && echo yes || echo no) $(moved_git)"
mv "$SRC" "$T/src-main"
G -C "$T/src-main" worktree add -q --detach "$SRC" "$C_MAIN" 2>/dev/null
dest_clear
CONFIRM_ANSWER=yes
en testnet pf
CONFIRM_ANSWER=no
check "ensure, the source checkout is a git worktree: rc 0, no prompt, the pinned files" "0 no yes" \
    "$EN_RC $(asked) $(installed)"
G -C "$T/src-main" worktree remove --force "$SRC" 2>/dev/null
mv "$T/src-main" "$SRC"
check "every new case left nothing in staging" yes "$(stg_empty)"
# Devnet keeps its pull (fd 9 closed).
en devnet
check "ensure devnet with a checkout: pull --ff-only as before, rc 0" "yes 0" \
    "$(grep -qxF -- "gap=unset fd9=closed -C ${SRC} pull --ff-only" "$GL" && echo yes || echo no) $EN_RC"

check "TN_ROOT_PREFIX: nothing written outside the temp area" "$OUTSIDE0" "$(outside_state)"
check "every case left nothing in staging" yes "$(stg_empty)"
finish
