#!/usr/bin/env bash
# V-DOC-PDF: extract the text of the three rebuilt partner PDFs with poppler in the
# tn-pdf-tools container (nothing PDF-related is installed on the host).
#
# Usage: bash extract_text.sh <repo-root> <out-dir> [image]
#   Writes <out-dir>/<doc>.layout.txt (pdftotext -layout), <doc>.plain.txt
#   (plain pdftotext) and <doc>.raw.txt (pdftotext -raw) for mno-node-guide, testnet-node-requirements and
#   mainnet-node-requirements. <out-dir> must not exist yet. The repo is mounted
#   read-only. Then run: python3 check_text.py <out-dir> <repo-root> <spec>.
set -euo pipefail

if [ "$#" -lt 2 ]; then
    echo "usage: bash extract_text.sh <repo-root> <out-dir> [image]" >&2
    exit 2
fi
repo="$1"
out="$2"
image="${3:-tn-pdf-tools}"
if [ -e "$out" ]; then
    echo "error: ${out} exists; give a new directory" >&2
    exit 2
fi
mkdir -p "$out"
docker run --rm -u "$(id -u):$(id -g)" -e HOME=/tmp \
    -v "${repo}:/w:ro" -v "${out}:/o" -w /w "$image" bash -c '
set -eu
for d in mno-node-guide testnet-node-requirements mainnet-node-requirements; do
    pdftotext -layout "docs/partner/$d/$d.pdf" "/o/$d.layout.txt"
    pdftotext "docs/partner/$d/$d.pdf" "/o/$d.plain.txt"
    pdftotext -raw "docs/partner/$d/$d.pdf" "/o/$d.raw.txt"
done
'
ls "$out"
