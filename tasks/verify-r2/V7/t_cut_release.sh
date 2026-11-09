#!/usr/bin/env bash
# =============================================================================
# tasks/verify-r2/V7/t_cut_release.sh -- V7 SIG item 6: tools/cut-release.sh
# against a bare origin on disk, with real git and real gpg (throwaway keys in
# a temporary GNUPGHOME) behind logging wrappers, and stubs for gh, curl and
# gpg --card-status. HOME is a temp dir, so no global git config is read or
# written; the run then inspects every git config file it could have touched.
#
#   bash tasks/verify-r2/V7/t_cut_release.sh     (host: git, gpg, gpgv)
# bash 3.2 safe.
# =============================================================================

set -u
# shellcheck source=tasks/verify-r2/V7/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
command -v gpg >/dev/null 2>&1 && command -v gpgv >/dev/null 2>&1 || { echo "needs gpg and gpgv"; exit 2; }

export HOME="${V7_TMP}/home" GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=v7 GIT_AUTHOR_EMAIL=v7@example.invalid GIT_COMMITTER_NAME=v7 GIT_COMMITTER_EMAIL=v7@example.invalid
mkdir -p "$HOME"
export TN_CUT_POLL_SECONDS=0 TN_CUT_POLL_TRIES=3
TAG="$V7_TAG"
BR="release/${TAG}"
BIN="${V7_TMP}/bin"
LOG="${V7_TMP}/calls.log"
export V7_LOG="$LOG" V7_STATE="${V7_TMP}/gh-state"
mkdir -p "$BIN" "$V7_STATE"
v7_keys

# --- wrappers and stubs -------------------------------------------------------
cat > "$BIN/git" <<EOF
#!/usr/bin/env bash
echo "git \$*" >> "\$V7_LOG"
exec "$V7_REAL_GIT" "\$@"
EOF
cat > "$BIN/gpgv" <<EOF
#!/usr/bin/env bash
echo "gpgv \$*" >> "\$V7_LOG"
exec "$(command -v gpgv)" "\$@"
EOF
cat > "$BIN/gpg" <<EOF
#!/usr/bin/env bash
echo "gpg \$*" >> "\$V7_LOG"
case " \$* " in
    *" --card-status "*) [ "\${FAKE_NO_CARD:-}" != 1 ] || exit 2; echo "Reader: stub card"; exit 0 ;;
esac
if [ "\${V7_KILL_AFTER_SIGN:-}" = 1 ] && [ "\$1" = --armor ] && [ "\$2" = --detach-sign ]; then
    "$V7_REAL_GPG" --batch --pinentry-mode loopback --passphrase '' "\$@"
    echo "KILL after sign" >> "\$V7_LOG"
    kill -TERM "\$PPID"
    exit 0
fi
exec "$V7_REAL_GPG" --batch --pinentry-mode loopback --passphrase '' "\$@"
EOF
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" >> "$V7_LOG"
case "$1 $2" in
    "pr list") [ ! -f "$V7_STATE/pr" ] || cat "$V7_STATE/pr" ;;
    "pr create")
        while [ $# -gt 0 ]; do [ "$1" != --body-file ] || cp "$2" "$V7_STATE/body"; shift; done
        echo "https://github.invalid/pr/1" > "$V7_STATE/pr"; cat "$V7_STATE/pr" ;;
    "run list")
        wf=""; while [ $# -gt 0 ]; do [ "$1" != --workflow ] || wf="$2"; shift; done
        n="$(cat "$V7_STATE/n-$wf" 2>/dev/null || echo 0)"; n=$((n + 1)); echo "$n" > "$V7_STATE/n-$wf"
        case "${V7_GH_MODE:-success}" in
            success) echo "completed success https://github.invalid/run/$wf" ;;
            failure) echo "completed failure https://github.invalid/run/$wf" ;;
            running) if [ "$n" -le 2 ]; then echo "in_progress  https://github.invalid/run/$wf"; else echo "completed success https://github.invalid/run/$wf"; fi ;;
        esac ;;
esac
EOF
cat > "$BIN/curl" <<'EOF'
#!/usr/bin/env bash
echo "curl $*" >> "$V7_LOG"
printf '#!/usr/bin/env bash\nreadonly TN_SCRIPTS_TAG="%s"   # written by tools/release-scripts.sh\n' "${V7_SERVED_TAG:-}"
EOF
chmod +x "$BIN"/*
export PATH="$BIN:$PATH"

# --- the seed tree: the worktree's tree with the valid key as the one release key
SEED="${V7_TMP}/seed"
mkdir -p "$SEED"
"$V7_REAL_GIT" -C "$V7_WT" archive HEAD | tar -xf - -C "$SEED"
cp "${V7_TMP}/keys/valid.asc" "$SEED/lib/release-keys/grantkee.asc"
(cd "$SEED" && bash tools/gen-checksums.sh >/dev/null)
"$V7_REAL_GIT" -C "$SEED" init -q -b main
"$V7_REAL_GIT" -C "$SEED" add -A
"$V7_REAL_GIT" -C "$SEED" commit -q -m "seed"

# fresh NAME -- a bare origin O and a clone W of it, new for each scenario.
fresh() {
    O="${V7_TMP}/$1.origin.git"
    W="${V7_TMP}/$1.work"
    "$V7_REAL_GIT" init -q --bare "$O"
    "$V7_REAL_GIT" -C "$O" symbolic-ref HEAD refs/heads/main
    "$V7_REAL_GIT" -C "$SEED" push -q "$O" main
    "$V7_REAL_GIT" clone -q "$O" "$W"
    rm -f "$V7_STATE"/*
    : > "$LOG"
}
cr() {
    RC=0
    OUT="$(cd "$W" && bash tools/cut-release.sh "$@" 2>&1)" || RC=$?
}
# first LINE-PATTERN -- the line number of the first log line matching it.
first() { grep -n -E -m1 -- "$1" "$LOG" | cut -d: -f1; }

echo "== refusals"
fresh dirty
printf 'x\n' > "$W/untracked.txt"
cr prep "$TAG" --serial 1 --yes
chk "prep on a dirty tree: rc 1" 1 "$RC"
chk_has "prep on a dirty tree: message" "the tree has uncommitted changes" "$OUT"
chk "prep on a dirty tree: no branch made, still on main" "main|" "$("$V7_REAL_GIT" -C "$W" rev-parse --abbrev-ref HEAD)|$("$V7_REAL_GIT" -C "$W" branch --list "$BR")"
rm -f "$W/untracked.txt"
cr prep "$TAG" --serial 1 --key "$(v7_fpr foreign)" --yes
chk "prep with a key not in lib/release-keys: rc 1" 1 "$RC"
chk_has "prep with a key not in lib/release-keys: message" "is not a primary key of lib/release-keys/*.asc" "$OUT"
chk "prep with a key not in lib/release-keys: nothing prepared or signed" "no no" "$([[ -f "$W/MANIFEST" ]] && echo yes || echo no) $(grep -q -- '--detach-sign' "$LOG" && echo yes || echo no)"
printf '   after the key refusal the clone is on: %s\n' "$("$V7_REAL_GIT" -C "$W" rev-parse --abbrev-ref HEAD)"
fresh signingkey
RC=0; OUT="$(cd "$W" && GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=user.signingkey GIT_CONFIG_VALUE_0="$(v7_fpr foreign)!" bash tools/cut-release.sh prep "$TAG" --serial 1 --yes 2>&1)" || RC=$?
chk "prep with user.signingkey naming a foreign key: rc 1" 1 "$RC"
chk_has "prep with user.signingkey naming a foreign key: message" "is not a primary key" "$OUT"

echo "== prep --yes, step order"
fresh happy
cr prep "$TAG" --serial 1 --yes
chk "prep --yes: rc 0" 0 "$RC"
p="$(first '^git ls-files --error-unmatch')"
s="$(first "^gpg --armor --detach-sign --local-user $(v7_fpr valid)! --output MANIFEST.asc MANIFEST$")"
c="$(awk -v s="${s:-0}" 'NR > s && /^gpgv / { print NR; exit }' "$LOG")"
m="$(first "^git commit -S$(v7_fpr valid)! -F ")"
u="$(first "^git push -u origin ${BR}$")"
r="$(first "^gh pr create --base main --head ${BR} --title release: ${TAG} --body-file ")"
printf '   log lines: prepare %s, sign %s, check %s, commit %s, push %s, pr %s\n' "$p" "$s" "$c" "$m" "$u" "$r"
order=no
if [[ -n "$p" && -n "$s" && -n "$c" && -n "$m" && -n "$u" && -n "$r" ]] && (( p < s && s < c && c < m && m < u && u < r )); then order=yes; fi
chk "prep: prepare < sign < check < commit < push < pr" yes "$order"
chk "prep: card checked through gpg --card-status" 1 "$(grep -c -- '^gpg --card-status$' "$LOG")"
chk "prep: steps 1-9 each have a header" 9 "$(printf '%s\n' "$OUT" | sed -n 's/^\[\([1-9]\)\/9\].*/\1/p' | LC_ALL=C sort -u | wc -l | tr -d ' ')"
chk "prep: every header that runs a command prints it (\$ line next)" 0 "$(printf '%s\n' "$OUT" | awk '/^\[[1-9]\/9\]/ { h = $0; getline; if ($0 !~ /^   \$ / && $0 !~ /^   already done/ && h !~ /^\[5\/9\] sign on the machine/) bad++ } END { print bad + 0 }')"
chk "prep: origin has the release commit" "release: ${TAG}" "$("$V7_REAL_GIT" -C "$O" log -1 --format=%s "$BR")"
chk "prep: the commit is signed by the valid key" yes "$(cd "$W" && "$V7_REAL_GIT" verify-commit --raw "$BR" 2>&1 | grep -q "VALIDSIG.* $(v7_fpr valid)\$" && echo yes || echo no)"
chk "prep: the commit holds MANIFEST, MANIFEST.asc, RELEASE, install.sh" "MANIFEST MANIFEST.asc RELEASE install.sh" "$("$V7_REAL_GIT" -C "$O" diff-tree --no-commit-id --name-only -r "$BR" | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')"
body="$(cat "$V7_STATE/body" 2>/dev/null)"
chk_has "prep: PR body names the serial" "serial 1" "$body"
chk_has "prep: PR body names the fingerprint" "$(v7_fpr valid)" "$body"
chk_has "prep: PR body names the tag" "$TAG" "$body"
: > "$LOG"
cr prep "$TAG" --serial 1 --yes
chk "prep again: rc 0" 0 "$RC"
chk "prep again: steps 2,4,5,7,8,9 already done" 6 "$(printf '%s\n' "$OUT" | grep -c 'already done')"
chk "prep again: no new signature, commit, push or PR" "0 0 0 0" "$(grep -c -- '--detach-sign' "$LOG") $(grep -c '^git commit' "$LOG") $(grep -c '^git push' "$LOG") $(grep -c '^gh pr create' "$LOG")"

echo "== resumability: killed right after sign"
fresh kill
RC=0; OUT="$(cd "$W" && V7_KILL_AFTER_SIGN=1 bash tools/cut-release.sh prep "$TAG" --serial 1 --yes 2>&1)" || RC=$?
chk "kill after sign: the run stopped (rc 143)" 143 "$RC"
chk "kill after sign: MANIFEST.asc is there, no commit yet" "yes 0" "$([[ -s "$W/MANIFEST.asc" ]] && echo yes || echo no) $(grep -c '^git commit' "$LOG")"
: > "$LOG"
cr prep "$TAG" --serial 1 --yes
chk "rerun after the kill: rc 0" 0 "$RC"
chk_has "rerun after the kill: step 4 already done" "already done: MANIFEST names ${TAG}" "$OUT"
chk_has "rerun after the kill: step 5 already done" "already done: MANIFEST.asc verifies" "$OUT"
chk "rerun after the kill: no second signature; check, commit, push, pr ran" "0 1 1 1" "$(grep -c -- '--detach-sign' "$LOG") $(grep -c '^git commit' "$LOG") $(grep -c '^git push -u' "$LOG") $(grep -c '^gh pr create' "$LOG")"
chk_has "rerun after the kill: step 6 check ran" "[6/9] check the release" "$OUT"

echo "== q at step 6, then carry on"
fresh quit
RC=0; OUT="$(cd "$W" && printf '\n\n\n\n\nq\n' | bash tools/cut-release.sh prep "$TAG" --serial 1 2>&1)" || RC=$?
chk "q at step 6: rc 0 and the stop message" "0 yes" "$RC $([[ "$OUT" == *"Stopped. Run the same command again"* ]] && echo yes || echo no)"
chk "q at step 6: signed, not committed" "yes 0" "$([[ -s "$W/MANIFEST.asc" ]] && echo yes || echo no) $(grep -c '^git commit' "$LOG")"

echo "== --sig-from"
fresh sigfrom
(cd "$W" && "$V7_REAL_GIT" switch -q -c scratch && bash tools/release-scripts.sh --serial 1 "$TAG" >/dev/null 2>&1)
: > "${V7_TMP}/external.asc"; v7_sign "${V7_TMP}/external.asc" valid "$W/MANIFEST"
(cd "$W" && "$V7_REAL_GIT" checkout -q -- . && rm -f MANIFEST RELEASE MANIFEST.asc && "$V7_REAL_GIT" switch -q main && "$V7_REAL_GIT" branch -q -D scratch)
: > "$LOG"
cr prep "$TAG" --serial 1 --sig-from "${V7_TMP}/external.asc" --yes
chk "--sig-from: rc 0" 0 "$RC"
chk_has "--sig-from: warns the card is not checked" "WARN the card is not checked: the signature comes from" "$OUT"
chk "--sig-from: no card check, no signing by the tool" "0 0" "$(grep -c -- '--card-status' "$LOG") $(grep -c -- '--detach-sign' "$LOG")"
chk "--sig-from: the committed MANIFEST.asc is the external file" "$(v7_sha "${V7_TMP}/external.asc")" "$("$V7_REAL_GIT" -C "$O" show "$BR:MANIFEST.asc" | v7_sha /dev/stdin)"
fresh sigfrombad
: > "${V7_TMP}/bad-external.asc"; v7_sign "${V7_TMP}/bad-external.asc" foreign "$SEED/README.md"
cr prep "$TAG" --serial 1 --sig-from "${V7_TMP}/bad-external.asc" --yes
chk "--sig-from with a signature that does not verify: rc 1 at step 6" "1 yes" "$RC $([[ "$OUT" == *"step 6 (check the release) failed"* ]] && echo yes || echo no)"
chk "--sig-from with a bad signature: nothing committed or pushed" "0 0" "$(grep -c '^git commit' "$LOG") $(grep -c '^git push' "$LOG")"

echo "== no card: waits for MANIFEST.asc"
fresh nocard
( cd "$W" && FAKE_NO_CARD=1 TN_CUT_POLL_SECONDS=1 bash tools/cut-release.sh prep "$TAG" --serial 1 --yes > "${V7_TMP}/nocard.out" 2>&1; echo "$?" > "${V7_TMP}/nocard.rc" ) &
bg=$!
i=0
while [[ ! -f "$W/MANIFEST" || "$(grep -c '^readonly TN_SCRIPTS_TAG="'"$TAG"'"' "$W/install.sh" 2>/dev/null)" != 1 ]] && [[ $i -lt 60 ]]; do sleep 1; i=$((i + 1)); done
sleep 2
v7_sign "${V7_TMP}/nocard.asc" valid "$W/MANIFEST"
cp "${V7_TMP}/nocard.asc" "$W/MANIFEST.asc"
wait "$bg"
chk "no card: carried on once MANIFEST.asc appeared, rc 0" 0 "$(cat "${V7_TMP}/nocard.rc")"
chk_has "no card: printed the signing command to run elsewhere" "gpg --armor --detach-sign --local-user $(v7_fpr valid)! --output MANIFEST.asc MANIFEST" "$(cat "${V7_TMP}/nocard.out")"
chk "no card: the tool did not sign" 0 "$(grep -c -- '--detach-sign' "$LOG")"

echo "== tag"
W_HAPPY="${V7_TMP}/happy.work"
O_HAPPY="${V7_TMP}/happy.origin.git"
W="$W_HAPPY"; O="$O_HAPPY"; : > "$LOG"
cr tag "$TAG" --yes
chk "tag before the merge: rc 1" 1 "$RC"
chk_has "tag before the merge: message" "origin/main does not carry release ${TAG}" "$OUT"
chk "tag before the merge: no tag here or on origin" "|" "$("$V7_REAL_GIT" -C "$W" tag -l "$TAG")|$("$V7_REAL_GIT" -C "$O" tag -l "$TAG")"
"$V7_REAL_GIT" -C "$O" update-ref refs/heads/main "$("$V7_REAL_GIT" -C "$O" rev-parse "$BR")"
# origin/main with a MANIFEST.asc other than the branch's
"$V7_REAL_GIT" -C "$W" fetch -q origin
"$V7_REAL_GIT" -C "$W" switch -q -c other origin/main
: > "$W/MANIFEST.asc"; v7_sign "$W/MANIFEST.asc" valid "$W/MANIFEST"; v7_sign "$W/MANIFEST.asc" valid "$W/MANIFEST"
"$V7_REAL_GIT" -C "$W" commit -q -am "re-sign"
"$V7_REAL_GIT" -C "$W" push -q origin other:main
"$V7_REAL_GIT" -C "$W" switch -q "$BR"
cr tag "$TAG" --yes
chk "tag when origin/main's MANIFEST.asc is not the branch's: rc 1" 1 "$RC"
chk_has "tag when MANIFEST.asc differs: message" "the MANIFEST.asc on origin/main is not the one on" "$OUT"
"$V7_REAL_GIT" -C "$O" update-ref refs/heads/main "$("$V7_REAL_GIT" -C "$O" rev-parse "$BR")"
: > "$LOG"
RC=0; OUT="$(cd "$W" && V7_SERVED_TAG="$TAG" V7_GH_MODE=running bash tools/cut-release.sh tag "$TAG" --yes 2>&1)" || RC=$?
chk "tag after the merge (CI runs still running at first): rc 0" 0 "$RC"
chk "tag: origin has the tag on main" "$("$V7_REAL_GIT" -C "$O" rev-parse main)" "$("$V7_REAL_GIT" -C "$O" rev-parse "refs/tags/${TAG}^{commit}" 2>/dev/null)"
chk "tag: annotated tag signed by the valid key" yes "$(cd "$W" && "$V7_REAL_GIT" verify-tag --raw "$TAG" 2>&1 | grep -q "VALIDSIG.* $(v7_fpr valid)\$" && echo yes || echo no)"
chk "tag: the check ran in a temporary worktree, then it was removed" "1 1" "$(grep -c '^git worktree add --detach' "$LOG") $(grep -c '^git worktree remove --force' "$LOG")"
chk_has "tag: prints the CI conclusions" "ci.yml: success https://github.invalid/run/ci.yml" "$OUT"
chk_has "tag: the installer serves the tag" "https://install.telcoin.network serves ${TAG}" "$OUT"
chk "tag: polled gh run list until completed" yes "$([[ "$(cat "$V7_STATE/n-ci.yml")" -ge 3 ]] && echo yes || echo no)"
: > "$LOG"
cr tag "$TAG" --yes
chk "tag again with the installer not serving the tag: rc 1" 1 "$RC"
chk_has "tag again: tag already done" "already done: ${TAG} names origin/main" "$OUT"
RC=0; OUT="$(cd "$W" && V7_SERVED_TAG="$TAG" V7_GH_MODE=failure bash tools/cut-release.sh tag "$TAG" --yes 2>&1)" || RC=$?
chk "tag with a failed CI run: rc 1" 1 "$RC"
chk_has "tag with a failed CI run: prints the conclusion" "ci.yml: failure" "$OUT"

echo "== status"
RC=0; OUT="$(cd "$W" && V7_GH_MODE=success bash tools/cut-release.sh status 2>&1)" || RC=$?
chk "status: rc 0" 0 "$RC"
chk_has "status: the signature verifies" "signature: MANIFEST.asc verifies" "$OUT"
chk_has "status: the tag signature" "tag signature: good" "$OUT"
chk_has "status: the MANIFEST serial" "serial=1" "$OUT"

echo "== git configuration after every run"
cfg=""
for d in "${V7_TMP}"/*.work; do
    cfg="${cfg}$("$V7_REAL_GIT" config --file "$d/.git/config" --list 2>/dev/null | grep -iE '^(commit\.gpgsign|tag\.gpgsign|user\.signingkey|gpg\.)' || true)"
done
for d in "${V7_TMP}"/*.origin.git; do
    cfg="${cfg}$("$V7_REAL_GIT" config --file "$d/config" --list 2>/dev/null | grep -iE '^(commit\.gpgsign|tag\.gpgsign|user\.signingkey|gpg\.)' || true)"
done
chk "no repo config names commit.gpgsign, tag.gpgsign, user.signingkey or gpg.*" "" "$cfg"
chk "no global git config was written" "no" "$([[ -e "$HOME/.gitconfig" || -e "$HOME/.config/git/config" ]] && echo yes || echo no)"
chk "cut-release.sh never runs git config other than --get" "" "$(grep -E '^git config' "$LOG" | grep -v -- '--get' || true)"
chk "cut-release.sh source: git config only with --get" "" "$(grep -n 'config' "$V7_WT/tools/cut-release.sh" | grep -E '_git config|git config' | grep -v -- '--get' | grep -v '^[0-9]*:#' || true)"

v7_finish
