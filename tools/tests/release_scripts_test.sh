#!/usr/bin/env bash
# =============================================================================
# tools/tests/release_scripts_test.sh -- tools/release-scripts.sh on a copy of
# this repository, then install.sh on the release it produced
#
#   bash tools/tests/release_scripts_test.sh
#
# Copies the tracked files into a temp git repository, prepares a release
# there, signs it with a throwaway key (tools/tests/signing.sh), checks it,
# and installs it with the install.sh the tool wrote, through a curl shim that
# serves the release archive. Needs git and tar; without git (the bash:3.2
# image) all but the date arithmetic checks are SKIP. No network, nothing
# outside the temp dir.
# =============================================================================

set -u

# shellcheck source=tools/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

T="$TN_TEST_TMP"
REPO="$TN_TEST_REPO"
BIN="$T/bin"
W="$T/repo"
mkdir -p "$BIN" "$W" "$T/archives"

# --- date arithmetic (every bash: no git needed) -------------------------------
# ymd_days and days_ymd, cut from the tool, against day numbers computed with
# GNU date; and every script that reads a MANIFEST date carries the same
# ymd_days text.
eval "$(sed -n -e '/^ymd_days() {/,/^}/p' -e '/^days_ymd() {/,/^}/p' "$REPO/tools/release-scripts.sh")"
bad=""
for pair in 1970-01-01:0 1970-03-01:59 2000-02-29:11016 2000-03-01:11017 2024-02-29:19782 \
            2026-11-03:20760 2027-02-01:20850 2100-02-28:47540 2100-03-01:47541 \
            2399-12-31:157053 2400-02-29:157113 9999-12-31:2932896; do
    [[ "$(ymd_days "${pair%%:*}")" == "${pair#*:}" && "$(days_ymd "${pair#*:}")" == "${pair%%:*}" ]] || bad="$bad $pair"
done
check "dates: known day numbers both ways" "" "$bad"
bad=""
for d in 2023-02-29 2100-02-29 1969-12-31 2026-13-01 2026-00-10 2026-04-31 2026-01-00 2026-1-01 \
         20260101 2026/01/01 "2026-01-01 " " 2026-01-01" "" x; do
    if ymd_days "$d" >/dev/null 2>&1; then bad="$bad [$d]"; fi
done
check "dates: malformed and impossible dates refused" "" "$bad"
bad=""
n=0
while [[ $n -le 120000 ]]; do
    [[ "$(ymd_days "$(days_ymd "$n")")" == "$n" ]] || bad="$bad $n"
    n=$((n + 293))
done
check "dates: day number to date and back, 1970 to 2298" "" "$bad"
# Digits other than 0-9 (full-width, Arabic-Indic) are a clean refusal in a
# UTF-8 locale too, never an arithmetic error: en_US.UTF-8 where it exists, else
# C.UTF-8.
loc=C.UTF-8
if command -v locale >/dev/null 2>&1 && locale -a 2>/dev/null | grep -qiE '^en_US\.utf-?8$'; then
    loc=en_US.UTF-8
fi
fw="$(printf '\357\274\222\357\274\220\357\274\222\357\274\226')"   # full-width 2026
ar="$(printf '\331\242')"                                                  # Arabic-Indic 2
for f in tools/release-scripts.sh update-scripts.sh install.sh check-node.sh; do
    fn="$(sed -n '/^ymd_days() {/,/^}/p' "$REPO/$f")"
    out="$(LC_ALL="$loc" "$BASH" -c 'eval "$1"; shift
        for d in "$@"; do ymd_days "$d"; echo "rc=$?"; done' _ "$fn" "${fw}-11-03" "2026-1${ar}-03" 2026-11-03 2>&1)"
    check "dates, $loc: $f refuses non-ASCII digits cleanly" "$(printf 'rc=1\nrc=1\n20760\nrc=0')" "$out"
done
ref="$(sed -n '/^ymd_days() {/,/^}/p' "$REPO/tools/release-scripts.sh")"
for f in update-scripts.sh install.sh check-node.sh; do
    check "dates: $f carries the same ymd_days" "$ref" "$(sed -n '/^ymd_days() {/,/^}/p' "$REPO/$f")"
done

if ! command -v git >/dev/null 2>&1 || ! git -C "$REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    skip "release-scripts.sh" "git absent or not a git checkout"
    finish
fi

_h() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1"
    else
        shasum -a 256 "$1"
    fi | awk '{print $1}'
}

# shellcheck source=tools/tests/signing.sh
. "$TN_TEST_DIR/signing.sh"
export PATH="$BIN:$PATH"
KEY1_LINE="$(newkey key1)"
# A date shim answers `date -u +%Y-%m-%d` with TODAY; other calls run the real date.
REAL_DATE="$(type -P date)"
cat > "$BIN/date" <<EOF
#!/bin/sh
if [ -n "\${TODAY:-}" ] && [ "\$*" = "-u +%Y-%m-%d" ]; then echo "\$TODAY"; exit 0; fi
exec $REAL_DATE "\$@"
EOF
chmod +x "$BIN/date"
export TODAY=""

gitc() {
    git -C "$W" -c user.name=test -c user.email=test@example.invalid -c commit.gpgsign=false "$@"
}
commit_all() {
    gitc add -A >/dev/null && gitc commit -q -m "$1" >/dev/null
}
# tool ARGS... -- run the copy's release tool; OUT and RC get its output and status.
tool() {
    OUT="$(cd "$W" && bash tools/release-scripts.sh "$@" 2>&1)"
    RC=$?
}

(cd "$REPO" && git ls-files | tar -cf - -T -) | tar -xf - -C "$W"
git -C "$W" init -q
commit_all "fixture"

# --- check on a tree without MANIFEST ------------------------------------------
# The fixture starts before any release: no release record and no signer key,
# also once main carries a release.
rm -f "$W/MANIFEST" "$W/MANIFEST.sig" "$W/RELEASE"
grep -E '^[[:space:]]*(#|$)' "$REPO/lib/allowed_signers" > "$W/lib/allowed_signers"
commit_all "no release yet" || true
tool --check
check_rc "no MANIFEST: check passes" 0 "$RC"
check "no MANIFEST: nothing to check" "No MANIFEST in the tree: nothing to check." "$OUT"
tool --check --require-fresh
check_rc "no MANIFEST, --require-fresh: fails" 1 "$RC"
check "no MANIFEST, --require-fresh: says why" "release-scripts.sh: no MANIFEST in the tree" "$OUT"

# --- refusals before the tree is ready ---------------------------------------
tool scripts-v2.0.0 --serial 200
check_rc "no key yet: refused" 1 "$RC"
check_has "no key yet: says why" "release-scripts.sh: lib/allowed_signers lists no key: add the release signer public key line first" "$OUT"

printf '%s\n' "$KEY1_LINE" >> "$W/lib/allowed_signers"
commit_all "add key"
tool scripts-v2.0.0 --serial 200
check_rc "signer list without sidecar: refused" 1 "$RC"
check_has "signer list without sidecar: says why" "release-scripts.sh: stale or missing sidecar: lib/allowed_signers.sha256" "$OUT"

# What release prep does: the signer list joins an updater array, sidecars refreshed.
awk '{ print } /^declare -a SCRIPTS=\(/ { print "    \"lib/allowed_signers:lib/allowed_signers:NONE\"" }' \
    "$W/update-scripts.sh" > "$T/us" && cat "$T/us" > "$W/update-scripts.sh"
(cd "$W" && bash tools/gen-checksums.sh >/dev/null)
commit_all "track signers"

printf 'dirty\n' >> "$W/README.md"
tool scripts-v2.0.0 --serial 200
check_rc "dirty tree: refused" 1 "$RC"
gitc checkout -q -- README.md

tool scripts-v2
check_rc "bad tag: refused" 1 "$RC"
tool scripts-v2.0.0
check_rc "first release without --serial: refused" 1 "$RC"
tool scripts-v2.0.0 --serial 200 --min-updater 99.0.0
check_rc "min_updater above the tree updater: refused" 1 "$RC"
for days in 0 3651 30x -5 ""; do
    tool scripts-v2.0.0 --serial 200 --expires "$days"
    check_rc "--expires '$days': refused" 1 "$RC"
done
check_has "--expires out of range: says why" "release-scripts.sh: --expires takes a number of days from 1 to 3650, got: " "$OUT"
tool scripts-v2.0.0 --serial 200 --date 2026-02-30
check_rc "--date not a calendar date: refused" 1 "$RC"
check_has "--date not a calendar date: says why" "release-scripts.sh: date must be a calendar date like 2026-10-15, got: 2026-02-30" "$OUT"
check "refusals leave the tree clean" "" "$(git -C "$W" status --porcelain)"

# --- prepare -------------------------------------------------------------------
tool scripts-v2.0.0 --serial 200 --date 2026-10-15
check_rc "prepare: exits 0" 0 "$RC"
check_has "prepare: prints the signing command" "       ssh-keygen -Y sign -f ~/.ssh/id_ed25519_sk -n tn-node-scripts MANIFEST" "$OUT"
uver="$(sed -n 's/^readonly SCRIPT_VERSION="\([0-9.]*\)"$/\1/p' "$W/update-scripts.sh")"
check "prepare: header" "$(printf 'format=1\nrelease=scripts-v2.0.0\nserial=200\nmin_updater=%s' "$uver")" "$(head -n 4 "$W/MANIFEST")"
check "prepare: RELEASE" "scripts-v2.0.0 2026-10-15" "$(cat "$W/RELEASE")"
check "prepare: date= and expires= (90 days by default) follow min_updater=" "$(printf 'date=2026-10-15\nexpires=2027-01-13')" "$(sed -n '5,6p' "$W/MANIFEST")"
check_has "prepare: prints the expiry" "Release date 2026-10-15; the release expires 2027-01-13 (90 days later)." "$OUT"
check "prepare: installer tag" 'readonly TN_SCRIPTS_TAG="scripts-v2.0.0"   # written by tools/release-scripts.sh' "$(grep '^readonly TN_SCRIPTS_TAG=' "$W/install.sh")"
check "prepare: installer still ends with main" 'main "$@"' "$(tail -n 1 "$W/install.sh")"
check "prepare: installer parses" "0" "$(bash -n "$W/install.sh" 2>&1; echo $?)"
embedded="$(awk -v q="'" '
    $0 == "TN_ALLOWED_SIGNERS" { inblock = 0 }
    inblock { print }
    index($0, "<<" q "TN_ALLOWED_SIGNERS" q) { inblock = 1 }
' "$W/install.sh")"
check "prepare: installer carries the signer list" "$(cat "$W/lib/allowed_signers")" "$embedded"
paths="$(awk '/^sha256  / {print $3}' "$W/MANIFEST")"
check "prepare: paths sorted and unique" "$(printf '%s\n' "$paths" | LC_ALL=C sort -u)" "$paths"
for p in install.sh open-ui.sh lib/allowed_signers update-scripts.sh lib/common.sh ui/server.py observability/config.alloy; do
    check_has "prepare: lists $p" "$p" "$paths"
done
bad=""
while IFS= read -r line; do
    p="$(printf '%s\n' "$line" | awk '{print $3}')"
    [[ "$(printf '%s\n' "$line" | awk '{print $2}')" == "$(_h "$W/$p")" ]] || bad="$bad $p"
done < <(grep '^sha256  ' "$W/MANIFEST")
check "prepare: every hash matches the file" "" "$bad"
check "prepare: no signature yet" "absent" "$([[ -e "$W/MANIFEST.sig" ]] && echo present || echo absent)"

# --- check -------------------------------------------------------------------------
tool --check
check_rc "check unsigned: passes with a warning" 0 "$RC"
tool --check --tag scripts-v2.0.0
check_rc "check --tag unsigned: fails" 1 "$RC"
sign_file "$W/MANIFEST" key1
tool --check --tag scripts-v2.0.0
check_rc "check --tag signed: passes" 0 "$RC"
tool --check --tag scripts-v2.0.1
check_rc "check with another tag: fails" 1 "$RC"

# --- check: the release date and the expiry -------------------------------------------
TODAY=2026-11-03 tool --check --tag scripts-v2.0.0 --require-fresh
check_rc "check, fresh, --require-fresh: passes" 0 "$RC"
check_has "check: prints the release date" "Release date 2026-10-15." "$OUT"
check_has "check: prints the expiry" "Release scripts-v2.0.0 expires 2027-01-13 (in 71 days)." "$OUT"
TODAY=2027-01-12 tool --check
check_has "check, the day before: 1 day" "Release scripts-v2.0.0 expires 2027-01-13 (in 1 day)." "$OUT"
TODAY=2027-01-13 tool --check --tag scripts-v2.0.0
check_rc "check, expired: still passes" 0 "$RC"
check_has "check, expired: warns" "WARN release scripts-v2.0.0 expired on 2027-01-13 (today): a newer signed release is overdue" "$OUT"
TODAY=2027-01-20 tool --check --tag scripts-v2.0.0 --require-fresh
check_rc "check, expired, --require-fresh: fails" 1 "$RC"
check_has "check, expired, --require-fresh: says why" "FAIL release scripts-v2.0.0 expired on 2027-01-13 (7 days ago): cut a newer release" "$OUT"
cp "$W/MANIFEST" "$T/MANIFEST.keep"
cp "$W/MANIFEST.sig" "$T/MANIFEST.sig.keep"
cp "$W/RELEASE" "$T/RELEASE.keep"
# reheader LINE... -- MANIFEST with its date= and expires= lines replaced by LINEs, signed.
reheader() {
    {
        grep -E '^(format|release|serial|min_updater)=' "$T/MANIFEST.keep"
        if [[ $# -gt 0 ]]; then printf '%s\n' "$@"; fi
        grep '^sha256  ' "$T/MANIFEST.keep"
    } > "$W/MANIFEST"
    sign_file "$W/MANIFEST" key1
}
reheader
TODAY=2027-06-01 tool --check --tag scripts-v2.0.0 --require-fresh
check_rc "check, 2.0.0-shaped manifest: passes" 0 "$RC"
check_has "check, 2.0.0-shaped manifest: no expiry" "MANIFEST has no expires= line: scripts-v2.0.0 does not expire." "$OUT"
reheader date=2026-10-15 expires=2027-01-13 expires=2027-02-13
tool --check
check_rc "check, expires twice: fails" 1 "$RC"
check_has "check, expires twice: says why" "release-scripts.sh: MANIFEST: expires= appears more than once" "$OUT"
reheader date=2026-10-15 expires=2027-02-30
tool --check
check_rc "check, expires not a calendar date: fails" 1 "$RC"
check_has "check, expires not a calendar date: says why" "release-scripts.sh: MANIFEST: expires=2027-02-30 is not a calendar date YYYY-MM-DD" "$OUT"
reheader date=2026-10-15 expires=
tool --check
check_rc "check, expires= empty: fails" 1 "$RC"
check_has "check, expires= empty: says why" "release-scripts.sh: MANIFEST: expires= is not a calendar date YYYY-MM-DD" "$OUT"
reheader date= expires=2027-01-13
tool --check
check_rc "check, date= empty: fails" 1 "$RC"
check_has "check, date= empty: says why" "release-scripts.sh: MANIFEST: date= is not a calendar date YYYY-MM-DD" "$OUT"
reheader date=2026-10-15 expires=2026-10-15
tool --check
check_rc "check, expires not after date: fails" 1 "$RC"
check_has "check, expires not after date: says why" "FAIL MANIFEST expires=2026-10-15 is not after date=2026-10-15" "$OUT"
reheader date=2026-10-14 expires=2027-01-13
tool --check
check_rc "check, RELEASE dated otherwise: fails" 1 "$RC"
check_has "check, RELEASE dated otherwise: says why" "FAIL RELEASE is dated 2026-10-15, MANIFEST date=2026-10-14" "$OUT"
cp "$T/MANIFEST.keep" "$W/MANIFEST"
cp "$T/MANIFEST.sig.keep" "$W/MANIFEST.sig"
cp "$T/RELEASE.keep" "$W/RELEASE"
cp "$W/setup-node.sh" "$T/setup-node.sh.keep"
printf '# edited after signing\n' >> "$W/setup-node.sh"
tool --check
check_rc "check after an edit: fails" 1 "$RC"
cat "$T/setup-node.sh.keep" > "$W/setup-node.sh"
newkey key2 >/dev/null
sign_file "$W/MANIFEST" key2
tool --check
check_rc "check with a foreign signature: fails" 1 "$RC"
sign_file "$W/MANIFEST" key1
commit_all "Release scripts-v2.0.0"

# --- install the release with the installer the tool wrote ---------------------------
ARCHIVE_URL_BASE="https://github.com/Telcoin-Association/tn-node-deployment/archive/refs/tags"
cat > "$BIN/curl" <<EOF
#!/bin/sh
out="" url=""
while [ \$# -gt 0 ]; do
    case "\$1" in
        -o) out="\$2"; shift ;;
        --proto|--max-time) shift ;;
        https://*) url="\$1" ;;
    esac
    shift
done
case "\$url" in
    $ARCHIVE_URL_BASE/*.tar.gz) f="$T/archives/\${url##*/}" ;;
    *) exit 6 ;;
esac
[ -f "\$f" ] || exit 22
cp "\$f" "\$out"
EOF
chmod +x "$BIN/curl"
gitc archive --format=tar.gz --prefix=tn-node-deployment-scripts-v2.0.0/ -o "$T/archives/scripts-v2.0.0.tar.gz" HEAD
mkdir -p "$T/home"
OUT="$(HOME="$T/home" TERM=dumb bash "$W/install.sh" < /dev/null 2>&1)"
RC=$?
check_rc "install the prepared release: exits 0" 0 "$RC"
check "install: every MANIFEST file present" "$(printf '%s\n' "$paths" | wc -l | tr -d ' ')" \
    "$(cd "$T/home/telcoin-node-scripts" 2>/dev/null && printf '%s\n' "$paths" | while IFS= read -r p; do [[ -f "$p" ]] && echo "$p"; done | wc -l | tr -d ' ')"

# --- next release: serial defaults to the previous + 1 --------------------------------------
printf '# next\n' >> "$W/open-ui.sh"
commit_all "change"
tool scripts-v2.0.1 --serial 200
check_rc "next release with a serial not above 200: refused" 1 "$RC"
TODAY=2026-11-03 tool scripts-v2.0.1 --date 2026-10-04 --expires 30
check_rc "prepare, expires today: still exits 0" 0 "$RC"
check_has "prepare, expires today: warns" "release-scripts.sh: WARN scripts-v2.0.1 expires 2026-11-03, on or before today (2026-11-03): every updater, installer and check-node will report it as expired. Prepare it again with a later --date or a longer --expires before signing." "$OUT"
gitc checkout -q -- .
TODAY=2026-11-03 tool scripts-v2.0.1 --date 2020-01-01
check_has "prepare, --date 2020-01-01: warns" "release-scripts.sh: WARN scripts-v2.0.1 expires 2020-03-31, on or before today (2026-11-03): every updater, installer and check-node will report it as expired. Prepare it again with a later --date or a longer --expires before signing." "$OUT"
gitc checkout -q -- .
TODAY=2026-11-02 tool scripts-v2.0.1 --date 2026-10-16 --expires 30
check_rc "next release: exits 0" 0 "$RC"
check_lacks "next release, expires ahead: no warning" "WARN" "$OUT"
check "next release: serial 201" "serial=201" "$(grep '^serial=' "$W/MANIFEST")"
check "next release: --expires 30" "$(printf 'date=2026-10-16\nexpires=2026-11-15')" "$(grep -E '^(date|expires)=' "$W/MANIFEST")"
check "next release: old signature removed" "absent" "$([[ -e "$W/MANIFEST.sig" ]] && echo present || echo absent)"

finish
