#!/usr/bin/env bash
# =============================================================================
# tools/tests/docker_image_test.sh -- images by digest: tn_docker_image_allowed
# with the TN_DOCKER_REQUIRE_DIGEST default (1: tags refused) and with =0 (a
# release tag accepted, latest and other tags never); devnet images by digest
# from TN_DEVNET_IMAGE_REPOS (a devnet tag only with =0, testnet tags and
# main-<sha> never), and with no network given the host's (_tn_guard_network:
# NETWORK=devnet in .node-meta); tn_docker_repo_for per network (the tn-testnet
# and tn-mainnet packages, the legacy repository for devnet), tn_docker_repos_for,
# tn_docker_repo_ok (whitespace refused), tn_docker_pull_repos_for and
# tn_docker_pull_repo_ok per network (the old single ghcr.io package recognised on
# testnet and devnet, never pulled); against a curl shim: the ghcr pull token on the tags and manifest calls (none for the
# legacy registry), fetched once and shared by a run's lookups for 120 s,
# tn_release_newest_tag over a Releases API answer (drafts,
# prereleases, an rc newer than the newest final, a mainnet final, no release,
# API unreachable), latest_docker_image (the signed IMAGE_DIGEST of the newest
# release without asking the registry; when that release cannot be verified, an
# unsigned one among them, the pinned default on testnet and nothing on mainnet,
# never the registry's digest; on testnet only, with no release or no API, the
# legacy repository's newest final, then the pinned default; nothing on
# mainnet); tn_docker_local_digest against a docker shim;
# tn_docker_image_for_tag (signed digest first, the registry's on testnet only
# when no signed release exists, never after a failed verification; a devnet tag
# refused before any download), tn_docker_resolve_ref (devnet: digests only; the
# other network's package and the old single package refused on every network),
# tn_docker_release_tag_for on devnet (the .node-meta record only, no registry
# call), tn_docker_holds_digest and, against a docker shim that prints a canned
# --version per image, tn_docker_image_network_ok (mainnet: no build features;
# testnet: adiri, faucet allowed; the line missing or doubled refused; a run that
# fails refused; devnet not checked).
#
#   bash tools/tests/docker_image_test.sh
#
# Maintainer tooling: not tracked by update-scripts.sh, no .sha256 sidecar.
# bash 3.2 safe.
# =============================================================================
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
T="$TN_TEST_TMP"
eval "$(tn_test_source_common)"
REC="$T/rec"
mkdir -p "$T/bin" "$REC"
export REC
R="$GAR_IMAGE_BASE"
D64="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
unset TN_DOCKER_REQUIRE_DIGEST

allowed() { # NAME EXPECTED IMAGE [NETWORK]
    local rc=0
    tn_docker_image_allowed "$3" "${4:-testnet}" 2>/dev/null || rc=$?
    check_rc "$1" "$2" "$rc"
}
allowed "digest accepted" 0 "${R}@sha256:${D64}"
allowed "tag refused by default" 1 "${R}:v0.16.0-adiri"
allowed "short digest refused" 1 "${R}@sha256:${D64:1}"
allowed "upper-case digest refused" 1 "${R}@sha256:$(printf '%s' "$D64" | tr a-f A-F)"
allowed "other repository by digest refused" 1 "evil.example/adiri@sha256:${D64}"
allowed "leading dash refused" 1 "-${R}@sha256:${D64}"
allowed "whitespace refused" 1 "${R}@sha256:${D64} --privileged"
allowed "mainnet: the legacy testnet repository refused" 1 "${R}@sha256:${D64}" mainnet
allowed "devnet: the legacy repository by digest accepted" 0 "${R}@sha256:${D64}" devnet
allowed "default image is allowed" 0 "$DEFAULT_DOCKER_IMAGE"
# GH the testnet package, GM the mainnet package, GL the old single package.
GH="ghcr.io/telcoin-association/tn-testnet"
GM="ghcr.io/telcoin-association/tn-mainnet"
GL="ghcr.io/telcoin-association/telcoin-network"
check "TN_TESTNET_IMAGE_REPO" "$GH" "$TN_TESTNET_IMAGE_REPO"
check "TN_MAINNET_IMAGE_REPO" "$GM" "$TN_MAINNET_IMAGE_REPO"
check "TN_GHCR_LEGACY_IMAGE_REPO" "$GL" "$TN_GHCR_LEGACY_IMAGE_REPO"
check "GAR_IMAGE_BASE is the legacy repository" "$TN_TESTNET_LEGACY_IMAGE_REPO" "$GAR_IMAGE_BASE"
allowed "testnet: the release workflow's repository by digest accepted" 0 "${GH}@sha256:${D64}"
allowed "testnet: the old single package recognised" 0 "${GL}@sha256:${D64}"
allowed "testnet: the mainnet package refused" 1 "${GM}@sha256:${D64}"
allowed "testnet: another ghcr.io repository refused" 1 "ghcr.io/someone-else/telcoin-network@sha256:${D64}"
allowed "testnet: a repository that only starts like an allowed one refused" 1 "${GH}-x@sha256:${D64}"
allowed "testnet: a repository that only ends like an allowed one refused" 1 "evil.example/${GH}@sha256:${D64}"
allowed "mainnet: the mainnet package by digest accepted" 0 "${GM}@sha256:${D64}" mainnet
allowed "mainnet: the testnet package refused" 1 "${GH}@sha256:${D64}" mainnet
allowed "mainnet: the old single package refused" 1 "${GL}@sha256:${D64}" mainnet
allowed "testnet: a tag on the release workflow's repository refused by default" 1 "${GH}:v0.16.0-adiri"
# Devnet: digests from TN_DEVNET_IMAGE_REPOS (the legacy repository and the old
# single ghcr.io package); a tag is refused by default, as on every network.
allowed "devnet: the old single package by digest recognised" 0 "${GL}@sha256:${D64}" devnet
allowed "devnet: the testnet package refused" 1 "${GH}@sha256:${D64}" devnet
allowed "devnet: the mainnet package refused" 1 "${GM}@sha256:${D64}" devnet
allowed "devnet: another repository by digest refused" 1 "evil.example/adiri@sha256:${D64}" devnet
allowed "devnet: another ghcr.io repository refused" 1 "ghcr.io/someone-else/telcoin-network@sha256:${D64}" devnet
allowed "devnet: a devnet tag refused by default" 1 "${R}:v0.2.0-devnet" devnet
allowed "devnet: a main-<sha> tag refused" 1 "${R}:main-0123abc" devnet
allowed "devnet: a testnet release tag refused" 1 "${R}:v0.16.0-adiri" devnet
allowed "devnet: whitespace refused" 1 "${GL}@sha256:${D64} --privileged" devnet
TN_DOCKER_REQUIRE_DIGEST=0
allowed "=0: release tag accepted" 0 "${R}:v0.16.0-adiri"
allowed "=0: latest refused" 1 "${R}:latest"
allowed "=0: a devnet tag refused on testnet" 1 "${R}:v0.16.0-devnet"
allowed "=0: hot-patch tag refused" 1 "${R}:v0.16.0-adiri-hotfix1"
allowed "=0: mainnet-form tag refused on testnet" 1 "${R}:v0.16.0"
allowed "=0: digest still accepted" 0 "${R}@sha256:${D64}"
allowed "=0: release tag on the release workflow's repository accepted" 0 "${GH}:v0.16.0-adiri"
allowed "=0: release tag on another repository refused" 1 "evil.example/adiri:v0.16.0-adiri"
allowed "=0: a testnet release candidate accepted" 0 "${R}:v0.17.0-adiri-rc1"
allowed "=0: rc0 refused" 1 "${R}:v0.17.0-adiri-rc0"
allowed "=0: a devnet tag accepted on devnet" 0 "${R}:v0.2.0-devnet" devnet
allowed "=0: a devnet tag on the old ghcr package accepted on devnet" 0 "${GL}:v0.2.0-devnet" devnet
allowed "=0: a testnet release tag refused on devnet" 1 "${R}:v0.16.0-adiri" devnet
allowed "=0: main-<sha> refused on devnet" 1 "${R}:main-0123abc" devnet
allowed "=0: a devnet tag on another repository refused" 1 "evil.example/adiri:v0.2.0-devnet" devnet
TN_DOCKER_REQUIRE_DIGEST=1
allowed "=1: release tag refused" 1 "${R}:v0.16.0-adiri"
unset TN_DOCKER_REQUIRE_DIGEST
rc=0; validate_docker_image "${R}@sha256:${D64}" testnet || rc=$?
check_rc "validate_docker_image: digest" 0 "$rc"
rc=0; validate_docker_image "${R}:v0.16.0-adiri" testnet 2>/dev/null || rc=$?
check_rc "validate_docker_image: tag refused" 1 "$rc"
# No network given and no NETWORK global: the host's network (_tn_guard_network),
# so a devnet host (tn_detect_network rc 1, NETWORK=devnet in .node-meta) takes
# its digests and a host whose network cannot be told takes none.
guard_case() {  # NAME EXPECTED-RC META-NETWORK DETECTED IMAGE
    local rc=0
    (
        unset NETWORK
        GC_META="$3" GC_DET="$4"
        tn_detect_network() { [[ -n "$GC_DET" ]] || return 1; printf '%s\n' "$GC_DET"; }
        meta_get() { [[ "$1" == NETWORK && -n "$GC_META" ]] || return 1; printf '%s\n' "$GC_META"; }
        tn_docker_image_allowed "$5"
    ) 2>/dev/null || rc=$?
    check_rc "$1" "$2" "$rc"
}
guard_case "no network given, a devnet host: a devnet digest accepted" 0 devnet "" "${GL}@sha256:${D64}"
guard_case "no network given, a devnet host: validate_docker_image too" 0 devnet "" "${R}@sha256:${D64}"
guard_case "no network given, a devnet host: a tag still refused" 1 devnet "" "${R}:v0.2.0-devnet"
guard_case "no network given, a testnet host: tn_detect_network's network" 0 "" testnet "${R}@sha256:${D64}"
guard_case "no network given, a mainnet host: the legacy repository refused" 1 "" mainnet "${R}@sha256:${D64}"
guard_case "no network given, network unknown: refused" 1 "" "" "${GH}@sha256:${D64}"
guard_case "no network given, .node-meta names testnet but detection fails: refused" 1 testnet "" "${GH}@sha256:${D64}"

# --- tn_docker_repo_for --------------------------------------------------------------
rc=0; out="$(tn_docker_repo_for testnet 2>/dev/null)" || rc=$?
check_rc "repo testnet" 0 "$rc"
check "repo testnet value (the testnet package, not the list)" "ghcr.io/telcoin-association/tn-testnet" "$out"
rc=0; out="$(tn_docker_repo_for mainnet 2>/dev/null)" || rc=$?
check "repo mainnet: the mainnet package" "0 ghcr.io/telcoin-association/tn-mainnet" "$rc $out"
rc=0; out="$(tn_docker_repo_for devnet 2>"$T/err")" || rc=$?
check_rc "repo devnet" 0 "$rc"
check "repo devnet: the legacy repository" "us-docker.pkg.dev/telcoin-network/tn-public/adiri" "$out"
check "repo devnet: nothing on stderr" "" "$(cat "$T/err")"
check "TN_DEVNET_IMAGE_REPOS" "us-docker.pkg.dev/telcoin-network/tn-public/adiri ghcr.io/telcoin-association/telcoin-network" "$TN_DEVNET_IMAGE_REPOS"
rc=0; out="$(tn_docker_repo_for foo 2>/dev/null)" || rc=$?
check_rc "repo foo refused" 1 "$rc"
rc=0; out="$(tn_docker_repo_for "" 2>/dev/null)" || rc=$?
check_rc "repo empty refused" 1 "$rc"
# tn_docker_repos_for: every repository a network's images may come from.
rc=0; out="$(tn_docker_repos_for testnet 2>/dev/null)" || rc=$?
check "repos testnet: TN_TESTNET_IMAGE_REPOS" "0 ${TN_TESTNET_IMAGE_REPOS}" "$rc $out"
rc=0; out="$(tn_docker_repos_for devnet 2>/dev/null)" || rc=$?
check "repos devnet: TN_DEVNET_IMAGE_REPOS" "0 ${TN_DEVNET_IMAGE_REPOS}" "$rc $out"
rc=0; out="$(tn_docker_repos_for mainnet 2>/dev/null)" || rc=$?
check "repos mainnet: its repository alone" "0 ghcr.io/telcoin-association/tn-mainnet" "$rc $out"
check "TN_TESTNET_IMAGE_REPOS: the legacy repository, the old package, the testnet package" \
    "us-docker.pkg.dev/telcoin-network/tn-public/adiri ghcr.io/telcoin-association/telcoin-network ghcr.io/telcoin-association/tn-testnet" "$TN_TESTNET_IMAGE_REPOS"
# tn_docker_pull_repos_for: the list without the old single package.
rc=0; out="$(tn_docker_pull_repos_for testnet 2>/dev/null)" || rc=$?
check "pull repos testnet: the legacy repository and the testnet package" "0 ${R} ${GH}" "$rc $out"
rc=0; out="$(tn_docker_pull_repos_for devnet 2>/dev/null)" || rc=$?
check "pull repos devnet: the devnet repository alone" "0 ${R}" "$rc $out"
rc=0; out="$(tn_docker_pull_repos_for mainnet 2>/dev/null)" || rc=$?
check "pull repos mainnet: the mainnet package alone" "0 ${GM}" "$rc $out"
rc=0; out="$(tn_docker_pull_repos_for foo 2>/dev/null)" || rc=$?
check "pull repos foo refused" "1 " "$rc $out"
pull_ok() {  # pull_ok NETWORK REPO -- the rc of tn_docker_pull_repo_ok
    local rc=0
    tn_docker_pull_repo_ok "$1" "$2" || rc=$?
    echo "$rc"
}
check "pull_ok testnet: the testnet package" 0 "$(pull_ok testnet "$GH")"
check "pull_ok testnet: the legacy repository" 0 "$(pull_ok testnet "$R")"
check "pull_ok testnet: the old single package refused" 1 "$(pull_ok testnet "$GL")"
check "pull_ok testnet: the mainnet package refused" 1 "$(pull_ok testnet "$GM")"
check "pull_ok mainnet: the mainnet package" 0 "$(pull_ok mainnet "$GM")"
check "pull_ok mainnet: the testnet package refused" 1 "$(pull_ok mainnet "$GH")"
check "pull_ok mainnet: the old single package refused" 1 "$(pull_ok mainnet "$GL")"
check "pull_ok mainnet: the legacy repository refused" 1 "$(pull_ok mainnet "$R")"
check "pull_ok devnet: the devnet repository" 0 "$(pull_ok devnet "$R")"
check "pull_ok devnet: the old single package refused" 1 "$(pull_ok devnet "$GL")"
check "pull_ok devnet: the testnet package refused" 1 "$(pull_ok devnet "$GH")"
check "pull_ok testnet: a prefix of the testnet package refused" 1 "$(pull_ok testnet "${GH%t}")"
check "pull_ok testnet: two words refused" 1 "$(pull_ok testnet "$GH $R")"
# in_list WORD LIST -- 1 when WORD is one of LIST's space separated words, else 0
# (a function: bash 3.2 misparses a case inside $(...)).
in_list() {
    case " $2 " in
        *" $1 "*) echo 1 ;;
        *) echo 0 ;;
    esac
}
for n in testnet devnet mainnet; do
    rc=0; out="$(tn_docker_repos_for "$n" 2>/dev/null)" || rc=$?
    check "repos ${n} holds tn_docker_repo_for's repository" 1 "$(in_list "$(tn_docker_repo_for "$n" 2>/dev/null)" "$out")"
done
rc=0; out="$(tn_docker_repos_for foo 2>"$T/err")" || rc=$?
check "repos foo refused" "1 " "$rc $out"
check_has "repos foo: the reason on stderr" "1" "$(grep -c "No image repository for network 'foo'" "$T/err")"
rc=0; out="$(tn_docker_repos_for "" 2>/dev/null)" || rc=$?
check "repos empty refused" "1 " "$rc $out"

# --- registries, the Releases API and latest_docker_image (curl shim) --------------------
# The shim serves: ghcr.io's token endpoint ({"token":"TOK123"}; $REC/token.down
# makes it a 403), tags/list and manifest HEADs of the legacy repository
# ($REC/tags.json, $REC/digest.<tag>) and of ghcr ($REC/ghtags.json,
# $REC/ghdigest.<tag>; ghcr answers 401 without the Bearer token), and the
# GitHub Releases API ($REC/releases.json; $REC/api.down: unreachable) and the
# release downloads ($REC/dl/<tag>/<file>). Every call is logged as
# "<head> <auth> <url>".
cat > "$T/bin/curl" <<'SH'
#!/bin/sh
head=0; url=""; auth="-"; out=""
while [ $# -gt 0 ]; do
    case "$1" in
        -I|-fsSI|-sI) head=1; shift ;;
        --url) url="$2"; shift 2 ;;
        -o) out="$2"; shift 2 ;;
        -H) case "$2" in Authorization:*) auth="$(printf '%s' "$2" | tr ' ' '_')" ;; esac; shift 2 ;;
        *) shift ;;
    esac
done
printf '%s %s %s\n' "$head" "$auth" "$url" >> "$REC/curl.log"
[ -f "$REC/down" ] && exit 7
case "$url" in
    https://api.github.com/repos/Telcoin-Association/telcoin-network/releases\?per_page=100)
        [ -f "$REC/api.down" ] && exit 7
        cat "$REC/releases.json" ;;
    https://github.com/Telcoin-Association/telcoin-network/releases/download/*)
        f="$REC/dl/${url#https://github.com/Telcoin-Association/telcoin-network/releases/download/}"
        [ -f "$f" ] || exit 22
        if [ -n "$out" ]; then cat "$f" > "$out"; else cat "$f"; fi ;;
    https://ghcr.io/token\?scope=repository:telcoin-association/*:pull)
        [ -f "$REC/token.down" ] && exit 22
        printf '{"token":"TOK123"}' ;;
    https://ghcr.io/*)
        [ "$auth" = "Authorization:_Bearer_TOK123" ] || exit 22
        case "$url" in
            */tags/list) [ -f "$REC/ghtags.json" ] || exit 22; cat "$REC/ghtags.json" ;;
            */manifests/*)
                [ "$head" = 1 ] || exit 22
                t="${url##*/manifests/}"
                [ -f "$REC/ghdigest.$t" ] || exit 22
                printf 'HTTP/2 200\r\nDocker-Content-Digest: %s\r\n\r\n' "$(cat "$REC/ghdigest.$t")" ;;
            *) exit 22 ;;
        esac ;;
    https://us-docker.pkg.dev/*/tags/list) cat "$REC/tags.json" ;;
    https://us-docker.pkg.dev/*/manifests/*)
        [ "$head" = 1 ] || exit 22
        t="${url##*/manifests/}"
        [ -f "$REC/digest.$t" ] || exit 22
        printf 'HTTP/2 200\r\ncontent-type: application/vnd.oci.image.index.v1+json\r\nDocker-Content-Digest: %s\r\n\r\n' "$(cat "$REC/digest.$t")"
        ;;
    *) exit 6 ;;
esac
SH
chmod 0755 "$T/bin/curl"
PATH="$T/bin:$PATH"
mkdir -p "$T/keys"
export TN_RELEASE_KEYS_DIR="$T/keys"
printf '[]' > "$REC/releases.json"
printf '{"name":"x","tags":["latest","v0.16.0-adiri","v0.17.0-adiri","v0.17.1-adiri-hotfix","v0.18.0-adiri-rc1","v0.18.0-devnet","v0.9.0-adiri","v1.0.0"]}' > "$REC/tags.json"
printf 'sha256:%s\n' "$D64" > "$REC/digest.v0.17.0-adiri"
printf 'sha256:%s\n' "$(printf '%s' "$D64" | tr 0 c)" > "$REC/digest.v0.18.0-adiri-rc1"

# The ghcr token reaches the tags and manifest calls; the legacy registry gets none.
printf '{"name":"telcoin-association/telcoin-network","tags":["v0.17.0-adiri","v0.17.0-adiri-rc1","latest"]}' > "$REC/ghtags.json"
printf 'sha256:%s\n' "$D64" > "$REC/ghdigest.v0.17.0-adiri"
: > "$REC/curl.log"
rc=0; out="$(tn_registry_token "$GH")" || rc=$?
check "token: ghcr's anonymous pull token" "0 TOK123" "$rc $out"
rc=0; out="$(tn_registry_token "$R")" || rc=$?
check "token: none for another registry" "0 " "$rc $out"
rc=0; out="$(tn_registry_digest "$GH" v0.17.0-adiri)" || rc=$?
check "ghcr digest with the token" "0 sha256:${D64}" "$rc $out"
check_has "ghcr manifest HEAD carried the Bearer token" "1 Authorization:_Bearer_TOK123 https://ghcr.io/v2/telcoin-association/tn-testnet/manifests/v0.17.0-adiri" "$(cat "$REC/curl.log")"
rc=0; out="$(tn_registry_tags "$GH" | tr '\n' ' ')" || rc=$?
check "ghcr tags with the token" "0 v0.17.0-adiri v0.17.0-adiri-rc1 " "$rc $out"
check_has "ghcr tags/list carried the Bearer token" "0 Authorization:_Bearer_TOK123 https://ghcr.io/v2/telcoin-association/tn-testnet/tags/list" "$(cat "$REC/curl.log")"
check_has "ghcr token asked for the testnet package" "0 - https://ghcr.io/token?scope=repository:telcoin-association/tn-testnet:pull" "$(cat "$REC/curl.log")"
: > "$REC/curl.log"
rc=0; out="$(tn_registry_digest "$R" v0.17.0-adiri)" || rc=$?
check "legacy digest" "0 sha256:${D64}" "$rc $out"
check "legacy registry: no token asked, no Authorization sent" "1 - https://us-docker.pkg.dev/v2/telcoin-network/tn-public/adiri/manifests/v0.17.0-adiri" "$(cat "$REC/curl.log")"
touch "$REC/token.down"
rc=0; out="$(tn_registry_digest "$GH" v0.17.0-adiri)" || rc=$?
check "ghcr without a token (package not public): unreadable" "1 " "$rc $out"
rc=0; out="$(tn_registry_tags "$GH")" || rc=$?
check "ghcr tags without a token: unreadable" "1 " "$rc $out"
rm -f "$REC/token.down"
# One pull token per repository for the process: tn_docker_release_tag_for's
# listing and its three manifest lookups (four lookups) share one token call;
# four digest lookups in this shell share one; after 120 s it is fetched again.
printf '{"name":"telcoin-association/telcoin-network","tags":["v0.17.0-adiri","v0.17.1-adiri","v0.17.2-adiri"]}' > "$REC/ghtags.json"
printf 'sha256:%s\n' "$(printf '%s' "$D64" | tr 0 1)" > "$REC/ghdigest.v0.17.1-adiri"
printf 'sha256:%s\n' "$(printf '%s' "$D64" | tr 0 2)" > "$REC/ghdigest.v0.17.2-adiri"
: > "$REC/curl.log"
rc=0; out="$(tn_docker_release_tag_for testnet "${GH}@sha256:${D64}" 2>/dev/null)" || rc=$?
check "token kept: the release tag found" "0 v0.17.0-adiri" "$rc $out"
check "token kept: four lookups (a listing, three manifests)" "4" "$(grep -c 'ghcr.io/v2/' "$REC/curl.log")"
check "token kept: one token call for them" "1" "$(grep -c 'ghcr.io/token' "$REC/curl.log")"
check "token kept: every lookup carried it" "0" "$(grep 'ghcr.io/v2/' "$REC/curl.log" | grep -vc 'Bearer_TOK123')"
: > "$REC/curl.log"
for t in v0.17.0-adiri v0.17.1-adiri v0.17.2-adiri v0.17.0-adiri; do
    tn_registry_digest "$GH" "$t" >> "$REC/digests" 2>/dev/null
done
check "token kept in this shell: four digests" "4" "$(grep -c '^sha256:' "$REC/digests")"
check "token kept in this shell: one token call" "1" "$(grep -c 'ghcr.io/token' "$REC/curl.log")"
tn_registry_digest "$R" v0.17.0-adiri >/dev/null 2>&1
tn_registry_digest "$GH" v0.17.0-adiri >/dev/null 2>&1
check "token kept: a registry that wants none leaves it in place" "1" "$(grep -c 'ghcr.io/token' "$REC/curl.log")"
_TN_REGISTRY_TOKEN_AT=$((SECONDS - 121))
tn_registry_digest "$GH" v0.17.0-adiri >/dev/null 2>&1
check "token kept: fetched again after 120 s" "2" "$(grep -c 'ghcr.io/token' "$REC/curl.log")"
touch "$REC/token.down"
_TN_REGISTRY_TOKEN_AT=$((SECONDS - 121))
rc=0; tn_registry_digest "$GH" v0.17.0-adiri >/dev/null 2>&1 || rc=$?
check_rc "token kept: an expired token is not used when the registry gives none" 1 "$rc"
check "token kept: no lookup without a token" "6" "$(grep -c 'ghcr.io/v2/' "$REC/curl.log")"
rm -f "$REC/token.down" "$REC/digests" "$REC/ghdigest.v0.17.1-adiri" "$REC/ghdigest.v0.17.2-adiri"
_TN_REGISTRY_TOKEN_REPO=""
rm -f "$REC/ghtags.json" "$REC/ghdigest.v0.17.0-adiri"

# The Releases API: drafts skipped, prereleases count on testnet only, finals only.
cat > "$REC/releases.full.json" <<'JSON'
[
  {
    "url": "https://api.github.com/repos/Telcoin-Association/telcoin-network/releases/9",
    "author": { "login": "grantkee", "type": "User" },
    "tag_name": "v0.20.0-adiri",
    "name": "draft",
    "draft": true,
    "prerelease": true,
    "assets": [],
    "body": "mentions \"tag_name\": \"v9.9.9-adiri\", \"draft\": false"
  },
  {
    "tag_name": "v0.19.0-adiri-rc1",
    "draft": false,
    "prerelease": true,
    "assets": [ { "name": "SHA256SUMS", "state": "uploaded", "uploader": { "login": "x" } } ]
  },
  {"tag_name":"v0.18.0-adiri","draft":false,"prerelease":true,"assets":[]},
  {"tag_name":"v0.9.0-adiri","draft":false,"prerelease":true},
  {"tag_name":"v1.1.0","draft":false,"prerelease":true},
  {"tag_name":"v1.0.0","draft":false,"prerelease":false},
  {"tag_name":"v0.18.0-adiri-hotfix","draft":false,"prerelease":true}
]
JSON
cp "$REC/releases.full.json" "$REC/releases.json"
rc=0; out="$(tn_release_newest_tag testnet 2>/dev/null)" || rc=$?
check "newest testnet release: a prerelease final, not the draft or the newer rc" "0 v0.18.0-adiri" "$rc $out"
rc=0; out="$(tn_release_newest_tag mainnet 2>/dev/null)" || rc=$?
check "newest mainnet release: the final that is not a prerelease" "0 v1.0.0" "$rc $out"
rc=0; out="$(tn_release_newest_tag devnet 2>/dev/null)" || rc=$?
check "newest devnet release: none" "1 " "$rc $out"
printf '[{"tag_name":"v1.1.0","draft":false,"prerelease":true}]' > "$REC/releases.json"
rc=0; out="$(tn_release_newest_tag testnet 2>"$T/err")" || rc=$?
check "no testnet release yet: rc 1" "1 " "$rc $out"
check_has "no release yet: said on stderr" "1" "$(grep -c 'No testnet release is published' "$T/err")"
touch "$REC/api.down"
rc=0; out="$(tn_release_newest_tag testnet 2>"$T/err")" || rc=$?
check "API unreachable: rc 1" "1 " "$rc $out"
check_has "API unreachable: said on stderr" "1" "$(grep -c 'Cannot read the telcoin-network releases' "$T/err")"
rm -f "$REC/api.down"

# latest_docker_image: no release yet -> the legacy listing (newest final, an rc
# skipped) by its registry digest, with a warning.
printf '[]' > "$REC/releases.json"
rc=0; out="$(latest_docker_image testnet 2>"$T/err")" || rc=$?
check "latest, no release yet: the legacy repository's newest final by digest" "0 ${R}@sha256:${D64}" "$rc $out"
check_has "latest, no release yet: warns no signed release confirms it" "1" "$(grep -c 'legacy repository.*no signed release confirms it' "$T/err")"
check_has "latest asked the manifest of v0.17.0-adiri" "1 - https://us-docker.pkg.dev/v2/telcoin-network/tn-public/adiri/manifests/v0.17.0-adiri" "$(cat "$REC/curl.log")"
rc=0; out="$(NETWORK=testnet latest_docker_image 2>/dev/null)" || rc=$?
check "latest: NETWORK global" "${R}@sha256:${D64}" "$out"
rm -f "$REC/digest.v0.17.0-adiri"
rc=0; out="$(latest_docker_image testnet 2>/dev/null)" || rc=$?
check "latest: no digest -> pinned default" "0 $DEFAULT_DOCKER_IMAGE" "$rc $out"
touch "$REC/down"
rc=0; out="$(latest_docker_image testnet 2>/dev/null)" || rc=$?
check "latest: GitHub and the registry down -> pinned default" "0 $DEFAULT_DOCKER_IMAGE" "$rc $out"
rm -f "$REC/down"
printf 'sha256:%s\n' "$D64" > "$REC/digest.v0.17.0-adiri"
touch "$REC/api.down"
rc=0; out="$(latest_docker_image testnet 2>"$T/err")" || rc=$?
check "latest, API unreachable, testnet: the legacy fallback" "0 ${R}@sha256:${D64}" "$rc $out"
check_has "latest, API unreachable: its own warning" "1" "$(grep -c 'Cannot read the telcoin-network releases' "$T/err")"
: > "$REC/curl.log"
rc=0; out="$(latest_docker_image mainnet 2>/dev/null)" || rc=$?
check "latest, API unreachable, mainnet: rc 1, nothing" "1 " "$rc $out"
check "latest, mainnet: no registry asked" "0" "$(grep -vc 'api.github.com' "$REC/curl.log")"
rm -f "$REC/api.down"
printf '[]' > "$REC/releases.json"
rc=0; out="$(latest_docker_image mainnet 2>/dev/null)" || rc=$?
check "latest, no mainnet release: rc 1, nothing" "1 " "$rc $out"
# Devnet has no releases: no newest image, and neither GitHub nor a registry asked.
cp "$REC/releases.full.json" "$REC/releases.json"
: > "$REC/curl.log"
rc=0; out="$(latest_docker_image devnet 2>/dev/null)" || rc=$?
check "latest, devnet: rc 1, nothing" "1 " "$rc $out"
check "latest, devnet: nothing asked" "" "$(cat "$REC/curl.log")"
printf '[]' > "$REC/releases.json"
# A release is listed but publishes no SHA256SUMS.asc: no verified image digest,
# so testnet takes the pinned default with the reason, mainnet gets rc 1, and the
# registry is never asked for that release. With gpg, a throwaway key makes the
# keyring readable and the missing signature is the reason; without gpg
# (bash:3.2) the missing gpg is, which ends the same way.
cp "$REC/releases.full.json" "$REC/releases.json"
mkdir -p "$REC/dl/v0.18.0-adiri" "$REC/dl/v1.0.0" "$T/keys2"
printf '%s  IMAGE_DIGEST\n' "$D64" > "$REC/dl/v0.18.0-adiri/SHA256SUMS"
cp "$REC/dl/v0.18.0-adiri/SHA256SUMS" "$REC/dl/v1.0.0/SHA256SUMS"
why="gpg is not installed"
if command -v gpg >/dev/null 2>&1 && command -v gpgv >/dev/null 2>&1; then
    mkdir -m 0700 "$T/gnupg"
    GNUPGHOME="$T/gnupg" gpg --batch --no-tty --quiet --pinentry-mode loopback --passphrase '' \
        --quick-gen-key 'Release A <a@example.invalid>' ed25519 sign 1y 2>/dev/null
    GNUPGHOME="$T/gnupg" gpg --batch --no-tty --quiet --armor --export a@example.invalid > "$T/keys2/a.asc" 2>/dev/null
    if [[ -s "$T/keys2/a.asc" ]]; then
        why="Could not download https://github.com/Telcoin-Association/telcoin-network/releases/download/v0.18.0-adiri/SHA256SUMS.asc"
    else
        why="No release signing key"
    fi
fi
mkdir -m 0700 "$T/stage"
export TN_RELEASE_STAGING_DIR="$T/stage"
TN_RELEASE_KEYS_DIR="$T/keys2"
: > "$REC/curl.log"
rc=0; out="$(latest_docker_image testnet 2>"$T/err")" || rc=$?
check "latest, newest release unsigned, testnet: the pinned default" "0 $DEFAULT_DOCKER_IMAGE" "$rc $out"
check_has "latest, newest release unsigned: the reason (${why%% http*})" "1" "$(grep -cF "$why" "$T/err")"
check_has "latest, newest release unsigned: no verified digest, registry not asked" "1" \
    "$(grep -c 'v0.18.0-adiri gave no verified image digest.*registry is not asked.*offering' "$T/err")"
check "latest, newest release unsigned: no registry call" "0" "$(grep -c 'ghcr.io\|pkg.dev' "$REC/curl.log")"
: > "$REC/curl.log"
rc=0; out="$(latest_docker_image mainnet 2>"$T/err")" || rc=$?
check "latest, newest mainnet release unsigned: rc 1, nothing" "1 " "$rc $out"
check_has "latest, newest mainnet release unsigned: only from a signed release" "1" \
    "$(grep -c 'v1.0.0 gave no verified image digest.*taken only from a signed release' "$T/err")"
check "latest, newest mainnet release unsigned: no registry call" "0" "$(grep -c 'ghcr.io\|pkg.dev' "$REC/curl.log")"
check "latest, newest release unsigned: nothing left in staging" "" "$(ls -A "$T/stage")"
TN_RELEASE_KEYS_DIR="$T/keys"
unset TN_RELEASE_STAGING_DIR
# A release exists: its signed IMAGE_DIGEST wins, the registry is not asked.
: > "$T/keys/k.asc"
SIGNED="${GH}@sha256:$(printf '%s' "$D64" | tr 0 f)"
tn_fetch_release_image() { printf '%s %s\n' "$1" "$2" >> "$REC/fetch.log"; printf '%s\n' "$SIGNED"; }
: > "$REC/curl.log"; : > "$REC/fetch.log"
rc=0; out="$(latest_docker_image testnet 2>/dev/null)" || rc=$?
check "latest, release published: the signed IMAGE_DIGEST" "0 ${SIGNED}" "$rc $out"
check "latest, release published: read from the newest final release" "v0.18.0-adiri testnet" "$(cat "$REC/fetch.log")"
check "latest, release published: no registry asked" "0" "$(grep -c 'manifests\|tags/list' "$REC/curl.log")"
: > "$REC/fetch.log"
rc=0; out="$(latest_docker_image mainnet 2>/dev/null)" || rc=$?
check "latest, mainnet release published: the signed IMAGE_DIGEST of v1.0.0" "0 ${SIGNED} v1.0.0 mainnet" "$rc $out $(cat "$REC/fetch.log")"
# The newest release fails verification (rc 1): nothing is offered on either network,
# never the registry and never the pinned default.
tn_fetch_release_image() { return 1; }
: > "$REC/curl.log"
rc=0; out="$(latest_docker_image testnet 2>"$T/err")" || rc=$?
check "latest, newest release refused, testnet: rc 1, nothing" "1 " "$rc $out"
check_has "latest, newest release refused: said" "1" "$(grep -c 'v0.18.0-adiri did not verify (see above); no image is offered' "$T/err")"
check "latest, newest release refused: not the pinned default" "0" "$(grep -c "$DEFAULT_DOCKER_IMAGE" "$T/err")"
rc=0; out="$(latest_docker_image mainnet 2>/dev/null)" || rc=$?
check "latest, newest mainnet release refused: rc 1, nothing" "1 " "$rc $out"
check "latest, newest release refused: no registry call" "0" "$(grep -c 'ghcr.io\|pkg.dev' "$REC/curl.log")"
unset -f tn_fetch_release_image
rm -f "$T/keys/k.asc"
printf '[]' > "$REC/releases.json"
printf 'sha256:%s\n' "$D64" > "$REC/digest.v0.16.0-adiri"
rc=0; out="$(tn_registry_digest "$R" v0.16.0-adiri)" || rc=$?
check "registry digest (CRLF header)" "sha256:${D64}" "$out"
printf 'sha256:short\n' > "$REC/digest.v0.16.0-adiri"
rc=0; out="$(tn_registry_digest "$R" v0.16.0-adiri)" || rc=$?
check_rc "registry digest malformed refused" 1 "$rc"

# --- tn_docker_release_tag_for: the release tag a digest belongs to ---------------------
D2="fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210"
printf 'sha256:%s\n' "$D64" > "$REC/digest.v0.16.0-adiri"
printf 'sha256:%s\n' "$D2" > "$REC/digest.v0.17.0-adiri"
out="$(NETWORK=testnet tn_docker_release_tag_for testnet "${R}@sha256:${D64}" 2>/dev/null)"
check "tag for a digest: older release found" "v0.16.0-adiri" "$out"
out="$(tn_docker_release_tag_for testnet "${R}@sha256:${D2}" 2>/dev/null)"
check "tag for a digest: newest release found" "v0.17.0-adiri" "$out"
rc=0; out="$(tn_docker_release_tag_for testnet "${R}@sha256:$(printf '%064d' 7)" 2>/dev/null)" || rc=$?
check "tag for a digest: no release names it" "1 " "$rc $out"
out="$(tn_docker_release_tag_for testnet "$DEFAULT_DOCKER_IMAGE" 2>/dev/null)"
check "tag for a digest: the pinned default" "$DEFAULT_DOCKER_TAG" "$out"
rc=0; out="$(tn_docker_release_tag_for testnet "evil.example/adiri@sha256:${D2}" 2>/dev/null)" || rc=$?
check "tag for a digest: other repository refused" "1 " "$rc $out"
out="$(tn_docker_release_tag_for testnet "${R}@sha256:$(printf '%s' "$D64" | tr 0 c)" 2>/dev/null)"
check "tag for a digest: a release candidate's digest names the rc" "v0.18.0-adiri-rc1" "$out"
rc=0; out="$(tn_registry_digest "$R" 'v1;x')" || rc=$?
check_rc "registry digest odd tag refused" 1 "$rc"

# --- tn_docker_local_digest (docker shim) -------------------------------------------------
cat > "$T/bin/docker" <<'SH'
#!/bin/sh
[ "$1 $2" = "image inspect" ] || exit 1
eval "img=\${$#}"
[ -f "$REC/local.$(printf '%s' "$img" | tr '/:@' '___')" ] || exit 1
cat "$REC/local.$(printf '%s' "$img" | tr '/:@' '___')"
SH
chmod 0755 "$T/bin/docker"
printf 'other.example/x@sha256:%s\n%s@sha256:%s\n' "$D64" "$R" "$D64" > "$REC/local.$(printf '%s' "${R}:v0.16.0-adiri" | tr '/:@' '___')"
rc=0; out="$(tn_docker_local_digest "${R}:v0.16.0-adiri")" || rc=$?
check_rc "local digest of a tag" 0 "$rc"
check "local digest picks the repository's entry" "${R}@sha256:${D64}" "$out"
rc=0; out="$(tn_docker_local_digest "${R}:v0.15.0-adiri")" || rc=$?
check_rc "local digest: image not held" 1 "$rc"
rc=0; out="$(tn_docker_local_digest "${R}@sha256:${D64}")" || rc=$?
check "local digest: digest passes through" "${R}@sha256:${D64}" "$out"
rc=0; out="$(tn_docker_local_digest "-x:y")" || rc=$?
check_rc "local digest: leading dash refused" 1 "$rc"


# --- tn_docker_image_for_tag / tn_docker_resolve_ref / tn_docker_holds_digest ----------
# The registry digest of v0.17.0-adiri; the signed-release path is shimmed below.
printf 'sha256:%s\n' "$D64" > "$REC/digest.v0.17.0-adiri"
rc=0; out="$(tn_docker_image_for_tag testnet v0.17.0-adiri 2>"$T/err")" || rc=$?
check "for_tag, no release key, testnet: the registry digest" "0 ${R}@sha256:${D64}" "$rc $out"
check_has "for_tag, no release key: warns that no signed release confirms it" "1" "$(grep -c 'no signed release confirms' "$T/err")"
rc=0; out="$(tn_docker_image_for_tag testnet v0.17.0-adiri-hotfix 2>/dev/null)" || rc=$?
check "for_tag: a non-release tag is rc 3" "3 " "$rc $out"
rc=0; out="$(tn_docker_image_for_tag mainnet v1.0.0 2>"$T/err")" || rc=$?
check_rc "for_tag: mainnet without a release key refused" 1 "$rc"
check_has "for_tag, mainnet: only from a signed release" "1" "$(grep -c 'taken only from a signed release' "$T/err")"
printf 'sha256:%s\n' "$D2" > "$REC/ghdigest.v0.17.5-adiri"
rc=0; out="$(tn_docker_image_for_tag testnet v0.17.5-adiri 2>/dev/null)" || rc=$?
check "for_tag, no release key, testnet: ghcr's digest first" "0 ${GH}@sha256:${D2}" "$rc $out"
rm -f "$REC/ghdigest.v0.17.5-adiri"
rc=0; out="$(tn_docker_image_for_tag mainnet v1.0.0-rc1 2>"$T/err")" || rc=$?
check "for_tag: a mainnet release candidate is rc 3" "3 " "$rc $out"
check_has "for_tag: the refusal names the grammar" "1" "$(grep -c 'release candidates are testnet only' "$T/err")"
printf 'sha256:%s\n' "$D2" > "$REC/digest.v0.17.0-adiri-rc2"
rc=0; out="$(tn_docker_image_for_tag testnet v0.17.0-adiri-rc2 2>/dev/null)" || rc=$?
check "for_tag: a named testnet release candidate resolves" "0 ${R}@sha256:${D2}" "$rc $out"
: > "$T/keys/k.asc"
FETCH_RC=0
tn_fetch_release_image() { [[ "$FETCH_RC" -eq 0 ]] || return "$FETCH_RC"; printf '%s@sha256:%s\n' "$R" "$D64" | tr 0 f; }
rc=0; out="$(tn_docker_image_for_tag testnet v0.17.0-adiri 2>/dev/null)" || rc=$?
check "for_tag, release key: the signed release's digest wins" "0 $(printf '%s@sha256:%s' "$R" "$D64" | tr 0 f)" "$rc $out"
FETCH_RC=2
rc=0; out="$(tn_docker_image_for_tag testnet v0.17.0-adiri 2>/dev/null)" || rc=$?
check "for_tag: no signed release published (rc 2), testnet: registry digest" "0 ${R}@sha256:${D64}" "$rc $out"
FETCH_RC=1
rc=0; out="$(tn_docker_image_for_tag testnet v0.17.0-adiri 2>/dev/null)" || rc=$?
check "for_tag: a release that fails verification is never replaced" "1 " "$rc $out"
FETCH_RC=0
# Devnet has no signed releases: a devnet tag names no image and is refused
# before any release is fetched or any registry asked, with a release key present;
# a tag of another form is not a devnet tag (rc 3).
: > "$REC/curl.log"; : > "$REC/fetch.log"
tn_fetch_release_image() { printf 'fetch %s %s\n' "$1" "$2" >> "$REC/fetch.log"; printf '%s@sha256:%s\n' "$R" "$D64"; }
rc=0; out="$(tn_docker_image_for_tag devnet v0.2.0-devnet 2>"$T/err")" || rc=$?
check "for_tag, devnet: a devnet tag refused (rc 1)" "1 " "$rc $out"
check_has "for_tag, devnet: says to give the image by digest" "1" "$(grep -c 'Devnet has no signed releases, so v0.2.0-devnet names no image: give the devnet image by digest' "$T/err")"
check "for_tag, devnet: no release fetched" "" "$(cat "$REC/fetch.log")"
check "for_tag, devnet: no registry call" "" "$(cat "$REC/curl.log")"
rc=0; out="$(tn_docker_image_for_tag devnet v0.16.0-adiri 2>/dev/null)" || rc=$?
check "for_tag, devnet: a testnet release tag is rc 3" "3 " "$rc $out"
rc=0; out="$(tn_docker_image_for_tag devnet main-0123abc 2>/dev/null)" || rc=$?
check "for_tag, devnet: main-<sha> is rc 3" "3 " "$rc $out"
check "for_tag, devnet: still nothing fetched" "" "$(cat "$REC/fetch.log")"
rm -f "$T/keys/k.asc"
unset -f tn_fetch_release_image

res() {  # res NAME ARG EXPECTED-RC EXPECTED-OUT
    local rc=0 o
    o="$(tn_docker_resolve_ref testnet "$2" 2>/dev/null)" || rc=$?
    check "$1" "$3 $4" "$rc $o"
}
res "resolve: bare release tag" v0.17.0-adiri 0 "${R}@sha256:${D64} v0.17.0-adiri"
res "resolve: release tag on the network repository" "${R}:v0.17.0-adiri" 0 "${R}@sha256:${D64} v0.17.0-adiri"
res "resolve: digest taken as given, no tag" "${R}@sha256:${D64}" 0 "${R}@sha256:${D64} "
res "resolve: latest refused" "${R}:latest" 1 ""
res "resolve: bare latest refused" latest 1 ""
res "resolve: hot-patch tag refused" v0.17.1-adiri-hotfix 1 ""
res "resolve: a named release candidate" v0.17.0-adiri-rc2 0 "${R}@sha256:${D2} v0.17.0-adiri-rc2"
res "resolve: other repository by digest refused" "docker.io/library/busybox@sha256:${D64}" 1 ""
res "resolve: other repository by tag refused" "docker.io/library/busybox:v0.17.0-adiri" 1 ""
res "resolve: leading dash refused" "-v0.17.0-adiri" 1 ""
res "resolve: short digest refused" "${R}@sha256:abc" 1 ""
res "resolve: the release workflow's repository by digest taken as given" "${GH}@sha256:${D64}" 0 "${GH}@sha256:${D64} "
res "resolve: release tag on the release workflow's repository" "${GH}:v0.17.0-adiri" 0 "${R}@sha256:${D64} v0.17.0-adiri"
res "resolve: a third repository by digest refused" "ghcr.io/someone-else/telcoin-network@sha256:${D64}" 1 ""
# The old single package is never pulled from, and the mainnet package is not
# testnet's.
res "resolve: the old single package by digest refused" "${GL}@sha256:${D64}" 1 ""
res "resolve: a release tag on the old single package refused" "${GL}:v0.17.0-adiri" 1 ""
res "resolve: the mainnet package by digest refused on testnet" "${GM}@sha256:${D64}" 1 ""
res "resolve: a mainnet release tag on the mainnet package refused on testnet" "${GM}:v0.1.0" 1 ""
res "resolve: a plain tag refused on testnet" v0.1.0 1 ""
rc=0; o="$(tn_docker_resolve_ref testnet "${GL}@sha256:${D64}" 2>"$T/err")" || rc=$?
check_has "resolve: the old package refusal says no release was published there" "1" "$(grep -c "No release was ever published to ${GL}, so no image is pulled from it; testnet images come from ${GH}. Give the testnet release tag instead." "$T/err")"
# Mainnet: the testnet package, the old package and an -adiri tag are refused
# before any release is fetched.
mresx() {  # mresx NAME ARG
    local rc=0 o
    o="$(tn_docker_resolve_ref mainnet "$2" 2>/dev/null)" || rc=$?
    check "$1" "1 " "$rc $o"
}
mresx "resolve, mainnet: a testnet release on the testnet package refused" "${GH}:v0.17.0-adiri"
mresx "resolve, mainnet: the testnet package by digest refused" "${GH}@sha256:${D64}"
mresx "resolve, mainnet: the old single package by digest refused" "${GL}@sha256:${D64}"
mresx "resolve, mainnet: a release tag on the old single package refused" "${GL}:v1.0.0"
mresx "resolve, mainnet: a bare -adiri tag refused" v0.17.0-adiri
unset -f mresx
# Mainnet, a digest given alone: only the signed release says which digest is a
# mainnet release image, so the digest is taken only when .node-meta records a
# mainnet release tag for it (a real .node-meta under TN_ROOT_PREFIX here, read by
# the library's own meta_get).
MAINNET_DIGEST_OFF="Image refused: on mainnet an image is named by its release tag, so the digest comes from the signed release; sha256:${D64} is not the image of a mainnet release this node has installed. Give the mainnet release tag instead."
mkdir -p "$T/mroot/etc/telcoin"
TN_ROOT_PREFIX="$T/mroot"
mmeta() { printf '%s\n' "NETWORK=mainnet" "$@" > "$T/mroot/etc/telcoin/.node-meta"; }
mres() {  # mres NAME EXPECTED-RC EXPECTED-OUT [REASON]
    local rc=0 o
    o="$(tn_docker_resolve_ref mainnet "${GM}@sha256:${D64}" 2>"$T/err")" || rc=$?
    check "$1" "$2 $3" "$rc $o"
    if [[ -n "${4:-}" ]]; then
        check_has "$1: the reason on stderr" "$(printf '%s' "$4" | sed 's/^/  [WARN] /')" "$(sed 's/\x1b\[[0-9;]*m//g' "$T/err")"
    fi
}
mmeta
mres "resolve, mainnet: a digest with nothing recorded refused" 1 "" "$MAINNET_DIGEST_OFF"
mmeta "DOCKER_IMAGE_DIGEST=sha256:${D64}" "RELEASE_TAG=v1.0.0"
mres "resolve, mainnet: a digest recorded as v1.0.0 taken, with its tag" 0 "${GM}@sha256:${D64} v1.0.0"
check "resolve, mainnet: a recorded release: no warning" "" "$(cat "$T/err")"
mmeta "DOCKER_IMAGE_DIGEST=sha256:$(printf '%s' "$D64" | tr 0 e)" "RELEASE_TAG=v1.0.0"
mres "resolve, mainnet: another digest recorded: refused" 1 "" "$MAINNET_DIGEST_OFF"
mmeta "DOCKER_IMAGE_DIGEST=sha256:${D64}" "RELEASE_TAG=v0.16.0-adiri"
mres "resolve, mainnet: a testnet tag recorded for it: refused" 1 "" "$MAINNET_DIGEST_OFF"
mmeta "DOCKER_IMAGE_DIGEST=sha256:${D64}"
mres "resolve, mainnet: the digest recorded without a release tag: refused" 1 "" "$MAINNET_DIGEST_OFF"
# Testnet keeps taking the same digest alone, with the warning, against the same file.
printf 'NETWORK=testnet\n' > "$T/mroot/etc/telcoin/.node-meta"
rc=0; o="$(tn_docker_resolve_ref testnet "${GH}@sha256:${D64}" 2>"$T/err")" || rc=$?
check "resolve, testnet: a digest with nothing recorded still taken" "0 ${GH}@sha256:${D64} " "$rc $o"
check "resolve, testnet: still warns the checks cannot be applied" yes "$(grep -q 'digest alone.*cannot be applied' "$T/err" && echo yes || echo no)"
TN_ROOT_PREFIX=""
unset -f mmeta mres
# A digest given alone: the release .node-meta records for that digest, else a
# warning that the downgrade and oldest-release checks cannot be applied.
META_DIGEST="" META_TAG=""
meta_get() {
    case "$1" in
        DOCKER_IMAGE_DIGEST) [[ -n "$META_DIGEST" ]] && printf '%s\n' "$META_DIGEST" ;;
        RELEASE_TAG) [[ -n "$META_TAG" ]] && printf '%s\n' "$META_TAG" ;;
        *) return 1 ;;
    esac
}
rc=0; o="$(tn_docker_resolve_ref testnet "${R}@sha256:${D64}" 2>"$T/err")" || rc=$?
check "resolve: digest alone, nothing recorded: no tag" "0 ${R}@sha256:${D64} " "$rc $o"
check "resolve: digest alone, nothing recorded: warns the checks cannot be applied" yes "$(grep -q 'digest alone.*cannot be applied' "$T/err" && echo yes || echo no)"
META_DIGEST="sha256:${D64}" META_TAG="v0.16.0-adiri"
rc=0; o="$(tn_docker_resolve_ref testnet "${R}@sha256:${D64}" 2>"$T/err")" || rc=$?
check "resolve: digest alone, recorded for this digest: the recorded release" "0 ${R}@sha256:${D64} v0.16.0-adiri" "$rc $o"
check "resolve: recorded release: no warning" "" "$(cat "$T/err")"
rc=0; o="$(tn_docker_resolve_ref testnet "${R}@sha256:$(printf '%s' "$D64" | tr 0 e)" 2>/dev/null)" || rc=$?
check "resolve: digest alone, another digest recorded: no tag" "0 ${R}@sha256:$(printf '%s' "$D64" | tr 0 e) " "$rc $o"
META_TAG="main"
rc=0; o="$(tn_docker_resolve_ref testnet "${R}@sha256:${D64}" 2>/dev/null)" || rc=$?
check "resolve: a recorded tag that is not a release tag is not used" "0 ${R}@sha256:${D64} " "$rc $o"
# Devnet: digests only, from TN_DEVNET_IMAGE_REPOS. A devnet tag names no image
# (devnet has no signed releases); a testnet tag is no devnet tag.
META_DIGEST="" META_TAG=""
resd() {  # resd NAME ARG EXPECTED-RC EXPECTED-OUT
    local rc=0 o
    o="$(tn_docker_resolve_ref devnet "$2" 2>/dev/null)" || rc=$?
    check "$1" "$3 $4" "$rc $o"
}
resd "resolve, devnet: the legacy repository by digest" "${R}@sha256:${D64}" 0 "${R}@sha256:${D64} "
resd "resolve, devnet: the old single package by digest refused" "${GL}@sha256:${D64}" 1 ""
resd "resolve, devnet: the testnet package by digest refused" "${GH}@sha256:${D64}" 1 ""
resd "resolve, devnet: the mainnet package by digest refused" "${GM}@sha256:${D64}" 1 ""
resd "resolve, devnet: another repository by digest refused" "docker.io/library/busybox@sha256:${D64}" 1 ""
resd "resolve, devnet: a third ghcr.io repository refused" "ghcr.io/someone-else/telcoin-network@sha256:${D64}" 1 ""
resd "resolve, devnet: a bare devnet tag refused" v0.2.0-devnet 1 ""
resd "resolve, devnet: a devnet tag on the devnet repository refused" "${R}:v0.2.0-devnet" 1 ""
resd "resolve, devnet: a testnet release tag refused" v0.17.0-adiri 1 ""
resd "resolve, devnet: main-<sha> refused" main-0123abc 1 ""
resd "resolve, devnet: latest refused" "${R}:latest" 1 ""
resd "resolve, devnet: short digest refused" "${R}@sha256:abc" 1 ""
resd "resolve, devnet: leading dash refused" "-${R}@sha256:${D64}" 1 ""
rc=0; o="$(tn_docker_resolve_ref devnet "${R}@sha256:${D64}" 2>"$T/err")" || rc=$?
check_has "resolve, devnet: digest alone: the devnet warning" "1" "$(grep -c 'as every devnet image is, so the release it holds is unknown: the downgrade check cannot be applied' "$T/err")"
rc=0; o="$(tn_docker_resolve_ref devnet "docker.io/library/busybox@sha256:${D64}" 2>"$T/err")" || rc=$?
check_has "resolve, devnet: a refusal names the repositories a devnet pull takes" "1" "$(grep -cF "from one of these repositories: ${R}." "$T/err")"
rc=0; o="$(tn_docker_resolve_ref devnet "${GL}@sha256:${D64}" 2>"$T/err")" || rc=$?
check_has "resolve, devnet: the old package refusal names the devnet repository" "1" "$(grep -cF "No release was ever published to ${GL}, so no image is pulled from it; give the devnet image by digest, ${R}@sha256:<digest>." "$T/err")"
META_DIGEST="sha256:${D64}" META_TAG="v0.2.0-devnet"
resd "resolve, devnet: digest alone, a devnet tag recorded for it: that tag" "${R}@sha256:${D64}" 0 "${R}@sha256:${D64} v0.2.0-devnet"
META_TAG="v0.16.0-adiri"
resd "resolve, devnet: a recorded testnet tag is not used" "${R}@sha256:${D64}" 0 "${R}@sha256:${D64} "
# tn_docker_release_tag_for on devnet: the .node-meta record only. The registry is
# never asked: its lookups are stubbed to fail loudly.
loud_tag_for() {  # loud_tag_for IMAGE
    tn_registry_tags() { printf 'tn_registry_tags %s\n' "$*" >> "$REC/loud.log"; return 1; }
    tn_registry_digest() { printf 'tn_registry_digest %s\n' "$*" >> "$REC/loud.log"; return 1; }
    _tn_registry_auth() { printf '_tn_registry_auth %s\n' "$*" >> "$REC/loud.log"; return 1; }
    tn_docker_release_tag_for devnet "$1"
}
: > "$REC/curl.log"; : > "$REC/loud.log"
META_DIGEST="" META_TAG=""
rc=0; out="$(loud_tag_for "${R}@sha256:${D64}" 2>&1)" || rc=$?
check "tag for a digest, devnet, nothing recorded: none" "1 " "$rc $out"
rc=0; out="$(loud_tag_for "$DEFAULT_DOCKER_IMAGE" 2>&1)" || rc=$?
check "tag for a digest, devnet: the pinned testnet default names no devnet release" "1 " "$rc $out"
META_DIGEST="sha256:${D64}" META_TAG="v0.2.0-devnet"
rc=0; out="$(loud_tag_for "${GL}@sha256:${D64}" 2>&1)" || rc=$?
check "tag for a digest, devnet: the .node-meta record" "0 v0.2.0-devnet" "$rc $out"
check "tag for a digest, devnet: the registry lookups never called" "" "$(cat "$REC/loud.log")"
check "tag for a digest, devnet: no registry call" "" "$(cat "$REC/curl.log")"
unset -f resd loud_tag_for
unset -f meta_get
rc=0; o="$(tn_docker_resolve_ref mainnet "${R}@sha256:${D64}" 2>/dev/null)" || rc=$?
check "resolve: mainnet refuses the legacy testnet repository" "1 " "$rc $o"
for repo in "$R" "$GL" "$GH" "$GM" "ghcr.io/someone-else/telcoin-network"; do
    rc=0; tn_docker_repo_ok testnet "$repo" || rc=$?
    check "repo_ok testnet ${repo}" "$([[ "$repo" == *someone-else* || "$repo" == "$GM" ]] && echo 1 || echo 0)" "$rc"
done
rc=0; tn_docker_repo_ok mainnet "$GM" || rc=$?
check_rc "repo_ok mainnet: the mainnet package" 0 "$rc"
for repo in "$R" "$GL" "$GH" "${GM}-x" "evil.example/${GM}"; do
    rc=0; tn_docker_repo_ok mainnet "$repo" || rc=$?
    check_rc "repo_ok mainnet: ${repo} refused" 1 "$rc"
done
for repo in "$R" "$GL" "$GH" "$GM" "ghcr.io/someone-else/telcoin-network" "evil.example/adiri"; do
    rc=0; tn_docker_repo_ok devnet "$repo" || rc=$?
    check "repo_ok devnet ${repo}" "$([[ "$repo" == "$R" || "$repo" == "$GL" ]] && echo 0 || echo 1)" "$rc"
done
for n in testnet devnet mainnet; do
    rc=0; tn_docker_repo_ok "$n" "$GH $R" || rc=$?
    check_rc "repo_ok ${n}: two repositories in one word refused" 1 "$rc"
    rc=0; tn_docker_repo_ok "$n" "$(printf '%s\t' "$GH")" || rc=$?
    check_rc "repo_ok ${n}: a trailing tab refused" 1 "$rc"
    rc=0; tn_docker_repo_ok "$n" "" || rc=$?
    check_rc "repo_ok ${n}: empty refused" 1 "$rc"
done
rc=0; tn_docker_repo_ok foo "$GH" || rc=$?
check_rc "repo_ok foo: a network without a repository refused" 1 "$rc"
printf '%s@sha256:%s\n' "$R" "$D64" > "$REC/local.$(printf '%s' "${R}@sha256:${D64}" | tr '/:@' '___')"
printf '%s@sha256:%s\n' "$R" "$D64" > "$REC/local.$(printf '%s' "${R}@sha256:$(printf '%s' "$D64" | tr 0 e)" | tr '/:@' '___')"
rc=0; tn_docker_holds_digest "${R}@sha256:${D64}" || rc=$?
check_rc "holds digest: listed in RepoDigests" 0 "$rc"
rc=0; tn_docker_holds_digest "${R}@sha256:$(printf '%s' "$D64" | tr 0 e)" || rc=$?
check_rc "holds digest: another digest refused" 1 "$rc"
rc=0; tn_docker_holds_digest "${R}:v0.16.0-adiri" || rc=$?
check_rc "holds digest: a tag is not a digest" 1 "$rc"

# --- tn_docker_image_network_ok (docker shim) ------------------------------------------
# docker run logs its argv to $REC/run.log and prints $REC/ver.<image> (the image
# with / : @ as _), or exits 125 when there is none, as for an image Docker does
# not hold.
cat > "$T/bin/docker" <<'SH'
#!/bin/sh
[ "$1" = run ] || exit 1
printf '%s\n' "$*" >> "$REC/run.log"
img=""
prev=""
for a in "$@"; do
    [ "$a" = "--version" ] && img="$prev"
    prev="$a"
done
f="$REC/ver.$(printf '%s' "$img" | tr '/:@' '___')"
[ -f "$f" ] || exit 125
cat "$f"
SH
chmod 0755 "$T/bin/docker"
# ver IMAGE FEATURES... -- the canned --version of IMAGE: one Build Features line
# per FEATURES argument; none at all with no argument.
ver() {
    local img="$1" f feats
    shift
    f="$REC/ver.$(printf '%s' "$img" | tr '/:@' '___')"
    printf 'telcoin-network-cli Version: 0.17.0\nCommit SHA: abc1234\n' > "$f"
    for feats in "$@"; do
        printf 'Build Features: %s\n' "$feats" >> "$f"
    done
    printf 'Build Profile: maxperf\n' >> "$f"
}
inok() {  # inok NAME EXPECTED-RC NETWORK IMAGE -- the rc; the message in $T/err
    local rc=0
    tn_docker_image_network_ok "$3" "$4" 2>"$T/err" || rc=$?
    check_rc "$1" "$2" "$rc"
}
MI="${GM}@sha256:${D64}"
TI="${GH}@sha256:${D64}"
ver "$MI" ""
: > "$REC/run.log"
inok "features, mainnet: none listed, accepted" 0 mainnet "$MI"
check "features: one docker run" "1" "$(wc -l < "$REC/run.log" | tr -d ' ')"
check_has "features: run with no network, no capabilities, the release binary as entrypoint" \
    "run --rm --pull=never --network none --cap-drop ALL --security-opt no-new-privileges --read-only --entrypoint /usr/local/bin/telcoin ${MI} --version" "$(cat "$REC/run.log")"
check "features, mainnet accepted: nothing said" "" "$(cat "$T/err")"
ver "$MI" "adiri"
inok "features, mainnet: adiri refused" 1 mainnet "$MI"
check_has "features, mainnet: the refusal names the image, the features and the network" "1" \
    "$(grep -cF "Image refused: ${MI} was built with the features adiri, and a mainnet image has none, so it is not a mainnet image." "$T/err")"
ver "$MI" "faucet"
inok "features, mainnet: faucet refused" 1 mainnet "$MI"
ver "$MI" "adiri,faucet"
inok "features, mainnet: adiri and faucet refused" 1 mainnet "$MI"
check_has "features, mainnet: both features named" "1" "$(grep -cF "built with the features adiri, faucet, and a mainnet image has none" "$T/err")"
ver "$MI" "metrics"
inok "features, mainnet: any feature refused" 1 mainnet "$MI"
ver "$TI" "adiri"
inok "features, testnet: adiri accepted" 0 testnet "$TI"
ver "$TI" "adiri,faucet"
inok "features, testnet: adiri and faucet accepted" 0 testnet "$TI"
ver "$TI" ""
inok "features, testnet: none listed refused" 1 testnet "$TI"
check_has "features, testnet: the refusal says what a testnet image has" "1" \
    "$(grep -cF "Image refused: ${TI} was built with the features none, and a testnet image has adiri, and faucet at most, so it is not a testnet image." "$T/err")"
ver "$TI" "faucet"
inok "features, testnet: faucet without adiri refused" 1 testnet "$TI"
ver "$TI" "adiri,metrics"
inok "features, testnet: another feature beside adiri refused" 1 testnet "$TI"
ver "$TI"
inok "features: no Build Features line refused" 1 testnet "$TI"
check_has "features: the missing line is said" "1" "$(grep -cF "Image refused: ${TI} prints 0 \"Build Features:\" lines with --version, not one" "$T/err")"
ver "$MI" "" ""
inok "features: two Build Features lines refused" 1 mainnet "$MI"
check_has "features: the doubled line is said" "1" "$(grep -cF "prints 2 \"Build Features:\" lines" "$T/err")"
inok "features: an image docker cannot run refused" 1 testnet "${GH}@sha256:$(printf '%s' "$D64" | tr 0 9)"
check_has "features: the failed run is said, with docker's exit code" "1" "$(grep -cF "(docker run exited 125), so it is not used and nothing was changed" "$T/err")"
: > "$REC/run.log"
inok "features: devnet is not checked" 0 devnet "${R}@sha256:${D64}"
check "features, devnet: docker never ran" "" "$(cat "$REC/run.log")"
check_has "features, devnet: an info line says so" "1" "$(grep -cF "Devnet images are not checked for their build features" "$T/err")"
inok "features: a network without a rule refused" 1 foo "$TI"
inok "features: a tag refused before docker runs" 1 testnet "${GH}:v0.17.0-adiri"
inok "features: a leading dash refused" 1 testnet "-${TI}"
check "features: no docker run for the refusals before it" "" "$(cat "$REC/run.log")"
# The progress-fn gets the refusal as a warn.
say_rec() { printf '%s %s\n' "$1" "$2" >> "$REC/say.log"; }
: > "$REC/say.log"
ver "$MI" "adiri"
rc=0; tn_docker_image_network_ok mainnet "$MI" say_rec 2>/dev/null || rc=$?
check "features: the refusal goes to the progress-fn as a warn" "1 1" "$rc $(grep -c '^warn Image refused' "$REC/say.log")"
unset -f ver inok say_rec

finish
