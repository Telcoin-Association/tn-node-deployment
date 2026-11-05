#!/usr/bin/env bash
# V4: the pure-bash date arithmetic of every script that reads a MANIFEST date,
# against a table computed independently with python3 (dates_table.txt,
# adddays_table.txt), plus refusal of malformed dates. Runs under any bash.
set -u
# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/v4lib.sh"

INVALID=(2027-13-01 2027-02-30 27-1-1 "" 2023-02-29 2100-02-29 1900-02-29 2027-00-01 2027-01-00
         2027-04-31 2027-06-31 2027-09-31 2027-11-31 2027-01-32 "2027-01-01 " " 2027-01-01" 2027-1-01
         2027-01-1 +027-01-01 2027-01-01x 2027-0a-01 1969-12-31 0000-01-01 20270101 2027/01/01
         "2027-01-01T00:00" "2027-01-01"$'\r' -2027-01-01 "２０２７-01-01")

for f in tools/release-scripts.sh update-scripts.sh install.sh check-node.sh; do
    body="$(sed -n '/^ymd_days() {/,/^}/p' "$V4_REPO/$f")"
    if [[ -z "$body" ]]; then
        check "$f: has ymd_days" "present" "absent"
        continue
    fi
    unset -f ymd_days
    eval "$body"
    bad=""
    nrows=0
    while read -r d n; do
        case "$d" in '#'*) continue ;; esac
        nrows=$((nrows + 1))
        got="$(ymd_days "$d")" || got="rc$?"
        [[ "$got" == "$n" ]] || bad="$bad $d:$got!=$n"
    done < "$V4_DIR/dates_table.txt"
    check "$f: ymd_days matches python3 on $nrows dates (leap days, centuries, year ends)" "" "$bad"
    bad=""
    for d in "${INVALID[@]}"; do
        # a subshell: a digit class that matches non-ASCII digits in a UTF-8
        # locale makes $((10#...)) abort the whole command (probed separately)
        if (ymd_days "$d") >/dev/null 2>&1; then bad="$bad [$d]"; fi
    done
    check "$f: ymd_days refuses ${#INVALID[@]} malformed or impossible dates" "" "$bad"
    # the timezone must not matter: pure arithmetic
    check "$f: ymd_days 2024-02-29 under TZ=ABC-14" "19782" "$(TZ=ABC-14 ymd_days 2024-02-29)"
done

# days_ymd (release-scripts only) and the add-days table that prepare uses.
unset -f ymd_days days_ymd
eval "$(sed -n '/^ymd_days() {/,/^}/p; /^days_ymd() {/,/^}/p' "$V4_REPO/tools/release-scripts.sh")"
bad=""
while read -r d n; do
    case "$d" in '#'*) continue ;; esac
    [[ "$(days_ymd "$n")" == "$d" ]] || bad="$bad $n:$(days_ymd "$n")!=$d"
done < "$V4_DIR/dates_table.txt"
check "release-scripts: days_ymd inverts the python3 table" "" "$bad"
bad=""
nrows=0
while read -r s k e; do
    case "$s" in '#'*) continue ;; esac
    nrows=$((nrows + 1))
    got="$(days_ymd $(( $(ymd_days "$s") + k )))"
    [[ "$got" == "$e" ]] || bad="$bad $s+$k:$got!=$e"
done < "$V4_DIR/adddays_table.txt"
check "release-scripts: date + DAYS matches python3 on $nrows rows" "" "$bad"

finish
