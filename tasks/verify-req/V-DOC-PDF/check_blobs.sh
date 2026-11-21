#!/usr/bin/env bash
# V-DOC-PDF P4: each partner PDF in the working tree is a regular file equal to its
# blob in HEAD (what tn-partner-site's Publish requires), and the technical
# specification is untouched since the round's base.
#
# Usage: bash check_blobs.sh <repo-root> [base-commit]   (base defaults to 01664cc)
# Exit 0 when every check holds.
set -euo pipefail

if [ "$#" -lt 1 ]; then
    echo "usage: bash check_blobs.sh <repo-root> [base-commit]" >&2
    exit 2
fi
repo="$1"
base="${2:-01664cc}"
cd "$repo"
rc=0
for doc in mno-node-guide testnet-node-requirements mainnet-node-requirements technical-specification; do
    pdf="docs/partner/${doc}/${doc}.pdf"
    if [ -L "$pdf" ] || [ ! -f "$pdf" ]; then
        echo "FAIL ${pdf}: not a regular file"
        rc=1
        continue
    fi
    mode="$(git ls-files -s -- "$pdf" | cut -d' ' -f1)"
    work="$(git hash-object --no-filters -- "$pdf")"
    head="$(git rev-parse "HEAD:${pdf}")"
    if [ "$work" = "$head" ] && [ "$mode" = "100644" ]; then
        echo "PASS ${pdf}: regular file, mode ${mode}, blob ${work} = HEAD"
    else
        echo "FAIL ${pdf}: mode ${mode}, working blob ${work}, HEAD blob ${head}"
        rc=1
    fi
done
spec_diff="$(git diff --stat "${base}..HEAD" -- docs/partner/technical-specification)"
spec_old="$(git rev-parse "${base}:docs/partner/technical-specification/technical-specification.pdf")"
spec_new="$(git rev-parse "HEAD:docs/partner/technical-specification/technical-specification.pdf")"
if [ -z "$spec_diff" ] && [ "$spec_old" = "$spec_new" ]; then
    echo "PASS technical-specification: no change ${base}..HEAD; PDF blob ${spec_new} at both"
else
    echo "FAIL technical-specification changed ${base}..HEAD: ${spec_diff}"
    rc=1
fi
attr="$(git check-attr -a -- docs/partner/*/*.pdf)"
echo "git attributes on the PDFs: ${attr:-none}"
exit "$rc"
