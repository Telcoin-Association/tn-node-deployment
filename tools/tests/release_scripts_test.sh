#!/usr/bin/env bash
# =============================================================================
# tools/tests/release_scripts_test.sh -- tools/release-scripts.sh on a copy of
# this repository, then install.sh on the release it produced
#
#   bash tools/tests/release_scripts_test.sh
#
# First the parts every bash runs: the date arithmetic, the RELEASE
# SIGNATURES block (the same text in the three scripts), its gpgv status
# policy fed with status lines, and its shell dearmor. Then it copies the
# tracked files into a temp git repository, prepares a release there, signs it
# with a throwaway OpenPGP key (tools/tests/signing.sh: real gpg, or the fake
# gpg and gpgv where GnuPG is absent), checks it, and installs it with the
# install.sh the tool wrote, through a curl shim that serves the release
# archive. Needs git and tar for that part; without git (the bash:3.2 and
# ubuntu:24.04 images) it is SKIP. No network, nothing outside the temp dir.
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
    # shellcheck disable=SC2016  # the inner bash expands the program
    out="$(LC_ALL="$loc" "$BASH" -c 'eval "$1"; shift
        for d in "$@"; do ymd_days "$d"; echo "rc=$?"; done' _ "$fn" "${fw}-11-03" "2026-1${ar}-03" 2026-11-03 2>&1)"
    check "dates, $loc: $f refuses non-ASCII digits cleanly" "$(printf 'rc=1\nrc=1\n20760\nrc=0')" "$out"
done
ref="$(sed -n '/^ymd_days() {/,/^}/p' "$REPO/tools/release-scripts.sh")"
for f in update-scripts.sh install.sh check-node.sh; do
    check "dates: $f carries the same ymd_days" "$ref" "$(sed -n '/^ymd_days() {/,/^}/p' "$REPO/$f")"
done

# --- RELEASE SIGNATURES: one text, one policy (every bash) -------------------------
block() { sed -n '/^# RELEASE SIGNATURES$/,/^# --- end of RELEASE SIGNATURES/p' "$REPO/$1"; }
ref="$(block tools/release-scripts.sh)"
check "signatures: the block is in tools/release-scripts.sh" "yes" "$([[ "$ref" == *"tn_verify_manifest() {"* ]] && echo yes || echo no)"
for f in update-scripts.sh install.sh; do
    check "signatures: $f carries the same RELEASE SIGNATURES block" "$ref" "$(block "$f")"
done
check "signatures: one signature file, threshold 1" "$(printf 'readonly TN_SIG_FILE="MANIFEST.asc"\nreadonly TN_SIG_THRESHOLD=1')" \
    "$(printf '%s\n' "$ref" | grep -E '^readonly TN_SIG_(FILE|THRESHOLD)=')"

# verdict THRESHOLD STATUS-LINES -- "rc line" from tn_sig_verdict, the block
# loaded with that threshold, in a child bash (stderr dropped).
verdict() {
    # shellcheck disable=SC2016  # the inner bash expands the program
    "$BASH" -c 'eval "$1"; printf "%s\n" "$2" | tn_sig_verdict; echo "rc=$?"' _ \
        "$(printf '%s\n' "$ref" | sed "s/^readonly TN_SIG_THRESHOLD=1\$/readonly TN_SIG_THRESHOLD=$1/")" "$2" 2>/dev/null | tr '\n' ' '
}
FA=AAAA1111AAAA1111AAAA1111AAAA1111AAAA1111
FB=BBBB2222BBBB2222BBBB2222BBBB2222BBBB2222
good() { printf '[GNUPG:] NEWSIG\n[GNUPG:] GOODSIG %s x\n[GNUPG:] VALIDSIG %s 2026-11-04 1 0 4 0 22 10 00 %s\n' "${1:24}" "$1" "$1"; }
check "policy: one good signature" "GOOD $FA rc=0 " "$(verdict 1 "$(good "$FA")")"
check "policy: two keys counted once each" "GOOD $FA $FB rc=0 " "$(verdict 1 "$(good "$FA"; good "$FB"; good "$FA")")"
check "policy: threshold 2, one key twice: refused" "THRESHOLD 1 $FA rc=1 " "$(verdict 2 "$(good "$FA"; good "$FA")")"
check "policy: threshold 2, two keys: accepted" "GOOD $FA $FB rc=0 " "$(verdict 2 "$(good "$FA"; good "$FB")")"
check "policy: BADSIG beside a good one refuses" "BADSIG 1111222233334444 rc=1 " \
    "$(verdict 1 "$(good "$FA"; printf '[GNUPG:] BADSIG 1111222233334444 x\n')")"
for kw in EXPKEYSIG REVKEYSIG EXPSIG; do
    check "policy: $kw refuses" "$kw ${FB:24} rc=1 " \
        "$(verdict 1 "$(good "$FA"; printf '[GNUPG:] %s %s x\n[GNUPG:] VALIDSIG %s 2026-11-04 1 0 4 0 22 10 00 %s\n' "$kw" "${FB:24}" "$FB" "$FB")")"
done
UNK='[GNUPG:] ERRSIG 1111222233334444 22 10 00 1792597639 9 -
[GNUPG:] NO_PUBKEY 1111222233334444'
check "policy: only a key that is not a release key: NOSIG" "NOSIG rc=1 " "$(verdict 1 "$UNK")"
check "policy: a good signature beside an unknown key: accepted" "GOOD $FA rc=0 " "$(verdict 1 "$(good "$FA"; printf '%s\n' "$UNK")")"
check "policy: the unknown key is named on stderr" "a signature by key 1111222233334444, which is not a release key, was not checked" \
    "$("$BASH" -c 'eval "$1"; printf "%s\n" "$2" | tn_sig_verdict' _ "$ref" "$(good "$FA"; printf '%s\n' "$UNK")" 2>&1 >/dev/null)"
check "policy: ERRSIG with another code refuses" "ERRSIG 1111222233334444 4 rc=1 " \
    "$(verdict 1 "$(good "$FA"; printf '[GNUPG:] ERRSIG 1111222233334444 22 10 00 1792597639 4 -\n')")"
check "policy: GOODSIG without VALIDSIG counts nothing" "NOSIG rc=1 " "$(verdict 1 "$(printf '[GNUPG:] GOODSIG %s x\n' "${FA:24}")")"
check "policy: VALIDSIG without GOODSIG counts nothing" "NOSIG rc=1 " "$(verdict 1 "$(printf '[GNUPG:] VALIDSIG %s 2026 1 0 4 0 22 10 00 %s\n' "$FA" "$FA")")"
check "policy: a short primary fingerprint counts nothing" "NOSIG rc=1 " "$(verdict 1 "$(good "${FA:8}")")"
check "policy: no status lines" "NOSIG rc=1 " "$(verdict 1 "gpgv: no signature found")"

# --- RELEASE SIGNATURES: the shell dearmor (every bash) ----------------------------
# dearmor FILE... -- tn_dearmor_keys over a dir holding FILEs: its output to
# $T/dearmor.out, "rc N" and its stderr on stdout.
mkdir -p "$T/dearmor"
dearmor() {
    rm -rf "$T/dearmor/keys"
    mkdir -p "$T/dearmor/keys"
    cp "$@" "$T/dearmor/keys/"
    # shellcheck disable=SC2016  # the inner bash expands the program
    "$BASH" -c 'eval "$1"; tn_dearmor_keys "$2" > "$3"; echo "rc $?"' _ "$ref" "$T/dearmor/keys" "$T/dearmor.out" 2>&1
}
printf 'packet one\001\002\377 binary\n' > "$T/dearmor/raw1"
printf 'second key\n' > "$T/dearmor/raw2"
armor() {   # armor RAW [HEADER...] -- an armored public key block of RAW
    local raw="$1"
    shift
    printf -- '-----BEGIN PGP PUBLIC KEY BLOCK-----\n'
    if [[ $# -gt 0 ]]; then printf '%s\n' "$@"; fi
    printf '\n'
    base64 < "$raw" | tr -d '\n' | fold -w 64
    printf '\n=AbCd\n-----END PGP PUBLIC KEY BLOCK-----\n'
}
armor "$T/dearmor/raw1" > "$T/dearmor/plain.asc"
armor "$T/dearmor/raw1" "Version: GnuPG v2" "Comment: a test key" > "$T/dearmor/headers.asc"
check "dearmor: plain block" "rc 0" "$(dearmor "$T/dearmor/plain.asc")"
check "dearmor: plain block, the bytes" "yes" "$(cmp -s "$T/dearmor.out" "$T/dearmor/raw1" && echo yes || echo no)"
check "dearmor: armor headers and a CRC line" "rc 0" "$(dearmor "$T/dearmor/headers.asc")"
check "dearmor: armor headers and a CRC line, the bytes" "yes" "$(cmp -s "$T/dearmor.out" "$T/dearmor/raw1" && echo yes || echo no)"
awk '{ printf "%s\r\n", $0 }' "$T/dearmor/headers.asc" > "$T/dearmor/crlf.asc"
check "dearmor: CRLF line endings" "rc 0" "$(dearmor "$T/dearmor/crlf.asc")"
check "dearmor: CRLF line endings, the bytes" "yes" "$(cmp -s "$T/dearmor.out" "$T/dearmor/raw1" && echo yes || echo no)"
{ armor "$T/dearmor/raw1"; armor "$T/dearmor/raw2"; } > "$T/dearmor/two.asc"
cat "$T/dearmor/raw1" "$T/dearmor/raw2" > "$T/dearmor/raw12"
check "dearmor: two blocks in one file" "rc 0" "$(dearmor "$T/dearmor/two.asc")"
check "dearmor: two blocks in one file, both decoded in order" "yes" "$(cmp -s "$T/dearmor.out" "$T/dearmor/raw12" && echo yes || echo no)"
printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOv5 not a pgp key\n' > "$T/dearmor/ssh.asc"
check "dearmor: a file that is not a key is refused" "yes" \
    "$(dearmor "$T/dearmor/ssh.asc" | grep -q 'ssh.asc is not an ASCII-armored OpenPGP public key' && echo yes || echo no)"
out="$(dearmor "$T/dearmor/plain.asc" "$T/dearmor/ssh.asc")"
check "dearmor: a file that is not a key beside a good key refuses the whole set" "rc 1" "$(printf '%s\n' "$out" | tail -n 1)"
check "dearmor: a file that is not a key beside a good key is named" "yes" \
    "$(printf '%s\n' "$out" | grep -q 'ssh.asc is not an ASCII-armored OpenPGP public key' && echo yes || echo no)"
sed 's/^-----BEGIN PGP PUBLIC KEY BLOCK-----$/-----BEGIN PGP SIGNATURE-----/' "$T/dearmor/plain.asc" > "$T/dearmor/sig.asc"
check "dearmor: a signature block is not a key" "rc 1" "$(dearmor "$T/dearmor/sig.asc" | tail -n 1)"
awk 'NR == 3 { $0 = "not*base64!" } { print }' "$T/dearmor/plain.asc" > "$T/dearmor/junk.asc"
check "dearmor: a body line that is not base64 is refused" "yes" \
    "$(dearmor "$T/dearmor/junk.asc" | grep -q 'junk.asc: public key block 1 is malformed' && echo yes || echo no)"
grep -v '^-----END' "$T/dearmor/plain.asc" > "$T/dearmor/noend.asc"
check "dearmor: a block without END is refused" "rc 1" "$(dearmor "$T/dearmor/noend.asc" | tail -n 1)"
grep -v '^$' "$T/dearmor/headers.asc" > "$T/dearmor/noblank.asc"
check "dearmor: a block without the blank line is refused" "rc 1" "$(dearmor "$T/dearmor/noblank.asc" | tail -n 1)"
printf 'not a key\n' > "$T/dearmor/README"
check "dearmor: no *.asc file is refused" "yes" \
    "$(dearmor "$T/dearmor/README" | grep -q '^no release key file (\*\.asc) in ' && echo yes || echo no)"
if command -v gpg >/dev/null 2>&1; then
    check "dearmor: the shipped key decodes as gpg --dearmor does" "yes" \
        "$(dearmor "$REPO/lib/release-keys/grantkee.asc" >/dev/null; mkdir -p "$T/dearmor/home"; chmod 700 "$T/dearmor/home"
           GNUPGHOME="$T/dearmor/home" gpg --batch --quiet --dearmor < "$REPO/lib/release-keys/grantkee.asc" > "$T/dearmor/gpg.out" 2>/dev/null
           cmp -s "$T/dearmor.out" "$T/dearmor/gpg.out" && echo yes || echo no)"
else
    skip "dearmor: the shipped key against gpg --dearmor" "gpg absent"
fi

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
FPR1="$(newkey key1)"
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
# The fixture starts before any release: no release record and no release key,
# also once main carries a release.
rm -f "$W/MANIFEST" "$W/MANIFEST.asc" "$W/RELEASE" "$W"/lib/release-keys/*.asc "$W"/lib/release-keys/*.asc.sha256
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
check_has "no key yet: says why" "release-scripts.sh: lib/release-keys holds no release key (*.asc): add the release signer public key first" "$OUT"

cp "$T/key1.asc" "$W/lib/release-keys/key1.asc"
commit_all "a key outside the arrays"
tool scripts-v2.0.0 --serial 200
check_rc "key file not in an updater array: refused" 1 "$RC"
check_has "key file not in an updater array: says why" "release-scripts.sh: lib/release-keys/key1.asc is not in an updater array: add the row \"lib/release-keys/key1.asc:lib/release-keys/key1.asc:NONE\" to SCRIPTS in update-scripts.sh so it ships, then run bash tools/gen-checksums.sh" "$OUT"

# The key takes the SCRIPTS row of the shipped key file (grantkee.asc).
gitc mv -f lib/release-keys/key1.asc lib/release-keys/grantkee.asc
commit_all "key in place"
tool scripts-v2.0.0 --serial 200
check_rc "key without sidecar: refused" 1 "$RC"
check_has "key without sidecar: says why" "release-scripts.sh: stale or missing sidecar: lib/release-keys/grantkee.asc.sha256" "$OUT"
cp "$W/lib/release-keys/grantkee.asc" "$T/key1.keep"
printf 'ssh-ed25519 AAAA not a pgp key\n' > "$W/lib/release-keys/grantkee.asc"
(cd "$W" && bash tools/gen-checksums.sh >/dev/null)
commit_all "a key file that is not a key"
tool scripts-v2.0.0 --serial 200
check_rc "key file that is not a key: refused" 1 "$RC"
check_has "key file that is not a key: says why" "release-scripts.sh: lib/release-keys/grantkee.asc is not an ASCII-armored OpenPGP public key" "$OUT"
awk '{ printf "%s\r\n", $0 }' "$T/key1.keep" > "$W/lib/release-keys/grantkee.asc"
(cd "$W" && bash tools/gen-checksums.sh >/dev/null)
commit_all "a key file with CR line endings"
tool scripts-v2.0.0 --serial 200
check_rc "key file with CR line endings: refused" 1 "$RC"
check_has "key file with CR line endings: says why" "release-scripts.sh: lib/release-keys/grantkee.asc has CR line endings: write it with LF line endings (as gpg --armor --export does)" "$OUT"
# A block that decodes, but to bytes that are no key: gpgv would drop the
# whole keyring, so gpg (real or the stand-in) must read a fingerprint.
armor "$T/dearmor/raw1" > "$W/lib/release-keys/grantkee.asc"
(cd "$W" && bash tools/gen-checksums.sh >/dev/null)
commit_all "a key file that decodes to no key"
tool scripts-v2.0.0 --serial 200
check_rc "key file that decodes to no key: refused" 1 "$RC"
check_has "key file that decodes to no key: says why" "release-scripts.sh: gpg reads no primary key from lib/release-keys/grantkee.asc: export the key again with gpg --armor --export <fingerprint>" "$OUT"
cp "$T/key1.keep" "$W/lib/release-keys/grantkee.asc"
(cd "$W" && bash tools/gen-checksums.sh >/dev/null)
commit_all "track the key"

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
check_has "prepare: prints the signing command" "       gpg --armor --detach-sign --local-user ${FPR1}! --output MANIFEST.asc MANIFEST   # lib/release-keys/grantkee.asc" "$OUT"
check_has "prepare: prints the signed commit" "       git commit -S -m \"release: scripts-v2.0.0\"" "$OUT"
uver="$(sed -n 's/^readonly SCRIPT_VERSION="\([0-9.]*\)"$/\1/p' "$W/update-scripts.sh")"
check "prepare: header" "$(printf 'format=1\nrelease=scripts-v2.0.0\nserial=200\nmin_updater=%s' "$uver")" "$(head -n 4 "$W/MANIFEST")"
check "prepare: RELEASE" "scripts-v2.0.0 2026-10-15" "$(cat "$W/RELEASE")"
check "prepare: date= and expires= (90 days by default) follow min_updater=" "$(printf 'date=2026-10-15\nexpires=2027-01-13')" "$(sed -n '5,6p' "$W/MANIFEST")"
check_has "prepare: prints the expiry" "Release date 2026-10-15; the release expires 2027-01-13 (90 days later)." "$OUT"
check "prepare: installer tag" 'readonly TN_SCRIPTS_TAG="scripts-v2.0.0"   # written by tools/release-scripts.sh' "$(grep '^readonly TN_SCRIPTS_TAG=' "$W/install.sh")"
check "prepare: installer still ends with main" 'main "$@"' "$(tail -n 1 "$W/install.sh")"
check "prepare: installer parses" "0" "$(bash -n "$W/install.sh" 2>&1; echo $?)"
embedded="$(awk -v q="'" '
    $0 == "TN_RELEASE_KEYS" { inblock = 0 }
    inblock { print }
    index($0, "<<" q "TN_RELEASE_KEYS" q) { inblock = 1 }
' "$W/install.sh")"
check "prepare: installer carries the release keys" "$(cat "$W"/lib/release-keys/*.asc)" "$embedded"
paths="$(awk '/^sha256  / {print $3}' "$W/MANIFEST")"
check "prepare: paths sorted and unique" "$(printf '%s\n' "$paths" | LC_ALL=C sort -u)" "$paths"
for p in install.sh open-ui.sh lib/release-keys/grantkee.asc lib/release-keys/README update-scripts.sh lib/common.sh ui/server.py observability/config.alloy; do
    check_has "prepare: lists $p" "$p" "$paths"
done
bad=""
while IFS= read -r line; do
    p="$(printf '%s\n' "$line" | awk '{print $3}')"
    [[ "$(printf '%s\n' "$line" | awk '{print $2}')" == "$(_h "$W/$p")" ]] || bad="$bad $p"
done < <(grep '^sha256  ' "$W/MANIFEST")
check "prepare: every hash matches the file" "" "$bad"
check "prepare: no signature yet" "absent" "$([[ -e "$W/MANIFEST.asc" ]] && echo present || echo absent)"

# --- check -------------------------------------------------------------------------
tool --check
check_rc "check unsigned: passes with a warning" 0 "$RC"
check_has "check unsigned: warns" "WARN no MANIFEST.asc yet (unsigned release candidate)" "$OUT"
tool --check --tag scripts-v2.0.0
check_rc "check --tag unsigned: fails" 1 "$RC"
tool --check --require-sig
check_rc "check --require-sig unsigned: fails" 1 "$RC"
check_has "check --require-sig unsigned: says why" "FAIL no MANIFEST.asc" "$OUT"
sign_file "$W/MANIFEST" key1
tool --check --tag scripts-v2.0.0
check_rc "check --tag signed: passes" 0 "$RC"
check_has "check --tag signed: names the key" "MANIFEST.asc verifies: signed by ${FPR1} (1 release key(s) needed)." "$OUT"
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
cp "$W/MANIFEST.asc" "$T/MANIFEST.asc.keep"
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
reheader date=2026-10-15 "expires =2027-01-13"
tool --check
check_rc "check, a blank before =: fails" 1 "$RC"
check_has "check, a blank before =: the line is not a known header" "-expires =2027-01-13" "$OUT"
reheader date=2026-10-15 expires=2026-10-15
tool --check
check_rc "check, expires not after date: fails" 1 "$RC"
check_has "check, expires not after date: says why" "FAIL MANIFEST expires=2026-10-15 is not after date=2026-10-15" "$OUT"
reheader date=2026-10-14 expires=2027-01-13
tool --check
check_rc "check, RELEASE dated otherwise: fails" 1 "$RC"
check_has "check, RELEASE dated otherwise: says why" "FAIL RELEASE is dated 2026-10-15, MANIFEST date=2026-10-14" "$OUT"
cp "$T/MANIFEST.keep" "$W/MANIFEST"
cp "$T/MANIFEST.asc.keep" "$W/MANIFEST.asc"
cp "$T/RELEASE.keep" "$W/RELEASE"
cp "$W/setup-node.sh" "$T/setup-node.sh.keep"
printf '# edited after signing\n' >> "$W/setup-node.sh"
tool --check
check_rc "check after an edit: fails" 1 "$RC"
cat "$T/setup-node.sh.keep" > "$W/setup-node.sh"
sed 's/^min_updater=.*/min_updater=1.0.0/' "$T/MANIFEST.keep" > "$W/MANIFEST"
tool --check --require-sig
check_rc "check, MANIFEST changed after signing: fails" 1 "$RC"
check_has "check, MANIFEST changed after signing: BADSIG" "FAIL MANIFEST.asc does not verify against lib/release-keys: the signature by key ${FPR1:24} does not match MANIFEST: one of the two was changed" "$OUT"
cp "$T/MANIFEST.keep" "$W/MANIFEST"
newkey key2 >/dev/null
sign_file "$W/MANIFEST" key2
tool --check
check_rc "check with a foreign signature: fails" 1 "$RC"
check_has "check with a foreign signature: says why" "FAIL MANIFEST.asc does not verify against lib/release-keys: no release key in lib/release-keys made a good signature" "$OUT"
sign_file "$W/MANIFEST" key1 key2
tool --check --require-sig
check_rc "check, a release key and a foreign key: passes" 0 "$RC"
check_has "check, a release key and a foreign key: warns about the other" "a signature by key $(fpr_of key2 | cut -c25-40), which is not a release key, was not checked" "$OUT"
sign_file "$W/MANIFEST" key1
sign_file_bad "$W/MANIFEST" key1
tool --check --require-sig
check_rc "check, a bad signature beside a good one: fails" 1 "$RC"
check_has "check, a bad signature beside a good one: BADSIG" "FAIL MANIFEST.asc does not verify against lib/release-keys: the signature by key ${FPR1:24} does not match MANIFEST: one of the two was changed" "$OUT"
sign_file "$W/MANIFEST" key2
sign_file_bad "$W/MANIFEST" key2
cat "$W/MANIFEST.asc" > "$T/foreign.asc"
sign_file "$W/MANIFEST" key1
cat "$T/foreign.asc" >> "$W/MANIFEST.asc"
tool --check --require-sig
check_rc "check, a good release signature and foreign ones that cannot be checked: passes" 0 "$RC"
sign_file "$W/MANIFEST" key1
cp "$W/install.sh" "$T/install.keep"
awk '/^TN_RELEASE_KEYS$/ && !done { print "# extra"; done = 1 } { print }' "$T/install.keep" > "$W/install.sh"
tool --check
check_rc "check, embedded keys edited: fails" 1 "$RC"
check_has "check, embedded keys edited: says why" "FAIL the release keys embedded in install.sh differ from lib/release-keys/*.asc" "$OUT"
cat "$T/install.keep" > "$W/install.sh"
cp "$W/lib/release-keys/grantkee.asc" "$T/key1.keep"
awk '{ printf "%s\r\n", $0 }' "$T/key1.keep" > "$W/lib/release-keys/grantkee.asc"
tool --check --require-sig --tag scripts-v2.0.0
check_rc "check, a key file with CR line endings: fails" 1 "$RC"
check_has "check, a key file with CR line endings: says why" "release-scripts.sh: lib/release-keys/grantkee.asc has CR line endings: write it with LF line endings (as gpg --armor --export does)" "$OUT"
cp "$T/key1.keep" "$W/lib/release-keys/grantkee.asc"
commit_all "release: scripts-v2.0.0"

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
check "next release: old signature removed" "absent" "$([[ -e "$W/MANIFEST.asc" ]] && echo present || echo absent)"

finish
