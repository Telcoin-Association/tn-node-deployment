#!/usr/bin/env bash
# =============================================================================
# tasks/verify-fup/V1/run.sh -- run the V1 harness in the three environments and
# keep the logs in records/:
#   bash tasks/verify-fup/V1/run.sh          # bash 5 (host), bash:3.2, ubuntu:24.04
#   bash tasks/verify-fup/V1/run.sh host     # the host only
# .base/ (lib/ and setup-node.sh at 0a9db45, before LIB-A and LIB-B) is written
# here from git, so the containers, which have no git, can read it.
# =============================================================================
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
rel="tasks/verify-fup/V1"
mkdir -p "$here/records" "$here/.base"
if [[ ! -f "$here/.base/lib/common.sh" ]]; then
    git -C "$repo" archive 0a9db45 lib setup-node.sh | tar -x -C "$here/.base" || exit 1
fi
rc=0
run_env() {  # run_env NAME CMD...
    local name="$1" r
    shift
    "$@" > "$here/records/$name.log" 2>&1
    r=$?
    printf '%-14s exit %s  %s\n' "$name" "$r" "$(tail -n 1 "$here/records/$name.log")"
    [[ $r -eq 0 ]] || rc=1
}
run_env host bash "$repo/$rel/v1_test.sh"
if [[ "${1:-all}" != host ]]; then
    run_env bash3.2 docker run --rm -v "$repo:/w" -w /w bash:3.2 bash "$rel/v1_test.sh"
    run_env ubuntu24.04 docker run --rm -v "$repo:/w" -w /w ubuntu:24.04 bash "$rel/v1_test.sh"
fi
exit "$rc"
