#!/usr/bin/env bash
# V4: update-scripts.sh (tip) against signed fixture releases: date=/expires=
# parsing, pre-existing refusals, the expired warning, the self-replacement
# path, and --check with its exit codes. No network, no root needed.
set -u
# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/v4lib.sh"
# shellcheck source=/dev/null
. "$V4_DIR/updlib.sh"

UPDATER="$V4_REPO/update-scripts.sh"
export V4_TODAY=2027-03-15
FRESH=2027-05-30      # 76 days after V4_TODAY (python3)
EXPIRED=2027-03-10    # 5 days before

R1="$SRC/r1"; mkrel "$R1" "$UPDATER" 1.0.0; mkman "$R1" "$(hdr scripts-v1.0.0 1)"$'\n'; sign "$R1"

# newest TAG SERIAL HEADER_EXTRA [MIN] [KEY] -- build R2 (setup-node 1.1.0)
# with HEADER_EXTRA lines after min_updater=, sign and publish it.
R2="$SRC/r2"
newest() {
    mkrel "$R2" "$UPDATER" 1.1.0
    mkman "$R2" "$(hdr "$1" "$2" "${4:-1.0.0}")"$'\n'"$3"
    sign "$R2" "${5:-v4key1}"
    publish "$R2" "$1"
}
# accepted NAME -- R1 installed, R2 published: the update installs R2.
accepted() {
    install_from "$R1"
    run_upd y
    check_rc "$1: exits 0" 0 "$RC"
    check "$1: record is R2" "$(_h "$R2/MANIFEST")" "$(_h "$INST/MANIFEST" 2>/dev/null)"
    check "$1: setup-node updated" "$(_h "$R2/setup-node.sh")" "$(_h "$INST/setup-node.sh")"
}
# refused NAME PHRASE -- rc 1, tree byte-identical, PHRASE in the output.
refused() {
    local before
    before="$(tree_sig)"
    run_upd y
    check_rc "$1: exits 1" 1 "$RC"
    check "$1: tree byte-identical" "$before" "$(tree_sig)"
    has "$1: says why" "$2" "$OUT"
}

# --- 1. accepted manifests --------------------------------------------------
newest scripts-v1.1.0 2 ""
accepted "no date/expires (2.0.0 shape)"
newest scripts-v1.1.0 2 $'date=2027-03-01\n'
accepted "date only"
newest scripts-v1.1.0 2 $'expires=2027-05-30\n'
accepted "expires only"
newest scripts-v1.1.0 2 $'date=2027-03-01\nexpires=2027-05-30\n'
accepted "date and expires"
hasnt "fresh release: no expiry warning" "expired" "$OUT"
mkrel "$R2" "$UPDATER" 1.1.0
mkman "$R2" $'expires=2027-05-30\ndate=2027-03-01\nformat=1\nrelease=scripts-v1.1.0\nserial=2\nmin_updater=1.0.0\n'
sign "$R2"; publish "$R2" scripts-v1.1.0
accepted "keys before format= (any order)"
newest scripts-v1.1.0 2 $'date=2027-03-01\nexpires=2027-02-01\n'
accepted "adversarial: expires earlier than date (updater accepts; signed)"
newest scripts-v1.1.0 2 $'expires =2026-01-01\n'
accepted "adversarial: 'expires =' with a space is an unknown key"
hasnt "adversarial: 'expires =' past date: no warning (key ignored)" "expired" "$OUT"

# --- 2. refused manifests: duplicates and malformed dates -----------------------
install_from "$R1"
newest scripts-v1.1.0 2 $'date=2027-03-01\ndate=2027-03-01\nexpires=2027-05-30\n'
refused "duplicate date=" "date and expires may each appear once at most"
newest scripts-v1.1.0 2 $'date=2027-03-01\nexpires=2027-05-30\nexpires=2027-05-30\n'
refused "duplicate expires=" "date and expires may each appear once at most"
for v in 2027-13-01 2027-02-30 27-1-1 "" "2027-06-01 " " 2027-06-01" 2027-6-1 1969-12-31; do
    newest scripts-v1.1.0 2 "date=2027-03-01"$'\n'"expires=${v}"$'\n'
    refused "malformed expires=[$v]" "release manifest is malformed"
    has "malformed expires=[$v]: names the key" "expires" "$OUT"
    newest scripts-v1.1.0 2 "date=${v}"$'\n'"expires=2027-05-30"$'\n'
    refused "malformed date=[$v]" "release manifest is malformed"
    has "malformed date=[$v]: names the key" "date" "$OUT"
done
# CRLF line endings on a manifest that carries the new keys
mkrel "$R2" "$UPDATER" 1.1.0
mkman "$R2" "$(hdr scripts-v1.1.0 2)"$'\ndate=2027-03-01\nexpires=2027-05-30\n'
sed 's/$/\r/' "$R2/MANIFEST" > "$R2/M.crlf" && mv "$R2/M.crlf" "$R2/MANIFEST"
sign "$R2"; publish "$R2" scripts-v1.1.0
refused "CRLF manifest with the new keys" "CR line endings"

# --- 3. pre-existing refusals still hold with the new keys -------------------------
R5="$SRC/r5"; mkrel "$R5" "$UPDATER" 1.0.0; mkman "$R5" "$(hdr scripts-v1.5.0 5)"$'\n'"date=2027-03-01"$'\n'"expires=$FRESH"$'\n'; sign "$R5"
install_from "$R5"
newest scripts-v1.1.0 2 "date=2027-03-01"$'\n'"expires=$FRESH"$'\n'
refused "lower serial (keys present)" "refusing to go back"
newest scripts-v1.5.1 5 "date=2027-03-02"$'\n'"expires=$FRESH"$'\n'
refused "same serial, different manifest (keys present)" "reuses the installed serial"
install_from "$R1"
newest scripts-v1.1.0 2 "date=2027-03-01"$'\n'"expires=$EXPIRED"$'\n' 9.9.9
refused "min_updater too new (keys present, expired)" "needs update-scripts.sh 9.9.9 or newer"
hasnt "min_updater refusal: no 'Installing it anyway'" "Installing it anyway" "$OUT"
newest scripts-v1.1.0 2 "date=2027-03-01"$'\n'"expires=$FRESH"$'\n' 1.0.0 v4key2
refused "bad signature (keys present)" "not signed by a Telcoin release key"
newest scripts-v1.1.0 9999999999 "date=2027-03-01"$'\n'"expires=$FRESH"$'\n'
refused "adversarial: huge serial 9999999999" "serial 9999999999"
newest scripts-v1.1.0 999999999 "date=2027-03-01"$'\n'"expires=$FRESH"$'\n'
accepted "adversarial: 9-digit serial 999999999"

# --- 4. expired warning ---------------------------------------------------------
WARN_X="Script release scripts-v1.1.0 expired on ${EXPIRED}; a newer signed release is overdue. Installing it anyway."
newest scripts-v1.1.0 2 "date=2027-03-01"$'\n'"expires=$EXPIRED"$'\n'
accepted "expired newest: still installs"
has "expired newest: exact warning text" "$WARN_X" "$OUT"
check "expired newest: warns once" "1" "$(count "expired on" "$OUT")"
newest scripts-v1.1.0 2 "date=2027-03-01"$'\n'"expires=$V4_TODAY"$'\n'
accepted "expires == today: installs"
has "expires == today: warns (today counts as expired)" "expired on ${V4_TODAY}; a newer signed release is overdue." "$OUT"
newest scripts-v1.1.0 2 "date=2027-03-01"$'\n'"expires=2027-03-16"$'\n'
accepted "expires tomorrow: installs"
hasnt "expires tomorrow: no warning" "expired" "$OUT"
# up to date and expired: warning without "Installing it anyway."
newest scripts-v1.1.0 2 "date=2027-03-01"$'\n'"expires=$EXPIRED"$'\n'
install_from "$R2"
run_upd y
check_rc "up to date + expired: exits 0" 0 "$RC"
has "up to date + expired: warns" "Script release scripts-v1.1.0 expired on ${EXPIRED}; a newer signed release is overdue." "$OUT"
hasnt "up to date + expired: no 'Installing it anyway'" "Installing it anyway" "$OUT"
# declined
install_from "$R1"
before="$(tree_sig)"
run_upd n
check_rc "expired + declined: exits 0" 0 "$RC"
check "expired + declined: tree unchanged" "$before" "$(tree_sig)"
has "expired + declined: warned" "expired on ${EXPIRED}" "$OUT"

# --- 5. self-replacement when the newest release is expired ---------------------------
mkrel "$R2" "$UPDATER" 1.1.0
printf '# v4 marker: a different updater\n' >> "$R2/update-scripts.sh"
mkman "$R2" "$(hdr scripts-v1.1.0 2)"$'\n'"date=2027-03-01"$'\n'"expires=$EXPIRED"$'\n'
sign "$R2"; publish "$R2" scripts-v1.1.0
install_from "$R1"
run_upd y
check_rc "self-replace + expired: exits 0" 0 "$RC"
has "self-replace + expired: relaunched" "copy of update-scripts.sh to install the release" "$OUT"
check "self-replace + expired: warning printed exactly once" "1" "$(count "expired on ${EXPIRED}" "$OUT")"
check "self-replace + expired: new updater installed" "$(_h "$R2/update-scripts.sh")" "$(_h "$INST/update-scripts.sh")"
check "self-replace + expired: no staging dir left" "" "$(cd "$INST" && find . -maxdepth 1 -name '.tn-update.*')"

# --- 6. --check exit codes ------------------------------------------------------------
# chk NAME RC [PHRASE...] -- run --check; rc, tree untouched, nothing left in
# TMPDIR, only RELEASE/MANIFEST/MANIFEST.sig fetched, no sudo, phrases present.
chk() {
    local name="$1" want="$2" before p
    shift 2
    before="$(tree_sig)"
    : > "$T/sudo.log"
    run_check
    check_rc "--check $name: rc $want" "$want" "$RC"
    check "--check $name: tree untouched" "$before" "$(tree_sig)"
    check "--check $name: TMPDIR clean" "" "$(ls -A "$T/tmpdir")"
    check "--check $name: no file downloads" "" "$(grep -vE '/main/RELEASE$|/MANIFEST$|/MANIFEST\.sig$' "$T/curl.log")"
    check "--check $name: no sudo" "" "$(cat "$T/sudo.log")"
    hasnt "--check $name: no banner or screen clear" "Script Updater" "$OUT"
    for p in "$@"; do has "--check $name: says [$p]" "$p" "$OUT"; done
}
# R2 fresh, installed R2: current
newest scripts-v1.1.0 2 "date=2027-03-01"$'\n'"expires=$FRESH"$'\n'
install_from "$R2"
chk "current and fresh" 0 \
    "Installed:  scripts-v1.1.0, serial 2, released 2027-03-01, expires ${FRESH} (signature verified)" \
    "Newest:     scripts-v1.1.0, serial 2, released 2027-03-01, expires ${FRESH} (signature verified)" \
    "No update pending" "Up to date with scripts-v1.1.0; it expires ${FRESH} (in 76 days)."
# from another directory, by a relative path, and on a read-only tree
RUN_CWD=/ chk "current, run from /" 0 "Up to date with scripts-v1.1.0"
RUN_CWD="$INST/lib" UPD=../update-scripts.sh chk "current, relative path from lib/" 0 "Up to date with scripts-v1.1.0"
if [[ "$(id -u)" != "0" ]]; then
    chmod -R a-w "$INST"
    chk "current, read-only tree (non-root)" 0 "Up to date with scripts-v1.1.0"
    chmod -R u+w "$INST"
else
    skip "--check on a read-only tree" "running as root: permissions do not bind"
fi
# 2.0.0-shaped current release (no keys)
newest scripts-v1.1.0 2 ""
install_from "$R2"
chk "current, no expiry keys" 0 "release date not recorded" "no expiry date" "it carries no expiry date"
# update pending
newest scripts-v1.1.0 2 "date=2027-03-01"$'\n'"expires=$FRESH"$'\n'
install_from "$R1"
chk "update pending" 1 "Installed:  scripts-v1.0.0, serial 1, release date not recorded, no expiry date" "Update pending"
# installed = newest, expired
newest scripts-v1.1.0 2 "date=2027-03-01"$'\n'"expires=$EXPIRED"$'\n'
install_from "$R2"
chk "installed expired (= newest)" 1 "Installed release scripts-v1.1.0 expired on ${EXPIRED} (5 days ago)"
check "--check installed expired: one expiry line" "1" "$(count "expired on" "$OUT")"
# expires today (installed = newest)
newest scripts-v1.1.0 2 "date=2027-03-01"$'\n'"expires=$V4_TODAY"$'\n'
install_from "$R2"
chk "installed expires today" 1 "expired on ${V4_TODAY} (today)"
newest scripts-v1.1.0 2 "date=2027-03-01"$'\n'"expires=2027-03-14"$'\n'
install_from "$R2"
chk "installed expired yesterday" 1 "(1 day ago)"
# installed fresh R1, newest expired R2
mkrel "$R1" "$UPDATER" 1.0.0; mkman "$R1" "$(hdr scripts-v1.0.0 1)"$'\n'"expires=$FRESH"$'\n'; sign "$R1"
newest scripts-v1.1.0 2 "date=2027-03-01"$'\n'"expires=$EXPIRED"$'\n'
install_from "$R1"
chk "newest expired" 1 "Update pending" "Newest release scripts-v1.1.0 expired on ${EXPIRED} (5 days ago)"
# installed expired R1, newest fresh R2
mkrel "$R1" "$UPDATER" 1.0.0; mkman "$R1" "$(hdr scripts-v1.0.0 1)"$'\n'"expires=$EXPIRED"$'\n'; sign "$R1"
newest scripts-v1.1.0 2 "date=2027-03-01"$'\n'"expires=$FRESH"$'\n'
install_from "$R1"
chk "installed expired, newest fresh" 1 "Installed release scripts-v1.0.0 expired on ${EXPIRED}"
# nothing installed
install_from "$R1"
rm -f "$INST/MANIFEST" "$INST/MANIFEST.sig"
chk "nothing installed" 2 "No signed release is installed" "Newest:     scripts-v1.1.0"
rm -f "$INST/lib/allowed_signers"
chk "nothing installed, no signer list" 2 "No signed release is installed"
# installed record unverifiable
install_from "$R1"
sign_file "$INST/MANIFEST" v4key2
chk "installed record signed by an unknown key" 2 "Re-install the scripts"
install_from "$R1"
rm -f "$INST/MANIFEST.sig"
chk "adversarial: installed MANIFEST readable, MANIFEST.sig missing" 2 "cannot be verified"
install_from "$R1"
sed 's/^serial=1$/serial=7/' "$INST/MANIFEST" > "$T/m" && cat "$T/m" > "$INST/MANIFEST"
chk "installed record tampered (serial edited)" 2 "Re-install the scripts"
# newest unfetchable / unverifiable
newest scripts-v1.1.0 2 "date=2027-03-01"$'\n'"expires=$FRESH"$'\n'
install_from "$R2"
export V4_CURL_FAIL=7
chk "newest unfetchable (network)" 2 "network error"
unset V4_CURL_FAIL
mv "$RAW/main/RELEASE" "$T/RELEASE.off"
chk "no RELEASE published" 2 "No signed script release is published yet"
mv "$T/RELEASE.off" "$RAW/main/RELEASE"
export V4_CURL_FAIL_MATCH=MANIFEST.sig
chk "MANIFEST.sig unfetchable" 2 "Could not download MANIFEST.sig"
unset V4_CURL_FAIL_MATCH
export V4_CURL_FAIL_MATCH=tags/scripts-v1.1.0/MANIFEST
chk "MANIFEST unfetchable (network)" 2 "Could not download MANIFEST of release scripts-v1.1.0"
unset V4_CURL_FAIL_MATCH
mv "$RAW/refs/tags/scripts-v1.1.0/MANIFEST" "$T/MANIFEST.off"
chk "tag has no MANIFEST" 2 "Release scripts-v1.1.0 has no MANIFEST"
mv "$T/MANIFEST.off" "$RAW/refs/tags/scripts-v1.1.0/MANIFEST"
newest scripts-v1.1.0 2 "date=2027-03-01"$'\n'"expires=$FRESH"$'\n' 1.0.0 v4key2
install_from "$R1"
chk "newest unverifiable (unknown key)" 2
newest scripts-v1.1.0 2 "date=2027-03-01"$'\n'"expires=2027-02-30"$'\n'
chk "newest malformed (expires=2027-02-30)" 2 "release manifest is malformed"
newest scripts-v1.1.0 2 "date=2027-03-01"$'\n'"expires=$FRESH"$'\n'
printf 'scripts-v1.2.0 2027-03-01\n' > "$RAW/main/RELEASE"
rm -rf "$RAW/refs/tags/scripts-v1.2.0"; cp -R "$R2" "$RAW/refs/tags/scripts-v1.2.0"
chk "RELEASE names a tag whose manifest is another release" 2 "but RELEASE names scripts-v1.2.0"
# RELEASE names an older serial than the installed one (rollback)
install_from "$R5"
newest scripts-v1.1.0 2 "date=2027-03-01"$'\n'"expires=$FRESH"$'\n'
chk "RELEASE older than installed" 1 "older than the installed serial 5"
# installed expired and the newest unfetchable: which answer wins (observed)
newest scripts-v1.1.0 2 "date=2027-03-01"$'\n'"expires=$EXPIRED"$'\n'
install_from "$R2"
export V4_CURL_FAIL=7
chk "installed expired + network down" 2 "network error"
unset V4_CURL_FAIL
printf 'probe offline-expired: rc=%s mentions-expiry=%s\n' "$RC" "$(plain "$OUT" | grep -c 'expired')" >> "$T/probe.log"
run_upd "" --json --check
check_rc "--json --check: rc 2 (no JSON mode)" 2 "$RC"
# arguments
run_upd "" --check --bogus
check_rc "--check --bogus: rc 2" 2 "$RC"
run_upd "" --bogus --check
check_rc "--bogus --check: rc 2" 2 "$RC"
run_upd "" --help
has "--help names --check" "--check" "$OUT"
check_rc "--help: rc 0" 0 "$RC"

# --- 7. UTC day boundary with the real clock (no V4_TODAY) -------------------------------
unset V4_TODAY
utc_today="$(date -u +%Y-%m-%d)"
eval "$(sed -n '/^days_ymd() {/,/^}/p' "$V4_WT/tools/release-scripts.sh")"
eval "$(sed -n '/^ymd_days() {/,/^}/p' "$V4_WT/tools/release-scripts.sh")"
utc_tomorrow="$(date -u -d "@$(( $(date -u +%s) + 86400 ))" +%Y-%m-%d 2>/dev/null)" || utc_tomorrow="$(days_ymd $(( $(ymd_days "$utc_today") + 1 )))"
differs=""
for tz in ABC-14 ABC+12; do
    [[ "$(TZ=$tz date +%Y-%m-%d)" == "$utc_today" ]] || differs="$differs $tz"
done
check "TZ probe: at least one far zone has a different local date now" "yes" "$([[ -n "$differs" ]] && echo yes || echo no)"
: > "$T/date-local.log"   # the probe above read the local date on purpose
newest scripts-v1.1.0 2 "date=2027-03-01"$'\n'"expires=$utc_today"$'\n'
install_from "$R2"
for tz in ABC-14 ABC+12; do
    export TZ=$tz
    chk "TZ=$tz expires = UTC today" 1 "(today)"
    unset TZ
done
newest scripts-v1.1.0 2 "date=2027-03-01"$'\n'"expires=$utc_tomorrow"$'\n'
install_from "$R2"
for tz in ABC-14 ABC+12; do
    export TZ=$tz
    chk "TZ=$tz expires = UTC tomorrow" 0 "(in 1 day)"
    unset TZ
done
check "no script read the local date" "" "$(cat "$T/date-local.log" 2>/dev/null)"

# --- 8. adversarial: non-ASCII digits in a signed expires= (UTF-8 locale) ----------------
export V4_TODAY=2027-03-15
utf8=""
for l in C.UTF-8 C.utf8 en_US.UTF-8 en_US.utf8; do
    if [[ "$(LC_ALL=$l bash -c '[[ "２" =~ ^[0-9]$ ]] && echo m' 2>/dev/null)" == m ]]; then utf8=$l; break; fi
done
newest scripts-v1.1.0 2 "date=2027-03-01"$'\n'"expires=２０２７-05-30"$'\n'
install_from "$R1"
before="$(tree_sig)"
export LC_ALL="${utf8:-C}"
run_upd y
unset LC_ALL
check "fullwidth expires (locale ${utf8:-C}): updater does not exit 0" "nonzero" "$([[ $RC -ne 0 ]] && echo nonzero || echo zero)"
check "fullwidth expires: tree unchanged" "$before" "$(tree_sig)"
printf 'probe fullwidth: locale=%s rc=%s out=%s\n' "${utf8:-C}" "$RC" "$(plain "$OUT" | grep -iE 'refused|invalid|error' | head -2 | tr '\n' ' ')" >> "$T/probe.log"
cat "$T/probe.log"

finish
