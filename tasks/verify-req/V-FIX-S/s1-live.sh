#!/usr/bin/env bash
# =============================================================================
# s1-live.sh -- V-FIX-S S1 driver: the live proof against the real
# telcoin-network repository, in two disposable ubuntu:26.04 containers.
#   run A: the scripts at 01664cc (git archive into a fresh scratch directory)
#   run B: the scripts at this worktree's tip (mounted read-only)
# Each run executes s1-inner.sh; its decisive lines land in
# <run>/out-<mode>/decisive.txt. Nothing is written into the worktree.
# Usage: bash s1-live.sh [scratch-base]
# =============================================================================
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
wt="/home/drtnarg/coding/telcoin/tnd-req-v-fix-s"
main_repo="/home/drtnarg/coding/telcoin/tn-node-deployment"
base="${1:-/var/tmp/claude-1000/-home-drtnarg-coding-telcoin-tn-node-deployment/46275ae3-5cf9-4f35-b799-c09950443243/scratchpad/v-fix-s}"
run="${base}/s1-$(date +%Y%m%d-%H%M%S)-$$"
if [[ -e "$run" ]]; then
    echo "refusing: ${run} exists" >&2
    exit 1
fi
mkdir -p "${run}/old" "${run}/out-old" "${run}/out-new"
git -C "$main_repo" archive 01664cc | tar -x -C "${run}/old"
echo "run dir: ${run}"
echo "worktree tip: $(git -C "$wt" rev-parse --short HEAD)"

rc_old=0
docker run --rm -v "${run}/old:/s:ro" -v "${here}:/h:ro" -v "${run}/out-old:/out" \
    ubuntu:26.04 bash /h/s1-inner.sh old > "${run}/old.console" 2>&1 || rc_old=$?
rc_new=0
docker run --rm -v "${wt}:/s:ro" -v "${here}:/h:ro" -v "${run}/out-new:/out" \
    ubuntu:26.04 bash /h/s1-inner.sh new > "${run}/new.console" 2>&1 || rc_new=$?

echo "container rc: old=${rc_old} new=${rc_new}"
cat "${run}/out-old/decisive.txt" "${run}/out-new/decisive.txt"
