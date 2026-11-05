#!/usr/bin/env bash
# =============================================================================
# tasks/verify-r2/V7-IMG/t_repos.sh -- IMG check 1 (V7 spec): the repository
# helpers per network (tn_docker_repo_for, tn_docker_repos_for, tn_docker_repo_ok,
# tn_docker_pull_repos_for, tn_docker_pull_repo_ok), tn_docker_resolve_ref across
# networks, image-reference shapes that might slip past the exact matches
# (uppercase, a trailing slash, a tag beside a digest, a registry prefix), and
# the repositories tn_docker_image_for_tag and latest_docker_image ever name
# (never the old single package, never tn-dev on testnet or mainnet).
#
#   bash tasks/verify-r2/V7-IMG/t_repos.sh
#
# Verifier harness (round 2, V7-IMG). bash 3.2 safe.
# =============================================================================
# shellcheck source=tasks/verify-r2/V7-IMG/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
mkdir -p "$T/root/etc/telcoin"
TN_ROOT_PREFIX="$T/root"
eval "$(tn_test_source_common)"
unset TN_DOCKER_REQUIRE_DIGEST

# --- repo_for / repos_for / pull_repos_for ------------------------------------------
out() { local o rc=0; o="$("$@" 2>/dev/null)" || rc=$?; printf '%s %s' "$rc" "$o"; }
check "repo_for testnet" "0 $GT" "$(out tn_docker_repo_for testnet)"
check "repo_for mainnet" "0 $GM" "$(out tn_docker_repo_for mainnet)"
check "repo_for devnet" "0 $GAR" "$(out tn_docker_repo_for devnet)"
check "repo_for adiri refused" "1 " "$(out tn_docker_repo_for adiri)"
check "repo_for empty refused" "1 " "$(out tn_docker_repo_for "")"
check "repos_for testnet" "0 $GAR $GL $GT" "$(out tn_docker_repos_for testnet)"
check "repos_for mainnet" "0 $GM" "$(out tn_docker_repos_for mainnet)"
check "repos_for devnet" "0 $GAR $GL $GD" "$(out tn_docker_repos_for devnet)"
check "repos_for other refused" "1 " "$(out tn_docker_repos_for prod)"
check "pull_repos_for testnet" "0 $GAR $GT" "$(out tn_docker_pull_repos_for testnet)"
check "pull_repos_for mainnet" "0 $GM" "$(out tn_docker_pull_repos_for mainnet)"
check "pull_repos_for devnet" "0 $GAR $GD" "$(out tn_docker_pull_repos_for devnet)"
check "pull_repos_for other refused" "1 " "$(out tn_docker_pull_repos_for prod)"

# --- repo_ok / pull_repo_ok matrix --------------------------------------------------
# expected per network in the order testnet mainnet devnet (1 = rc 0).
matrix() {  # NAME REPO RECOG(t m d) PULL(t m d)
    local name="$1" repo="$2" n i want got
    i=0
    for n in testnet mainnet devnet; do
        i=$((i + 1))
        want="$(printf '%s' "$3" | cut -c"$i")"
        got=0; tn_docker_repo_ok "$n" "$repo" && got=1
        check "repo_ok $n $name" "$want" "$got"
        want="$(printf '%s' "$4" | cut -c"$i")"
        got=0; tn_docker_pull_repo_ok "$n" "$repo" && got=1
        check "pull_repo_ok $n $name" "$want" "$got"
    done
}
matrix "tn-testnet" "$GT" 100 100
matrix "tn-mainnet" "$GM" 010 010
matrix "old single package" "$GL" 101 000
matrix "tn-dev" "$GD" 001 001
matrix "GAR legacy" "$GAR" 101 101
matrix "tn-testnet trailing slash" "$GT/" 000 000
matrix "tn-mainnet trailing slash" "$GM/" 000 000
matrix "tn-mainnet uppercase" "GHCR.IO/TELCOIN-ASSOCIATION/TN-MAINNET" 000 000
matrix "tn-testnet uppercase package" "ghcr.io/telcoin-association/TN-TESTNET" 000 000
matrix "docker.io prefix" "docker.io/$GM" 000 000
matrix "double slash" "ghcr.io/telcoin-association//tn-mainnet" 000 000
matrix "with tag" "$GM:v1.0.0" 000 000
matrix "with whitespace" "$GM $GT" 000 000
matrix "empty" "" 000 000
matrix "tn-mainnet suffix" "${GM}x" 000 000

# --- tn_docker_resolve_ref ----------------------------------------------------------
# The release lookup is stubbed (no network): a tag resolves to <network package>@sha256:D64,
# and every call is logged, so a refusal can be shown to happen before any lookup.
RES_LOG="$T/res.log"
# The library's own function stays callable as _v7_orig_image_for_tag (devnet goes to it).
eval "$(declare -f tn_docker_image_for_tag | sed '1s/^tn_docker_image_for_tag/_v7_orig_image_for_tag/')"
tn_docker_image_for_tag() {
    printf 'image_for_tag %s %s\n' "$1" "$2" >> "$RES_LOG"
    if [[ "$1" == devnet ]]; then
        _v7_orig_image_for_tag "$@"
        return
    fi
    tn_release_tag_ok "$1" "$2" || return 3
    printf '%s@sha256:%s\n' "$(tn_docker_repo_for "$1")" "$D64"
}
meta() { printf '%s\n' "$@" > "$T/root/etc/telcoin/.node-meta"; }
res() {  # NAME NETWORK ARG EXPECTED ("rc out")
    local rc=0 o
    o="$(tn_docker_resolve_ref "$2" "$3" 2>"$T/res.err")" || rc=$?
    check "resolve $2: $1" "$4" "$rc $o"
}
: > "$RES_LOG"
meta "NETWORK=mainnet"
res "tn-testnet:-adiri tag refused" mainnet "${GT}:v0.17.0-adiri" "1 "
res "tn-testnet:plain tag refused" mainnet "${GT}:v1.0.0" "1 "
res "tn-mainnet:v1.0.0 resolved" mainnet "${GM}:v1.0.0" "0 ${GM}@sha256:${D64} v1.0.0"
res "bare v1.0.0 resolved" mainnet "v1.0.0" "0 ${GM}@sha256:${D64} v1.0.0"
res "bare -adiri tag refused" mainnet "v0.17.0-adiri" "1 "
res "tn-mainnet:-adiri tag refused" mainnet "${GM}:v1.0.0-adiri" "1 "
res "rc tag refused" mainnet "v1.0.0-rc1" "1 "
res "tn-mainnet:rc tag refused" mainnet "${GM}:v1.0.0-rc1" "1 "
res "latest refused" mainnet "latest" "1 "
res "tn-mainnet:latest refused" mainnet "${GM}:latest" "1 "
res "old package tag refused" mainnet "${GL}:v1.0.0" "1 "
res "old package digest refused" mainnet "${GL}@sha256:${D64}" "1 "
res "GAR digest refused" mainnet "${GAR}@sha256:${D64}" "1 "
res "GAR tag refused" mainnet "${GAR}:v1.0.0" "1 "
res "tn-dev digest refused" mainnet "${GD}@sha256:${D64}" "1 "
res "tn-dev tag refused" mainnet "${GD}:v1.0.0" "1 "
res "tn-testnet digest refused" mainnet "${GT}@sha256:${D64}" "1 "
res "raw digest, nothing recorded, refused" mainnet "${GM}@sha256:${D64}" "1 "
meta "NETWORK=mainnet" "DOCKER_IMAGE_DIGEST=sha256:${D64}" "RELEASE_TAG=v0.17.0-adiri"
res "raw digest recorded with a testnet tag refused" mainnet "${GM}@sha256:${D64}" "1 "
meta "NETWORK=mainnet" "DOCKER_IMAGE_DIGEST=sha256:${D64}" "RELEASE_TAG=v1.0.0-rc1"
res "raw digest recorded with an rc tag refused" mainnet "${GM}@sha256:${D64}" "1 "
meta "NETWORK=mainnet" "DOCKER_IMAGE_DIGEST=sha256:${D64}" "RELEASE_TAG=v1.0.0"
res "raw digest recorded as v1.0.0 taken" mainnet "${GM}@sha256:${D64}" "0 ${GM}@sha256:${D64} v1.0.0"
res "recorded digest, other repo still refused" mainnet "${GT}@sha256:${D64}" "1 "
check "resolve mainnet: no lookup ran for a refused shape" \
    "image_for_tag mainnet v1.0.0
image_for_tag mainnet v1.0.0" "$(cat "$RES_LOG")"

: > "$RES_LOG"
meta "NETWORK=testnet"
res "tn-mainnet:plain tag refused" testnet "${GM}:v1.0.0" "1 "
res "tn-mainnet:-adiri tag refused" testnet "${GM}:v0.17.0-adiri" "1 "
res "bare plain tag refused" testnet "v1.0.0" "1 "
res "tn-testnet:plain tag refused" testnet "${GT}:v1.0.0" "1 "
res "tn-testnet:-adiri resolved" testnet "${GT}:v0.17.0-adiri" "0 ${GT}@sha256:${D64} v0.17.0-adiri"
res "bare -adiri resolved" testnet "v0.17.0-adiri" "0 ${GT}@sha256:${D64} v0.17.0-adiri"
res "GAR:-adiri resolved through the release" testnet "${GAR}:v0.17.0-adiri" "0 ${GT}@sha256:${D64} v0.17.0-adiri"
res "old package tag refused" testnet "${GL}:v0.17.0-adiri" "1 "
res "old package digest refused" testnet "${GL}@sha256:${D64}" "1 "
res "tn-dev digest refused" testnet "${GD}@sha256:${D64}" "1 "
res "tn-dev tag refused" testnet "${GD}:v0.17.0-adiri" "1 "
res "tn-mainnet digest refused" testnet "${GM}@sha256:${D64}" "1 "
res "latest refused" testnet "latest" "1 "
res "tn-testnet:latest refused" testnet "${GT}:latest" "1 "
res "tn-testnet digest alone taken (unknown tag)" testnet "${GT}@sha256:${D64}" "0 ${GT}@sha256:${D64} "
res "GAR digest alone taken (unknown tag)" testnet "${GAR}@sha256:${D64}" "0 ${GAR}@sha256:${D64} "
check "resolve testnet: lookups only for the accepted tags" \
    "image_for_tag testnet v0.17.0-adiri
image_for_tag testnet v0.17.0-adiri
image_for_tag testnet v0.17.0-adiri" "$(cat "$RES_LOG")"

meta "NETWORK=devnet"
res "tn-dev digest taken" devnet "${GD}@sha256:${D64}" "0 ${GD}@sha256:${D64} "
res "GAR digest taken" devnet "${GAR}@sha256:${D64}" "0 ${GAR}@sha256:${D64} "
res "old package digest refused" devnet "${GL}@sha256:${D64}" "1 "
res "tn-testnet digest refused" devnet "${GT}@sha256:${D64}" "1 "
res "tn-mainnet digest refused" devnet "${GM}@sha256:${D64}" "1 "
res "devnet tag refused" devnet "v0.2.0-devnet" "1 "
res "tn-dev tag refused" devnet "${GD}:v0.2.0-devnet" "1 "

# --- reference shapes ---------------------------------------------------------------
UP="$(printf '%s' "$D64" | tr a-f A-F)"
for net in testnet mainnet; do
    meta "NETWORK=${net}" "DOCKER_IMAGE_DIGEST=sha256:${D64}" "RELEASE_TAG=v1.0.0"
    if [[ "$net" == testnet ]]; then P="$GT"; TG=v0.17.0-adiri; else P="$GM"; TG=v1.0.0; fi
    res "shape: uppercase repository refused" "$net" "$(printf '%s' "$P" | tr a-z A-Z):${TG}" "1 "
    res "shape: uppercase repository digest refused" "$net" "$(printf '%s' "$P" | tr a-z A-Z)@sha256:${D64}" "1 "
    res "shape: uppercase digest refused" "$net" "${P}@sha256:${UP}" "1 "
    res "shape: trailing slash tag refused" "$net" "${P}/:${TG}" "1 "
    res "shape: trailing slash digest refused" "$net" "${P}/@sha256:${D64}" "1 "
    res "shape: tag and digest refused" "$net" "${P}:${TG}@sha256:${D64}" "1 "
    res "shape: digest then tag refused" "$net" "${P}@sha256:${D64}:${TG}" "1 "
    res "shape: docker.io prefix refused" "$net" "docker.io/${P}@sha256:${D64}" "1 "
    res "shape: leading dash refused" "$net" "-${P}@sha256:${D64}" "1 "
    res "shape: trailing space refused" "$net" "${P}@sha256:${D64} " "1 "
    res "shape: short digest refused" "$net" "${P}@sha256:${D64:1}" "1 "
    res "shape: sha512 refused" "$net" "${P}@sha512:${D64}${D64}" "1 "
    res "shape: old package uppercase refused" "$net" "GHCR.IO/TELCOIN-ASSOCIATION/TELCOIN-NETWORK:${TG}" "1 "
    res "shape: old package trailing slash refused" "$net" "${GL}/@sha256:${D64}" "1 "
    res "shape: empty refused" "$net" "" "1 "
done
TN_ROOT_PREFIX=""
rm -f "$T/root/etc/telcoin/.node-meta"
eval "$(declare -f _v7_orig_image_for_tag | sed '1s/^_v7_orig_image_for_tag/tn_docker_image_for_tag/')"

# --- what tn_docker_image_for_tag ever names ----------------------------------------
# Without release keys (testnet only) and after a network failure of the signed
# release (rc 2), the registry is asked; record which repositories.
REG_LOG="$T/reg.log"
tn_registry_digest() { printf '%s %s\n' "$1" "$2" >> "$REG_LOG"; [[ "$1" == "${REG_HIT:-}" ]] && printf 'sha256:%s\n' "$D64"; [[ "$1" == "${REG_HIT:-}" ]]; }
ift() {  # NAME NETWORK TAG KEYS(0/1) FETCH_RC EXPECTED ("rc out") EXPECTED_REG_LOG
    local rc=0 o
    : > "$REG_LOG"
    o="$( _tn_release_keys_present() { [[ "$KEYS" == 1 ]]; }
          tn_fetch_release_image() { [[ "$FRC" == 0 ]] && printf '%s@sha256:%s\n' "$(tn_docker_repo_for "$2")" "$D64"; return "$FRC"; }
          KEYS="$4" FRC="$5" tn_docker_image_for_tag "$2" "$3" 2>/dev/null )" || rc=$?
    check "image_for_tag $2: $1" "$6" "$rc $o"
    check "image_for_tag $2: $1: registry asked" "$7" "$(cat "$REG_LOG")"
}
REG_HIT="$GT"
ift "signed release" testnet v0.17.0-adiri 1 0 "0 ${GT}@sha256:${D64}" ""
ift "no keys: tn-testnet first" testnet v0.17.0-adiri 0 0 "0 ${GT}@sha256:${D64}" "${GT} v0.17.0-adiri"
REG_HIT="$GAR"
ift "no keys: then GAR, never the old package" testnet v0.16.0-adiri 0 0 "0 ${GAR}@sha256:${D64}" "${GT} v0.16.0-adiri
${GAR} v0.16.0-adiri"
ift "release unreachable (rc 2): registry" testnet v0.16.0-adiri 1 2 "0 ${GAR}@sha256:${D64}" "${GT} v0.16.0-adiri
${GAR} v0.16.0-adiri"
REG_HIT="none"
ift "release unreachable, registry silent: refused" testnet v0.16.0-adiri 1 2 "1 " "${GT} v0.16.0-adiri
${GAR} v0.16.0-adiri"
ift "release refused (rc 1): no registry" testnet v0.17.0-adiri 1 1 "1 " ""
REG_HIT="$GM"
ift "mainnet signed release" mainnet v1.0.0 1 0 "0 ${GM}@sha256:${D64}" ""
ift "mainnet no keys: refused, no registry" mainnet v1.0.0 0 0 "1 " ""
ift "mainnet release unreachable: refused, no registry" mainnet v1.0.0 1 2 "1 " ""
ift "devnet tag refused before any download" devnet v0.2.0-devnet 1 0 "1 " ""
unset -f tn_registry_digest

# --- latest_docker_image: the testnet fallback reads GAR only; mainnet never falls back
TAGS_LOG="$T/tags.log"
eval "$(declare -f tn_release_newest_tag | sed '1s/^tn_release_newest_tag/_v7_orig_newest_tag/')"
lat() {  # NAME NETWORK NEWEST_RC FETCH_RC EXPECTED ("rc out") EXPECTED_TAGS_LOG
    local rc=0 o
    : > "$TAGS_LOG"
    o="$( tn_release_newest_tag() { [[ "$1" == devnet ]] && { _v7_orig_newest_tag "$@"; return; }; [[ "$NRC" == 0 ]] && { [[ "$1" == mainnet ]] && echo v1.0.0 || echo v0.17.0-adiri; }; return "$NRC"; }
          tn_fetch_release_image() { [[ "$FRC" == 0 ]] && printf '%s@sha256:%s\n' "$(tn_docker_repo_for "$2")" "$D64"; return "$FRC"; }
          tn_registry_tags() { printf '%s\n' "$1" >> "$TAGS_LOG"; printf 'v0.16.0-adiri\n'; }
          tn_registry_digest() { printf 'sha256:%s\n' "$D64"; }
          NRC="$3" FRC="$4" latest_docker_image "$2" 2>/dev/null )" || rc=$?
    check "latest $2: $1" "$5" "$rc $o"
    check "latest $2: $1: registry listed" "$6" "$(cat "$TAGS_LOG")"
}
lat "signed newest" testnet 0 0 "0 ${GT}@sha256:${D64}" ""
lat "no release on GitHub: GAR newest" testnet 1 0 "0 ${GAR}@sha256:${D64}" "$GAR"
lat "release unreachable: pinned default" testnet 0 2 "0 ${DEFAULT_DOCKER_IMAGE}" ""
lat "release refused: nothing" testnet 0 1 "1 " ""
lat "mainnet signed newest" mainnet 0 0 "0 ${GM}@sha256:${D64}" ""
lat "mainnet no release: nothing" mainnet 1 0 "1 " ""
lat "mainnet unreachable: nothing" mainnet 0 2 "1 " ""
lat "devnet: nothing" devnet 0 0 "1 " ""
check "DEFAULT_DOCKER_IMAGE is in GAR (a testnet pull repository)" "1" "$(tn_docker_pull_repo_ok testnet "${DEFAULT_DOCKER_IMAGE%%@*}" && echo 1 || echo 0)"

finish
