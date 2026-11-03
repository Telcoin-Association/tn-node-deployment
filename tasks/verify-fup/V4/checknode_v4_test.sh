#!/usr/bin/env bash
# V4: check-node.sh's script-release block (report_scripts_release), cut from
# the script and run on fixture records: present and fresh, expired (today,
# 1 day, N days), missing, without release= or serial=, the 2.0.0 shape, a
# release dated ahead, an unreadable expiry, CRLF. HEALTH_ISSUES must not move.
set -u
# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/v4lib.sh"
CN="$V4_REPO/check-node.sh"
TN_ROOT_PREFIX="$T/fx"
mkdir -p "$T/fx"
eval "$(tn_test_source_common)"
{
    sed -n '/^ymd_days() {/,/^}/p' "$CN"
    sed -n '/^cn_days() {/,/^}/p' "$CN"
    sed -n '/^cn_manifest_key() {/,/^}/p' "$CN"
    sed -n '/^report_scripts_release() {/,/^}/p' "$CN"
} > "$T/fns.sh"
# shellcheck source=/dev/null
. "$T/fns.sh"
check "check-node calls report_scripts_release at the top level" "1" \
    "$(awk '/^[A-Za-z_][A-Za-z0-9_]*\(\) *\{/ {f=1} f && /^\}/ {f=0; next} !f && $0 == "report_scripts_release" {c++} END {print c+0}' "$CN")"
check "the call comes before the summary (exit 0)" "yes" \
    "$(awk '$0 == "report_scripts_release" {a=NR} /^exit 0$/ {b=NR} END {print (a && b && a < b) ? "yes" : "no"}' "$CN")"

SCRIPT_DIR="$T/scripts"
mkdir -p "$SCRIPT_DIR"
M="$SCRIPT_DIR/MANIFEST"
export V4_TODAY=2027-03-15
runb() {   # runb -> OUT, ISS
    HEALTH_ISSUES=0
    OUT="$(report_scripts_release 2>&1; printf '\nissues=%s' "$HEALTH_ISSUES")"
    OUT="$(plain "$OUT")"
}
rec() { printf '%s' "$1" > "$M"; printf 'sha256  %064d  update-scripts.sh\n' 0 >> "$M"; }
H="format=1"$'\n'"release=scripts-v1.1.0"$'\n'"serial=2"$'\n'"min_updater=1.0.0"$'\n'

rec "${H}date=2027-03-01"$'\n'"expires=2027-05-30"$'\n'
runb
check_has "fresh: info line" "  ->  Scripts release: scripts-v1.1.0 (serial 2), released 2027-03-01, 14 days ago" "$OUT"
check_has "fresh: ok line" "  [OK]  Scripts release expires 2027-05-30 (in 76 days)" "$OUT"
check_lacks "fresh: no warn" "[WARN]" "$OUT"
check_has "fresh: no health issue" "issues=0" "$OUT"

rec "${H}date=2027-01-01"$'\n'"expires=2027-03-10"$'\n'
runb
check_has "expired 5 days: warn" "  [WARN] Scripts release scripts-v1.1.0 expired 5 days ago (on 2027-03-10): a newer signed release is overdue." "$OUT"
check_has "expired: points at --check" "  ->    Check for it: bash ${SCRIPT_DIR}/update-scripts.sh --check" "$OUT"
check_has "expired: age of the release" "  ->  Scripts release: scripts-v1.1.0 (serial 2), released 2027-01-01, 73 days ago" "$OUT"
check_has "expired: no health issue" "issues=0" "$OUT"
rec "${H}date=2027-01-01"$'\n'"expires=2027-03-14"$'\n'
runb
check_has "expired 1 day" "  [WARN] Scripts release scripts-v1.1.0 expired 1 day ago (on 2027-03-14): a newer signed release is overdue." "$OUT"
rec "${H}date=2027-01-01"$'\n'"expires=2027-03-15"$'\n'
runb
check_has "expires today" "  [WARN] Scripts release scripts-v1.1.0 expired today (on 2027-03-15): a newer signed release is overdue." "$OUT"
rec "${H}date=2027-03-14"$'\n'"expires=2027-03-16"$'\n'
runb
check_has "expires tomorrow: ok" "  [OK]  Scripts release expires 2027-03-16 (in 1 day)" "$OUT"
check_has "released yesterday" "  ->  Scripts release: scripts-v1.1.0 (serial 2), released 2027-03-14, 1 day ago" "$OUT"
rec "${H}date=2027-03-15"$'\n'"expires=2027-06-13"$'\n'
runb
check_has "released today" "  ->  Scripts release: scripts-v1.1.0 (serial 2), released 2027-03-15, today" "$OUT"
rec "${H}date=2027-04-01"$'\n'"expires=2027-06-30"$'\n'
runb
check_has "dated ahead of the clock" "  ->  Scripts release: scripts-v1.1.0 (serial 2), released 2027-04-01, dated ahead of this host's clock" "$OUT"

rm -f "$M"
runb
check_has "missing record: warn" "  [WARN] No signed release installed: ${SCRIPT_DIR} has no MANIFEST record." "$OUT"
check_has "missing record: hint" "  ->    Bring the scripts to the latest signed release: bash ${SCRIPT_DIR}/update-scripts.sh" "$OUT"
check_has "missing record: no health issue" "issues=0" "$OUT"

rec "format=1"$'\n'"serial=2"$'\n'"min_updater=1.0.0"$'\n'"expires=2027-05-30"$'\n'
runb
check_has "no release= line: warn" "  [WARN] The release record ${M} lacks a valid release= or serial= line." "$OUT"
rec "format=1"$'\n'"release=scripts-v1.1.0"$'\n'"min_updater=1.0.0"$'\n'"expires=2027-05-30"$'\n'
runb
check_has "no serial= line: warn" "  [WARN] The release record ${M} lacks a valid release= or serial= line." "$OUT"
check_has "no serial= line: hint" "  ->    Check it: bash ${SCRIPT_DIR}/update-scripts.sh --check" "$OUT"

rec "$H"
runb
check_has "2.0.0 shape: date not recorded" "  ->  Scripts release: scripts-v1.1.0 (serial 2), release date not recorded" "$OUT"
check_has "2.0.0 shape: no expiry" "  ->    The release carries no expiry date." "$OUT"
check_lacks "2.0.0 shape: no warn" "[WARN]" "$OUT"

rec "${H}date=2027-03-01"$'\n'"expires=2027-02-30"$'\n'
runb
check_has "unreadable expiry: warn" "  [WARN] The release record has an unreadable expiry date: expires=2027-02-30" "$OUT"

rec "${H}date=2027-03-01"$'\n'"expires=2027-03-10"$'\n'
sed 's/$/\r/' "$M" > "$T/crlf" && cat "$T/crlf" > "$M"
runb
check_has "CRLF record: reported as lacking release=/serial=" "  [WARN] The release record ${M} lacks a valid release= or serial= line." "$OUT"

# UTC boundary with the real clock
unset V4_TODAY
utc_today="$(date -u +%Y-%m-%d)"
rec "${H}expires=$utc_today"$'\n'
for tz in ABC-14 ABC+12; do
    export TZ=$tz
    runb
    unset TZ
    check_has "TZ=$tz expires = UTC today: expired today" "  [WARN] Scripts release scripts-v1.1.0 expired today (on $utc_today): a newer signed release is overdue." "$OUT"
done
check "check-node never read the local date" "" "$(cat "$T/date-local.log" 2>/dev/null)"

finish
