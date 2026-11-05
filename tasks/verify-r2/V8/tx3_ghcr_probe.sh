#!/usr/bin/env bash
# X3 (optional, network READ only; runs only with V8_NETWORK=1): the premise of the first-push
# path, that ghcr answers an anonymous read of a never-pushed package as it answers a private
# one. Anonymous GET of the token endpoint and HEAD of a manifest, as registry_digest does;
# nothing is written anywhere.
set -u
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
if [ "${V8_NETWORK:-}" != 1 ]; then
    printf 'SKIP tx3_ghcr_probe: set V8_NETWORK=1 to run the anonymous ghcr reads\n'
    exit 0
fi
probe() {
    local path=$1 ref=$2 tcode mcode token
    tcode=$(curl -sS --max-time 20 -o "$SCRATCH/probe.tok" -w '%{http_code}' "https://ghcr.io/token?scope=repository:$path:pull") || tcode=000
    token=$(sed -n 's/.*"token" *: *"\([^"]*\)".*/\1/p' "$SCRATCH/probe.tok")
    mcode=-
    if [ "$tcode" = 200 ]; then
        mcode=$(curl -sS -I --max-time 20 -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $token" \
            -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json' \
            "https://ghcr.io/v2/$path/manifests/$ref") || mcode=000
    fi
    printf '%-58s token=%s manifest=%s\n' "$path:$ref" "$tcode" "$mcode"
}
{
    probe telcoin-association/tn-mainnet v0.1.0
    probe telcoin-association/tn-testnet v0.17.0-adiri
    probe telcoin-association/tn-dev latest
    probe telcoin-association/telcoin-network latest
    probe telcoin-association/v8-never-pushed-"$(date +%s)" latest
    probe orhun/git-cliff/git-cliff 2.10.1
    probe orhun/git-cliff/git-cliff v0-no-such-tag
} | tee "$OUT/tx3-probe.txt"

# What login_digest parses: docker buildx imagetools inspect --format '{{println .Manifest.Digest}}'
# with stderr merged, as login_digest runs it. An empty DOCKER_CONFIG keeps every credential out:
# these are anonymous reads, the login itself is not exercised.
anon=$SCRATCH/docker-anon
mkdir -p "$anon"
printf '{}\n' >"$anon/config.json"
inspect() {
    local rc=0 out
    out=$(DOCKER_CONFIG=$anon docker buildx imagetools inspect "$1" --format '{{println .Manifest.Digest}}' 2>&1) || rc=$?
    printf '%-52s rc=%s out=[%s]\n' "$1" "$rc" "$(printf '%s' "$out" | tr '\n' '|')"
}
if docker buildx version >/dev/null 2>&1; then
    {
        inspect ghcr.io/orhun/git-cliff/git-cliff:2.10.1
        inspect ghcr.io/orhun/git-cliff/git-cliff:v0-no-such-tag
        inspect ghcr.io/telcoin-association/tn-mainnet:v0.1.0
    } | tee "$OUT/tx3-inspect.txt"
fi
