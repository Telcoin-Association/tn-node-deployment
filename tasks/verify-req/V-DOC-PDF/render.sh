#!/usr/bin/env bash
# V-DOC-PDF P5: render PDF pages with pdftoppm in the tn-pdf-tools container.
#
# Usage: bash render.sh <out-dir> <dpi> <format> <pdf>... [image via RENDER_IMAGE]
#   <format> is png (to look at) or ppm (raw pixels: two renders are pixel-identical
#   exactly when their .ppm files are byte-identical, so `cmp` compares renders).
#   Each <pdf> is mounted read-only; page images land in <out-dir> as
#   <pdf-basename>-<page>.<format>. <out-dir> must not exist yet.
set -euo pipefail

if [ "$#" -lt 4 ]; then
    echo "usage: bash render.sh <out-dir> <dpi> <png|ppm> <pdf>..." >&2
    exit 2
fi
out="$1"
dpi="$2"
fmt="$3"
shift 3
image="${RENDER_IMAGE:-tn-pdf-tools}"
if [ -e "$out" ]; then
    echo "error: ${out} exists; give a new directory" >&2
    exit 2
fi
case "$fmt" in
    png) flag="-png" ;;
    ppm) flag="" ;;
    *) echo "error: format must be png or ppm" >&2; exit 2 ;;
esac
mkdir -p "$out"
for pdf in "$@"; do
    dir="$(cd "$(dirname "$pdf")" && pwd)"
    name="$(basename "$pdf" .pdf)"
    docker run --rm -u "$(id -u):$(id -g)" -e HOME=/tmp \
        -v "${dir}:/in:ro" -v "${out}:/o" "$image" \
        pdftoppm ${flag:+"$flag"} -r "$dpi" "/in/${name}.pdf" "/o/${name}"
done
find "$out" -type f | wc -l
