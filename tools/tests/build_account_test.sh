#!/usr/bin/env bash
# =============================================================================
# tools/tests/build_account_test.sh -- what runs as the build account stays with
# it. tn_as_build_user closes every file descriptor above 2 for the command (the
# --json event channel on fd 3, the update lock on fd 9) and, once the command
# returns, kills every process the account still runs, so a build that leaves a
# child behind has none left when its output is staged. tn_stage_binary reads the
# build output as the build account into root's staging directory (the copy is
# root's and equals the output; a symlink or a file only root can read is never
# copied), and tn_build_version runs only the caller's own staged copy.
#
#   bash tools/tests/build_account_test.sh
#   docker run --rm -v "$PWD:/w" -w /w bash:3.2 bash tools/tests/build_account_test.sh
#   docker run --rm -v "$PWD:/w" -w /w ubuntu:24.04 bash tools/tests/build_account_test.sh
#
# The descriptor cases run anywhere (a setpriv shim when this is not root with a
# real setpriv). The process, staging and symlink cases need root, setpriv and
# useradd (a throwaway system account), so they run in the ubuntu container and
# are skipped elsewhere. Maintainer tooling (not updater-tracked). bash 3.2 safe.
# =============================================================================

set -u

# shellcheck source=tools/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

T="$TN_TEST_TMP"
chmod 0711 "$T"
mkdir -p "$T/stg" "$T/bin" "$T/bsrc"
chmod 0700 "$T/stg"
TN_RELEASE_STAGING_DIR="$T/stg"
TN_BUILD_HOME="$T/bh"
export TN_RELEASE_STAGING_DIR

# Real mode: root, a setpriv that knows --clear-groups, and useradd for a
# throwaway build account. Otherwise a setpriv shim runs the command as this
# account, and the build account is this one (or nobody when this is root).
REAL=no
if [[ "$(id -u)" == "0" ]] && command -v useradd >/dev/null 2>&1 \
    && setpriv --help 2>&1 | grep -q -- '--clear-groups'; then
    if id -u tnbuildtest >/dev/null 2>&1 \
        || useradd --system --no-create-home --shell /usr/sbin/nologin tnbuildtest >/dev/null 2>&1; then
        REAL=yes
    fi
fi
if [[ "$REAL" == "yes" ]]; then
    TN_BUILD_USER=tnbuildtest
    install -d -o tnbuildtest -g "$(id -g tnbuildtest)" -m 0700 "$T/bh" "$T/bh/.cargo" "$T/bh/.cargo/bin"
else
    if [[ "$(id -u)" == "0" ]]; then
        TN_BUILD_USER=nobody
    else
        TN_BUILD_USER="$(id -un)"
    fi
    mkdir -p "$T/bh/.cargo/bin"
    cat > "$T/bin/setpriv" <<'SHIM'
#!/bin/sh
while [ $# -gt 0 ] && [ "$1" != "--" ]; do shift; done
shift
exec "$@"
SHIM
    chmod 0755 "$T/bin/setpriv"
    PATH="$T/bin:$PATH"
fi

eval "$(tn_test_source_common)"
TN_BUILD_USER="$TN_BUILD_USER" TN_BUILD_HOME="$T/bh"
stg_empty() { [[ -z "$(ls -A "$T/stg" 2>/dev/null)" ]] && echo yes || echo no; }

# ---- descriptors above 2 are closed for the build account's command -------------------
if id -u "$TN_BUILD_USER" >/dev/null 2>&1; then
    : > "$T/chan3"
    : > "$T/chan9"
    : > "$T/chan7"
    exec 3>>"$T/chan3" 7>>"$T/chan7" 9>>"$T/chan9"
    tn_as_build_user sh -c 'echo forged >&3; echo forged >&7; echo forged >&9; ls /proc/self/fd 2>/dev/null' \
        > "$T/fds" 2>/dev/null
    exec 3>&- 7>&- 9>&-
    check "fd 3 (the --json channel): nothing written by the child" "" "$(cat "$T/chan3")"
    check "fd 9 (the update lock): nothing written by the child" "" "$(cat "$T/chan9")"
    check "fd 7: nothing written by the child" "" "$(cat "$T/chan7")"
    if [[ -s "$T/fds" ]]; then
        # ls holds one descriptor of its own on /proc/self/fd (3).
        check "the child holds no descriptor above 3" "" "$(awk '$1 > 3' "$T/fds")"
    else
        skip "the child's descriptor list" "/proc is not readable"
    fi
else
    skip "descriptor cases" "no build account"
fi

# ---- real build account: nothing outlives a build, staging reads as the account ----
if [[ "$REAL" == "yes" ]]; then
    BUID="$(id -u tnbuildtest)"
    alive() {  # alive PID -- yes when PID runs and is not a zombie
        local st=""
        st="$(awk '$1 == "State:" { print $2 }' "/proc/$1/status" 2>/dev/null)" || st=""
        case "$st" in ""|Z|X) echo no ;; *) echo yes ;; esac
    }
    uid_procs() {  # the pids whose real uid is BUID, zombies aside
        local s
        for s in /proc/[0-9]*/status; do
            awk -v u="$BUID" '$1 == "State:" { st = $2 } $1 == "Uid:" { if ($2 == u && st != "Z" && st != "X") print FILENAME; exit }' "$s" 2>/dev/null
        done
    }

    # A build that starts a child in its own session, ignoring TERM and HUP and
    # holding stdout, writes the output and returns.
    cat > "$T/bh/.cargo/bin/cargo" <<'STUB'
#!/bin/sh
mkdir -p "$CARGO_TARGET_DIR/release"
printf '#!/bin/sh\nprintf "telcoin-network-cli Version: 0.1.0\\nBuild Features: adiri\\n"\n' > "$CARGO_TARGET_DIR/release/telcoin-network"
chmod 0755 "$CARGO_TARGET_DIR/release/telcoin-network"
setsid sh -c 'trap "" TERM HUP; echo $$ > "$HOME/child.pid"; sleep 30' &
i=0
while [ ! -s "$HOME/child.pid" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
exit 0
STUB
    chown tnbuildtest "$T/bh/.cargo/bin/cargo"
    chmod 0755 "$T/bh/.cargo/bin/cargo"
    chown tnbuildtest "$T/bsrc"
    started="$(date +%s)"
    rc=0; tn_source_build "$T/bsrc" testnet 2>&1 | cat > "$T/build.out" || rc=$?
    took=$(( $(date +%s) - started ))
    check_rc "build with a lingering child: rc 0" 0 "$rc"
    check "the pipeline did not wait for the child (under 20 s)" yes "$([[ $took -lt 20 ]] && echo yes || echo no)"
    cpid="$(cat "$T/bh/child.pid" 2>/dev/null)"
    check "the build's child wrote its pid" yes "$([[ "$cpid" =~ ^[0-9]+$ ]] && echo yes || echo no)"
    check "the build's child is gone once the build returns" no "$(alive "${cpid:-0}")"
    check "no process of the build account is left" "" "$(uid_procs)"

    built="$T/bh/target/release/telcoin-network"
    rc=0; staged="$(tn_stage_binary "$built" testnet "" 2>/dev/null)" || rc=$?
    check_rc "stage the build output: rc 0" 0 "$rc"
    check "the staged copy equals the build output" yes "$(cmp -s "$built" "$staged" && echo yes || echo no)"
    check "the staged copy is root's, 0755" "0 755" "$(stat -c '%u %a' "$staged" 2>/dev/null)"
    check "no process of the build account is left after staging" "" "$(uid_procs)"
    tn_staged_cleanup "$staged"
    check "staging empty after cleanup" yes "$(stg_empty)"

    # A symlink planted as the output, to a file only root can read.
    printf 'root only\n' > "$T/secret"
    chmod 0600 "$T/secret"
    rm -f "$built"
    setpriv --reuid "$BUID" --regid "$(id -g tnbuildtest)" --clear-groups ln -s "$T/secret" "$built"
    rc=0; tn_stage_binary "$built" testnet "" >/dev/null 2>&1 || rc=$?
    check "a symlink as the build output: refused, staging empty" "1 yes" "$rc $(stg_empty)"
    # A path outside staging is read as the build account, never by root: a file
    # only root can read is not copied.
    rc=0; tn_stage_binary "$T/secret" testnet "" >/dev/null 2>&1 || rc=$?
    check "a root-only file outside staging: not copied (rc 2), staging empty" "2 yes" "$rc $(stg_empty)"
    check "nothing in the build home holds the root-only text" "" "$(grep -rl 'root only' "$T/bh" 2>/dev/null)"

    # tn_build_version runs only the caller's own file.
    printf '#!/bin/sh\necho x\n' > "$T/other"
    chmod 0755 "$T/other"
    chown tnbuildtest "$T/other"
    rc=0; tn_build_version "$T/other" >/dev/null 2>&1 || rc=$?
    check_rc "tn_build_version: a file of the build account is refused" 1 "$rc"
    check "tn_build_version leaves no probe directory behind" "" "$(ls -d "$T"/bh/probe.* 2>/dev/null)"
else
    skip "lingering build child, staging as the build account, planted symlink" "needs root, setpriv and useradd"
fi

finish
