#!/usr/bin/env bash
# V3 mutation run: for each entry of mutations.py, copy the tracked tree to a temp dir,
# revert one OBS behaviour there, run the harness that covers it, and call the mutant
# killed when a check fails that does not fail on the unmutated tree (the baseline
# FAILs are the findings). Output: records/mutations.txt.
#   bash tasks/verify-fup/V3/mutate.sh [NAME-SUBSTRING]
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/../../.." || exit 1
V=tasks/verify-fup/V3; OUT="$V/records/mutations.txt"
UP="${TN_UPSTREAM_ALLOY_CONFIG:-$HOME/coding/telcoin/adiri-genesis/common/observability/node-agent/config.alloy}"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
mkdir -p "$W/base"; git ls-files -z | xargs -0 cp --parents -t "$W/base"
mkdir -p "$V/fixtures"
runh() { # runh KIND TREE LOG
    case "$1" in
        lib)   V3_REPO="$2" TN_UPSTREAM_ALLOY_CONFIG="$UP" bash "$V/v3_obs_lib_test.sh" > "$3" 2>&1 ;;
        lib32) docker run --rm -v "$PWD:/w:ro" -v "$2:/m:ro" -v "$UP:/up/config.alloy:ro" -e TN_UPSTREAM_ALLOY_CONFIG=/up/config.alloy -e V3_REPO=/m -w /w bash:3.2 bash "$V/v3_obs_lib_test.sh" > "$3" 2>&1 ;;
        skew)  V3_REPO="$2" bash "$V/v3_obs_skew_test.sh" > "$3" 2>&1 ;;
        e2e)   docker run --rm -e V3_DISPOSABLE=1 -e V3_REPO=/m --cap-add SYS_ADMIN --security-opt apparmor=unconfined \
                   -v "$PWD:/w:ro" -v "$2:/m:ro" -v "$W/rec:/w/$V/records" -w /w ubuntu:24.04 bash "$V/v3_obs_e2e_test.sh" > "$3" 2>&1 ;;
    esac
}
mkdir -p "$W/rec"
for k in lib lib32 skew e2e; do
    runh "$k" "$W/base" "$W/base-$k.log"
    grep '^FAIL' "$W/base-$k.log" | sort -u > "$W/base-$k.fails"
done
: > "$OUT"
printf '# V3 mutation run %s on %s\n' "$(date -u +%FT%TZ)" "$(git rev-parse --short HEAD)" | tee -a "$OUT"
for k in lib lib32 skew e2e; do printf 'baseline %-5s %s\n' "$k" "$(tail -n 1 "$W/base-$k.log")" | tee -a "$OUT"; done
killed=0; total=0
while IFS=$'\t' read -r kind name; do
    [ -z "${1:-}" ] || case "$name" in *"$1"*) ;; *) continue ;; esac
    total=$((total + 1))
    rm -rf "$W/m"; cp -a "$W/base" "$W/m"
    ap="$(python3 "$V/mutations.py" "$name" "$W/m")"
    if [ "$ap" != applied ]; then printf '%-58s %s\n' "$name" "$ap" | tee -a "$OUT"; continue; fi
    runh "$kind" "$W/m" "$W/m.log"
    new="$(grep '^FAIL' "$W/m.log" | sort -u | comm -13 "$W/base-$kind.fails" -)"
    if [ -n "$new" ]; then
        killed=$((killed + 1))
        printf '%-58s KILLED (%s) by: %s\n' "$name" "$kind" "$(printf '%s' "$new" | head -n 2 | sed 's/^FAIL  //' | tr '\n' ';')" | tee -a "$OUT"
    else
        printf '%-58s SURVIVED (%s) %s\n' "$name" "$kind" "$(tail -n 1 "$W/m.log")" | tee -a "$OUT"
    fi
done < <(python3 "$V/mutations.py" list)
printf '%s of %s mutants killed\n' "$killed" "$total" | tee -a "$OUT"
