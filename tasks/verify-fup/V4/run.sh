#!/usr/bin/env bash
# tasks/verify-fup/V4/run.sh -- run the V4 (REL) harness.
#
#   bash tasks/verify-fup/V4/run.sh [host|bash32|ubuntu|all]   (default all)
#
# host = this machine's bash (5.3); bash32 = docker bash:3.2 (busybox, no git,
# no ssh-keygen); ubuntu = docker ubuntu:24.04 (root, GNU, no git). The 2.0.0
# copies are extracted on the host with git into cache/ first, so every
# environment runs the compatibility test. Logs go to records/<env>.log and
# a summary line per test to records/summary.txt. Exit 1 if any test failed.
set -u
V4="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WT="$(cd "$V4/../../.." && pwd)"
TESTS=(dates_v4_test.sh updater_v4_test.sh install_v4_test.sh checknode_v4_test.sh release_v4_test.sh compat200_v4_test.sh)

if [[ "${1:-}" == "--inner" ]]; then
    # inside the environment: run every test, print its log, then a result line
    rc=0
    for t in "${TESTS[@]}"; do
        out="$(bash "$V4/$t" 2>&1)"
        r=$?
        printf '%s\n' "$out"
        printf 'RESULT %s rc=%s %s\n' "$t" "$r" "$(printf '%s\n' "$out" | grep -E '^[0-9]+ checks, ' | tail -n 1)"
        [[ $r -eq 0 ]] || rc=1
    done
    exit "$rc"
fi

if command -v git >/dev/null 2>&1; then
    mkdir -p "$V4/cache"
    git -C "$WT" show 1187ddb:update-scripts.sh > "$V4/cache/update-scripts-2.0.0.sh"
    git -C "$WT" show 1187ddb:install.sh > "$V4/cache/install-2.0.0.sh"
fi
mkdir -p "$V4/records"
envs="${1:-all}"
[[ "$envs" != all ]] || envs="host bash32 ubuntu"
total=0
for e in $envs; do
    log="$V4/records/$e.log"
    case "$e" in
        host)   (cd "$WT" && bash "$V4/run.sh" --inner) > "$log" 2>&1 ;;
        bash32) (cd "$WT" && docker run --rm -v "$WT:/w" -w /w bash:3.2 bash tasks/verify-fup/V4/run.sh --inner) > "$log" 2>&1 ;;
        ubuntu) (cd "$WT" && docker run --rm -v "$WT:/w" -w /w ubuntu:24.04 bash tasks/verify-fup/V4/run.sh --inner) > "$log" 2>&1 ;;
        *) echo "unknown env: $e" >&2; exit 2 ;;
    esac
    r=$?
    [[ $r -eq 0 ]] || total=1
    {
        printf '== %s (rc %s) %s\n' "$e" "$r" "$(date -u +%Y-%m-%dT%H:%MZ)"
        grep '^RESULT ' "$log"
    } | tee -a "$V4/records/summary.txt"
done
exit "$total"
