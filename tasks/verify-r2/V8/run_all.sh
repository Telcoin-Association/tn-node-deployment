#!/usr/bin/env bash
# Runs every V8 check and prints one summary line per script. tx3_ghcr_probe.sh reads ghcr
# anonymously and runs only with V8_NETWORK=1. Exit 0 only when every script passed.
set -u
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
source "$here/lib.sh"
rc=0
for t in t1_matrix t2_package t3_env t4_alias t5_make t6_lint t7_docs t8_commits tx1_build tx2_draft tx3_ghcr_probe; do
    if bash "$here/$t.sh" >"$SCRATCH/run-$t.log" 2>&1; then
        tail -n 1 "$SCRATCH/run-$t.log"
    else
        rc=1
        tail -n 1 "$SCRATCH/run-$t.log"
        grep '^FAIL' "$SCRATCH/run-$t.log" | sed 's/^/  /'
    fi
done
exit "$rc"
