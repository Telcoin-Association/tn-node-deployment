#!/usr/bin/env bash
# =============================================================================
# tasks/verify-v220/rehearse-updater.sh -- run a real update-scripts.sh from one
# ref against a release from another, offline, in a container.
#
#   bash tasks/verify-v220/rehearse-updater.sh INSTALLED_REF RELEASE_SRC TAG
#
#   INSTALLED_REF  the tree the host has, as a git ref (scripts-v2.1.0, origin/main)
#   RELEASE_SRC    the release the updater is offered: a git ref
#                  (origin/release/scripts-v2.2.0) or a directory that holds
#                  MANIFEST, MANIFEST.asc and the files
#   TAG            the tag RELEASE names (scripts-v2.2.0)
#
# It extracts INSTALLED_REF as ~/telcoin-node-scripts of a container user, serves
# RELEASE_SRC through a curl stand-in as refs/tags/TAG of the repository's raw
# URL, answers the updater's question with y, and prints the exit status, the
# output without colours, whether the tree is byte-identical afterwards, how many
# staging directories are left and which URLs were fetched. Nothing leaves the
# machine: the container runs with --network=none and needs only the gpgv of the
# ubuntu:26.04 image.
#
# What to expect:
#   scripts-v2.1.0 against a release signed by the new keys: exit 1, the tree
#     byte-identical, no staging directory, and the output ends with the warning
#     "a signature by key <id>, which is not a release key, was not checked",
#     gpgv's own lines and the [ERROR] line the docs quote.
#   a tree with the three keys against the same release: exit 0, the tree changed,
#     MANIFEST naming TAG.
#
# Maintainer tooling: not tracked by update-scripts.sh, no .sha256 sidecar.
# bash 3.2 safe.
# =============================================================================
set -u

usage() { sed -n '3,12p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
[ $# -eq 3 ] || usage
INSTALLED_REF="$1" RELEASE_SRC="$2" TAG="$3"
IMAGE="${TN_REHEARSE_IMAGE:-ubuntu:26.04}"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"

W="$(mktemp -d "${TMPDIR:-/tmp}/tn-rehearse.XXXXXX")" || { echo "no temp dir" >&2; exit 2; }
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/old" "$W/raw/main" "$W/raw/refs/tags/$TAG" "$W/bin"

git -C "$REPO" archive "$INSTALLED_REF" | tar -x -C "$W/old" || { echo "cannot read ${INSTALLED_REF}" >&2; exit 2; }
if [ -d "$RELEASE_SRC" ]; then
    cp -R "$RELEASE_SRC"/. "$W/raw/refs/tags/$TAG/"
else
    git -C "$REPO" archive "$RELEASE_SRC" | tar -x -C "$W/raw/refs/tags/$TAG" || { echo "cannot read ${RELEASE_SRC}" >&2; exit 2; }
fi
for f in MANIFEST MANIFEST.asc; do
    [ -f "$W/raw/refs/tags/$TAG/$f" ] || { echo "${RELEASE_SRC} has no ${f}" >&2; exit 2; }
done
printf '%s %s\n' "$TAG" "$(date -u +%Y-%m-%d)" > "$W/raw/main/RELEASE"
printf 'README\n' > "$W/raw/main/README.md"

# The stand-in of tools/tests/updater_manifest_test.sh, with fixed paths.
cat > "$W/bin/curl" <<'EOF'
#!/bin/sh
out="" head=0 url=""
while [ $# -gt 0 ]; do
    case "$1" in
        -o) out="$2"; shift ;;
        -I|-fsSLI|-sfI) head=1 ;;
        --proto|--max-time) shift ;;
        https://*) url="$1" ;;
    esac
    shift
done
echo "$url" >> /tmp/curl.log
case "$url" in
    https://raw.githubusercontent.com/Telcoin-Association/tn-node-deployment/*)
        f="/r/raw/${url#https://raw.githubusercontent.com/Telcoin-Association/tn-node-deployment/}" ;;
    *) exit 6 ;;
esac
[ -f "$f" ] || exit 22
if [ "$head" = 1 ]; then echo "HTTP/2 200"; exit 0; fi
if [ -n "$out" ]; then cp "$f" "$out"; else cat "$f"; fi
EOF

cat > "$W/run.sh" <<'EOF'
#!/bin/bash
set -u
export PATH="/r/bin:$PATH" TERM=dumb HOME=/tmp/home
mkdir -p "$HOME"
INST="$HOME/telcoin-node-scripts"
cp -R /r/old "$INST"
sig() { (cd "$INST" && find . -print | LC_ALL=C sort && find . -type f -print | LC_ALL=C sort | xargs sha256sum); }
sig > /tmp/before
cd "$HOME" || exit 2
printf 'y\n' | bash "$INST/update-scripts.sh" > /tmp/out 2>&1
rc=$?
sig > /tmp/after
echo "== installed updater: $(grep -m1 'SCRIPT_VERSION=' /r/old/update-scripts.sh)"
echo "== exit status: $rc"
echo "== output (colours removed):"
sed 's/\x1b\[[0-9;]*m//g' /tmp/out
echo "== tree byte-identical: $(cmp -s /tmp/before /tmp/after && echo yes || echo NO)"
echo "== staging dirs left: $(find "$INST" -maxdepth 1 -name '.tn-update.*' | wc -l | tr -d ' ')"
echo "== release recorded: $(grep -m1 '^release=' "$INST/MANIFEST" 2>/dev/null || echo none)"
echo "== release keys on the host: $(cd "$INST/lib/release-keys" 2>/dev/null && ls -- *.asc 2>/dev/null | tr '\n' ' ')"
echo "== urls fetched: $(wc -l < /tmp/curl.log | tr -d ' ') (first four below)"
head -4 /tmp/curl.log
EOF
chmod +x "$W/bin/curl" "$W/run.sh"

docker run --rm --network=none -v "$W:/r:ro" "$IMAGE" bash /r/run.sh
