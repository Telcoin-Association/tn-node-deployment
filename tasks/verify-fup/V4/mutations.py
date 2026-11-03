#!/usr/bin/env python3
"""V4 mutation table: each entry reverts or breaks one REL behaviour hunk.
  python3 -I mutations.py list            -> "ID TESTS" lines
  python3 -I mutations.py apply ID DIR    -> apply mutation ID inside DIR (exactly one hit required)
"""
import sys

M = [
 ("M01", "tools/release-scripts.sh", "        printf 'expires=%s\\n' \"$expires\"\n", "", "release", "prepare stops writing expires="),
 ("M02", "tools/release-scripts.sh", "days=90 require_sig=0", "days=60 require_sig=0", "release", "default expiry 60 days"),
 ("M03", "tools/release-scripts.sh", "cut a newer release\" >&2\n        return 1", "cut a newer release\" >&2\n        return 0", "release", "--require-fresh no longer fails"),
 ("M04", "tools/release-scripts.sh", "    if (( left > 0 )); then\n        echo \"Release ${rel} expires", "    if (( left >= 0 )); then\n        echo \"Release ${rel} expires", "release", "expires==today not expired (--check)"),
 ("M05", "tools/release-scripts.sh", "if [[ -n \"$tag\" || \"$require_sig\" == \"1\" || \"$require_fresh\" == \"1\" ]]; then", "if [[ -n \"$tag\" || \"$require_sig\" == \"1\" ]]; then", "release", "--require-fresh passes without MANIFEST"),
 ("M06", "tools/release-scripts.sh", "        printf 'date=%s\\n' \"$date\"\n", "", "release", "prepare stops writing date="),
 ("M07", "tools/release-scripts.sh", "    if [[ -n \"$rdate\" && \"$(awk 'NR == 1 {print $2}' RELEASE)\" != \"$rdate\" ]]; then", "    if false; then", "release", "RELEASE date vs date= not compared"),
 ("M08", "tools/release-scripts.sh", "    d=$(( doy - (153 * mp + 2) / 5 + 1 ))", "    d=$(( doy - (153 * mp + 2) / 5 + 0 ))", "dates release", "days_ymd off by one"),
 ("M09", "update-scripts.sh", "    [[ $n_date -le 1 && $n_exp -le 1 ]] || { manifest_bad \"date and expires may each appear once at most\"; return 1; }\n", "", "updater", "duplicates accepted"),
 ("M10", "update-scripts.sh", "    if [[ $n_exp -eq 1 ]] && ! ymd_days \"$M_EXPIRES\" >/dev/null; then manifest_bad \"expires ${M_EXPIRES}\"; return 1; fi\n", "", "updater", "malformed expires accepted"),
 ("M11", "update-scripts.sh", "    if [[ $n_date -eq 1 ]] && ! ymd_days \"$M_DATE\" >/dev/null; then manifest_bad \"date ${M_DATE}\"; return 1; fi\n", "", "updater", "malformed date accepted"),
 ("M12", "update-scripts.sh", "    plan_changes || exit 1\n    warn_expired\n", "    plan_changes || exit 1\n", "updater", "no expired warning in an update run"),
 ("M13", "update-scripts.sh", "    check_serial || exit 1\n    self_update || exit 1\n", "    check_serial || exit 1\n    warn_expired\n    self_update || exit 1\n", "updater", "warning before self-update (would warn twice)"),
 ("M14", "update-scripts.sh", "a newer signed release is overdue.\"\n        rc=1\n    fi\n    if [[ \"$M_RELEASE\" != \"$i_rel\" ]]", "a newer signed release is overdue.\"\n    fi\n    if [[ \"$M_RELEASE\" != \"$i_rel\" ]]", "updater", "--check: installed expired keeps rc 0"),
 ("M15", "update-scripts.sh", "    today=\"$(ymd_days \"$(date -u +%Y-%m-%d)\")\" || return 1\n    echo $(( $(ymd_days \"$1\") - today ))", "    today=\"$(ymd_days \"$(date +%Y-%m-%d)\")\" || return 1\n    echo $(( $(ymd_days \"$1\") - today ))", "updater", "local date instead of UTC"),
 ("M16", "update-scripts.sh", "        [[ \"$installed\" != \"none\" ]] || print_info \"To install it: bash ${SCRIPT_DIR}/update-scripts.sh\"\n        return 2", "        [[ \"$installed\" != \"none\" ]] || print_info \"To install it: bash ${SCRIPT_DIR}/update-scripts.sh\"\n        return 0", "updater", "--check: nothing installed rc 0"),
 ("M17", "update-scripts.sh", "Run: bash ${SCRIPT_DIR}/update-scripts.sh\"\n        rc=1\n    elif", "Run: bash ${SCRIPT_DIR}/update-scripts.sh\"\n        rc=0\n    elif", "updater", "--check: update pending rc 0"),
 ("M18", "update-scripts.sh", "    fetch_release_file \"$RELEASE_TAG\" MANIFEST || return 2\n", "    fetch_release_file \"$RELEASE_TAG\" MANIFEST || return 1\n", "updater", "--check: unfetchable MANIFEST rc 1"),
 ("M19", "update-scripts.sh", "            --check) mode=check ;;", "            --check) ;;", "updater", "--check ignored (runs an update)"),
 ("M20", "update-scripts.sh", "    (( left <= 0 )) || return 1", "    (( left < 0 )) || return 1", "updater", "expires==today not expired (updater)"),
 ("M21", "update-scripts.sh", "    elif ! verify_manifest \"$INSTALLED_MANIFEST\" \"$INSTALLED_SIG\" \"$SIGNERS_FILE\" quiet \\\n        || ! parse_manifest \"$INSTALLED_MANIFEST\"; then", "    elif ! parse_manifest \"$INSTALLED_MANIFEST\"; then", "updater", "--check trusts an unverified installed record"),
 ("M22", "update-scripts.sh", "            date=*)        n_date=$((n_date + 1)); M_DATE=\"${line#date=}\" ;;\n", "", "updater", "date= no longer parsed (falls to unknown key)"),
 ("M23", "update-scripts.sh", "        + (153 * m + 2) / 5 + d - 1 - 719468 ))\"", "        + (153 * m + 2) / 5 + d - 1 - 719467 ))\"", "dates updater", "ymd_days epoch off by one (updater copy)"),
 ("M24", "install.sh", "    warn_expired \"$rel\" \"$expires\"\n", "", "install", "installer stops warning"),
 ("M25", "install.sh", "            format=*|release=*|serial=*|min_updater=*|date=*|expires=*)", "            format=*|release=*|serial=*|min_updater=*)", "install", "installer ignores the new keys (no dup/malformed refusal)"),
 ("M26", "install.sh", "    if grep -qx 'h:expires' \"$seen\" && ! ymd_days \"$expires\" >/dev/null; then", "    if false; then", "install", "installer accepts malformed expires"),
 ("M27", "install.sh", "    (( today >= $(ymd_days \"$2\") )) || return 0", "    (( today > $(ymd_days \"$2\") )) || return 0", "install", "installer: expires==today not expired"),
 ("M28", "check-node.sh", "        print_warn \"Scripts release ${rel} expired ${age} (on ${expires}): a newer signed release is overdue.\"", "        print_ok \"Scripts release ${rel} expired ${age} (on ${expires}): a newer signed release is overdue.\"", "checknode", "expired is not a warn"),
 ("M29", "check-node.sh", "        print_warn \"No signed release installed: ${SCRIPT_DIR} has no MANIFEST record.\"", "        print_info \"No signed release installed: ${SCRIPT_DIR} has no MANIFEST record.\"", "checknode", "missing record not a warn"),
 ("M30", "check-node.sh", "    elif (( day > today )); then", "    elif (( day >= today )); then", "checknode", "check-node: expires==today not expired"),
 ("M31", "check-node.sh", "\nreport_scripts_release\n", "\n", "checknode", "block never called"),
 ("M32", "check-node.sh", "        if (( y % 4 == 0 && (y % 100 != 0 || y % 400 == 0) )); then n=29; fi", "        if (( y % 4 == 0 )); then n=29; fi", "dates", "check-node ymd_days: no century rule"),
 ("M33", "check-node.sh", "    if [[ ! \"$rel\" =~ ^scripts-v[0-9]+\\.[0-9]+\\.[0-9]+$ || ! \"$serial\" =~ ^[1-9][0-9]{0,8}$ ]]; then", "    if [[ -z \"$rel\" && -z \"$serial\" ]]; then", "checknode", "record without serial= not flagged"),
]

def main():
    if sys.argv[1] == "list":
        for m in M:
            print(m[0], m[4].replace(" ", ","), m[5].replace(" ", "_"))
        return 0
    if sys.argv[1] == "apply":
        mid, d = sys.argv[2], sys.argv[3]
        m = [x for x in M if x[0] == mid][0]
        p = d + "/" + m[1]
        s = open(p, encoding="utf-8").read()
        n = s.count(m[2])
        if n != 1:
            print("mutation %s: %d hits in %s" % (mid, n, m[1]), file=sys.stderr)
            return 3
        open(p, "w", encoding="utf-8").write(s.replace(m[2], m[3]))
        return 0
    return 2

sys.exit(main())
