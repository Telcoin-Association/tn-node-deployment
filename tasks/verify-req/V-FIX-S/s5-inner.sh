#!/usr/bin/env bash
# =============================================================================
# s5-inner.sh -- V-FIX-S S5: the known open items of spec 6.2 that belong to
# the fix (FIX-T F1-F6; F7 is shown by s2-inner.sh) and the unlisted cases of
# the brief, as root in a disposable ubuntu:26.04 container (through vrun.sh).
# One real clone at the tag from GitHub first (s2-case.sh infra, consent
# given); every later step is a fresh process. "Offline" is a real DNS failure
# through url.insteadOf; "origin reachable, tag gone" points origin at another
# public repository of the same organisation that has no such tag.
# =============================================================================
set -u
# shellcheck source=tasks/verify-req/V-FIX-S/vcommon.sh
. /h/vcommon.sh
v_setup util-linux

# ens LABEL [VAR=VALUE ...] -- ensure_chain_configs_available testnet in a
# fresh process (library sourced as the scripts do, consenting confirm).
ens() {
    local label="$1"
    shift
    : > /out/gitwrap.log
    env -i PATH="$WRAPPATH" HOME=/root TN_ASSUME_YES=true "$@" bash -c '
        source /s/lib/common.sh
        NETWORK=testnet
        rc=0
        ensure_chain_configs_available testnet || rc=$?
        echo "ENSURE_RC=${rc}"' > "${OUT}/${label}.log" 2>&1
    cp /out/gitwrap.log "${OUT}/${label}.git"
    say "[${label}] $(grep -m1 '^ENSURE_RC=' "${OUT}/${label}.log" || echo 'ENSURE_RC=missing') git-calls=$(wc -l < "${OUT}/${label}.git")"
    grep -vE '^ENSURE_RC=|^>>> Ensuring|^$' "${OUT}/${label}.log" | sed "s/^/[${label}]   | /" >> "$DEC"
}
pin_files() { find "$PIN" -maxdepth 1 -mindepth 1 -printf '%f(%y,%m,%u) ' 2>/dev/null; echo; }

say "== baseline: clone at the tag (consent given) =="
run_case base-infra infra plain '\n\ny\n'
MAINSHA="$(git -C "$SRC" rev-parse origin/main)"
TAGOBJ="$(git -C "$SRC" rev-parse "refs/tags/${TAG}")"
say "[base] HEAD=$(git -C "$SRC" rev-parse HEAD) origin/main=${MAINSHA}"

say "== F1: pin mismatch (local copy of the tag moved to main's commit, offline) =="
empty_pin
git -C "$SRC" update-ref "refs/tn-remote-tags/${TAG}" "$MAINSHA"
ens f1 "${OFFLINE[@]}"
stage="$(grep -oE '/tmp/tmp\.[A-Za-z0-9]+' "${OUT}/f1.log" | head -1)"
say "[f1] staging path named: ${stage:-none}; exists now: $([[ -n "$stage" && -e "$stage" ]] && echo yes || echo no); pinned dir: $(pin_files)"
git -C "$SRC" update-ref "refs/tn-remote-tags/${TAG}" "$(git -C "$SRC" rev-parse "${TAG}^{commit}")"

say "== F2: committee.yaml in the destination is a directory (a stale entry) =="
empty_pin
mkdir -p "${PIN}/committee.yaml"
ens f2-run1
say "[f2] after run 1: $(pin_files)"
ens f2-run2
say "[f2] after run 2: $(pin_files)"
rmdir "${PIN}/committee.yaml"

say "== F3: destination a symlink to a nobody-owned 0777 directory holding the pinned files =="
ens f3-prep
mkdir -p /srv/evil
cp "${PIN}/genesis.yaml" "${PIN}/committee.yaml" "${PIN}/parameters.yaml" /srv/evil/
chown -R nobody /srv/evil
chmod 0777 /srv/evil
mv "$PIN" /etc/telcoin/chain-configs/testnet.real
ln -s /srv/evil "$PIN"
ens f3
run_case f3-write write plain ''
rm -f "$PIN"
mv /etc/telcoin/chain-configs/testnet.real "$PIN"

say "== F3b (unlisted): hand-made pinned dir 0700 with 0600 files (umask 077), contents pinned =="
mv "$PIN" /etc/telcoin/chain-configs/testnet.real
( umask 077; mkdir "$PIN"; cp /etc/telcoin/chain-configs/testnet.real/genesis.yaml /etc/telcoin/chain-configs/testnet.real/committee.yaml /etc/telcoin/chain-configs/testnet.real/parameters.yaml "$PIN"/ )
say "[f3b] pinned before: $(stat -c '%a' "$PIN") $(pin_files)"
run_case f3b-infra infra plain '\n\n'
say "[f3b] pinned after infra: $(stat -c '%a' "$PIN") $(pin_files)"
run_case f3b-write write plain ''
rm -f "${PIN}/genesis.yaml" "${PIN}/committee.yaml" "${PIN}/parameters.yaml"
rmdir "$PIN"
mv /etc/telcoin/chain-configs/testnet.real "$PIN"

say "== F4: origin reachable but without the tag (insteadOf to tn-contracts) =="
empty_pin
ens f4 GIT_CONFIG_COUNT=1 "GIT_CONFIG_KEY_0=url.https://github.com/Telcoin-Association/tn-contracts.git.insteadOf" "GIT_CONFIG_VALUE_0=https://github.com/Telcoin-Association/telcoin-network.git"
say "[f4] fetch by hand: $(GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=url.https://github.com/Telcoin-Association/tn-contracts.git.insteadOf GIT_CONFIG_VALUE_0=https://github.com/Telcoin-Association/telcoin-network.git git -C "$SRC" fetch --no-tags origin "+refs/tags/${TAG}:refs/v-fix-s/x" 2>&1 | head -1)"

say "== F5: the checkout is a git worktree (.git is a file) =="
empty_pin
mv "$SRC" /opt/tn-main
git -C /opt/tn-main worktree add -q --detach "$SRC" "$TAG" > "${OUT}/f5-worktree.log" 2>&1
say "[f5] ${SRC}/.git is: $(stat -c '%F' "${SRC}/.git")"
ens f5
say "[f5] worktree still there: $([[ -f "${SRC}/.git" ]] && echo yes || echo no)"
git -C /opt/tn-main worktree remove --force "$SRC" > /dev/null 2>&1
mv /opt/tn-main "$SRC"

say "== F6: the run killed while the staging directory exists (setup-node traps, SIGTERM) =="
empty_pin
mkdir -p /opt/gitslow
cat > /opt/gitslow/git <<'SLOW'
#!/bin/bash
case "$*" in *committee.yaml*) sleep 6 ;; esac
exec /usr/bin/git "$@"
SLOW
chmod 0755 /opt/gitslow/git
before="$(find /tmp -maxdepth 1 -name 'tmp.*' | wc -l)"
printf '\n\n' > "${OUT}/f6.in"
env -i PATH="/opt/gitslow:${BASEPATH}" HOME=/root TERM=dumb bash /h/s2-case.sh infra plain < "${OUT}/f6.in" > "${OUT}/f6.out" 2>&1 &
pid=$!
sleep 4
kill -TERM "$pid" 2>/dev/null
wait "$pid"
say "[f6] rc=$? tmp.* before=${before} after=$(find /tmp -maxdepth 1 -name 'tmp.*' | wc -l): $(find /tmp -maxdepth 2 -path '/tmp/tmp.*' | tr '\n' ' ')"
pkill -f 'sleep 6' 2>/dev/null || true

say "== U1: the update lock is held while the consent prompt waits =="
mv "$SRC" /opt/telcoin-source.keep
empty_pin
rm -f /tmp/v-fifo
mkfifo /tmp/v-fifo
env -i PATH="$WRAPPATH" HOME=/root TERM=dumb bash /h/s2-case.sh infra plain < /tmp/v-fifo > "${OUT}/u1.out" 2>&1 &
pid=$!
exec 7> /tmp/v-fifo
printf '\n\n' >&7
sleep 3
if flock -n /run/telcoin/update.lock true; then lockstate=free; else lockstate=HELD; fi
say "[u1] at the prompt: lock ${lockstate}; prompt shown: $(grep -c 'Clone the repository now' "${OUT}/u1.out")"
printf 'n\n' >&7
exec 7>&-
wait "$pid"
say "[u1] rc=$? $(grep -m1 'Skipped' "${OUT}/u1.out")"
mv /opt/telcoin-source.keep "$SRC"

say "== U2: TN_ROOT_PREFIX=/r: nothing written outside /r =="
mkdir -p /r/opt
cp -a "$SRC" /r/opt/telcoin-source
touch /opt/u2-marker
sleep 1
ens u2 TN_ROOT_PREFIX=/r
say "[u2] /r pinned: $(find /r/etc/telcoin/chain-configs -type f | wc -l) files; written outside /r: $(find / -xdev -newer /opt/u2-marker ! -path '/r*' ! -path '/out*' ! -path '/proc*' ! -path '/sys*' ! -path '/dev*' 2>/dev/null | tr '\n' ' ')"
mv /r/opt/telcoin-source /r/opt/telcoin-source.keep
ens u2-clone TN_ROOT_PREFIX=/r "${OFFLINE[@]}"

say "== U3: a stale pinned dir from a release with other pins (committee from main) =="
empty_pin
ens u3-prep
git -C "$SRC" show "${MAINSHA}:chain-configs/testnet/committee.yaml" > "${PIN}/committee.yaml"
ens u3-online
say "[u3] committee now: $(sha256sum < "${PIN}/committee.yaml" | cut -c1-16)"
git -C "$SRC" show "${MAINSHA}:chain-configs/testnet/committee.yaml" > "${PIN}/committee.yaml"
git -C "$SRC" update-ref -d "refs/tn-remote-tags/${TAG}"
git -C "$SRC" tag -d "$TAG" > /dev/null
ens u3-offline-nocopy "${OFFLINE[@]}"
say "[u3] committee after the failed run: $(sha256sum < "${PIN}/committee.yaml" | cut -c1-16)"
git -C "$SRC" update-ref "refs/tags/${TAG}" "$TAGOBJ"

say "== U4: proxy and GIT_DIR in the environment reach git =="
empty_pin
ens u4-proxy https_proxy=http://127.0.0.1:9 HTTPS_PROXY=http://127.0.0.1:9
mkdir -p /opt/other
git init -q /opt/other
empty_pin
ens u4-gitdir GIT_DIR=/opt/other/.git

say "== U5: plain run, the consent prompt cannot be answered (stdin ends) =="
mv "$SRC" /opt/telcoin-source.keep
empty_pin
run_case u5-eof infra plain '\n\n'
run_case u5-write-eof write plain ''
run_case u5-devnull infra plain ''
mv /opt/telcoin-source.keep "$SRC"

chown -R 1000:1000 "$OUT" 2>/dev/null || true
exit 0
