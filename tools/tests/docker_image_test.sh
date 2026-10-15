#!/usr/bin/env bash
# =============================================================================
# tools/tests/docker_image_test.sh -- images by digest: tn_docker_image_allowed
# with the TN_DOCKER_REQUIRE_DIGEST default (1: tags refused) and with =0 (a
# release tag accepted, latest and other tags never); tn_docker_repo_for per
# network (mainnet and devnet refused while their repositories are unnamed);
# latest_docker_image and tn_registry_digest against a curl shim (release tags
# only, resolved to a digest, the pinned default when the registry is down,
# nothing on mainnet); tn_docker_local_digest against a docker shim;
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
allowed "mainnet has no repository yet" 1 "${R}@sha256:${D64}" mainnet
allowed "devnet has no repository yet" 1 "${R}@sha256:${D64}" devnet
allowed "default image is allowed" 0 "$DEFAULT_DOCKER_IMAGE"
TN_DOCKER_REQUIRE_DIGEST=0
allowed "=0: release tag accepted" 0 "${R}:v0.16.0-adiri"
allowed "=0: latest refused" 1 "${R}:latest"
allowed "=0: devnet tag refused" 1 "${R}:v0.16.0-devnet"
allowed "=0: hot-patch tag refused" 1 "${R}:v0.16.0-adiri-hotfix1"
allowed "=0: mainnet-form tag refused on testnet" 1 "${R}:v0.16.0"
allowed "=0: digest still accepted" 0 "${R}@sha256:${D64}"
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
check "repo testnet value" "$R" "$out"
rc=0; out="$(tn_docker_repo_for mainnet 2>"$T/err")" || rc=$?
check_rc "repo mainnet refused" 1 "$rc"
check "repo mainnet prints nothing" "" "$out"
check_has "repo mainnet names the open decision" "1" "$(grep -c 'open decision' "$T/err")"
rc=0; out="$(tn_docker_repo_for devnet 2>/dev/null)" || rc=$?
check_rc "repo devnet refused" 1 "$rc"
rc=0; out="$(tn_docker_repo_for foo 2>/dev/null)" || rc=$?
check_rc "repo foo refused" 1 "$rc"
rc=0; out="$(tn_docker_repo_for "" 2>/dev/null)" || rc=$?
check_rc "repo empty refused" 1 "$rc"

# --- latest_docker_image / tn_registry_digest (curl shim) ------------------------------
cat > "$T/bin/curl" <<'SH'
#!/bin/sh
head=0; url=""
while [ $# -gt 0 ]; do
    case "$1" in
        -I|-fsSI|-sI) head=1; shift ;;
        --url) url="$2"; shift 2 ;;
        *) shift ;;
    esac
done
printf '%s %s\n' "$head" "$url" >> "$REC/curl.log"
[ -f "$REC/down" ] && exit 7
case "$url" in
    */tags/list) cat "$REC/tags.json" ;;
    */manifests/*)
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
printf '{"name":"x","tags":["latest","v0.16.0-adiri","v0.17.0-adiri","v0.17.1-adiri-hotfix","v0.18.0-devnet","v0.9.0-adiri","v1.0.0"]}' > "$REC/tags.json"
printf 'sha256:%s\n' "$D64" > "$REC/digest.v0.17.0-adiri"
rc=0; out="$(latest_docker_image testnet 2>/dev/null)" || rc=$?
check_rc "latest testnet" 0 "$rc"
check "latest testnet: newest release tag by digest" "${R}@sha256:${D64}" "$out"
check_has "latest asked the manifest of v0.17.0-adiri" "1 https://us-docker.pkg.dev/v2/telcoin-network/tn-public/adiri/manifests/v0.17.0-adiri" "$(cat "$REC/curl.log")"
rc=0; out="$(NETWORK=testnet latest_docker_image 2>/dev/null)" || rc=$?
check "latest: NETWORK global" "${R}@sha256:${D64}" "$out"
rm -f "$REC/digest.v0.17.0-adiri"
rc=0; out="$(latest_docker_image testnet 2>/dev/null)" || rc=$?
check_rc "latest: no digest falls back" 0 "$rc"
check "latest: no digest -> pinned default" "$DEFAULT_DOCKER_IMAGE" "$out"
touch "$REC/down"
rc=0; out="$(latest_docker_image testnet 2>/dev/null)" || rc=$?
check "latest: registry down -> pinned default" "$DEFAULT_DOCKER_IMAGE" "$out"
rm -f "$REC/down"
: > "$REC/curl.log"
rc=0; out="$(latest_docker_image mainnet 2>/dev/null)" || rc=$?
check_rc "latest mainnet refused" 1 "$rc"
check "latest mainnet prints nothing" "" "$out"
check "latest mainnet asks no registry" "" "$(cat "$REC/curl.log")"
printf 'sha256:%s\n' "$D64" > "$REC/digest.v0.16.0-adiri"
rc=0; out="$(tn_registry_digest "$R" v0.16.0-adiri)" || rc=$?
check "registry digest (CRLF header)" "sha256:${D64}" "$out"
printf 'sha256:short\n' > "$REC/digest.v0.16.0-adiri"
rc=0; out="$(tn_registry_digest "$R" v0.16.0-adiri)" || rc=$?
check_rc "registry digest malformed refused" 1 "$rc"
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
mkdir -p "$T/keys"
export TN_RELEASE_KEYS_DIR="$T/keys"
rc=0; out="$(tn_docker_image_for_tag testnet v0.17.0-adiri 2>"$T/err")" || rc=$?
check "for_tag, no release key, testnet: the registry digest" "0 ${R}@sha256:${D64}" "$rc $out"
check_has "for_tag, no release key: warns that no signed release confirms it" "1" "$(grep -c 'no signed release confirms' "$T/err")"
rc=0; out="$(tn_docker_image_for_tag testnet v0.17.0-adiri-hotfix 2>/dev/null)" || rc=$?
check "for_tag: a non-release tag is rc 3" "3 " "$rc $out"
rc=0; out="$(tn_docker_image_for_tag mainnet v1.0.0 2>/dev/null)" || rc=$?
check_rc "for_tag: mainnet (no repository yet) refused" 1 "$rc"
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
res "resolve: other repository by digest refused" "docker.io/library/busybox@sha256:${D64}" 1 ""
res "resolve: other repository by tag refused" "docker.io/library/busybox:v0.17.0-adiri" 1 ""
res "resolve: leading dash refused" "-v0.17.0-adiri" 1 ""
res "resolve: short digest refused" "${R}@sha256:abc" 1 ""
printf '%s@sha256:%s\n' "$R" "$D64" > "$REC/local.$(printf '%s' "${R}@sha256:${D64}" | tr '/:@' '___')"
printf '%s@sha256:%s\n' "$R" "$D64" > "$REC/local.$(printf '%s' "${R}@sha256:$(printf '%s' "$D64" | tr 0 e)" | tr '/:@' '___')"
rc=0; tn_docker_holds_digest "${R}@sha256:${D64}" || rc=$?
check_rc "holds digest: listed in RepoDigests" 0 "$rc"
rc=0; tn_docker_holds_digest "${R}@sha256:$(printf '%s' "$D64" | tr 0 e)" || rc=$?
check_rc "holds digest: another digest refused" 1 "$rc"
rc=0; tn_docker_holds_digest "${R}:v0.16.0-adiri" || rc=$?
check_rc "holds digest: a tag is not a digest" 1 "$rc"

finish
