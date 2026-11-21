#!/usr/bin/env bash
# =============================================================================
# s2-inner.sh -- V-FIX-S S2: setup-node.sh end to end (fixture style, through
# s2-case.sh), as root in a disposable ubuntu:26.04 container. /s = scripts at
# the tip (read-only), /h = this harness, /out = output. The clone and fetch
# go to the real public repository; "unreachable" is a real DNS failure
# (url.https://unreachable.invalid/.insteadOf through GIT_CONFIG_*). Every
# case is a fresh process started with env -i (no shared environment).
# =============================================================================
set -u
OUT=/out
DEC="${OUT}/decisive.txt"
SRC=/opt/telcoin-source
PIN=/etc/telcoin/chain-configs/testnet
TAG=v0.16.0-adiri
BASEPATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
OFFLINE=(GIT_CONFIG_COUNT=1 "GIT_CONFIG_KEY_0=url.https://unreachable.invalid/.insteadOf" "GIT_CONFIG_VALUE_0=https://github.com/")
: > "$DEC"
say() { printf '%s\n' "$*" >> "$DEC"; printf '%s\n' "$*"; }

if ! { apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends git ca-certificates; } > "${OUT}/apt.log" 2>&1; then
    say "APT_FAILED"; exit 3
fi
say "git: $(git --version); setup-node $(grep -m1 '^readonly SCRIPT_VERSION=' /s/setup-node.sh)"

# A logging git wrapper: argv, and whether fd 9 (the update lock) is open in it.
mkdir -p /opt/gitwrap
cat > /opt/gitwrap/git <<'WRAP'
#!/bin/bash
fd9=closed
[[ -e /proc/$$/fd/9 ]] && fd9="OPEN->$(readlink /proc/$$/fd/9)"
printf 'git %s [fd9 %s] [GIT_ALLOW_PROTOCOL=%s]\n' "$*" "$fd9" "${GIT_ALLOW_PROTOCOL:-unset}" >> /out/gitwrap.log
exec /usr/bin/git "$@"
WRAP
chmod 0755 /opt/gitwrap/git
WRAPPATH="/opt/gitwrap:${BASEPATH}"

empty_pin() { rm -f /etc/telcoin/chain-configs/testnet/genesis.yaml /etc/telcoin/chain-configs/testnet/committee.yaml /etc/telcoin/chain-configs/testnet/parameters.yaml; }

# run_case LABEL STEP MODE STDIN-TEXT [VAR=VALUE ...]
run_case() {
    local label="$1" step="$2" mode="$3" input="$4" rc=0
    shift 4
    printf '%b' "$input" > "${OUT}/${label}.in"
    : > /out/gitwrap.log
    env -i PATH="$WRAPPATH" HOME=/root TERM=dumb "$@" bash /h/s2-case.sh "$step" "$mode" \
        < "${OUT}/${label}.in" > "${OUT}/${label}.out" 2> "${OUT}/${label}.err" || rc=$?
    cp /out/gitwrap.log "${OUT}/${label}.git"
    say "[${label}] ${step}/${mode} rc=${rc} completed=$(grep -c '^S2_STEP_COMPLETED' "${OUT}/${label}.err" "${OUT}/${label}.out" | awk -F: '{s+=$2} END {print s}') git-calls=$(wc -l < "${OUT}/${label}.git")"
    grep -nE 'line [0-9]+: |unbound variable|command not found|syntax error|bad substitution' "${OUT}/${label}.err" \
        | sed "s/^/[${label}]   BASH-ERROR: /" >> "$DEC"
    grep -E 'chain|Chain|clone|Clone|Fetch|fetch|pinned|Skipped|owned|Found|copied|Copy |tree/|not found|local copy|origin|Infrastructure ready' "${OUT}/${label}.err" \
        | grep -v '^S2_' | sed "s/^/[${label}]   err| /" >> "$DEC"
    if [[ "$mode" == "json" ]]; then
        grep -E '"event":"(error|done)"|chain|Chain|Fetch|clone|Clone|WARNING' "${OUT}/${label}.out" \
            | sed "s/^/[${label}]   json| /" >> "$DEC"
        say "[${label}]   json lines total=$(wc -l < "${OUT}/${label}.out") non-json=$(grep -vc '^{' "${OUT}/${label}.out")"
    fi
    sed "s/^/[${label}]   git> /" "${OUT}/${label}.git" >> "$DEC"
}

repo_head() { git -C "$SRC" rev-parse HEAD 2>/dev/null || echo none; }

# ------------------------------------------------------------- C1 refused
say "== C1 interactive, clone consent refused (fresh host) =="
run_case c1-infra infra plain '\n\nn\n'
say "[c1] checkout exists: $([[ -e "$SRC" ]] && echo yes || echo no); pinned dir exists: $([[ -e "$PIN" ]] && echo yes || echo no)"
run_case c1-write write plain '\n'

# ------------------------------------------------------------- C2 given
say "== C2 interactive, clone consent given (fresh checkout from GitHub) =="
run_case c2-infra infra plain '\n\ny\n'
say "[c2] HEAD=$(repo_head) tag=$(git -C "$SRC" rev-parse "${TAG}^{commit}" 2>/dev/null) submodules=$(git -C "$SRC" submodule status 2>&1 | cut -c1 | tr -d '\n')"
say "[c2] $(stat -c '%U:%G %a %n' /etc/telcoin/chain-configs "$PIN" "${PIN}/genesis.yaml" "${PIN}/committee.yaml" "${PIN}/parameters.yaml" | tr '\n' ';')"
run_case c2-write write plain ''
say "[c2] copies: $(sha256sum /var/lib/telcoin/genesis/genesis.yaml /var/lib/telcoin/genesis/committee.yaml /var/lib/telcoin/parameters.yaml 2>&1 | cut -c1-16 | tr '\n' ' ')"
TAGOBJ="$(git -C "$SRC" rev-parse "refs/tags/${TAG}")"

# ------------------------------------------------------------- C3 UI path
say "== C3 UI path: checkout moved to origin/main, pinned emptied; keygen and finalize as two env -i processes =="
git -C "$SRC" checkout -q -B main origin/main
before="$(repo_head)"
empty_pin
rm -f /var/lib/telcoin/genesis/genesis.yaml /var/lib/telcoin/genesis/committee.yaml /var/lib/telcoin/parameters.yaml
run_case c3-keygen infra json ''
say "[c3] HEAD unchanged: $([[ "$(repo_head)" == "$before" ]] && echo yes || echo NO); porcelain lines: $(git -C "$SRC" status --porcelain | wc -l)"
run_case c3-finalize write json ''
say "[c3] copies: $(sha256sum /var/lib/telcoin/genesis/committee.yaml 2>&1 | cut -c1-16)"

# ------------------------------------------------------------- C4 genesis dir
say "== C4 --genesis-dir (TN_GENESIS_DIR) given: used as is, no git =="
mkdir -p /srv/gd-good /srv/gd-bad
cp "${PIN}/genesis.yaml" "${PIN}/committee.yaml" "${PIN}/parameters.yaml" /srv/gd-good/
cp "${PIN}/genesis.yaml" "${PIN}/parameters.yaml" /srv/gd-bad/
cp "${SRC}/chain-configs/testnet/committee.yaml" /srv/gd-bad/
chmod 0755 /srv/gd-good /srv/gd-bad
empty_pin
run_case c4-good-infra infra plain '\n\n' TN_GENESIS_DIR=/srv/gd-good
say "[c4] pinned dir files after: $(find "$PIN" -type f | wc -l)"
run_case c4-good-write write plain '' TN_GENESIS_DIR=/srv/gd-good
run_case c4-bad-infra infra plain '\n\n' TN_GENESIS_DIR=/srv/gd-bad
run_case c4-bad-json infra json '' TN_GENESIS_DIR=/srv/gd-bad

# ------------------------------------------------------------- C5 failed clone
say "== C5 failed clone (fresh host, origin unreachable) =="
mv "$SRC" /opt/telcoin-source.keep
empty_pin
run_case c5-plain infra plain '\n\ny\n' "${OFFLINE[@]}"
say "[c5] checkout left behind: $([[ -e "$SRC" ]] && echo yes || echo no)"
run_case c5-json infra json '' "${OFFLINE[@]}"
mv /opt/telcoin-source.keep "$SRC"

# ------------------------------------------------------------- C6 failed fetch
say "== C6 failed fetch (checkout present, origin unreachable) =="
empty_pin
run_case c6a-local-copy infra plain '\n\n' "${OFFLINE[@]}"
empty_pin
git -C "$SRC" update-ref -d "refs/tn-remote-tags/${TAG}"
git -C "$SRC" tag -d "$TAG" > /dev/null
run_case c6b-plain infra plain '\n\n' "${OFFLINE[@]}"
run_case c6b-json infra json '' "${OFFLINE[@]}"
git -C "$SRC" update-ref "refs/tags/${TAG}" "$TAGOBJ"

# ------------------------------------------------------------- C7 ownership
say "== C7 checkout owned by another account / a symlink / .git not ours =="
empty_pin
chown nobody "$SRC"
run_case c7a-plain infra plain '\n\n'
run_case c7a-json infra json ''
chown root "$SRC"
mv "$SRC" /opt/telcoin-source.real
ln -s /opt/telcoin-source.real "$SRC"
run_case c7b-symlink infra plain '\n\n'
rm -f "$SRC"
mv /opt/telcoin-source.real "$SRC"
chown -R nobody "${SRC}/.git"
run_case c7c-dotgit-other infra plain '\n\n'
chown -R root "${SRC}/.git"
run_case c7d-restored infra plain '\n\n'
say "[c7] HEAD=$(repo_head) (main expected)"

chown -R 1000:1000 "$OUT" 2>/dev/null || true
exit 0
