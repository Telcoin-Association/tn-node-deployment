#!/usr/bin/env bash
# V2 driver: run the V2 harness files under bash 5.3 (this host, as this user),
# bash:3.2 (busybox, root) and ubuntu:24.04 (GNU, root). Output goes to
# tasks/verify-fup/V2/records/<env>-<file>.txt and a summary line per run.
#   bash tasks/verify-fup/V2/run.sh [host|b32|ubuntu|all] [file.sh ...]
# Run from the repository root.
set -u
envs="${1:-all}"
shift || true
files=("$@")
[[ ${#files[@]} -gt 0 ]] || files=(keys_v2.sh audit_v2.sh hooks_v2.sh)
D=tasks/verify-fup/V2
mkdir -p "$D/records"
# The library of 0a9db45 (before this round) for the skew cases, outside git add.
if [[ ! -d "$D/work/old/lib" || ! -f "$D/work/old/edit-config.sh" ]]; then
    mkdir -p "$D/work/old"
    git archive 0a9db45 lib edit-config.sh | tar -x -C "$D/work/old"
fi
[[ "$envs" == all ]] && envs="host b32 ubuntu"
rc=0
for e in $envs; do
    for f in "${files[@]}"; do
        # The real-tool run needs a disposable root container.
        [[ "$f" != real_v2.sh || "$e" == ubuntu ]] || continue
        out="$D/records/${e}-${f%.sh}.txt"
        case "$e" in
            host)   V2_OLDLIB="$PWD/$D/work/old/lib" bash "$D/$f" > "$out" 2>&1 ;;
            b32)    docker run --rm -e V2_OLDLIB="/w/$D/work/old/lib" -v "$PWD:/w" -w /w bash:3.2 bash "$D/$f" > "$out" 2>&1 ;;
            ubuntu) docker run --rm -e V2_OLDLIB="/w/$D/work/old/lib" -v "$PWD:/w" -w /w ubuntu:24.04 bash "$D/$f" > "$out" 2>&1 ;;
        esac
        r=$?
        [[ $r -eq 0 ]] || rc=1
        printf '%-7s %-14s rc=%s  %s\n' "$e" "$f" "$r" "$(tail -1 "$out")"
    done
done
exit "$rc"
