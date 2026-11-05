#!/usr/bin/env bash
# V4: install.sh (tip) on signed fixture releases with and without date= and
# expires=: acceptance, refusal of duplicates and malformed dates, the
# pre-existing refusals, and the expired-release warning (install proceeds).
set -u
# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/v4lib.sh"
# shellcheck source=/dev/null
. "$V4_DIR/instlib.sh"

TAG=scripts-v1.0.0
COPY="$T/install-tip.sh"
tagged_copy "$V4_REPO/install.sh" "$TAG" "$COPY"
H="format=1"$'\n'"release=$TAG"$'\n'"serial=3"$'\n'"min_updater=1.0.0"$'\n'
export V4_TODAY=2027-03-15
REL="$T/rel"

ok_case() {   # ok_case NAME HEADER
    irel "$REL" "$TAG" "$2"; pack "$REL" "$TAG"; run_inst "$COPY"
    check_rc "install $1: rc 0" 0 "$RC"
    check "install $1: installed" yes "$(installed)"
    check "install $1: record is the release MANIFEST" "$(_h "$REL/MANIFEST")" "$(_h "$IDIR/MANIFEST" 2>/dev/null)"
}
bad_case() {  # bad_case NAME HEADER PHRASE [KEY]
    irel "$REL" "$TAG" "$2" "${4:-v4key1}"; pack "$REL" "$TAG"; run_inst "$COPY"
    check_rc "install $1: rc 1" 1 "$RC"
    check "install $1: nothing installed" no "$(installed)"
    check "install $1: no staging left" "" "$(cd "$T/home" && find . -maxdepth 1 -name '.telcoin-node-scripts.*')"
    has "install $1: says why" "$3" "$OUT"
}

ok_case "no date/expires (2.0.0 shape)" "$H"
hasnt "install 2.0.0 shape: no warning" "expired" "$OUT"
ok_case "date only" "${H}date=2027-03-01"$'\n'
ok_case "expires only, fresh" "${H}expires=2027-05-30"$'\n'
hasnt "install fresh: no warning" "expired" "$OUT"
ok_case "keys before format=" "expires=2027-05-30"$'\n'"date=2027-03-01"$'\n'"$H"
ok_case "expired" "${H}date=2027-03-01"$'\n'"expires=2027-03-10"$'\n'
has "install expired: exact warning" "Script release $TAG expired on 2027-03-10; a newer signed release is overdue. Installing it anyway." "$OUT"
has "install expired: support line" "The release still verifies. If no newer one appears soon, tell support@telcoin.org." "$OUT"
has "install expired: still reports success" "Scripts installed ($TAG)" "$OUT"
check "install expired: warns once" 1 "$(count "expired on" "$OUT")"
ok_case "expires today" "${H}expires=$V4_TODAY"$'\n'
has "install expires today: warns" "expired on $V4_TODAY" "$OUT"
ok_case "expires tomorrow" "${H}expires=2027-03-16"$'\n'
hasnt "install expires tomorrow: no warning" "expired" "$OUT"
ok_case "adversarial: expires before date (accepted)" "${H}date=2027-03-01"$'\n'"expires=2027-02-01"$'\n'

bad_case "duplicate date=" "${H}date=2027-03-01"$'\n'"date=2027-03-01"$'\n' "MANIFEST repeats date=."
bad_case "duplicate expires=" "${H}expires=2027-05-30"$'\n'"expires=2027-05-30"$'\n' "MANIFEST repeats expires=."
for v in 2027-13-01 2027-02-30 27-1-1 "" "2027-06-01 " 1969-12-31; do
    bad_case "malformed expires=[$v]" "${H}expires=${v}"$'\n' "MANIFEST expires=${v} is not a calendar date YYYY-MM-DD."
    bad_case "malformed date=[$v]" "${H}date=${v}"$'\n' "MANIFEST date=${v} is not a calendar date YYYY-MM-DD."
done
# pre-existing refusals with the new keys present
K="date=2027-03-01"$'\n'"expires=2027-05-30"$'\n'
bad_case "bad signature (keys)" "${H}${K}" "does not verify" v4key2
bad_case "other release (keys)" "format=1"$'\n'"release=scripts-v9.9.9"$'\n'"serial=3"$'\n'"min_updater=1.0.0"$'\n'"$K" "MANIFEST is for scripts-v9.9.9"
bad_case "serial malformed (keys)" "format=1"$'\n'"release=$TAG"$'\n'"serial=0"$'\n'"min_updater=1.0.0"$'\n'"$K" "MANIFEST serial is malformed."
bad_case "huge serial (keys)" "format=1"$'\n'"release=$TAG"$'\n'"serial=9999999999"$'\n'"min_updater=1.0.0"$'\n'"$K" "MANIFEST serial is malformed."
bad_case "format 2 (keys)" "format=2"$'\n'"release=$TAG"$'\n'"serial=3"$'\n'"min_updater=1.0.0"$'\n'"$K" "MANIFEST format 2 is not supported"
# CRLF
irel "$REL" "$TAG" "${H}${K}"
sed 's/$/\r/' "$REL/MANIFEST" > "$T/crlf" && cat "$T/crlf" > "$REL/MANIFEST" && sign_file "$REL/MANIFEST" v4key1
pack "$REL" "$TAG"; run_inst "$COPY"
check_rc "install CRLF (keys): rc 1" 1 "$RC"
has "install CRLF: says why" "CR line endings" "$OUT"

# UTC boundary with the real clock
unset V4_TODAY
utc_today="$(date -u +%Y-%m-%d)"
for tz in ABC-14 ABC+12; do
    irel "$REL" "$TAG" "${H}expires=$utc_today"$'\n'; pack "$REL" "$TAG"
    export TZ=$tz
    run_inst "$COPY"
    unset TZ
    check_rc "install TZ=$tz expires = UTC today: rc 0" 0 "$RC"
    has "install TZ=$tz expires = UTC today: warns" "expired on $utc_today" "$OUT"
done
check "installer never read the local date" "" "$(cat "$T/date-local.log" 2>/dev/null)"

finish
