#!/usr/bin/env bash
# =============================================================================
# tools/tests/staging_sweep_test.sh -- release staging directories do not outlive
# their run. Each one (rel., rustup., tag., bin., docker-apt.) is named with the
# PID of the script run that made it, also when a subshell made it; the EXIT
# traps remove the run's own (tn_remove_inflight_tmp -> tn_staging_sweep), and a
# run that holds the update lock removes those of dead runs and unnamed ones
# (tn_staging_sweep stale). The staged binary of a pending update is kept. A TERM
# in the middle of a download, to the process group or to the script alone,
# leaves nothing behind.
#
#   bash tools/tests/staging_sweep_test.sh
#   docker run --rm -v "$PWD:/w" -w /w bash:3.2 bash tools/tests/staging_sweep_test.sh
#   docker run --rm -v "$PWD:/w" -w /w ubuntu:24.04 bash tools/tests/staging_sweep_test.sh
#
# Maintainer tooling (not updater-tracked). bash 3.2 safe.
# =============================================================================

set -u

# shellcheck source=tools/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

T="$TN_TEST_TMP"
mkdir -p "$T/stg" "$T/bin" "$T/bh/.cargo/bin" "$T/root/etc/telcoin"
tn_test_timeout_standin "$T/bh/.cargo/bin"
chmod 0700 "$T/stg"
TN_ROOT_PREFIX="$T/root"
TN_RELEASE_STAGING_DIR="$T/stg"
export TN_RELEASE_STAGING_DIR TN_ROOT_PREFIX
eval "$(tn_test_source_common)"
names() { ls -A "$T/stg" 2>/dev/null | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//'; }
want() { printf '%s\n' "$@" | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//'; }

# A live PID that is not this run's, and one that is not running.
sleep 120 &
LIVE=$!
DEAD=99999
while [[ -d "/proc/$DEAD" && $DEAD -gt 40000 ]]; do DEAD=$((DEAD - 1)); done

# ---- tn_staging_sweep: this run's entries, then stale ones -------------------------
mk() { mkdir -p "$T/stg/$1"; printf x > "$T/stg/$1/f"; }
for k in rel rustup tag bin docker-apt; do mk "$k.$$.aaaaaa"; done
mk "rel.${LIVE}.bbbbbb"      # a live run
mk "rel.${DEAD}.cccccc"      # a dead run
mk "bin.${DEAD}.pppppp"      # a dead run's staged binary that a pending update names
mk "rel.dddddd"              # unnamed: an earlier release of the scripts
mk "tn-build-log.eeeeee"     # a kept build log is not a staging directory
printf 'NETWORK=testnet\n' > "$T/root/etc/telcoin/.node-meta"
printf 'PHASE=build_complete\nBUILT_BINARY=%s\n' "$T/stg/bin.${DEAD}.pppppp/telcoin-network" > "$T/root/etc/telcoin/.pending-update"
tn_remove_inflight_tmp
check "exit sweep: only this run's entries go" \
    "$(want "bin.${DEAD}.pppppp" "rel.${DEAD}.cccccc" "rel.${LIVE}.bbbbbb" rel.dddddd tn-build-log.eeeeee)" "$(names)"
# The stale sweep tells a live run from a dead one by /proc/<pid>.
if [[ -d /proc/$$ ]]; then
    for k in rel bin; do mk "$k.$$.ffffff"; done
    tn_staging_sweep stale
    check "stale sweep: dead and unnamed go; live, this run's, pending and the log stay" \
        "$(want "bin.$$.ffffff" "bin.${DEAD}.pppppp" "rel.$$.ffffff" "rel.${LIVE}.bbbbbb" tn-build-log.eeeeee)" "$(names)"
    rm -f "$T/root/etc/telcoin/.pending-update"
    tn_staging_sweep stale
    check "stale sweep without a pending update: the dead run's staged binary goes" \
        "$(want "bin.$$.ffffff" "rel.$$.ffffff" "rel.${LIVE}.bbbbbb" tn-build-log.eeeeee)" "$(names)"
    ln -s "$T/stg/rel.${LIVE}.bbbbbb" "$T/stg/rel.${DEAD}.symlnk"
    tn_staging_sweep stale
    check "a symlink is never followed or removed" yes "$([[ -L "$T/stg/rel.${DEAD}.symlnk" && -f "$T/stg/rel.${LIVE}.bbbbbb/f" ]] && echo yes || echo no)"
else
    skip "stale sweep: live, dead and pending runs; symlinks" "/proc absent: the sweep reads run PIDs there"
fi
rm -rf "$T/stg"/* "$T/stg"/.[!.]* 2>/dev/null

# ---- staging names carry the run's PID ------------------------------------------------
if [[ "$(id -u)" == "0" ]]; then BU=nobody; else BU="$(id -un)"; fi
cat > "$T/bin/setpriv" <<'SHIM'
#!/bin/sh
while [ $# -gt 0 ] && [ "$1" != "--" ]; do shift; done
shift
exec "$@"
SHIM
# curl: write part of the -o file, say so, then sleep for $T/curl.sleep seconds.
cat > "$T/bin/curl" <<SHIM
#!/bin/sh
out=""
while [ \$# -gt 0 ]; do
    if [ "\$1" = "-o" ]; then out="\$2"; shift; fi
    shift
done
[ -n "\$out" ] && printf 'partial' > "\$out"
: > "$T/curl.reached"
sleep "\$(cat "$T/curl.sleep" 2>/dev/null || echo 0)"
exit 0
SHIM
chmod 0755 "$T/bin/setpriv" "$T/bin/curl"
printf '#!/bin/sh\nprintf "telcoin-network-cli Version: 0.1.0\\nBuild Features: adiri\\n"\n' > "$T/built"
chmod 0755 "$T/built"
if id -u "$BU" >/dev/null 2>&1; then
    staged="$(PATH="$T/bin:$PATH" TN_BUILD_USER="$BU" TN_BUILD_HOME="$T/bh" tn_stage_binary "$T/built" testnet "" 2>/dev/null)"
    check "a subshell's staged binary is named with this run's PID" yes "$([[ "$staged" == "$T/stg/bin.$$."*/telcoin-network ]] && echo yes || echo "no: $staged")"
    tn_staged_cleanup "$staged"
else
    skip "staged binary name" "no account $BU"
fi

# ---- TERM mid-download -------------------------------------------------------------
# A driver with the scripts' trap pattern downloads rustup-init (the release fetch
# downloads the same way) inside a command substitution, like the scripts do.
cat > "$T/driver.sh" <<EOF
echo \$\$ > "$T/driver.pid"
TN_ROOT_PREFIX="$T/root"
. "$TN_TEST_REPO/lib/common.sh" >/dev/null 2>&1
set +e
PATH="$T/bin:\$PATH"
TN_BUILD_USER="$BU" TN_BUILD_HOME="$T/bh" TN_RELEASE_STAGING_DIR="$T/stg"
trap tn_remove_inflight_tmp EXIT
trap 'exit 143' TERM
out="\$(tn_rustup_ensure)"
echo DRIVER_END
EOF
term_case() {  # term_case NAME SLEEP GROUP
    local pid i
    rm -f "$T/curl.reached" "$T/driver.pid" "$T/driver.out"
    printf '%s\n' "$2" > "$T/curl.sleep"
    setsid "$BASH" "$T/driver.sh" > "$T/driver.out" 2>&1 < /dev/null &
    pid=$!
    i=0
    while [[ ! -e "$T/curl.reached" || ! -s "$T/driver.pid" ]] && [[ $i -lt 100 ]]; do sleep 0.1; i=$((i + 1)); done
    if [[ ! -e "$T/curl.reached" ]]; then
        check "$1: the download started" yes no
        kill -KILL "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
        return
    fi
    check "$1: a rustup staging directory exists mid-download" yes "$(ls -d "$T/stg"/rustup.* >/dev/null 2>&1 && echo yes || echo no)"
    if [[ "$3" == "group" ]]; then
        kill -TERM -- "-$(cat "$T/driver.pid")" 2>/dev/null
    else
        kill -TERM "$(cat "$T/driver.pid")" 2>/dev/null
    fi
    wait "$pid" 2>/dev/null
    sleep 0.2
    check "$1: no staging left" "" "$(names)"
    check "$1: the run stopped" no "$(grep -q DRIVER_END "$T/driver.out" && echo yes || echo no)"
}
if ! command -v setsid >/dev/null 2>&1; then
    skip "TERM mid-download" "setsid absent"
elif ! id -u "$BU" >/dev/null 2>&1; then
    skip "TERM mid-download" "no account $BU"
else
    term_case "TERM to the process group mid-download" 30 group
    term_case "TERM to the script alone mid-download" 2 alone
fi

kill "$LIVE" 2>/dev/null
wait "$LIVE" 2>/dev/null
finish
