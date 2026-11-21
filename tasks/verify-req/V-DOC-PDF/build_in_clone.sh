#!/usr/bin/env bash
# V-DOC-PDF P3: build partner documents in a scratch clone with a given image and
# compare each candidate with the PDF committed in that clone.
#
# Usage: bash build_in_clone.sh <image> <clone-dir> <mount-path> <out-dir> <doc>...
#   <clone-dir>  a git clone (checked out at the commit under test); it is mounted
#                read-write at <mount-path> inside the container and the build runs
#                there, so the script's git lookups work and the in-container
#                absolute path is <mount-path> (vary it for the second-path check).
#   <out-dir>    must not exist yet; receives <doc>.pdf (the candidate the build left
#                in docs/partner/<doc>/build/), <doc>.log (the build's output) and
#                sha256.txt.
# The build never needs --force here: with no source changed since the commit that
# last wrote the PDF, build-partner-pdf.sh either prints "PDF unchanged" or keeps the
# committed PDF and warns "toolchain drift"; both leave the candidate in build/.
# After each build the clone must show no tracked change (checked, fails otherwise).
set -euo pipefail

if [ "$#" -lt 5 ]; then
    echo "usage: bash build_in_clone.sh <image> <clone-dir> <mount-path> <out-dir> <doc>..." >&2
    exit 2
fi
image="$1"
clone="$2"
mnt="$3"
out="$4"
shift 4
if [ -e "$out" ]; then
    echo "error: ${out} exists; give a new directory" >&2
    exit 2
fi
mkdir -p "$out"
rc=0
for doc in "$@"; do
    log="${out}/${doc}.log"
    brc=0
    docker run --rm -u "$(id -u):$(id -g)" -e HOME=/tmp \
        -v "${clone}:${mnt}" -w "$mnt" "$image" \
        bash tools/build-partner-pdf.sh "$doc" >"$log" 2>&1 || brc=$?
    cand="${clone}/docs/partner/${doc}/build/${doc}.pdf"
    committed="${clone}/docs/partner/${doc}/${doc}.pdf"
    if [ "$brc" -ne 0 ] || [ ! -s "$cand" ]; then
        echo "BUILD-FAILED ${doc} (exit ${brc}); log ${log}"
        rc=1
        continue
    fi
    cp "$cand" "${out}/${doc}.pdf"
    if cmp -s "$cand" "$committed"; then
        same="byte-identical"
    else
        same="DIFFERS"
        rc=1
    fi
    status_line="$(git -C "$clone" status --short --untracked-files=no)"
    if [ -n "$status_line" ]; then
        echo "TRACKED-CHANGE in ${clone}: ${status_line}"
        rc=1
    fi
    say="$(grep -E '^(PDF unchanged|Wrote |warn: toolchain drift|Done )' "$log" | tr '\n' ' ')"
    printf '%s %s %s | %s\n' "$doc" "$same" "$(sha256sum "${out}/${doc}.pdf" | cut -d' ' -f1)" "$say"
    printf '%s  %s\n' "$(sha256sum "${out}/${doc}.pdf" | cut -d' ' -f1)" "${doc}.pdf" >>"${out}/sha256.txt"
done
exit "$rc"
