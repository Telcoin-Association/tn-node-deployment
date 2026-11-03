#!/usr/bin/env bash
# =============================================================================
# tools/release-scripts.sh -- prepare and check a signed script release
#
#   bash tools/release-scripts.sh [--serial N] [--min-updater X.Y.Z] [--date YYYY-MM-DD] [--expires DAYS] TAG
#   bash tools/release-scripts.sh --check [--tag TAG] [--require-sig] [--require-fresh]
#
# TAG is scripts-vX.Y.Z. A release is the commit that tag names. That commit
# carries MANIFEST and MANIFEST.sig at the repository root, and RELEASE on main
# names the tag. update-scripts.sh and install.sh install a release only when
# MANIFEST.sig verifies against lib/allowed_signers and every file matches its
# MANIFEST hash.
#
# Prepare mode needs a clean git tree. It writes:
#   install.sh  the TN_SCRIPTS_TAG line and the embedded copy of lib/allowed_signers
#   RELEASE     one line, "<tag> <date>": the pointer update-scripts.sh reads from main
#   MANIFEST    format=1, release=, serial=, min_updater=, date=, expires=, then one
#               line per file: "sha256  <64 hex>  <path>", sorted by path
# and removes a MANIFEST.sig left over from the previous release. It never signs:
# it prints the ssh-keygen commands the release signer runs with the hardware key.
#
#   --serial N          default: the previous MANIFEST's serial + 1 (required for
#                       the first release). Must be higher than the previous one.
#   --min-updater VER   default: the previous MANIFEST's min_updater, else the
#                       SCRIPT_VERSION of update-scripts.sh in the tree. Never higher
#                       than that SCRIPT_VERSION (the release could not install).
#   --date YYYY-MM-DD   the release date, written to RELEASE and to MANIFEST as
#                       date= (default: today, UTC).
#   --expires DAYS      the release expires DAYS days after its date (default 90,
#                       at most 3650): MANIFEST gets expires=YYYY-MM-DD. From that
#                       day the updater, the installer and check-node warn that a
#                       newer signed release is overdue; they still install it.
#                       Updaters and installers of 2.0.0 ignore date= and expires=.
#
# The file list is every path in the SCRIPTS, UI_BUNDLE and TESTNET_ADDONS_BUNDLE
# arrays of update-scripts.sh (read as text, the way tools/gen-checksums.sh reads
# them), plus install.sh, open-ui.sh and lib/allowed_signers. Every array file and
# lib/allowed_signers must have a fresh .sha256 sidecar: updaters older than the
# manifest flow still read the sidecars, and the first signed release delivers
# lib/allowed_signers through its sidecar.
#
# Check mode regenerates the file lines from the tree and compares them with
# MANIFEST, checks RELEASE, the install.sh tag and embedded signers, the sidecars,
# and verifies MANIFEST.sig when it is present. It prints the release date and
# the expiry date, and warns when the release has expired (date= and expires= are
# optional: the manifests of 2.0.0 have neither). Without MANIFEST it reports that
# there is nothing to check and exits 0, unless --tag, --require-sig or
# --require-fresh is given. --tag also requires release= to equal TAG; --tag and
# --require-sig require a MANIFEST.sig that verifies; --require-fresh fails the
# check when the release has expired (today, UTC, is on or after expires=). CI
# runs check mode on release changes and tags, without --require-fresh.
#
# Exit status: 0 done or check passed; 1 refused or check failed; 2 usage error.
#
# Maintainer tooling: update-scripts.sh does not track tools/ and this file has
# no .sha256 sidecar. bash 3.2 safe.
# =============================================================================

set -euo pipefail

readonly SIGNER_PRINCIPAL="release@telcoin.org"
readonly SIGNER_NAMESPACE="tn-node-scripts"
readonly TAG_RE='^scripts-v[0-9]+\.[0-9]+\.[0-9]+$'
readonly SIGNERS_HEREDOC="TN_ALLOWED_SIGNERS"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

die() {
    printf 'release-scripts.sh: %s\n' "$*" >&2
    exit 1
}

usage() {
    echo "Usage:"
    sed -n '5,6p' "${BASH_SOURCE[0]}" | sed 's/^#//'
}

_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1"
    else
        shasum -a 256 "$1"
    fi | awk '{print $1}'
}

# version_gt A B: rc 0 when A > B (X.Y.Z, compared field by field).
version_gt() {
    local IFS=.
    local -a a b
    local i
    read -r -a a <<< "$1"
    read -r -a b <<< "$2"
    for i in 0 1 2; do
        if ((10#${a[i]:-0} > 10#${b[i]:-0})); then return 0; fi
        if ((10#${a[i]:-0} < 10#${b[i]:-0})); then return 1; fi
    done
    return 1
}

# ymd_days YYYY-MM-DD -- print the day number (days since 1970-01-01) of a real
# calendar date from 1970 on; rc 1 for anything else. Pure bash: busybox and
# macOS date cannot parse a date, and the same text runs in every script that
# reads a MANIFEST date (tools/tests/release_scripts_test.sh checks the copies).
ymd_days() {
    local y m d n
    [[ "$1" =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2})$ ]] || return 1
    y=$((10#${BASH_REMATCH[1]}))
    m=$((10#${BASH_REMATCH[2]}))
    d=$((10#${BASH_REMATCH[3]}))
    n=31
    if [[ $m -eq 4 || $m -eq 6 || $m -eq 9 || $m -eq 11 ]]; then
        n=30
    elif [[ $m -eq 2 ]]; then
        n=28
        if (( y % 4 == 0 && (y % 100 != 0 || y % 400 == 0) )); then n=29; fi
    fi
    if (( y < 1970 || m < 1 || m > 12 || d < 1 || d > n )); then return 1; fi
    # Days from the civil date (H. Hinnant's algorithm), the year starting in March.
    if (( m <= 2 )); then y=$((y - 1)); m=$((m + 9)); else m=$((m - 3)); fi
    printf '%s\n' "$(( (y / 400) * 146097 + (y % 400) * 365 + (y % 400) / 4 - (y % 400) / 100 \
        + (153 * m + 2) / 5 + d - 1 - 719468 ))"
}

# days_ymd N -- the YYYY-MM-DD of day number N (days since 1970-01-01).
days_ymd() {
    local z era doe yoe y doy mp d m
    z=$(( $1 + 719468 ))
    era=$(( z / 146097 ))
    doe=$(( z - era * 146097 ))
    yoe=$(( (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365 ))
    y=$(( yoe + era * 400 ))
    doy=$(( doe - (365 * yoe + yoe / 4 - yoe / 100) ))
    mp=$(( (5 * doy + 2) / 153 ))
    d=$(( doy - (153 * mp + 2) / 5 + 1 ))
    if (( mp < 10 )); then m=$((mp + 3)); else m=$((mp - 9)); y=$((y + 1)); fi
    printf '%04d-%02d-%02d\n' "$y" "$m" "$d"
}

# days_text N -- "1 day" or "N days".
days_text() {
    if [[ "$1" == "1" ]]; then echo "1 day"; else echo "$1 days"; fi
}

# path_ok P: rc 0 for a relative path made of [A-Za-z0-9._/-] with no empty,
# "." or ".." component and no leading "-" (the rule update-scripts.sh applies).
path_ok() {
    local p="$1"
    [[ "$p" =~ ^[A-Za-z0-9._][A-Za-z0-9._/-]*$ ]] || return 1
    case "/$p/" in
        */./*|*/../*|*//*) return 1 ;;
    esac
    case "$p" in
        MANIFEST|MANIFEST.sig) return 1 ;;
    esac
    return 0
}

# array_paths: the local path of every row of the three updater arrays.
array_paths() {
    awk '
        /^declare -a (SCRIPTS|UI_BUNDLE|TESTNET_ADDONS_BUNDLE)=\(/ { inblock = 1; next }
        inblock && /^\)/                                          { inblock = 0; next }
        inblock && /"/                                            { print }
    ' update-scripts.sh \
        | sed -e 's/^[[:space:]]*"//' -e 's/".*$//' \
        | cut -d: -f1
}

# release_paths: the sorted, de-duplicated list MANIFEST covers.
release_paths() {
    { array_paths; printf '%s\n' install.sh open-ui.sh lib/allowed_signers; } | LC_ALL=C sort -u
}

# manifest_lines: one "sha256  <hash>  <path>" line per release path, or rc 1
# with a message for a path that is missing, not a regular file, or malformed.
manifest_lines() {
    local p bad=0
    while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        if ! path_ok "$p"; then
            printf 'release-scripts.sh: malformed path in the updater arrays: %s\n' "$p" >&2
            bad=1
        elif [[ -L "$p" || ! -f "$p" ]]; then
            printf 'release-scripts.sh: not a regular file: %s\n' "$p" >&2
            bad=1
        else
            printf 'sha256  %s  %s\n' "$(_sha256 "$p")" "$p"
        fi
    done < <(release_paths)
    return "$bad"
}

# check_sidecars: every array file and lib/allowed_signers has a sidecar whose
# first field is the file's hash.
check_sidecars() {
    local p want have bad=0
    while IFS= read -r p; do
        [[ -n "$p" && -f "$p" ]] || continue
        want="$(_sha256 "$p")"
        have=""
        [[ -f "${p}.sha256" ]] && have="$(awk 'NR == 1 {print $1}' "${p}.sha256")"
        if [[ "$have" != "$want" ]]; then
            printf 'release-scripts.sh: stale or missing sidecar: %s.sha256\n' "$p" >&2
            bad=1
        fi
    done < <({ array_paths; printf '%s\n' lib/allowed_signers; } | LC_ALL=C sort -u)
    if [[ $bad -ne 0 ]]; then
        printf 'release-scripts.sh: lib/allowed_signers needs a row in an updater array; then run bash tools/gen-checksums.sh and commit the sidecars.\n' >&2
        return 1
    fi
}

# header FILE KEY: the value of KEY=... in FILE; rc 1 when absent or repeated.
header() {
    local n
    n="$(awk -F= -v k="$2" '$1 == k {c++} END {print c + 0}' "$1")"
    [[ "$n" == "1" ]] || return 1
    awk -F= -v k="$2" '$1 == k {sub(/^[^=]*=/, ""); print; exit}' "$1"
}

# header_count FILE KEY: how many KEY=... lines FILE has.
header_count() {
    awk -F= -v k="$2" '$1 == k {c++} END {print c + 0}' "$1"
}

updater_version() {
    sed -n 's/^readonly SCRIPT_VERSION="\([0-9][0-9.]*\)"$/\1/p' update-scripts.sh | head -1
}

signer_keys() {
    grep -cvE '^[[:space:]]*(#|$)' lib/allowed_signers || true
}

# embedded_signers: the allowed-signers copy embedded in install.sh.
embedded_signers() {
    awk -v m="$SIGNERS_HEREDOC" -v q="'" '
        $0 == m { inblock = 0 }
        inblock { print }
        index($0, "<<" q m q) { inblock = 1 }
    ' install.sh
}

installer_tag() {
    sed -n 's/^readonly TN_SCRIPTS_TAG="\([^"]*\)".*$/\1/p' install.sh | head -1
}

verify_sig() {
    command -v ssh-keygen >/dev/null 2>&1 || die "ssh-keygen not found: cannot verify MANIFEST.sig"
    ssh-keygen -Y verify -f lib/allowed_signers -I "$SIGNER_PRINCIPAL" \
        -n "$SIGNER_NAMESPACE" -s MANIFEST.sig < MANIFEST
}

# rewrite_installer TAG: set TN_SCRIPTS_TAG and replace the embedded signers.
rewrite_installer() {
    local tag="$1" tmp
    grep -qx "$SIGNERS_HEREDOC" lib/allowed_signers && die "lib/allowed_signers contains the heredoc marker line ${SIGNERS_HEREDOC}"
    [[ "$(grep -c '^readonly TN_SCRIPTS_TAG=' install.sh)" == "1" ]] || die "install.sh: expected one readonly TN_SCRIPTS_TAG= line"
    [[ "$(grep -c "^${SIGNERS_HEREDOC}\$" install.sh)" == "1" ]] || die "install.sh: expected one ${SIGNERS_HEREDOC} heredoc"
    tmp="$(mktemp "install.sh.XXXXXX")"
    awk -v tag="$tag" -v m="$SIGNERS_HEREDOC" -v sf="lib/allowed_signers" -v q="'" '
        /^readonly TN_SCRIPTS_TAG=/ {
            print "readonly TN_SCRIPTS_TAG=\"" tag "\"   # written by tools/release-scripts.sh"
            next
        }
        skipping && $0 == m { skipping = 0 }
        skipping { next }
        { print }
        index($0, "<<" q m q) {
            while ((getline line < sf) > 0) print line
            close(sf)
            skipping = 1
        }
    ' install.sh > "$tmp"
    chmod 755 "$tmp"
    mv -f "$tmp" install.sh
}

prepare() {
    local tag="$1" serial="$2" min="$3" date="$4" days="$5"
    local prev_serial="" prev_min="" uver tmp day expires today

    [[ "$tag" =~ $TAG_RE ]] || die "release tag must look like scripts-v1.2.3, got: ${tag}"
    git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not inside a git work tree"
    [[ -z "$(git status --porcelain)" ]] || die "the tree has uncommitted changes; commit or stash them first"
    [[ -f lib/allowed_signers ]] || die "lib/allowed_signers is missing"
    [[ "$(signer_keys)" -gt 0 ]] || die "lib/allowed_signers lists no key: add the release signer public key line first"

    uver="$(updater_version)"
    [[ "$uver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "cannot read SCRIPT_VERSION from update-scripts.sh"

    if [[ -f MANIFEST ]]; then
        prev_serial="$(header MANIFEST serial)" || die "the previous MANIFEST has no single serial= line"
        prev_min="$(header MANIFEST min_updater)" || die "the previous MANIFEST has no single min_updater= line"
    fi
    if [[ -z "$serial" ]]; then
        [[ -n "$prev_serial" ]] || die "first release: pass --serial N"
        serial=$((10#$prev_serial + 1))
    fi
    [[ "$serial" =~ ^[1-9][0-9]{0,8}$ ]] || die "serial must be a positive integer, got: ${serial}"
    if [[ -n "$prev_serial" ]] && (( 10#$serial <= 10#$prev_serial )); then
        die "serial ${serial} is not higher than the previous release serial ${prev_serial}"
    fi
    if [[ -z "$min" ]]; then
        min="${prev_min:-$uver}"
    fi
    [[ "$min" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "min_updater must look like 1.2.3, got: ${min}"
    if version_gt "$min" "$uver"; then
        die "min_updater ${min} is newer than the updater in this tree (${uver}): no host could install the release"
    fi
    [[ -n "$date" ]] || date="$(date -u +%Y-%m-%d)"
    day="$(ymd_days "$date")" || die "date must be a calendar date like 2026-10-15, got: ${date}"
    if [[ ! "$days" =~ ^[1-9][0-9]{0,3}$ ]] || (( 10#$days > 3650 )); then
        die "--expires takes a number of days from 1 to 3650, got: ${days}"
    fi
    expires="$(days_ymd "$((day + 10#$days))")"
    today="$(ymd_days "$(date -u +%Y-%m-%d)")" || die "cannot read today's date"

    check_sidecars || exit 1
    local p
    while IFS= read -r p; do
        git ls-files --error-unmatch -- "$p" >/dev/null 2>&1 || die "not committed to git: ${p}"
    done < <(release_paths)

    rewrite_installer "$tag"
    printf '%s %s\n' "$tag" "$date" > RELEASE

    tmp="$(mktemp "MANIFEST.XXXXXX")"
    {
        printf 'format=1\n'
        printf 'release=%s\n' "$tag"
        printf 'serial=%s\n' "$serial"
        printf 'min_updater=%s\n' "$min"
        printf 'date=%s\n' "$date"
        printf 'expires=%s\n' "$expires"
        manifest_lines
    } > "$tmp" || { rm -f "$tmp"; die "could not hash the release files"; }
    chmod 644 "$tmp"
    mv -f "$tmp" MANIFEST
    rm -f MANIFEST.sig

    cat <<EOF
Prepared ${tag}: serial ${serial}, min_updater ${min}, $(grep -c '^sha256 ' MANIFEST) files.
Release date ${date}; the release expires ${expires} (${days} days later).
Wrote MANIFEST, RELEASE and install.sh (tag and embedded signers). Nothing is signed yet.

Release signer, on the machine that holds the hardware key:

  1. Review the change:            git diff -- install.sh RELEASE; cat MANIFEST
  2. Sign the manifest (touch the key when it blinks):
       ssh-keygen -Y sign -f ~/.ssh/id_ed25519_sk -n ${SIGNER_NAMESPACE} MANIFEST
     (-f names your key handle file; the command writes MANIFEST.sig)
  3. Check the signature against the signer list the release ships:
       ssh-keygen -Y verify -f lib/allowed_signers -I ${SIGNER_PRINCIPAL} -n ${SIGNER_NAMESPACE} -s MANIFEST.sig < MANIFEST
       bash tools/release-scripts.sh --check --tag ${tag}
  4. Commit and open the release pull request:
       git add MANIFEST MANIFEST.sig RELEASE install.sh
       git commit -m "Release ${tag}"
  5. After it merges, tag the merge commit on main and push the tag:
       git tag -a ${tag} -m "${tag}" <merge commit>
       git push origin ${tag}
EOF
    if (( day + 10#$days <= today )); then
        printf 'release-scripts.sh: WARN %s expires %s, on or before today (%s): every updater, installer and check-node will report it as expired. Prepare it again with a later --date or a longer --expires before signing.\n' \
            "$tag" "$expires" "$(days_ymd "$today")" >&2
    fi
}

check() {
    local tag="$1" require_sig="$2" require_fresh="$3"
    local fmt rel serial min rdate="" expires="" n uver itag rtag bad=0 tmp

    if [[ ! -f MANIFEST ]]; then
        if [[ -n "$tag" || "$require_sig" == "1" || "$require_fresh" == "1" ]]; then
            die "no MANIFEST in the tree"
        fi
        echo "No MANIFEST in the tree: nothing to check."
        return 0
    fi
    if grep -q $'\r' MANIFEST; then die "MANIFEST has CR line endings"; fi

    fmt="$(header MANIFEST format)" || die "MANIFEST: no single format= line"
    rel="$(header MANIFEST release)" || die "MANIFEST: no single release= line"
    serial="$(header MANIFEST serial)" || die "MANIFEST: no single serial= line"
    min="$(header MANIFEST min_updater)" || die "MANIFEST: no single min_updater= line"
    [[ "$fmt" == "1" ]] || die "MANIFEST: format=${fmt}, expected 1"
    [[ "$rel" =~ $TAG_RE ]] || die "MANIFEST: release=${rel} is not a scripts-vX.Y.Z tag"
    [[ "$serial" =~ ^[1-9][0-9]{0,8}$ ]] || die "MANIFEST: serial=${serial} is not a positive integer"
    [[ "$min" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "MANIFEST: min_updater=${min} is not X.Y.Z"
    # date= and expires= are optional; a line that is there must hold a calendar
    # date (an empty value too is refused, as the updater and installer refuse it).
    n="$(header_count MANIFEST date)"
    [[ "$n" -le 1 ]] || die "MANIFEST: date= appears more than once"
    if [[ "$n" == "1" ]]; then
        rdate="$(header MANIFEST date)"
        ymd_days "$rdate" >/dev/null || die "MANIFEST: date=${rdate} is not a calendar date YYYY-MM-DD"
    fi
    n="$(header_count MANIFEST expires)"
    [[ "$n" -le 1 ]] || die "MANIFEST: expires= appears more than once"
    if [[ "$n" == "1" ]]; then
        expires="$(header MANIFEST expires)"
        ymd_days "$expires" >/dev/null || die "MANIFEST: expires=${expires} is not a calendar date YYYY-MM-DD"
    fi
    if [[ -n "$tag" && "$rel" != "$tag" ]]; then
        die "MANIFEST: release=${rel} but the tag is ${tag}"
    fi

    uver="$(updater_version)"
    if version_gt "$min" "$uver"; then
        echo "FAIL min_updater ${min} is newer than the updater in the tree (${uver})" >&2
        bad=1
    fi

    tmp="$(mktemp "${TMPDIR:-/tmp}/tn-manifest.XXXXXX")"
    if ! manifest_lines > "$tmp"; then
        bad=1
    fi
    if ! grep -vE '^[a-z_]+=' MANIFEST | diff -u - "$tmp" >&2; then
        echo "FAIL MANIFEST file lines differ from the tree (- MANIFEST, + tree)" >&2
        bad=1
    fi
    rm -f "$tmp"

    if [[ -f RELEASE ]]; then
        rtag="$(awk 'NR == 1 {print $1}' RELEASE)"
        if [[ "$rtag" != "$rel" ]]; then
            echo "FAIL RELEASE names ${rtag:-nothing}, MANIFEST is ${rel}" >&2
            bad=1
        fi
        if [[ -n "$rdate" && "$(awk 'NR == 1 {print $2}' RELEASE)" != "$rdate" ]]; then
            echo "FAIL RELEASE is dated $(awk 'NR == 1 {print $2}' RELEASE), MANIFEST date=${rdate}" >&2
            bad=1
        fi
    elif [[ -n "$tag" ]]; then
        echo "FAIL no RELEASE file" >&2
        bad=1
    fi
    itag="$(installer_tag)"
    if [[ "$itag" != "$rel" ]]; then
        echo "FAIL install.sh TN_SCRIPTS_TAG is ${itag:-empty}, MANIFEST is ${rel}" >&2
        bad=1
    fi
    if [[ "$(embedded_signers)" != "$(cat lib/allowed_signers)" ]]; then
        echo "FAIL the signers embedded in install.sh differ from lib/allowed_signers" >&2
        bad=1
    fi
    check_sidecars || bad=1
    check_expiry "$rel" "$rdate" "$expires" "$require_fresh" || bad=1

    if [[ -f MANIFEST.sig ]]; then
        if verify_sig; then
            echo "MANIFEST.sig verifies against lib/allowed_signers."
        else
            echo "FAIL MANIFEST.sig does not verify against lib/allowed_signers" >&2
            bad=1
        fi
    elif [[ -n "$tag" || "$require_sig" == "1" ]]; then
        echo "FAIL no MANIFEST.sig" >&2
        bad=1
    else
        echo "WARN no MANIFEST.sig yet (unsigned release candidate)" >&2
    fi

    if [[ $bad -ne 0 ]]; then
        echo "MANIFEST check failed for ${rel}." >&2
        return 1
    fi
    echo "MANIFEST check passed for ${rel} (serial ${serial}, min_updater ${min})."
}

# check_expiry REL DATE EXPIRES REQUIRE_FRESH: print the release date and the
# expiry; warn when the release has expired (today, UTC, is on or after
# EXPIRES), and fail (rc 1) then when REQUIRE_FRESH is 1. A release with no
# expires= line never expires. Fails as well when EXPIRES is not after DATE.
check_expiry() {
    local rel="$1" rdate="$2" expires="$3" fresh="$4" today left when
    [[ -z "$rdate" ]] || echo "Release date ${rdate}."
    if [[ -z "$expires" ]]; then
        echo "MANIFEST has no expires= line: ${rel} does not expire."
        return 0
    fi
    if [[ -n "$rdate" ]] && (( $(ymd_days "$expires") <= $(ymd_days "$rdate") )); then
        echo "FAIL MANIFEST expires=${expires} is not after date=${rdate}" >&2
        return 1
    fi
    today="$(ymd_days "$(date -u +%Y-%m-%d)")" || die "cannot read today's date"
    left=$(( $(ymd_days "$expires") - today ))
    if (( left > 0 )); then
        echo "Release ${rel} expires ${expires} (in $(days_text "$left"))."
        return 0
    fi
    when="today"
    (( left == 0 )) || when="$(days_text $(( -left ))) ago"
    if [[ "$fresh" == "1" ]]; then
        echo "FAIL release ${rel} expired on ${expires} (${when}): cut a newer release" >&2
        return 1
    fi
    echo "WARN release ${rel} expired on ${expires} (${when}): a newer signed release is overdue" >&2
}

main() {
    local mode=prepare tag="" serial="" min="" date="" days=90 require_sig=0 require_fresh=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --check) mode=check ;;
            --tag) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; tag="$2"; shift ;;
            --require-sig) require_sig=1 ;;
            --require-fresh) require_fresh=1 ;;
            --serial) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; serial="$2"; shift ;;
            --min-updater) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; min="$2"; shift ;;
            --date) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; date="$2"; shift ;;
            --expires) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; days="$2"; shift ;;
            -h|--help) usage; exit 0 ;;
            -*) printf 'release-scripts.sh: unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
            *) [[ -z "$tag" ]] || { usage >&2; exit 2; }; tag="$1" ;;
        esac
        shift
    done
    if [[ "$mode" == "check" ]]; then
        if [[ -n "$tag" && ! "$tag" =~ $TAG_RE ]]; then
            die "--tag must look like scripts-v1.2.3, got: ${tag}"
        fi
        check "$tag" "$require_sig" "$require_fresh"
    else
        [[ -n "$tag" ]] || { usage >&2; exit 2; }
        prepare "$tag" "$serial" "$min" "$date" "$days"
    fi
}

main "$@"
