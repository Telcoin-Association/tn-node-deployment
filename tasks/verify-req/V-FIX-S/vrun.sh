#!/usr/bin/env bash
# =============================================================================
# vrun.sh INNER [ARGS...] -- run one V-FIX-S container harness (s2-inner.sh,
# s3-inner.sh, s4-inner.sh, s5-inner.sh) as root in a disposable ubuntu:26.04
# container. Mounts: /s = this worktree read-only (the scripts at the tip),
# /old = the scripts at 01664cc (git archive into a fresh scratch directory),
# /h = this harness read-only, /out = a fresh output directory. Prints the run
# directory and the harness's decisive.txt.
# =============================================================================
set -euo pipefail

inner="${1:-}"
shift || true
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
wt="/home/drtnarg/coding/telcoin/tnd-req-v-fix-s"
main_repo="/home/drtnarg/coding/telcoin/tn-node-deployment"
base="/var/tmp/claude-1000/-home-drtnarg-coding-telcoin-tn-node-deployment/46275ae3-5cf9-4f35-b799-c09950443243/scratchpad/v-fix-s"
if [[ ! -f "${here}/${inner}" ]]; then
    echo "usage: vrun.sh s2-inner.sh|s3-inner.sh|s4-inner.sh|s5-inner.sh" >&2
    exit 2
fi
run="${base}/${inner%.sh}-$(date +%Y%m%d-%H%M%S)-$$"
if [[ -e "$run" ]]; then
    echo "refusing: ${run} exists" >&2
    exit 1
fi
mkdir -p "${run}/old" "${run}/out"
git -C "$main_repo" archive 01664cc | tar -x -C "${run}/old"
echo "run dir: ${run}"
rc=0
docker run --rm -v "${wt}:/s:ro" -v "${run}/old:/old:ro" -v "${here}:/h:ro" -v "${run}/out:/out" \
    ubuntu:26.04 bash "/h/${inner}" "$@" > "${run}/console" 2>&1 || rc=$?
echo "container rc=${rc}"
cat "${run}/out/decisive.txt" 2>/dev/null || tail -20 "${run}/console"
