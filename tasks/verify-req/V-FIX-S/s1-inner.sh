#!/usr/bin/env bash
# =============================================================================
# s1-inner.sh MODE -- V-FIX-S live proof, runs as root inside a disposable
# ubuntu:26.04 container (driven by s1-live.sh). MODE is "old" (scripts at
# 01664cc) or "new" (scripts at 1a3404b). The scripts are mounted read-only at
# /s, this harness at /h, the output directory at /out.
#
# Phase 1 (both modes): fresh host. Source lib/common.sh the way the scripts do,
# NETWORK=testnet, TN_ASSUME_YES=true, call ensure_chain_configs_available
# testnet, then run tn_chain_configs_check on the directory step_write_config
# would use (the first entry of its search list holding all three files).
# Phases 2-4 (new only): checkout moved to the remote default branch by hand and
# the pinned directory emptied; network cut with the directory in place (a git
# wrapper that logs and fails every network command); directory emptied again
# with origin unreachable (wrapper; then a real DNS failure through
# url.insteadOf, with refs/tn-remote-tags removed so refs/tags is the copy).
# Every decisive line goes to /out/decisive.txt.
# =============================================================================
set -u

mode="${1:-}"
OUT=/out
SRC=/opt/telcoin-source
PIN=/etc/telcoin/chain-configs/testnet
TAG=v0.16.0-adiri
DEC="${OUT}/decisive.txt"
: > "$DEC"

say() { printf '%s\n' "$*" >> "$DEC"; printf '%s\n' "$*"; }

case "$mode" in
    old|new) ;;
    *) echo "usage: s1-inner.sh old|new" >&2; exit 2 ;;
esac

say "== MODE ${mode} =="
if ! { apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends git ca-certificates; } > "${OUT}/apt.log" 2>&1; then
    say "APT_FAILED (no network?) -- see apt.log"
    exit 3
fi
say "git: $(git --version)"
say "os: $(. /etc/os-release && printf '%s' "$PRETTY_NAME")"
say "COMMON_VERSION: $(grep -m1 '^readonly COMMON_VERSION=' /s/lib/common.sh)"

# run_ensure LABEL [VAR=VALUE ...] -- one fresh bash process, as a script run:
# source the library, NETWORK=testnet, consenting confirm, call ensure.
run_ensure() {
    local label="$1"
    shift
    env "$@" TN_ASSUME_YES=true bash -c '
        source /s/lib/common.sh
        NETWORK=testnet
        rc=0
        ensure_chain_configs_available testnet || rc=$?
        echo "ENSURE_RC=${rc}"' > "${OUT}/${label}.log" 2>&1
    say "[${label}] $(grep -m1 '^ENSURE_RC=' "${OUT}/${label}.log" || echo 'ENSURE_RC=missing (process died)')"
    grep -E 'committee.yaml|match|Cloning|cloned|Fetching|Installed|already in|local copy|Could not|Clone failed|pulling|not a git|must be' "${OUT}/${label}.log" \
        | sed "s/^/[${label}]   | /" >> "$DEC"
}

# check_dir LABEL DIR -- tn_chain_configs_check DIR testnet, in a fresh process.
check_dir() {
    bash -c 'source /s/lib/common.sh; rc=0; tn_chain_configs_check "$1" testnet || rc=$?; echo "CHECK_RC=${rc}"' _ "$2" \
        > "${OUT}/${1}-check.log" 2>&1
    say "[${1}] tn_chain_configs_check ${2}: $(grep -m1 '^CHECK_RC=' "${OUT}/${1}-check.log")"
    grep -v '^CHECK_RC=' "${OUT}/${1}-check.log" | sed "s/^/[${1}]   | /" >> "$DEC"
}

# swc_dir -- the directory step_write_config would copy from: the first entry
# of its search list with all three files (TN_GENESIS_DIR is unset here).
# old (01664cc setup-node.sh:2352-2357): checkout, /opt/telcoin-source, config.
# new (1a3404b setup-node.sh:2371-2377): pinned dir (testnet has a tag), then those.
swc_dir() {
    local d
    if [[ "$mode" == "new" ]]; then
        set -- "$PIN" "${SRC}/chain-configs/testnet" "/opt/telcoin-source/chain-configs/testnet" "/etc/telcoin/chain-configs/testnet"
    else
        set -- "${SRC}/chain-configs/testnet" "/opt/telcoin-source/chain-configs/testnet" "/etc/telcoin/chain-configs/testnet"
    fi
    for d in "$@"; do
        if [[ -f "${d}/genesis.yaml" && -f "${d}/committee.yaml" && -f "${d}/parameters.yaml" ]]; then
            printf '%s\n' "$d"
            return 0
        fi
    done
    printf '%s\n' "(none)"
}

repo_state() {
    local label="$1" head sym
    head="$(git -C "$SRC" rev-parse HEAD 2>/dev/null || echo none)"
    sym="$(git -C "$SRC" symbolic-ref -q HEAD 2>/dev/null || echo detached)"
    say "[${label}] HEAD=${head} ref=${sym} describe=$(git -C "$SRC" describe --tags --exact-match HEAD 2>/dev/null || echo -)"
    git -C "$SRC" status --porcelain > "${OUT}/${label}-porcelain.txt" 2>&1
    say "[${label}] porcelain lines: $(wc -l < "${OUT}/${label}-porcelain.txt")"
}

pin_state() {
    local label="$1" f
    for f in /etc/telcoin/chain-configs "$PIN"; do
        say "[${label}] $(stat -c '%U:%G %a %F %n' "$f" 2>&1)"
    done
    for f in genesis.yaml committee.yaml parameters.yaml; do
        say "[${label}] $(stat -c '%U:%G %a %F' "${PIN}/${f}" 2>&1) $(sha256sum "${PIN}/${f}" 2>&1)"
    done
}

# ---------------------------------------------------------------- phase 1
say "-- phase 1: fresh host, ensure_chain_configs_available testnet --"
[[ ! -e "$SRC" && ! -e /etc/telcoin ]] || say "WARN: not a fresh host"
remote_tag="$(GIT_TERMINAL_PROMPT=0 git ls-remote https://github.com/Telcoin-Association/telcoin-network.git "refs/tags/${TAG}^{}" | cut -f1)"
remote_def="$(GIT_TERMINAL_PROMPT=0 git ls-remote --symref https://github.com/Telcoin-Association/telcoin-network.git HEAD | head -2 | tr '\t\n' '  ')"
say "remote ${TAG}^{} = ${remote_tag}"
say "remote HEAD = ${remote_def}"
run_ensure p1-ensure
repo_state p1
d="$(swc_dir)"
say "[p1] step_write_config would copy from: ${d}"
check_dir p1 "$d"
say "[p1] submodule status: $(git -C "$SRC" submodule status 2>&1 | tr '\n' ';')"
say "[p1] .git/modules present: $([[ -d "${SRC}/.git/modules" ]] && echo yes || echo no)"
say "[p1] refs/tn-remote-tags/${TAG}: $(git -C "$SRC" rev-parse -q --verify "refs/tn-remote-tags/${TAG}^{commit}" 2>/dev/null || echo none)"
if [[ "$mode" == "old" ]]; then
    say "[p1] checkout committee.yaml sha256: $(sha256sum "${SRC}/chain-configs/testnet/committee.yaml" 2>&1)"
    say "[p1] /etc/telcoin/chain-configs exists: $([[ -e /etc/telcoin/chain-configs ]] && echo yes || echo no)"
    chown -R 1000:1000 "$OUT" 2>/dev/null || true
    exit 0
fi
pin_state p1
say "[p1] HEAD equals the tag's commit: $([[ "$(git -C "$SRC" rev-parse HEAD)" == "$remote_tag" ]] && echo yes || echo NO)"

# ---------------------------------------------------------------- phase 2
say "-- phase 2: checkout moved to the remote default branch, pinned dir emptied --"
def="$(git -C "$SRC" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || echo origin/main)"
git -C "$SRC" checkout -q -B "${def#origin/}" "$def" > "${OUT}/p2-checkout.log" 2>&1
say "[p2] moved to ${def}: checkout committee.yaml sha256 $(sha256sum < "${SRC}/chain-configs/testnet/committee.yaml" | cut -c1-16)..."
repo_state p2-before
rm -f /etc/telcoin/chain-configs/testnet/genesis.yaml /etc/telcoin/chain-configs/testnet/committee.yaml /etc/telcoin/chain-configs/testnet/parameters.yaml
say "[p2] pinned dir entries after emptying: $(find "$PIN" -mindepth 1 | wc -l)"
run_ensure p2-ensure
repo_state p2-after
cmp -s "${OUT}/p2-before-porcelain.txt" "${OUT}/p2-after-porcelain.txt" && say "[p2] porcelain unchanged: yes" || say "[p2] porcelain unchanged: NO"
pin_state p2
check_dir p2 "$(swc_dir)"
say "[p2] step_write_config would copy from: $(swc_dir)"

# ---------------------------------------------------------------- phase 3
say "-- phase 3: network cut (git wrapper fails fetch/clone/pull/ls-remote, logs every call), dir in place --"
mkdir -p /opt/gitwrap
cat > /opt/gitwrap/git <<'WRAP'
#!/bin/bash
printf 'git %s\n' "$*" >> /out/gitwrap.log
for a in "$@"; do
    case "$a" in
        fetch|clone|pull|ls-remote|remote-https|push) echo "fatal: unable to access (V-FIX-S offline wrapper)" >&2; exit 128 ;;
    esac
done
exec /usr/bin/git "$@"
WRAP
chmod 0755 /opt/gitwrap/git
: > "${OUT}/gitwrap.log"
repo_state p3-before
run_ensure p3-ensure PATH="/opt/gitwrap:${PATH}"
say "[p3] git calls made: $(wc -l < "${OUT}/gitwrap.log")"
sed 's/^/[p3]   git> /' "${OUT}/gitwrap.log" >> "$DEC"
repo_state p3-after

# ---------------------------------------------------------------- phase 4
say "-- phase 4a: pinned dir emptied, origin unreachable (wrapper): local refs/tn-remote-tags copy --"
rm -f /etc/telcoin/chain-configs/testnet/genesis.yaml /etc/telcoin/chain-configs/testnet/committee.yaml /etc/telcoin/chain-configs/testnet/parameters.yaml
: > "${OUT}/gitwrap.log"
repo_state p4a-before
run_ensure p4a-ensure PATH="/opt/gitwrap:${PATH}"
sed 's/^/[p4a]   git> /' "${OUT}/gitwrap.log" >> "$DEC"
repo_state p4a-after
cmp -s "${OUT}/p4a-before-porcelain.txt" "${OUT}/p4a-after-porcelain.txt" && say "[p4a] porcelain unchanged: yes" || say "[p4a] porcelain unchanged: NO"
pin_state p4a

say "-- phase 4b: emptied again, real DNS failure via url.insteadOf, refs/tn-remote-tags deleted: refs/tags copy --"
rm -f /etc/telcoin/chain-configs/testnet/genesis.yaml /etc/telcoin/chain-configs/testnet/committee.yaml /etc/telcoin/chain-configs/testnet/parameters.yaml
git -C "$SRC" update-ref -d "refs/tn-remote-tags/${TAG}"
say "[p4b] refs/tags/${TAG}: $(git -C "$SRC" rev-parse -q --verify "refs/tags/${TAG}^{commit}" || echo none); tn-remote-tags: $(git -C "$SRC" rev-parse -q --verify "refs/tn-remote-tags/${TAG}" || echo none)"
repo_state p4b-before
run_ensure p4b-ensure GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="url.https://unreachable.invalid/.insteadOf" GIT_CONFIG_VALUE_0="https://github.com/"
repo_state p4b-after
cmp -s "${OUT}/p4b-before-porcelain.txt" "${OUT}/p4b-after-porcelain.txt" && say "[p4b] porcelain unchanged: yes" || say "[p4b] porcelain unchanged: NO"
pin_state p4b
check_dir p4b "$PIN"

say "-- phase 4c: emptied again, origin unreachable, neither ref: rc 2 expected --"
rm -f /etc/telcoin/chain-configs/testnet/genesis.yaml /etc/telcoin/chain-configs/testnet/committee.yaml /etc/telcoin/chain-configs/testnet/parameters.yaml
git -C "$SRC" tag -d "$TAG" > /dev/null 2>&1
run_ensure p4c-ensure GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="url.https://unreachable.invalid/.insteadOf" GIT_CONFIG_VALUE_0="https://github.com/"
say "[p4c] pinned dir entries: $(find "$PIN" -mindepth 1 | wc -l)"

chown -R 1000:1000 "$OUT" 2>/dev/null || true
exit 0
