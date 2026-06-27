#!/usr/bin/env bash
# =============================================================================
# tools/gen-checksums.sh -- regenerate SHA-256 sidecars for updater-tracked files
#
# update-scripts.sh fetches each tracked file from raw.githubusercontent.com and,
# whenever a <file>.sha256 sidecar exists, verifies the download against it. This
# maintainer tool (re)generates those sidecars so they stay honest.
#
# The file list is derived from the SCRIPTS, UI_BUNDLE, and TESTNET_ADDONS_BUNDLE
# arrays in update-scripts.sh -- the exact set the updater downloads -- so it never
# drifts from what operators receive. CI runs this and fails if any sidecar is stale
# or missing (see .github/workflows/ci.yml), so AFTER EDITING ANY TRACKED FILE you
# must re-run this and commit the refreshed sidecars.
#
# This script itself is not tracked by the updater (operators never fetch it), so it
# gets no sidecar. Kept bash-3.2-safe (indexed arrays only, no associative arrays or
# mapfile) so it runs on stock macOS too.
#
# USAGE:
#   bash tools/gen-checksums.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$REPO_ROOT"

readonly UPDATER="update-scripts.sh"
if [[ ! -f "$UPDATER" ]]; then
    echo "error: ${UPDATER} not found at repo root (${REPO_ROOT})" >&2
    exit 1
fi

# Portable SHA-256 (hash only): GNU sha256sum on Linux, shasum -a 256 on macOS.
# Mirrors the helper in update-scripts.sh so generation and verification agree.
_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1"
    else
        shasum -a 256 "$1"
    fi | awk '{print $1}'
}

# Emit the local_path (first colon-field) of every entry in the three updater
# arrays. Reads them straight out of update-scripts.sh so that file stays the
# single source of truth. Assumes the current one-entry-per-line layout, with the
# `declare -a NAME=(` opener and the closing `)` each on their own line.
extract_tracked_paths() {
    awk '
        /^declare -a (SCRIPTS|UI_BUNDLE|TESTNET_ADDONS_BUNDLE)=\(/ { inblock = 1; next }
        inblock && /^\)/                                          { inblock = 0; next }
        inblock && /"/                                            { print }
    ' "$UPDATER" \
        | sed -e 's/^[[:space:]]*"//' -e 's/".*$//' \
        | cut -d: -f1
}

declare -a files=()
while IFS= read -r f; do
    [[ -n "$f" ]] && files+=("$f")
done < <(extract_tracked_paths)

if [[ ${#files[@]} -eq 0 ]]; then
    echo "error: parsed 0 tracked files from ${UPDATER} -- has the array layout changed?" >&2
    exit 1
fi

generated=0
missing=0
for f in "${files[@]}"; do
    if [[ ! -f "$f" ]]; then
        echo "warn: '${f}' is listed in ${UPDATER} but missing on disk -- skipping" >&2
        missing=$((missing + 1))
        continue
    fi
    printf '%s  %s\n' "$(_sha256 "$f")" "$f" > "${f}.sha256"
    generated=$((generated + 1))
done

echo "Generated ${generated} sidecar(s) from ${UPDATER}."
if [[ $missing -gt 0 ]]; then
    echo "error: ${missing} tracked file(s) missing on disk (see warnings above)." >&2
    exit 1
fi
