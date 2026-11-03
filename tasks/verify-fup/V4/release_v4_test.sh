#!/usr/bin/env bash
# V4: tools/release-scripts.sh prepare and --check on a copy of the tree:
# date= and expires= after min_updater=, --expires bounds, --check output,
# the expired warning, --require-fresh, the tree without MANIFEST, malformed
# and duplicate keys, the UTC day boundary. Uses real git where present, else a
# git stand-in that reports a clean work tree (prepare's only git use).
set -u
# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/v4lib.sh"

W="$T/repo"
mkdir -p "$W"
if command -v git >/dev/null 2>&1 && git -C "$V4_REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    (cd "$V4_REPO" && git ls-files -z | xargs -0 tar -cf - 2>/dev/null) | tar -xf - -C "$W"
else
    (cd "$V4_REPO" && tar -cf - --exclude=./.git --exclude=./tasks . 2>/dev/null || tar -cf - .) | tar -xf - -C "$W"
    rm -rf "$W/.git" "$W/tasks"
fi
rm -f "$W/MANIFEST" "$W/MANIFEST.sig" "$W/RELEASE"
printf '%s\n' "$KEY1_LINE" >> "$W/lib/allowed_signers"
(cd "$W" && bash tools/gen-checksums.sh >/dev/null 2>&1)
REALGIT=0
if command -v git >/dev/null 2>&1; then
    REALGIT=1
    (cd "$W" && git init -q . && git -c user.name=v4 -c user.email=v4@example.invalid add -A \
        && git -c user.name=v4 -c user.email=v4@example.invalid commit -qm base) >/dev/null 2>&1
else
    cat > "$BIN/git" <<'STUB'
#!/bin/sh
# git stand-in for images without git: a clean work tree where every file is committed.
case "$1" in
    rev-parse) echo true ;;
    status) ;;
    ls-files) for a in "$@"; do last="$a"; done; [ -e "$last" ] ;;
esac
STUB
    chmod +x "$BIN/git"
fi
skip_or_note="real git: $REALGIT"
printf '%s\n' "$skip_or_note" > "$T/gitmode"
commit_all() {
    [[ $REALGIT -eq 1 ]] || return 0
    (cd "$W" && git -c user.name=v4 -c user.email=v4@example.invalid add -A \
        && git -c user.name=v4 -c user.email=v4@example.invalid commit -qm step) >/dev/null 2>&1
}
rs() {   # rs ARGS... -> OUT, RC (run in the copy)
    OUT="$(cd "$W" && bash tools/release-scripts.sh "$@" 2>&1)"
    RC=$?
}
UVER="$(sed -n 's/^readonly SCRIPT_VERSION="\([0-9][0-9.]*\)"$/\1/p' "$W/update-scripts.sh" | head -1)"

# --- tree without MANIFEST ---------------------------------------------------------
rs --check
check_rc "no MANIFEST: --check rc 0" 0 "$RC"
check "no MANIFEST: --check output" "No MANIFEST in the tree: nothing to check." "$OUT"
rs --check --require-fresh
check_rc "no MANIFEST: --check --require-fresh rc 1" 1 "$RC"
rs --check --require-sig
check_rc "no MANIFEST: --check --require-sig rc 1" 1 "$RC"

# --- prepare: date= and expires= right after min_updater= ----------------------------
export V4_TODAY=2026-11-03
rs --serial 1 --date 2026-11-03 scripts-v9.0.0
check_rc "prepare default: rc 0" 0 "$RC"
check "prepare default: header lines in order" \
    "format=1|release=scripts-v9.0.0|serial=1|min_updater=${UVER}|date=2026-11-03|expires=2027-02-01" \
    "$(head -n 6 "$W/MANIFEST" | tr '\n' '|' | sed 's/|$//')"
check "prepare default: line 7 is a file line" "sha256" "$(sed -n 7p "$W/MANIFEST" | awk '{print $1}')"
check "prepare default: RELEASE" "scripts-v9.0.0 2026-11-03" "$(cat "$W/RELEASE")"
has "prepare default: says the expiry" "Release date 2026-11-03; the release expires 2027-02-01 (90 days later)." "$OUT"
check "prepare: no MANIFEST.sig left" "absent" "$([[ -e "$W/MANIFEST.sig" ]] && echo present || echo absent)"
# the date-less default: today, UTC (V4_TODAY via the date shim)
rm -f "$W/MANIFEST" "$W/RELEASE"
commit_all
export V4_TODAY=2027-03-15
rs --serial 1 scripts-v9.0.0
check "prepare without --date: date= is today (UTC)" "date=2027-03-15" "$(grep '^date=' "$W/MANIFEST")"
check "prepare without --date: expires= 90 days on" "expires=2027-06-13" "$(grep '^expires=' "$W/MANIFEST")"
# --expires values (python3 table)
bad=""
n=0
while read -r s k e; do
    case "$s" in '#'*) continue ;; esac
    n=$((n + 1))
    [[ $n -le 12 ]] || break
    rm -f "$W/MANIFEST" "$W/RELEASE"; commit_all
    rs --serial 1 --date "$s" --expires "$k" scripts-v9.0.0
    [[ $RC -eq 0 && "$(grep '^expires=' "$W/MANIFEST")" == "expires=$e" && "$(sed -n 6p "$W/MANIFEST")" == "expires=$e" ]] \
        || bad="$bad [$s+$k:rc$RC:$(grep '^expires=' "$W/MANIFEST" 2>/dev/null)!=$e]"
done < "$V4_DIR/adddays_table.txt"
check "prepare --expires: 12 table rows (leap days, year ends, 3650)" "" "$bad"
rm -f "$W/MANIFEST" "$W/RELEASE"; commit_all
rs --serial 1 --date 2026-11-03 --expires 30 scripts-v9.0.0
check "prepare --expires 30" "expires=2026-12-03" "$(grep '^expires=' "$W/MANIFEST")"
rm -f "$W/MANIFEST" "$W/RELEASE"; commit_all
rs --serial 1 --date 2024-02-29 --expires 365 scripts-v9.0.0
check "prepare 2024-02-29 + 365" "expires=2025-02-28" "$(grep '^expires=' "$W/MANIFEST")"
rm -f "$W/MANIFEST" "$W/RELEASE"; commit_all
rs --serial 1 --date 2026-11-03 --expires 3650 scripts-v9.0.0
check "prepare --expires 3650 (upper bound)" "expires=2036-10-31" "$(grep '^expires=' "$W/MANIFEST")"
rm -f "$W/MANIFEST" "$W/RELEASE"; commit_all
for v in 0 3651 abc 030 -5 "" 1.5 99999; do
    rs --serial 1 --date 2026-11-03 --expires "$v" scripts-v9.0.0
    check_rc "prepare --expires [$v]: refused" 1 "$RC"
    has "prepare --expires [$v]: says the range" "--expires takes a number of days from 1 to 3650" "$OUT"
    check "prepare --expires [$v]: wrote no MANIFEST" "absent" "$([[ -e "$W/MANIFEST" ]] && echo present || echo absent)"
done
rs --serial 1 --date 2026-11-03 scripts-v9.0.0 --expires
check_rc "prepare --expires without a value: usage rc 2" 2 "$RC"
for v in 2027-02-30 2027-13-01 27-1-1 2023-02-29; do
    rs --serial 1 --date "$v" scripts-v9.0.0
    check_rc "prepare --date [$v]: refused" 1 "$RC"
    has "prepare --date [$v]: says why" "date must be a calendar date" "$OUT"
done

# --- --check on a signed release ---------------------------------------------------
rs --serial 1 --date 2026-11-03 scripts-v9.0.0
sign_file "$W/MANIFEST" v4key1
export V4_TODAY=2026-12-01
rs --check
check_rc "--check fresh: rc 0" 0 "$RC"
has "--check fresh: release date" "Release date 2026-11-03." "$OUT"
has "--check fresh: expiry" "Release scripts-v9.0.0 expires 2027-02-01 (in 62 days)." "$OUT"
has "--check fresh: passed" "MANIFEST check passed for scripts-v9.0.0" "$OUT"
rs --check --require-sig --require-fresh
check_rc "--check --require-sig --require-fresh fresh: rc 0" 0 "$RC"
rs --check --tag scripts-v9.0.0
check_rc "--check --tag fresh: rc 0" 0 "$RC"
export V4_TODAY=2027-02-01
rs --check
check_rc "--check expires today: rc 0" 0 "$RC"
has "--check expires today: warns" "WARN release scripts-v9.0.0 expired on 2027-02-01 (today): a newer signed release is overdue" "$OUT"
rs --check --require-fresh
check_rc "--check --require-fresh expires today: rc 1" 1 "$RC"
has "--check --require-fresh: says why" "FAIL release scripts-v9.0.0 expired on 2027-02-01 (today): cut a newer release" "$OUT"
export V4_TODAY=2027-02-11
rs --check
check_rc "--check expired 10 days: rc 0" 0 "$RC"
has "--check expired 10 days: warns" "expired on 2027-02-01 (10 days ago)" "$OUT"
rs --check --require-fresh
check_rc "--check --require-fresh expired: rc 1" 1 "$RC"
rs --check --tag scripts-v9.0.0
check_rc "--check --tag expired (no --require-fresh): rc 0" 0 "$RC"
export V4_TODAY=2027-01-31
rs --check --require-fresh
check_rc "--check --require-fresh the day before: rc 0" 0 "$RC"
has "--check the day before: in 1 day" "(in 1 day)" "$OUT"

# --- --check on edited manifests (re-signed) -----------------------------------------
cp "$W/MANIFEST" "$T/M.good"
edit() {   # edit SED_EXPR -- MANIFEST from M.good through sed, re-signed
    sed "$1" "$T/M.good" > "$W/MANIFEST"
    sign_file "$W/MANIFEST" v4key1
}
export V4_TODAY=2026-12-01
edit '/^date=/d; /^expires=/d'
rs --check
check_rc "--check 2.0.0 shape: rc 0" 0 "$RC"
has "--check 2.0.0 shape: does not expire" "MANIFEST has no expires= line: scripts-v9.0.0 does not expire." "$OUT"
rs --check --require-fresh
check_rc "--check --require-fresh 2.0.0 shape: rc 0" 0 "$RC"
edit 's/^date=.*/&\n&/'
rs --check
check_rc "--check duplicate date=: rc 1" 1 "$RC"
edit 's/^expires=.*/&\n&/'
rs --check
check_rc "--check duplicate expires=: rc 1" 1 "$RC"
for v in 2027-02-30 2027-13-01 27-1-1 "2027-02-01 "; do
    edit "s/^expires=.*/expires=$v/"
    rs --check
    check_rc "--check malformed expires=[$v]: rc 1" 1 "$RC"
done
edit 's/^expires=.*/expires=/'
rs --check
check_rc "--check empty expires= (the updater refuses it): rc 1" 1 "$RC"
edit 's/^date=.*/date=/'
rs --check
check_rc "--check empty date= (the updater refuses it): rc 1" 1 "$RC"
edit 's/^expires=.*/expires=2026-11-03/'
rs --check
check_rc "--check expires equal to date: rc 1" 1 "$RC"
has "--check expires equal to date: says why" "is not after date=" "$OUT"
edit 's/^expires=.*/expires=2026-10-01/'
rs --check
check_rc "--check expires before date: rc 1" 1 "$RC"
edit '/^expires=/d; s/^min_updater=.*/expires=2027-02-01\n&/'
rs --check
check_rc "--check expires= before min_updater= (order): rc 0" 0 "$RC"
cp "$T/M.good" "$W/MANIFEST"; sign_file "$W/MANIFEST" v4key1
printf 'scripts-v9.0.0 2026-11-04\n' > "$W/RELEASE"
rs --check
check_rc "--check RELEASE date differs from date=: rc 1" 1 "$RC"
printf 'scripts-v9.0.0 2026-11-03\n' > "$W/RELEASE"
sed 's/$/\r/' "$T/M.good" > "$W/MANIFEST"; sign_file "$W/MANIFEST" v4key1
rs --check
check_rc "--check CRLF manifest: rc 1" 1 "$RC"
cp "$T/M.good" "$W/MANIFEST"; sign_file "$W/MANIFEST" v4key1

# --- UTC day boundary with the real clock ---------------------------------------------
unset V4_TODAY
eval "$(sed -n '/^ymd_days() {/,/^}/p; /^days_ymd() {/,/^}/p' "$V4_WT/tools/release-scripts.sh")"
utc_today="$(date -u +%Y-%m-%d)"
start="$(date -u -d "@$(( $(date -u +%s) - 10 * 86400 ))" +%Y-%m-%d 2>/dev/null)" || start="$(days_ymd $(( $(ymd_days "$utc_today") - 10 )))"
rm -f "$W/MANIFEST" "$W/MANIFEST.sig" "$W/RELEASE"; commit_all
rs --serial 1 --date "$start" --expires 10 scripts-v9.0.0
check "real clock: expires is UTC today" "expires=$utc_today" "$(grep '^expires=' "$W/MANIFEST")"
sign_file "$W/MANIFEST" v4key1
for tz in ABC-14 ABC+12; do
    export TZ=$tz
    rs --check --require-fresh
    unset TZ
    check_rc "real clock TZ=$tz: expires = UTC today -> --require-fresh rc 1" 1 "$RC"
    has "real clock TZ=$tz: (today)" "(today)" "$OUT"
done
rm -f "$W/MANIFEST" "$W/MANIFEST.sig" "$W/RELEASE"; commit_all
rs --serial 1 --date "$start" --expires 11 scripts-v9.0.0
sign_file "$W/MANIFEST" v4key1
for tz in ABC-14 ABC+12; do
    export TZ=$tz
    rs --check --require-fresh
    unset TZ
    check_rc "real clock TZ=$tz: expires = UTC tomorrow -> rc 0" 0 "$RC"
done
check "release-scripts never read the local date" "" "$(cat "$T/date-local.log" 2>/dev/null)"
printf 'git mode: %s\n' "$(cat "$T/gitmode")"

finish
