#!/usr/bin/env bash
# =============================================================================
# V3 skew harness: the new setup-observability.sh behind an older library.
#   1. lib/observability.sh from 6cbf52e (before OBS: no obs_rotate_token)
#   2. lib/common.sh from c027873^ (no _tn_shred, no addon_meta_lock)
# Both must stop with rc 2 before anything changes and name update-scripts.sh;
# a --json run must end with one done ok:false event. Non-root is fine: the check
# runs before check_root. Fixtures come from run.sh (git show into fixtures/).
# =============================================================================
set -u
V3_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${V3_REPO:-$(cd "$V3_DIR/../../.." && pwd)}"
# shellcheck source=/dev/null
. "$REPO/tools/tests/lib.sh"
T="$TN_TEST_TMP"
FX="$V3_DIR/fixtures"
mk_tree() { # mk_tree NAME: a copy of the scripts with one library swapped
    rm -rf "$T/$1"; mkdir -p "$T/$1/lib" "$T/$1/observability"
    cp "$REPO/setup-observability.sh" "$T/$1/"
    cp "$REPO"/lib/*.sh "$REPO"/lib/*.env "$T/$1/lib/" 2>/dev/null
    cp "$REPO/observability/config.alloy" "$T/$1/observability/"
}
for case in obs common; do
    if [ "$case" = obs ]; then fx="$FX/observability.sh@6cbf52e"; dst=lib/observability.sh; want="lib/observability.sh is older"
    else fx="$FX/common.sh@c027873p"; dst=lib/common.sh; want="lib/common.sh"; fi
    if [ ! -r "$fx" ]; then skip "skew $case" "fixture $fx missing (run run.sh)"; continue; fi
    mk_tree "$case"; cp "$fx" "$T/$case/$dst"
    printf 'tok-0123456789abcdef\n' > "$T/tok"
    bash "$T/$case/setup-observability.sh" --rotate-token --token-stdin < "$T/tok" > "$T/o" 2>&1; rc=$?
    check_rc "skew $case: --rotate-token stops with rc 2" 2 "$rc"
    check "skew $case: names the library" "yes" "$(grep -q "$want" "$T/o" && echo yes || echo no)"
    check "skew $case: names update-scripts.sh" "yes" "$(grep -q 'update-scripts.sh' "$T/o" && echo yes || echo no)"
    [ "$case" = obs ] && check "skew obs: names obs_rotate_token" "yes" "$(grep -q 'obs_rotate_token' "$T/o" && echo yes || echo no)"
    bash "$T/$case/setup-observability.sh" --json --rotate-token --token-stdin < "$T/tok" > "$T/j" 2>/dev/null; rc=$?
    check_rc "skew $case json: rc 2" 2 "$rc"
    check "skew $case json: one done ok:false event, no other non-empty line" "1 0" "$(grep -c '"event":"done","ok":false' "$T/j") $(grep -v '^{.*}$' "$T/j" | grep -c .)"
    check "skew $case json: stdout carries no blank line either (pre-existing gate)" "0" "$(grep -c '^$' "$T/j")"
    bash "$T/$case/setup-observability.sh" --json --enable-logs --token-stdin < "$T/tok" > "$T/j" 2>/dev/null; rc=$?
    check_rc "skew $case json enable: rc 2 (the gate covers every run)" 2 "$rc"
done
finish
