#!/usr/bin/env bash
# =============================================================================
# tools/tests/docker_image_test.sh -- images by digest: tn_docker_image_allowed
# with the TN_DOCKER_REQUIRE_DIGEST default (1: tags refused) and with =0 (a
# release tag accepted, latest and other tags never); tn_docker_repo_for per
# network (ghcr for testnet and mainnet, devnet refused while unnamed); against a
# curl shim: the ghcr pull token on the tags and manifest calls (none for the
# legacy registry), tn_release_newest_tag over a Releases API answer (drafts,
# prereleases, an rc newer than the newest final, a mainnet final, no release,
# API unreachable), latest_docker_image (the signed IMAGE_DIGEST of the newest
# release without asking the registry; on testnet only, with no release or no
# API, the legacy repository's newest final, then the pinned default; nothing
# on mainnet); tn_docker_local_digest against a docker shim;
# tn_docker_image_for_tag (signed digest first, the registry's on testnet only
# when no signed release exists, never after a failed verification),
# tn_docker_resolve_ref and tn_docker_holds_digest.
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
allowed "devnet has no repository yet" 1 "${R}@sha256:${D64}" devnet
allowed "default image is allowed" 0 "$DEFAULT_DOCKER_IMAGE"
GH="ghcr.io/telcoin-association/telcoin-network"
check "TN_GHCR_IMAGE_REPO" "$GH" "$TN_GHCR_IMAGE_REPO"
check "GAR_IMAGE_BASE is the legacy repository" "$TN_TESTNET_LEGACY_IMAGE_REPO" "$GAR_IMAGE_BASE"
allowed "testnet: the release workflow's repository by digest accepted" 0 "${GH}@sha256:${D64}"
allowed "testnet: another ghcr.io repository refused" 1 "ghcr.io/someone-else/telcoin-network@sha256:${D64}"
allowed "testnet: a repository that only starts like an allowed one refused" 1 "${GH}-x@sha256:${D64}"
allowed "testnet: a repository that only ends like an allowed one refused" 1 "evil.example/${GH}@sha256:${D64}"
allowed "mainnet: the ghcr repository by digest accepted" 0 "${GH}@sha256:${D64}" mainnet
allowed "testnet: a tag on the release workflow's repository refused by default" 1 "${GH}:v0.16.0-adiri"
TN_DOCKER_REQUIRE_DIGEST=0
allowed "=0: release tag accepted" 0 "${R}:v0.16.0-adiri"
allowed "=0: latest refused" 1 "${R}:latest"
allowed "=0: devnet tag refused" 1 "${R}:v0.16.0-devnet"
allowed "=0: hot-patch tag refused" 1 "${R}:v0.16.0-adiri-hotfix1"
allowed "=0: mainnet-form tag refused on testnet" 1 "${R}:v0.16.0"
allowed "=0: digest still accepted" 0 "${R}@sha256:${D64}"
allowed "=0: release tag on the release workflow's repository accepted" 0 "${GH}:v0.16.0-adiri"
allowed "=0: release tag on another repository refused" 1 "evil.example/adiri:v0.16.0-adiri"
allowed "=0: a testnet release candidate accepted" 0 "${R}:v0.17.0-adiri-rc1"
allowed "=0: rc0 refused" 1 "${R}:v0.17.0-adiri-rc0"
TN_DOCKER_REQUIRE_DIGEST=1
allowed "=1: release tag refused" 1 "${R}:v0.16.0-adiri"
unset TN_DOCKER_REQUIRE_DIGEST
rc=0; validate_docker_image "${R}@sha256:${D64}" testnet || rc=$?
check_rc "validate_docker_image: digest" 0 "$rc"
rc=0; validate_docker_image "${R}:v0.16.0-adiri" testnet 2>/dev/null || rc=$?
check_rc "validate_docker_image: tag refused" 1 "$rc"

# --- tn_docker_repo_for --------------------------------------------------------------
rc=0; out="$(tn_docker_repo_for testnet 2>/dev/null)" || rc=$?
check_rc "repo testnet" 0 "$rc"
check "repo testnet value (ghcr, not the list)" "ghcr.io/telcoin-association/telcoin-network" "$out"
rc=0; out="$(tn_docker_repo_for mainnet 2>/dev/null)" || rc=$?
check "repo mainnet: ghcr" "0 ghcr.io/telcoin-association/telcoin-network" "$rc $out"
rc=0; out="$(tn_docker_repo_for devnet 2>"$T/err")" || rc=$?
check_rc "repo devnet refused" 1 "$rc"
check_has "repo devnet names the open decision" "1" "$(grep -c 'open decision' "$T/err")"
rc=0; out="$(tn_docker_repo_for foo 2>/dev/null)" || rc=$?
check_rc "repo foo refused" 1 "$rc"
rc=0; out="$(tn_docker_repo_for "" 2>/dev/null)" || rc=$?
check_rc "repo empty refused" 1 "$rc"

# --- registries, the Releases API and latest_docker_image (curl shim) --------------------
# The shim serves: ghcr.io's token endpoint ({"token":"TOK123"}; $REC/token.down
# makes it a 403), tags/list and manifest HEADs of the legacy repository
# ($REC/tags.json, $REC/digest.<tag>) and of ghcr ($REC/ghtags.json,
# $REC/ghdigest.<tag>; ghcr answers 401 without the Bearer token), and the
# GitHub Releases API ($REC/releases.json; $REC/api.down: unreachable). Every
# call is logged as "<head> <auth> <url>".
cat > "$T/bin/curl" <<'SH'
#!/bin/sh
head=0; url=""; auth="-"
while [ $# -gt 0 ]; do
    case "$1" in
        -I|-fsSI|-sI) head=1; shift ;;
        --url) url="$2"; shift 2 ;;
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
    https://ghcr.io/token\?scope=repository:telcoin-association/telcoin-network:pull)
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
check_has "ghcr manifest HEAD carried the Bearer token" "1 Authorization:_Bearer_TOK123 https://ghcr.io/v2/telcoin-association/telcoin-network/manifests/v0.17.0-adiri" "$(cat "$REC/curl.log")"
rc=0; out="$(tn_registry_tags "$GH" | tr '\n' ' ')" || rc=$?
check "ghcr tags with the token" "0 v0.17.0-adiri v0.17.0-adiri-rc1 " "$rc $out"
check_has "ghcr tags/list carried the Bearer token" "0 Authorization:_Bearer_TOK123 https://ghcr.io/v2/telcoin-association/telcoin-network/tags/list" "$(cat "$REC/curl.log")"
: > "$REC/curl.log"
rc=0; out="$(tn_registry_digest "$R" v0.17.0-adiri)" || rc=$?
check "legacy digest" "0 sha256:${D64}" "$rc $out"
check "legacy registry: no token asked, no Authorization sent" "1 - https://us-docker.pkg.dev/v2/telcoin-network/tn-public/adiri/manifests/v0.17.0-adiri" "$(cat "$REC/curl.log")"
touch "$REC/token.down"
rc=0; out="$(tn_registry_digest "$GH" v0.17.0-adiri)" || rc=$?
check "ghcr without a token (package not public): unreadable" "1 " "$rc $out"
rc=0; out="$(tn_registry_tags "$GH")" || rc=$?
check "ghcr tags without a token: unreadable" "1 " "$rc $out"
rm -f "$REC/token.down" "$REC/ghtags.json" "$REC/ghdigest.v0.17.0-adiri"

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
# A release exists: its signed IMAGE_DIGEST wins, the registry is not asked.
cp "$REC/releases.full.json" "$REC/releases.json"
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
unset -f meta_get
rc=0; o="$(tn_docker_resolve_ref mainnet "${R}@sha256:${D64}" 2>/dev/null)" || rc=$?
check "resolve: mainnet refuses the legacy testnet repository" "1 " "$rc $o"
for repo in "$R" "$GH" "ghcr.io/someone-else/telcoin-network"; do
    rc=0; tn_docker_repo_ok testnet "$repo" || rc=$?
    check "repo_ok testnet ${repo}" "$([[ "$repo" == *someone-else* ]] && echo 1 || echo 0)" "$rc"
done
rc=0; tn_docker_repo_ok mainnet "$GH" || rc=$?
check_rc "repo_ok mainnet: ghcr" 0 "$rc"
rc=0; tn_docker_repo_ok mainnet "$R" || rc=$?
check_rc "repo_ok mainnet: the legacy repository refused" 1 "$rc"
printf '%s@sha256:%s\n' "$R" "$D64" > "$REC/local.$(printf '%s' "${R}@sha256:${D64}" | tr '/:@' '___')"
printf '%s@sha256:%s\n' "$R" "$D64" > "$REC/local.$(printf '%s' "${R}@sha256:$(printf '%s' "$D64" | tr 0 e)" | tr '/:@' '___')"
rc=0; tn_docker_holds_digest "${R}@sha256:${D64}" || rc=$?
check_rc "holds digest: listed in RepoDigests" 0 "$rc"
rc=0; tn_docker_holds_digest "${R}@sha256:$(printf '%s' "$D64" | tr 0 e)" || rc=$?
check_rc "holds digest: another digest refused" 1 "$rc"
rc=0; tn_docker_holds_digest "${R}:v0.16.0-adiri" || rc=$?
check_rc "holds digest: a tag is not a digest" 1 "$rc"

finish
