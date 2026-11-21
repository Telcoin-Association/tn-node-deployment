#!/usr/bin/env bash
# =============================================================================
# vcommon.sh -- helpers sourced by s3-inner.sh, s4-inner.sh and s5-inner.sh
# (inside the container, as root): the output file, apt, a logging git wrapper
# and run_case (one fresh env -i process of s2-case.sh). Same shape as the
# helpers in s2-inner.sh.
# =============================================================================
OUT=/out
DEC="${OUT}/decisive.txt"
SRC=/opt/telcoin-source
PIN=/etc/telcoin/chain-configs/testnet
TAG=v0.16.0-adiri
BASEPATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
WRAPPATH="/opt/gitwrap:${BASEPATH}"
OFFLINE=(GIT_CONFIG_COUNT=1 "GIT_CONFIG_KEY_0=url.https://unreachable.invalid/.insteadOf" "GIT_CONFIG_VALUE_0=https://github.com/")
: > "$DEC"

say() { printf '%s\n' "$*" >> "$DEC"; printf '%s\n' "$*"; }

v_setup() {
    if ! { apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends git ca-certificates "$@"; } > "${OUT}/apt.log" 2>&1; then
        say "APT_FAILED"
        exit 3
    fi
    mkdir -p /opt/gitwrap
    cat > /opt/gitwrap/git <<'WRAP'
#!/bin/bash
fd9=closed
[[ -e /proc/$$/fd/9 ]] && fd9="OPEN"
printf 'git %s [fd9 %s]\n' "$*" "$fd9" >> /out/gitwrap.log
exec /usr/bin/git "$@"
WRAP
    chmod 0755 /opt/gitwrap/git
    : > /out/gitwrap.log
}

empty_pin() { rm -f /etc/telcoin/chain-configs/testnet/genesis.yaml /etc/telcoin/chain-configs/testnet/committee.yaml /etc/telcoin/chain-configs/testnet/parameters.yaml; }

# run_case LABEL STEP MODE STDIN-TEXT [VAR=VALUE ...] -- s2-case.sh in a fresh
# env -i process; stdout to LABEL.out, stderr to LABEL.err, git calls to
# LABEL.git. Prints rc, bash errors and every line naming the chain configs.
run_case() {
    local label="$1" step="$2" mode="$3" input="$4" rc=0
    shift 4
    printf '%b' "$input" > "${OUT}/${label}.in"
    : > /out/gitwrap.log
    env -i PATH="$WRAPPATH" HOME=/root TERM=dumb "$@" bash /h/s2-case.sh "$step" "$mode" \
        < "${OUT}/${label}.in" > "${OUT}/${label}.out" 2> "${OUT}/${label}.err" || rc=$?
    cp /out/gitwrap.log "${OUT}/${label}.git"
    say "[${label}] ${step}/${mode} rc=${rc} git-calls=$(wc -l < "${OUT}/${label}.git")"
    grep -nE 'line [0-9]+: |unbound variable|command not found|syntax error|bad substitution' "${OUT}/${label}.err" \
        | sed "s/^/[${label}]   BASH-ERROR: /" >> "$DEC"
    cat "${OUT}/${label}.out" "${OUT}/${label}.err" \
        | grep -E 'hain.config|clone|Clone|Fetch|pinned|Skipped|owned|Found|copied|tree/|not found|local copy|older than|ERROR|WARN' \
        | grep -v '^{' | sed "s/^/[${label}]   | /" >> "$DEC"
    if [[ "$mode" == "json" ]]; then
        grep -E '"event":"(error|done)"' "${OUT}/${label}.out" | sed "s/^/[${label}]   json| /" >> "$DEC"
    fi
}
