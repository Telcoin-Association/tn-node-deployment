#!/usr/bin/env bash
# V-DOC-PDF P1: pdfinfo (with -meta, the XMP stream if any) and pdffonts for the
# three rebuilt partner PDFs and for their copies at a base commit, side by side.
#
# Usage: bash pdf_props.sh <repo-root> <base-pdf-dir> <out-dir> [image]
#   <base-pdf-dir> holds <doc>.pdf as at the base (git show 01664cc:<path> > ...).
#   <out-dir> must not exist yet; receives <doc>.{info,fonts,strings}.{new,base}.txt
#   and prints the page counts, the info diff and the font-set diff, then greps every
#   info/XMP field and the raw PDF bytes for a home directory, a build path or a
#   user name (/home/, /Users/, /tmp/, /w/, file:).
set -euo pipefail

if [ "$#" -lt 3 ]; then
    echo "usage: bash pdf_props.sh <repo-root> <base-pdf-dir> <out-dir> [image]" >&2
    exit 2
fi
repo="$1"
basedir="$2"
out="$3"
image="${4:-tn-pdf-tools}"
if [ -e "$out" ]; then
    echo "error: ${out} exists; give a new directory" >&2
    exit 2
fi
mkdir -p "$out"
docker run --rm -u "$(id -u):$(id -g)" -e HOME=/tmp \
    -v "${repo}:/w:ro" -v "${basedir}:/b:ro" -v "${out}:/o" -w /w "$image" bash -c '
set -eu
for d in mno-node-guide testnet-node-requirements mainnet-node-requirements; do
    for v in new base; do
        if [ "$v" = new ]; then p="docs/partner/$d/$d.pdf"; else p="/b/$d.pdf"; fi
        pdfinfo -isodates "$p" >"/o/$d.info.$v.txt"
        pdfinfo -meta "$p" >"/o/$d.meta.$v.txt" 2>&1 || true
        pdffonts "$p" >"/o/$d.fonts.$v.txt"
        strings -n 6 "$p" >"/o/$d.strings.$v.txt" 2>/dev/null || tr -c "[:print:]" "\n" <"$p" >"/o/$d.strings.$v.txt"
    done
done
'
rc=0
for d in mno-node-guide testnet-node-requirements mainnet-node-requirements; do
    echo "=== ${d}"
    for v in new base; do
        printf '%s: %s; %s\n' "$v" \
            "$(grep -E '^Pages:' "${out}/${d}.info.${v}.txt" | tr -s ' ')" \
            "$(grep -E '^Page size:' "${out}/${d}.info.${v}.txt" | tr -s ' ')"
    done
    echo "--- info diff (base -> new):"
    diff "${out}/${d}.info.base.txt" "${out}/${d}.info.new.txt" || true
    echo "--- font set diff (name, type, encoding, emb, sub, uni; object ids dropped):"
    for v in base new; do
        tail -n +3 "${out}/${d}.fonts.${v}.txt" | awk '{print $1, $2, $3, $(NF-4), $(NF-3), $(NF-2)}' |
            sed -e 's/^[A-Z]\{6\}+//' | sort -u >"${out}/${d}.fontset.${v}.txt"
    done
    if diff "${out}/${d}.fontset.base.txt" "${out}/${d}.fontset.new.txt"; then
        echo "same font set ($(wc -l <"${out}/${d}.fontset.new.txt") distinct)"
    else
        rc=1
    fi
    notemb="$(tail -n +3 "${out}/${d}.fonts.new.txt" | awk '$(NF-4) != "yes"' | wc -l | tr -d ' ')"
    echo "fonts not embedded in new: ${notemb}"
    if [ "$notemb" != "0" ]; then rc=1; fi
    hits="$(cat "${out}/${d}.info.new.txt" "${out}/${d}.meta.new.txt" "${out}/${d}.strings.new.txt" |
        grep -n -E '/home/|/Users/|/tmp/|/w/|file:|drtnarg|grantkee' || true)"
    if [ -n "$hits" ]; then
        echo "path or user-name hits in new:"
        printf '%s\n' "$hits" | head -20
        rc=1
    else
        echo "no home directory, build path or user name in the info, XMP or bytes of new"
    fi
done
exit "$rc"
