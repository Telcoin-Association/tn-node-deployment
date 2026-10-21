#!/usr/bin/env bash
# =============================================================================
# tools/tests/addon_oldlib_test.sh -- firewall-setup.sh, setup-vpn.sh and
# setup-observability.sh with a library older than they are: each stops with
# exit 2 and one message naming update-scripts.sh before anything else (no ufw
# call, no file written), and a --json run still ends with a done event. With
# the current library the checks pass.
#
#   bash tools/tests/addon_oldlib_test.sh
#   docker run --rm -v "$PWD:/w" -w /w bash:3.2 bash tools/tests/addon_oldlib_test.sh
#
# The old library is lib/common.sh, lib/fallback.sh and lib/observability.sh at
# 037c810 (git show) when git and that commit are at hand; otherwise the current
# files with addon_meta_get and obs_quorum_guard renamed away.
# =============================================================================

set -u

# shellcheck source=tools/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
T="$TN_TEST_TMP"
export TN_ROOT_PREFIX="$T/root"
export CALLS="$T/calls"
mkdir -p "$T/old/lib" "$T/new" "$T/bin" "$TN_ROOT_PREFIX/etc/telcoin"
printf 'NETWORK=testnet\nOWNERSHIP_LAYOUT=2\n' > "$TN_ROOT_PREFIX/etc/telcoin/.node-meta"
for c in ufw systemctl apt-get curl wg wg-quick visudo useradd usermod; do
    printf '#!/usr/bin/env bash\nprintf "%%s %%s\\n" %s "$*" >> "${CALLS:?}"\nexit 0\n' "$c" > "$T/bin/$c"
done
chmod +x "$T/bin/"*
: > "$CALLS"

# The old tree: the three scripts of this checkout beside an old lib/.
cp -R "${TN_TEST_REPO}/lib/." "$T/old/lib/"
old_from=""
if command -v git >/dev/null 2>&1 \
    && git -C "$TN_TEST_REPO" cat-file -e 037c810:lib/common.sh 2>/dev/null; then
    for f in common.sh fallback.sh observability.sh; do
        git -C "$TN_TEST_REPO" show "037c810:lib/${f}" > "$T/old/lib/${f}"
    done
    old_from="037c810"
else
    sed -e 's/^addon_meta_get()/addon_meta_get_gone()/' "${TN_TEST_REPO}/lib/common.sh" > "$T/old/lib/common.sh"
    sed -e 's/^obs_quorum_guard()/obs_quorum_guard_gone()/' "${TN_TEST_REPO}/lib/observability.sh" > "$T/old/lib/observability.sh"
    old_from="renamed helpers"
fi
for s in firewall-setup.sh setup-vpn.sh setup-observability.sh; do
    cp "${TN_TEST_REPO}/${s}" "$T/old/${s}"
done
printf 'old library: %s\n' "$old_from"

# old_run NAME SCRIPT ARGS... -- run SCRIPT from the old tree; RC, OUT, ERR.
old_run() {
    local name="$1"
    shift
    : > "$CALLS"
    RC=0
    ( cd "$T/old" && PATH="$T/bin:$PATH" bash "$@" ) >"$T/out" 2>"$T/err" </dev/null || RC=$?
    OUT="$(cat "$T/out")"
    ERR="$(cat "$T/err")"
    check_rc "${name}: exit 2" 2 "$RC"
    check "${name}: names update-scripts.sh" "yes" \
        "$(printf '%s\n%s\n' "$OUT" "$ERR" | grep -qE '(is|are) older than this script.*run update-scripts.sh' && echo yes)"
    check "${name}: one message" "1" \
        "$(printf '%s\n' "$ERR" | grep -cE '(is|are) older than this script')"
    check "${name}: no command run" "" "$(cat "$CALLS")"
    check "${name}: .node-meta untouched" "NETWORK=testnet
OWNERSHIP_LAYOUT=2" "$(cat "$TN_ROOT_PREFIX/etc/telcoin/.node-meta")"
}

old_run "firewall --enable" firewall-setup.sh --enable --ssh-from 203.0.113.0/24
old_run "firewall --reset" firewall-setup.sh --reset --ssh-anywhere
old_run "firewall --json --enable" firewall-setup.sh --json --enable --ssh-from 203.0.113.0/24
check "firewall --json: stdout is the done event" "yes" \
    "$(tail -n1 "$T/out" | grep -q '^{"event":"done","ok":false,.*update-scripts.sh' && echo yes)"
old_run "vpn --enable" setup-vpn.sh --enable
old_run "vpn --sync-keys" setup-vpn.sh --sync-keys
old_run "vpn --status" setup-vpn.sh --status
old_run "observability --json --enable-logs" setup-observability.sh --json --enable-logs --region us
check "observability --json: stdout is the done event" "yes" \
    "$(tail -n1 "$T/out" | grep -q '^{"event":"done","ok":false,.*update-scripts.sh' && echo yes)"
check "observability --json: one done event" "1" "$(grep -c '"event":"done"' "$T/out")"
old_run "observability menu" setup-observability.sh

# The current library passes every check.
for s in firewall-setup.sh setup-vpn.sh setup-observability.sh; do
    grep -v '^main "\$@"$' "${TN_TEST_REPO}/${s}" > "$T/new/${s}"
done
ln -s "${TN_TEST_REPO}/lib" "$T/new/lib"
check_rc "current lib: fw_require_lib passes" 0 \
    "$(bash -c 'source "$1" >/dev/null 2>&1; fw_require_lib false >/dev/null 2>&1; echo $?' _ "$T/new/firewall-setup.sh")"
check_rc "current lib: vpn_require_lib passes" 0 \
    "$(bash -c 'source "$1" >/dev/null 2>&1; vpn_require_lib >/dev/null 2>&1; echo $?' _ "$T/new/setup-vpn.sh")"
check_rc "current lib: addons_require_lib passes" 0 \
    "$(bash -c 'source "$1" >/dev/null 2>&1; addons_require_lib >/dev/null 2>&1; echo $?' _ "$T/new/setup-observability.sh")"

finish
