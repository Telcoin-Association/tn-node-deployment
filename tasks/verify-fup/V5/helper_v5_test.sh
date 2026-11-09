#!/usr/bin/env bash
# =============================================================================
# tasks/verify-fup/V5/helper_v5_test.sh -- V5's checks of
# `telcoin-ui-helper firewall-enable [<ssh>|-] [<p2p>]` (ui/telcoin-ui-helper.sh).
# The helper is sourced (sourcing runs nothing) and its main runs in a subshell
# under set -euo pipefail; the engine is a fake that records argv and cwd.
#   bash tasks/verify-fup/V5/helper_v5_test.sh     (V5_SRC overrides the tree)
# =============================================================================
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${V5_SRC:-$(cd "${HERE}/../../.." && pwd)}"
CHECKS=0; FAILS=0
T="$(mktemp -d "${TMPDIR:-/tmp}/v5helper.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT
check() {
    CHECKS=$((CHECKS + 1))
    if [[ "$2" == "$3" ]]; then printf 'ok    %s\n' "$1"; return 0; fi
    FAILS=$((FAILS + 1)); printf 'FAIL  %s\n      expected: %s\n      actual:   %s\n' "$1" "$2" "$3"; return 1
}
# shellcheck source=/dev/null
source "$SRC/ui/telcoin-ui-helper.sh"
set +e +o pipefail
mkdir -p "$T/engine" "$T/root/etc/telcoin" "$T/audit"
# shellcheck disable=SC2034
{
    FIREWALL_SCRIPT="$T/engine/firewall-setup.sh"
    HELPER_LIB="$SRC/lib/common.sh"
    LIB_REQUIRE_ROOT=0
    ETC_DIR="$T/root/etc/telcoin"
    AUDIT_LOG="$T/audit/audit.log"
    AUDIT_LOGGER=""
}
ENGLOG="$T/engine.log"
export ENGLOG
cat > "$T/engine/firewall-setup.sh" <<'V5E'
# fake engine: knows --ssh-from and --p2p-from
{ printf 'engine'; for a in "$@"; do printf ' [%s]' "$a"; done; printf ' cwd=[%s]\n' "$PWD"; } >> "$ENGLOG"
exit 0
V5E
cat > "$T/engine/firewall-old.sh" <<'V5E'
# fake engine of an older release: knows --ssh-from only
{ printf 'old-engine'; for a in "$@"; do printf ' [%s]' "$a"; done; printf '\n'; } >> "$ENGLOG"
exit 0
V5E
# h ARGS -- run the helper's main; RC, OUT, ENG (engine argv line, "" when not run)
h() {
    : > "$ENGLOG"
    OUT="$( (set -euo pipefail; main "$@") 2>&1 )"
    RC=$?
    ENG="$(cat "$ENGLOG")"
}
h firewall-enable
check "H1 no lists" "0|engine [--json] [--enable] cwd=[/]" "$RC|$ENG"
h firewall-enable 203.0.113.7
check "H2 SSH only" "0|engine [--json] [--enable] [--ssh-from] [203.0.113.7] cwd=[/]" "$RC|$ENG"
h firewall-enable 203.0.113.0/24 198.51.100.0/24,2001:db8::/32
check "H3 SSH + P2P" "0|engine [--json] [--enable] [--ssh-from] [203.0.113.0/24] [--p2p-from] [198.51.100.0/24,2001:db8::/32] cwd=[/]" "$RC|$ENG"
h firewall-enable - 198.51.100.7
check "H4 '-' + P2P" "0|engine [--json] [--enable] [--p2p-from] [198.51.100.7] cwd=[/]" "$RC|$ENG"
h firewall-enable "" 198.51.100.7
check "H5 empty SSH + P2P" "0|engine [--json] [--enable] [--p2p-from] [198.51.100.7] cwd=[/]" "$RC|$ENG"
h firewall-enable -
check "H6 '-' alone" "0|engine [--json] [--enable] cwd=[/]" "$RC|$ENG"
bad=""
for p in 0.0.0.0/0 10.0.0.0/4 /etc/passwd /10.0.0.1 "10.0.0.1," ",10.0.0.1" "10.0.0.1,,10.0.0.2" \
         "héllo" "10.0.0.1;id" "10.0.0.1 10.0.0.2" "-" "--p2p-anywhere" "::" "010.0.0.1" '$(id)' \
         "10.0.0.1/33" "2001:db8::/129" "::/0" "10.0.0.1/08" "１０.0.0.1" $'10.0.0.1\n10.0.0.2' "*"; do
    h firewall-enable 203.0.113.7 "$p"
    if [[ "$RC" == 0 || -n "$ENG" ]]; then bad="${bad} [${p}]"; fi
done
check "H7 every bad P2P list refused, engine not run" "" "$bad"
h firewall-enable 203.0.113.7 /etc/telcoin/p2p.list
check "H8 leading / names the file-path refusal" "yes" "$([[ "$RC" != 0 && "$OUT" == *"a file path is not taken here"* ]] && echo yes)"
h firewall-enable "10.0.0.1," 198.51.100.7
check "H9 bad SSH list with a good P2P list refused, says SSH" "yes" "$([[ "$RC" != 0 && -z "$ENG" && "$OUT" == *"invalid SSH source list"* ]] && echo yes)"
s16=""; i=1; while [[ $i -le 16 ]]; do s16="${s16}10.0.${i}.0/24,"; i=$((i + 1)); done
h firewall-enable - "${s16%,}"
check "H10 16 P2P sources taken" "0" "$RC"
h firewall-enable - "${s16}10.0.17.0/24"
check "H11 17 P2P sources refused" "yes" "$([[ "$RC" != 0 && -z "$ENG" && "$OUT" == *"too many P2P sources: 17"* ]] && echo yes)"
h firewall-enable 10.0.0.1 10.0.0.2 10.0.0.3
check "H12 a third argument refused" "yes" "$([[ "$RC" != 0 && -z "$ENG" ]] && echo yes)"
FIREWALL_SCRIPT="$T/engine/firewall-old.sh"
h firewall-enable 203.0.113.7 198.51.100.7
check "H13 engine without --p2p-from refused with the update hint" "yes" \
    "$([[ "$RC" != 0 && -z "$ENG" && "$OUT" == *"has no --p2p-from"* && "$OUT" == *"update-scripts.sh"* ]] && echo yes)"
h firewall-enable 203.0.113.7
check "H14 old engine still takes an SSH list alone" "0|old-engine [--json] [--enable] [--ssh-from] [203.0.113.7]" "$RC|$ENG"
FIREWALL_SCRIPT="$T/engine/firewall-setup.sh"
h firewall-enable 203.0.113.7 "fe80::1"
echo "info  H15 link-local P2P source fe80::1: rc=$RC engine=[$ENG]"
printf '\n%s checks, %s failures\n' "$CHECKS" "$FAILS"
[[ "$FAILS" -eq 0 ]]
