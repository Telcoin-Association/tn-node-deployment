#!/usr/bin/env bash
# tasks/verify-fup/V4/mutate.sh -- apply each mutation of mutations.py to a
# fresh copy of the tip (git archive HEAD) and run the V4 tests it names with
# V4_REPO pointed at the copy. A mutation is KILLED when a named test fails.
# Host only (python3, git). Writes records/mutation.txt. Exit 1 if any survived.
set -u
V4="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WT="$(cd "$V4/../../.." && pwd)"
SCR="${V4_MUT_DIR:-${TMPDIR:-/tmp}/v4-mut}"
rm -rf "$SCR"; mkdir -p "$SCR"
out="$V4/records/mutation.txt"
mkdir -p "$V4/records"
printf '# V4 mutation run %s on %s\n' "$(date -u +%Y-%m-%dT%H:%MZ)" "$(git -C "$WT" rev-parse --short HEAD)" > "$out"
# baseline: the unmutated copy must pass every test the table names
# (release_v4 is expected to fail the two empty-key checks: finding A)
survived=0
python3 -I "$V4/mutations.py" list | while read -r id tests desc; do
    d="$SCR/$id"
    mkdir -p "$d"
    git -C "$WT" archive 7924f26 | tar -xf - -C "$d"
    if ! python3 -I "$V4/mutations.py" apply "$id" "$d"; then
        printf '%s APPLY-FAILED %s\n' "$id" "$desc" | tee -a "$out"
        continue
    fi
    verdict=SURVIVED
    detail=""
    for t in ${tests//,/ }; do
        log="$SCR/$id.$t.log"
        V4_REPO="$d" bash "$V4/${t}_v4_test.sh" > "$log" 2>&1
        summ="$(grep -E '^[0-9]+ checks, ' "$log" | tail -n 1)"
        nf="$(printf '%s\n' "$summ" | sed -n 's/.* \([0-9]*\) failures.*/\1/p')"
        base=0
        [[ "$t" != release ]] || base=2
        if [[ -z "$nf" ]]; then nf=999; fi
        detail="$detail $t:${nf}F"
        if (( nf > base )); then
            verdict=KILLED
            detail="$detail($(grep '^FAIL' "$log" | grep -v 'empty expires=\|empty date=' | head -1 | cut -c7-70))"
        fi
    done
    printf '%s %s %s |%s\n' "$id" "$verdict" "$desc" "$detail" | tee -a "$out"
    rm -rf "$d"
done
! grep -q ' SURVIVED \| APPLY-FAILED ' "$out"
