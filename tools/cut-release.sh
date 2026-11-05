#!/usr/bin/env bash
# =============================================================================
# tools/cut-release.sh -- cut a signed script release, one step at a time
#
#   bash tools/cut-release.sh prep TAG [--serial N] [--key FPR] [--sig-from FILE] [--yes]
#   bash tools/cut-release.sh tag TAG [--key FPR] [--yes]
#   bash tools/cut-release.sh status
#
# prep opens the release pull request for TAG (scripts-vX.Y.Z):
#   1 fetch    git fetch origin
#   2 branch   create release/TAG from origin/main, or switch to it; a tree with
#              uncommitted changes is refused (untracked files count, as for
#              tools/release-scripts.sh). Before the branch is made or entered,
#              the signing key must be a primary key of a lib/release-keys/*.asc
#              file of the branch to be (origin/main for a new one): --key FPR,
#              else git config user.signingkey, else the one key there
#   3 key      gpg --card-status checks that the card answers, here or through a
#              forwarded gpg-agent (skipped with --sig-from)
#   4 prepare  bash tools/release-scripts.sh [--serial N] TAG
#   5 sign     gpg --armor --detach-sign --local-user FPR! --output MANIFEST.asc MANIFEST;
#              with --sig-from FILE the signature is copied from FILE; when no card
#              answers, the run waits until MANIFEST.asc appears (sign MANIFEST on
#              the machine with the key and copy the file here)
#   6 check    bash tools/release-scripts.sh --check --require-sig --tag TAG
#   7 commit   git add MANIFEST MANIFEST.asc RELEASE install.sh &&
#              git commit -S<FPR>! with the message "release: TAG" (one prompt)
#   8 push     git push -u origin release/TAG
#   9 pr       gh pr create --base main --head release/TAG --title "release: TAG"
#
# tag TAG, once the pull request has merged:
#   1 fetch    git fetch origin
#   2 main     origin/main carries the release: its MANIFEST names TAG, its
#              MANIFEST and MANIFEST.asc are the release branch's (when that
#              branch is still here), and the check with --require-sig --tag TAG
#              passes in a clean temporary worktree of origin/main
#   3 tag      git tag -s --local-user=FPR! -m TAG TAG origin/main
#   4 verify   git verify-tag --raw TAG must report a good signature (GOODSIG
#              then VALIDSIG) whose primary fingerprint is a key of
#              lib/release-keys/*.asc on origin/main, and no bad, expired or
#              revoked one; an existing tag passes only this way too
#   5 push     git push origin TAG
#   6 ci       wait for the ci.yml and publish-installer.yml runs of the tag and
#              print their conclusions (gh run list)
#   7 served   curl -fsSL https://install.telcoin.network must name TAG in its
#              readonly TN_SCRIPTS_TAG= line
#
# status prints what exists for the newest release/* branch and scripts-v* tag:
# the branch and its commit, the MANIFEST serial, whether MANIFEST.asc verifies,
# which release key signed the tag (a key of lib/release-keys at the tag) and
# the CI runs of the tag.
#
# Every step prints its command and asks "[Enter] run / s skip / q quit"; --yes
# runs every step without asking. A step whose result is already there (the
# branch, a prepared or verifying MANIFEST, the release commit, the pushed
# branch, the open pull request, the tag, the pushed tag) is reported and
# passed over, so running the same command again carries on where a run
# stopped. The tool never changes git configuration: the commit and the tag
# name the key with -S and --local-user. TN_CUT_POLL_SECONDS (default 30) and
# TN_CUT_POLL_TRIES (default 120) pace the waits.
#
# Exit status: 0 done, or stopped with q; 1 a step refused or failed; 2 usage error.
#
# Maintainer tooling: update-scripts.sh does not track tools/ and this file has
# no .sha256 sidecar. bash 3.2 safe.
# =============================================================================

set -euo pipefail

readonly TAG_RE='^scripts-v[0-9]+\.[0-9]+\.[0-9]+$'
readonly KEYS_DIR="lib/release-keys"
readonly SIG_FILE="MANIFEST.asc"
readonly INSTALLER_URL="https://install.telcoin.network"
readonly POLL_SECONDS="${TN_CUT_POLL_SECONDS:-30}"
readonly POLL_TRIES="${TN_CUT_POLL_TRIES:-120}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
YES=0
TMP=""
STEP_TOTAL=0
SHOW_AS=""
CARD=1
FPR=""
FPR_FILE=""

die() {
    printf 'cut-release.sh: %s\n' "$*" >&2
    exit 1
}

usage() {
    echo "Usage:"
    sed -n '5,7p' "${BASH_SOURCE[0]}" | sed 's/^#//'
}

cleanup() {
    if [[ -n "$TMP" ]]; then
        rm -rf "$TMP"
    fi
}

# The tools this script drives, one wrapper each, so that a test can put
# stand-ins for them on PATH.
_git() { git "$@"; }
_gh() { gh "$@"; }
_gpg() { gpg "$@"; }
_curl() { curl "$@"; }

# show CMD... -- CMD as one shell line, each wrapper named by its tool.
show() {
    local a out=""
    for a in "$@"; do
        case "$a" in
            _git|_gh|_gpg|_curl) a="${a#_}" ;;
        esac
        out="${out:+${out} }$(printf '%q' "$a")"
    done
    printf '%s\n' "$out"
}

# ask -- rc 0 to run the step, 1 to skip it; q stops the run. --yes runs it.
ask() {
    local ans=""
    if [[ $YES -eq 1 ]]; then
        return 0
    fi
    if ! read -r -p "   [Enter] run / s skip / q quit: " ans; then
        ans=q
        echo ""
    fi
    case "$ans" in
        s|S)
            echo "   skipped"
            return 1
            ;;
        q|Q)
            echo "Stopped. Run the same command again to carry on from here."
            exit 0
            ;;
    esac
    return 0
}

# step N DESC CMD... -- print the step and its command (SHOW_AS instead, when
# set), ask, run it. rc 1 when skipped; a command that fails ends the run.
step() {
    local n="$1" desc="$2" shown
    shift 2
    shown="${SHOW_AS:-$(show "$@")}"
    SHOW_AS=""
    printf '\n[%s/%s] %s\n   $ %s\n' "$n" "$STEP_TOTAL" "$desc" "$shown"
    ask || return 1
    if ! "$@"; then
        die "step ${n} (${desc}) failed: ${shown}"
    fi
}

# done_step N DESC WHAT -- a step whose result is already there.
done_step() {
    printf '\n[%s/%s] %s\n   already done: %s\n' "$1" "$STEP_TOTAL" "$2" "$3"
}

# key_fprs FILE -- the primary fingerprints of the keys in FILE, one per line.
# gpg reads the file in a throwaway home: nothing is imported.
key_fprs() {
    local home
    home="$(mktemp -d "${TMP}/gpg.XXXXXX")"
    GNUPGHOME="$home" _gpg --batch --no-tty --quiet --with-colons --import-options show-only \
        --import < "$1" 2>/dev/null \
        | awk -F: '$1 == "pub" { want = 1; next } $1 == "fpr" && want { print $10; want = 0 }' || true
    rm -rf "$home"
}

# release_key_list [REF] -- one line "<fingerprint> <file>" per primary key of
# every lib/release-keys/*.asc: in the working tree, or at the git REF.
release_key_list() {
    local ref="${1:-}" f p d
    if [[ -z "$ref" ]]; then
        for f in "$KEYS_DIR"/*.asc; do
            [[ -f "$f" ]] || continue
            for p in $(key_fprs "$f"); do
                printf '%s %s\n' "$p" "$f"
            done
        done
        return 0
    fi
    d="$(mktemp -d "${TMP}/keys.XXXXXX")"
    while IFS= read -r f; do
        case "$f" in
            "${KEYS_DIR}"/*.asc) ;;
            *) continue ;;
        esac
        _git show "${ref}:${f}" > "${d}/key.asc" 2>/dev/null || continue
        for p in $(key_fprs "${d}/key.asc"); do
            printf '%s %s\n' "$p" "$f"
        done
    done < <(_git ls-tree --name-only "$ref" "${KEYS_DIR}/" 2>/dev/null || true)
    rm -rf "$d"
}

# pick_key WANT [REF] -- set FPR and FPR_FILE to the release key to sign with:
# the primary key of a lib/release-keys/*.asc file (in the working tree, or at
# REF) that WANT names (a fingerprint, or a long key id of 16 or more hex
# digits, with or without a trailing !), or the one key there when WANT is
# empty.
pick_key() {
    local want="$1" ref="${2:-}" where p f n=0 first="" first_file=""
    want="${want%!}"
    want="${want#0x}"
    want="$(printf '%s' "$want" | tr 'abcdef' 'ABCDEF')"
    where="${KEYS_DIR}/*.asc${ref:+ on ${ref}}"
    FPR=""
    FPR_FILE=""
    while read -r p f; do
        [[ -n "$p" ]] || continue
        n=$((n + 1))
        if [[ -z "$first" ]]; then
            first="$p"
            first_file="$f"
        fi
        if [[ -n "$want" && ${#want} -ge 16 && "$p" == *"$want" ]]; then
            FPR="$p"
            FPR_FILE="$f"
        fi
    done < <(release_key_list "$ref")
    [[ $n -gt 0 ]] || die "gpg reads no primary key from ${where}"
    if [[ -z "$want" ]]; then
        [[ $n -eq 1 ]] || die "${where} holds ${n} keys: name the signing key with --key FPR"
        FPR="$first"
        FPR_FILE="$first_file"
    fi
    [[ -n "$FPR" ]] || die "the signing key ${want} is not a primary key of ${where}: sign with a listed key (--key FPR), or add its key file in a release first"
}

# tag_signed_by_release_key TAG REF -- rc 0 when git verify-tag --raw TAG
# reports a good signature (GOODSIG, then VALIDSIG) whose primary fingerprint
# (the last VALIDSIG field) is a key of lib/release-keys/*.asc at REF, and no
# BADSIG, EXPKEYSIG, REVKEYSIG, EXPSIG or ERRSIG; it prints which key signed.
# The verdict comes from the status lines, never from the exit status.
tag_signed_by_release_key() {
    local tag="$1" ref="$2" keys raw t kw rest fpr good=0 ok="" bad=""
    keys="$(release_key_list "$ref" | awk '{ print $1 }')"
    raw="$(_git verify-tag --raw "$tag" 2>&1 > /dev/null || true)"
    while read -r t kw rest; do
        [[ "$t" == "[GNUPG:]" ]] || continue
        case "$kw" in
            BADSIG|EXPKEYSIG|REVKEYSIG|EXPSIG|ERRSIG) bad="${bad:-$kw}" ;;
            GOODSIG) good=1 ;;
            VALIDSIG)
                fpr="${rest##* }"
                if [[ $good -eq 1 && "$fpr" =~ ^[0-9A-F]{40}$ ]] && printf '%s\n' "$keys" | grep -qxF -- "$fpr"; then
                    ok="$fpr"
                fi
                good=0
                ;;
        esac
    done <<< "$raw"
    if [[ -n "$bad" ]]; then
        printf '   the signature of %s is refused: gpg reports %s\n' "$tag" "$bad" >&2
        return 1
    fi
    if [[ -z "$ok" ]]; then
        printf '   %s carries no good signature by a key of %s/*.asc on %s\n' "$tag" "$KEYS_DIR" "$ref" >&2
        return 1
    fi
    printf '   %s is signed by release key %s\n' "$tag" "$ok"
}

# card_check -- set CARD to 1 when gpg reaches a card (here or through a
# forwarded agent), else 0 with a warning.
card_check() {
    if _gpg --card-status > /dev/null 2>&1; then
        CARD=1
        echo "   the card answers"
    else
        CARD=0
        echo "   WARN gpg cannot reach a card here: step 5 waits for ${SIG_FILE} to be copied in"
    fi
}

# only_release_files PORCELAIN -- rc 0 when every changed path is a file the
# prepare step writes.
only_release_files() {
    local line p
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        p="${line:3}"
        case "$p" in
            MANIFEST|MANIFEST.asc|RELEASE|install.sh) ;;
            *) return 1 ;;
        esac
    done <<< "$1"
    return 0
}

# manifest_value KEY -- KEY=... of MANIFEST in the tree, or "".
manifest_value() {
    awk -F= -v k="$1" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' MANIFEST 2>/dev/null || true
}

# check_in_worktree REF [TAG] -- run the release check with --require-sig (and
# --tag TAG) in a temporary worktree of REF; its rc.
check_in_worktree() {
    local ref="$1" wt="${TMP}/worktree" rc=0
    rm -rf "$wt"
    _git worktree add --detach "$wt" "$ref" > /dev/null 2>&1 || return 1
    if [[ -n "${2:-}" ]]; then
        (cd "$wt" && bash tools/release-scripts.sh --check --require-sig --tag "$2") || rc=$?
    else
        (cd "$wt" && bash tools/release-scripts.sh --check --require-sig) || rc=$?
    fi
    _git worktree remove --force "$wt" > /dev/null 2>&1 || true
    return "$rc"
}

# commit_release -- stage the release files and make the signed release commit.
commit_release() {
    _git add MANIFEST "$SIG_FILE" RELEASE install.sh && _git commit -S"${FPR}!" -F "${TMP}/commit-msg"
}

# wait_for_sig -- wait until MANIFEST.asc is in the tree.
wait_for_sig() {
    while [[ ! -s "$SIG_FILE" ]]; do
        sleep "$POLL_SECONDS"
    done
    echo "   ${SIG_FILE} is here"
}

prep() {
    local tag="$1" serial="$2" key="$3" sigfrom="$4" branch="release/$1" cur dirty url keyref=""
    local -a args
    STEP_TOTAL=9
    args=()
    if [[ -n "$serial" ]]; then
        args=(--serial "$serial")
    fi

    step 1 "fetch origin" _git fetch origin || true

    # The tree and the signing key are checked before the branch is made or
    # entered; the key against the key files of the branch to be.
    cur="$(_git rev-parse --abbrev-ref HEAD)"
    dirty="$(_git status --porcelain)"
    if [[ "$cur" == "$branch" ]]; then
        if [[ -n "$dirty" ]] && ! only_release_files "$dirty"; then
            die "the tree has changes outside MANIFEST, MANIFEST.asc, RELEASE and install.sh: commit or stash them first"
        fi
    else
        [[ -z "$dirty" ]] || die "the tree has uncommitted changes: commit or stash them first"
        if _git rev-parse -q --verify "refs/heads/${branch}" > /dev/null; then
            keyref="refs/heads/${branch}"
        elif _git rev-parse -q --verify "refs/remotes/origin/${branch}" > /dev/null; then
            keyref="refs/remotes/origin/${branch}"
        else
            keyref="origin/main"
        fi
    fi
    pick_key "${key:-$(_git config --get user.signingkey 2>/dev/null || true)}" "$keyref"

    if [[ "$cur" == "$branch" ]]; then
        done_step 2 "release branch" "on ${branch}"
    else
        if [[ "$keyref" != origin/main ]]; then
            step 2 "switch to the release branch" _git checkout "$branch" || true
        else
            step 2 "create the release branch from origin/main" _git checkout -b "$branch" origin/main || true
        fi
        [[ "$(_git rev-parse --abbrev-ref HEAD)" == "$branch" ]] \
            || die "not on ${branch}: run again and let step 2 create or switch to it"
    fi
    if [[ -n "$sigfrom" ]]; then
        printf '\n[3/%s] signing key %s (%s)\n   WARN the card is not checked: the signature comes from %s\n' \
            "$STEP_TOTAL" "$FPR" "$FPR_FILE" "$sigfrom"
    else
        SHOW_AS="gpg --card-status"
        step 3 "signing key ${FPR} (${FPR_FILE}): check that the card answers" card_check || true
    fi

    if [[ "$(manifest_value release)" == "$tag" ]]; then
        done_step 4 "prepare" "MANIFEST names ${tag}"
    else
        step 4 "prepare MANIFEST, RELEASE and install.sh" bash tools/release-scripts.sh ${args[@]+"${args[@]}"} "$tag" || true
    fi
    [[ "$(manifest_value release)" == "$tag" ]] || die "MANIFEST does not name ${tag}: run again and let step 4 prepare it"

    if [[ -f "$SIG_FILE" ]] && bash tools/release-scripts.sh --check --require-sig --tag "$tag" > /dev/null 2>&1; then
        done_step 5 "sign" "${SIG_FILE} verifies"
    elif [[ -n "$sigfrom" ]]; then
        step 5 "copy the signature" cp "$sigfrom" "$SIG_FILE" || true
    elif [[ -f "$SIG_FILE" ]]; then
        die "${SIG_FILE} is here but the release check fails (bash tools/release-scripts.sh --check --require-sig --tag ${tag} says why): remove it and run again"
    elif [[ $CARD -eq 1 ]]; then
        step 5 "sign MANIFEST with the release key (touch the key when it blinks)" \
            _gpg --armor --detach-sign --local-user "${FPR}!" --output "$SIG_FILE" MANIFEST || true
    else
        printf '\n[5/%s] sign on the machine with the release key, in a copy of %s with this MANIFEST:\n' "$STEP_TOTAL" "$branch"
        printf '     gpg --armor --detach-sign --local-user %s! --output %s MANIFEST\n' "$FPR" "$SIG_FILE"
        printf '   then copy %s into %s. Waiting for it (Ctrl-C stops; run again to carry on).\n' "$SIG_FILE" "$REPO_ROOT"
        wait_for_sig
    fi

    step 6 "check the release" bash tools/release-scripts.sh --check --require-sig --tag "$tag" || true

    if [[ "$(_git log -1 --format=%s)" == "release: ${tag}" && -z "$(_git status --porcelain -- MANIFEST "$SIG_FILE" RELEASE install.sh)" ]]; then
        done_step 7 "commit" "$(_git log -1 --format='%s (%h)')"
    else
        printf 'release: %s\n' "$tag" > "${TMP}/commit-msg"
        SHOW_AS="$(show _git add MANIFEST "$SIG_FILE" RELEASE install.sh) && $(show _git commit -S"${FPR}!" -F "${TMP}/commit-msg")"
        step 7 "commit the release files, signed with the release key" commit_release || true
    fi

    if [[ "$(_git rev-parse -q --verify "refs/remotes/origin/${branch}" 2>/dev/null || true)" == "$(_git rev-parse HEAD)" ]]; then
        done_step 8 "push" "origin/${branch} is $(_git rev-parse --short HEAD)"
    else
        step 8 "push the release branch" _git push -u origin "$branch" || true
    fi

    url="$(_gh pr list --head "$branch" --state open --json url --jq '.[0].url // empty' 2>/dev/null || true)"
    if [[ -n "$url" ]]; then
        done_step 9 "pull request" "$url"
    else
        {
            printf 'Script release %s: serial %s, %s files, released %s, expires %s.\n\n' "$tag" \
                "$(manifest_value serial)" "$(grep -c '^sha256  ' MANIFEST)" "$(manifest_value date)" "$(manifest_value expires)"
            printf '%s is signed by release key %s (%s); `bash tools/release-scripts.sh --check --require-sig --tag %s` passes on this branch.\n\n' \
                "$SIG_FILE" "$FPR" "$FPR_FILE" "$tag"
            printf 'After this merges, `bash tools/cut-release.sh tag %s` makes the signed tag %s on main, pushes it, waits for CI and the installer publish, and checks that %s serves it.\n' \
                "$tag" "$tag" "$INSTALLER_URL"
        } > "${TMP}/pr-body.md"
        step 9 "open the release pull request" _gh pr create --base main --head "$branch" \
            --title "release: ${tag}" --body-file "${TMP}/pr-body.md" || true
    fi

    printf '\nRelease %s is prepared on %s. Once its pull request has merged, run:\n  bash tools/cut-release.sh tag %s\n' "$tag" "$branch" "$tag"
}

# main_has_release TAG -- origin/main carries release TAG (see step 2 of tag).
main_has_release() {
    local tag="$1" branch="release/$1" ref="" c f rel
    rel="$(_git show origin/main:MANIFEST 2>/dev/null | awk -F= '$1 == "release" { print $2; exit }' || true)"
    if [[ "$rel" != "$tag" ]]; then
        printf '   origin/main does not carry release %s (its MANIFEST names %s): merge the release pull request first\n' \
            "$tag" "${rel:-no release}" >&2
        return 1
    fi
    for c in "refs/heads/${branch}" "refs/remotes/origin/${branch}"; do
        if _git rev-parse -q --verify "$c" > /dev/null; then
            ref="$c"
            break
        fi
    done
    if [[ -n "$ref" ]]; then
        for f in MANIFEST "$SIG_FILE"; do
            if [[ "$(_git rev-parse "origin/main:${f}" 2>/dev/null || true)" != "$(_git rev-parse "${ref}:${f}" 2>/dev/null || true)" ]]; then
                printf '   the %s on origin/main is not the one on %s\n' "$f" "${ref#refs/*/}" >&2
                return 1
            fi
        done
    fi
    check_in_worktree origin/main "$tag"
}

# wait_runs TAG -- wait for the ci.yml and publish-installer.yml runs of TAG to
# finish; rc 1 unless both succeeded.
wait_runs() {
    local tag="$1" wf line st concl i bad=0
    for wf in ci.yml publish-installer.yml; do
        i=0
        while :; do
            line="$(_gh run list --workflow "$wf" --branch "$tag" --limit 1 --json status,conclusion,url \
                --jq '.[0] | [.status, (.conclusion // ""), .url] | join(" ")' 2>/dev/null || true)"
            st="${line%% *}"
            if [[ "$st" == completed ]]; then
                break
            fi
            i=$((i + 1))
            if [[ $i -ge $POLL_TRIES ]]; then
                printf '   %s: no finished run of %s yet (%s); check later with: gh run list --workflow %s --branch %s\n' \
                    "$wf" "$tag" "${line:-none}" "$wf" "$tag"
                bad=1
                break
            fi
            sleep "$POLL_SECONDS"
        done
        if [[ "$st" == completed ]]; then
            concl="${line#completed }"
            printf '   %s: %s\n' "$wf" "$concl"
            [[ "${concl%% *}" == success ]] || bad=1
        fi
    done
    return "$bad"
}

# served_tag TAG -- the installer served at INSTALLER_URL names TAG.
served_tag() {
    local tag="$1" line="" i=0
    while :; do
        line="$(_curl --proto '=https' --tlsv1.2 -fsSL "$INSTALLER_URL" 2>/dev/null | grep -m1 '^readonly TN_SCRIPTS_TAG=' || true)"
        if [[ "$line" == *"\"${tag}\""* ]]; then
            printf '   %s serves %s\n' "$INSTALLER_URL" "$tag"
            return 0
        fi
        i=$((i + 1))
        if [[ $i -ge $POLL_TRIES ]]; then
            printf '   %s serves: %s\n' "$INSTALLER_URL" "${line:-no TN_SCRIPTS_TAG line}" >&2
            return 1
        fi
        sleep "$POLL_SECONDS"
    done
}

tag_release() {
    local tag="$1" key="$2" main_sha remote local_obj
    STEP_TOTAL=7

    step 1 "fetch origin" _git fetch origin || true

    SHOW_AS="git worktree add --detach <temp dir> origin/main; cd <temp dir>; bash tools/release-scripts.sh --check --require-sig --tag ${tag}"
    step 2 "origin/main carries release ${tag}" main_has_release "$tag" || true

    main_sha="$(_git rev-parse origin/main)"
    if _git rev-parse -q --verify "refs/tags/${tag}" > /dev/null; then
        [[ "$(_git rev-parse "${tag}^{commit}")" == "$main_sha" ]] \
            || die "tag ${tag} exists here and names $(_git rev-parse --short "${tag}^{commit}"), not origin/main $(_git rev-parse --short "$main_sha")"
        done_step 3 "tag" "${tag} names origin/main $(_git rev-parse --short "$main_sha")"
    else
        pick_key "${key:-$(_git config --get user.signingkey 2>/dev/null || true)}" origin/main
        step 3 "make the signed tag with release key ${FPR}" \
            _git tag -s --local-user="${FPR}!" -m "$tag" "$tag" origin/main || true
    fi

    SHOW_AS="git verify-tag --raw ${tag} (a good signature by a key of ${KEYS_DIR}/*.asc on origin/main)"
    step 4 "verify the tag signature" tag_signed_by_release_key "$tag" origin/main || true

    remote="$(_git ls-remote origin "refs/tags/${tag}" 2>/dev/null | awk 'NR == 1 { print $1 }' || true)"
    local_obj="$(_git rev-parse -q --verify "refs/tags/${tag}" 2>/dev/null || true)"
    if [[ -n "$remote" && "$remote" == "$local_obj" ]]; then
        done_step 5 "push" "origin has ${tag}"
    else
        step 5 "push the tag" _git push origin "$tag" || true
    fi

    SHOW_AS="gh run list --workflow ci.yml --branch ${tag}; gh run list --workflow publish-installer.yml --branch ${tag} (every ${POLL_SECONDS} s until both finish)"
    step 6 "wait for CI and the installer publish" wait_runs "$tag" || true

    SHOW_AS="curl -fsSL ${INSTALLER_URL} | grep -m1 '^readonly TN_SCRIPTS_TAG='"
    step 7 "the published installer names ${tag}" served_tag "$tag" || true

    printf '\nRelease %s is tagged, published and served.\n' "$tag"
}

status_report() {
    local br tag line wf
    br="$(_git for-each-ref --sort=-committerdate --format='%(refname:short)' refs/heads/release refs/remotes/origin/release \
        | awk 'NR == 1')"
    if [[ -z "$br" ]]; then
        echo "Release branch: none (no release/* branch here or on origin)"
    else
        echo "Release branch: ${br}"
        echo "  commit:    $(_git log -1 --format='%h %s' "$br")"
        echo "  MANIFEST:  $(_git show "${br}:MANIFEST" 2>/dev/null | awk -F= '$1 == "release" || $1 == "serial" { printf "%s ", $0 }')"
        if check_in_worktree "$br" > /dev/null 2>&1; then
            echo "  signature: ${SIG_FILE} verifies (release check passes)"
        else
            echo "  signature: the release check fails (bash tools/release-scripts.sh --check --require-sig on ${br} says why)"
        fi
    fi
    tag="$(_git tag -l 'scripts-v*' --sort=-v:refname | awk 'NR == 1')"
    if [[ -z "$tag" ]]; then
        echo "Release tag: none (no scripts-v* tag here; git fetch origin --tags to see origin's)"
        return 0
    fi
    echo "Release tag: ${tag} on $(_git rev-parse --short "${tag}^{commit}")"
    if line="$(tag_signed_by_release_key "$tag" "$tag" 2>/dev/null)"; then
        echo "  tag signature: ${line#   }"
    else
        echo "  tag signature: no good signature by a key of ${KEYS_DIR}/*.asc at ${tag} (git verify-tag --raw ${tag})"
    fi
    for wf in ci.yml publish-installer.yml; do
        line="$(_gh run list --workflow "$wf" --branch "$tag" --limit 1 --json status,conclusion,url \
            --jq '.[0] | [.status, (.conclusion // ""), .url] | join(" ")' 2>/dev/null || true)"
        echo "  ${wf}: ${line:-no run found}"
    done
}

main() {
    local cmd="${1:-}" tag="" serial="" key="" sigfrom=""
    case "$cmd" in
        prep|tag|status) shift ;;
        -h|--help) usage; exit 0 ;;
        "") usage >&2; exit 2 ;;
        *) printf 'cut-release.sh: unknown command: %s\n' "$cmd" >&2; usage >&2; exit 2 ;;
    esac
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --serial|--key|--sig-from)
                [[ $# -ge 2 ]] || { usage >&2; exit 2; }
                case "$1" in
                    --serial) serial="$2" ;;
                    --key) key="$2" ;;
                    --sig-from) sigfrom="$2" ;;
                esac
                shift
                ;;
            --yes|-y) YES=1 ;;
            -h|--help) usage; exit 0 ;;
            -*) printf 'cut-release.sh: unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
            *) [[ -z "$tag" ]] || { usage >&2; exit 2; }; tag="$1" ;;
        esac
        shift
    done
    if [[ "$cmd" == status ]]; then
        [[ -z "$tag$serial$key$sigfrom" ]] || { usage >&2; exit 2; }
    else
        [[ -n "$tag" ]] || { usage >&2; exit 2; }
        [[ "$tag" =~ $TAG_RE ]] || die "release tag must look like scripts-v1.2.3, got: ${tag}"
        if [[ "$cmd" == tag && -n "$serial$sigfrom" ]]; then
            usage >&2
            exit 2
        fi
    fi
    if [[ -n "$sigfrom" ]]; then
        [[ -f "$sigfrom" ]] || die "--sig-from ${sigfrom}: no such file"
        sigfrom="$(cd "$(dirname "$sigfrom")" && pwd)/${sigfrom##*/}"
    fi

    cd "$REPO_ROOT"
    _git rev-parse --is-inside-work-tree > /dev/null 2>&1 || die "not inside a git work tree"
    TMP="$(mktemp -d "${TMPDIR:-/tmp}/tn-cut-release.XXXXXX")" || die "could not create a temp directory"
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    case "$cmd" in
        prep) prep "$tag" "$serial" "$key" "$sigfrom" ;;
        tag) tag_release "$tag" "$key" ;;
        status) status_report ;;
    esac
}

main "$@"
