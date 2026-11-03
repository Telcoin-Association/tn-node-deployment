#!/usr/bin/env bash
# V3 driver: the three harnesses under bash 5.3 (host), bash:3.2 and ubuntu:24.04 (root),
# logs in records/. Run from the repository root:  bash tasks/verify-fup/V3/run.sh
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/../../.." || exit 1
V=tasks/verify-fup/V3
UP="${TN_UPSTREAM_ALLOY_CONFIG:-$HOME/coding/telcoin/adiri-genesis/common/observability/node-agent/config.alloy}"
mkdir -p "$V/records" "$V/fixtures"
git show 6cbf52e:lib/observability.sh > "$V/fixtures/observability.sh@6cbf52e"
git show c027873^:lib/common.sh > "$V/fixtures/common.sh@c027873p"
rc=0
run() { # run ENV LOG CMD...
    local env="$1" log="$2"; shift 2
    "$@" > "$V/records/$log" 2>&1; local r=$?
    printf '%-10s %-28s rc=%s  %s\n' "$env" "$log" "$r" "$(tail -n 1 "$V/records/$log")"
    [ "$r" -eq 0 ] || rc=1
}
UPV=(); [ -r "$UP" ] && UPV=(-v "$UP:/up/config.alloy:ro" -e TN_UPSTREAM_ALLOY_CONFIG=/up/config.alloy)
for t in lib skew; do
    run bash5.3 "$t-bash53.log" env TN_UPSTREAM_ALLOY_CONFIG="$UP" V3_CLAIMED_SHA="${V3_CLAIMED_SHA:-}" bash "$V/v3_obs_${t}_test.sh"
    run bash3.2 "$t-bash32.log" docker run --rm "${UPV[@]}" -e V3_CLAIMED_SHA="${V3_CLAIMED_SHA:-}" -v "$PWD:/w:ro" -w /w bash:3.2 bash "$V/v3_obs_${t}_test.sh"
    run ubuntu "$t-ubuntu.log" docker run --rm "${UPV[@]}" -e V3_CLAIMED_SHA="${V3_CLAIMED_SHA:-}" -v "$PWD:/w:ro" -w /w ubuntu:24.04 bash "$V/v3_obs_${t}_test.sh"
done
# e2e: real paths as root, disposable containers only (records/ is the one writable mount)
run bash5.3 e2e-host.log bash "$V/v3_obs_e2e_test.sh"
run ubuntu e2e-ubuntu.log docker run --rm -e V3_DISPOSABLE=1 --cap-add SYS_ADMIN --security-opt apparmor=unconfined \
    -v "$PWD:/w:ro" -v "$PWD/$V/records:/w/$V/records" -w /w ubuntu:24.04 bash "$V/v3_obs_e2e_test.sh"
exit "$rc"
