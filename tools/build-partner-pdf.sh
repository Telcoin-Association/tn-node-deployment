#!/usr/bin/env bash
# =============================================================================
# tools/build-partner-pdf.sh -- build the branded MNO partner guide PDF
#
# Renders docs/partner/mno-node-guide.md into docs/partner/mno-node-guide.pdf in
# two steps: pandoc turns the Markdown into HTML (docs/partner/template.html for
# the cover and contents, docs/partner/metadata.yaml for the cover fields), then
# WeasyPrint lays that HTML out as A4 pages using docs/partner/theme.css (CSS
# paged media: running header and footer, page numbers, TOC leaders). Fonts and
# logos are vendored under docs/partner/assets/ so the build never hits the
# network. Scratch output (HTML preview, candidate PDF, WeasyPrint log) goes to
# docs/partner/build/, which is gitignored.
#
# Before rendering, the Markdown is linted for things that must never reach a
# partner: personal addresses, removed flags and scripts, repo-relative links,
# and "legacy" material. The committed PDF is only replaced when a source file
# changed (or with --force), so a pandoc/WeasyPrint upgrade that shifts bytes
# without changing the page does not churn the repo.
#
# This is a maintainer tool. It is not tracked by the updater (operators never
# fetch it), so it gets no sidecar. Kept bash-3.2-safe (indexed arrays only, no
# associative arrays or mapfile) so it runs on stock macOS too.
#
# USAGE:
#   bash tools/build-partner-pdf.sh [--html-only] [--open] [--force]
#   bash tools/build-partner-pdf.sh --help
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$REPO_ROOT"

usage() {
    cat <<'EOF'
Usage: bash tools/build-partner-pdf.sh [--html-only] [--open] [--force]

Build docs/partner/mno-node-guide.pdf from docs/partner/mno-node-guide.md.

Options:
  --html-only   Lint and run pandoc only; write docs/partner/build/mno-node-guide.html
                (a browser preview) and stop before WeasyPrint.
  --open        Open the result when done (the HTML with --html-only, else the PDF).
  --force       Replace the committed PDF even if no source file changed since the
                commit that last wrote it (normally treated as toolchain drift).
  -h, --help    Show this help.

Environment:
  PARTNER_MD    Build a different Markdown file instead of the guide, for testing
                the pipeline. Output goes to docs/partner/build/<name>.{html,pdf},
                the committed PDF is never touched, and the page-count check only
                warns. Example: PARTNER_MD=/tmp/test.md bash tools/build-partner-pdf.sh

Requires pandoc >= 3.8, WeasyPrint >= 61 and python3.
  macOS:          brew install pandoc weasyprint
  Debian/Ubuntu:  pandoc .deb from https://github.com/jgm/pandoc/releases (apt's is
                  too old); sudo apt-get install weasyprint (Ubuntu 24.04+) or
                  pipx install weasyprint

Exit status: 0 success, 1 lint or build failure, 2 usage error.
EOF
}

HTML_ONLY=0
OPEN=0
FORCE=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --html-only) HTML_ONLY=1 ;;
        --open)      OPEN=1 ;;
        --force)     FORCE=1 ;;
        -h|--help)   usage; exit 0 ;;
        *)
            echo "error: unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
    shift
done

readonly PARTNER_DIR="docs/partner"
readonly DEFAULT_MD="${PARTNER_DIR}/mno-node-guide.md"
readonly MD="${PARTNER_MD:-$DEFAULT_MD}"
readonly META="${PARTNER_DIR}/metadata.yaml"
readonly TEMPLATE="${PARTNER_DIR}/template.html"
readonly CSS="${PARTNER_DIR}/theme.css"
readonly ASSETS_DIR="${PARTNER_DIR}/assets"
readonly BUILD_DIR="${PARTNER_DIR}/build"
readonly PDF="${PARTNER_DIR}/mno-node-guide.pdf"
readonly CONTACT="support@telcoin.org"
readonly MIN_PAGES=15
readonly MAX_PAGES=150
readonly MAX_CODE_LINE=90

# Scratch output is named after the source, so a PARTNER_MD test build never
# overwrites the guide's own preview, candidate PDF or log.
OVERRIDE=0
NAME="mno-node-guide"
WP_LOG="${BUILD_DIR}/weasyprint.log"
if [[ "$MD" != "$DEFAULT_MD" ]]; then
    OVERRIDE=1
    NAME="$(basename "$MD" .md)"
    WP_LOG="${BUILD_DIR}/${NAME}.weasyprint.log"
fi
readonly OVERRIDE NAME WP_LOG
readonly HTML="${BUILD_DIR}/${NAME}.html"
readonly PDF_NEW="${BUILD_DIR}/${NAME}.pdf"

# Everything that shapes the PDF. A change to any of these since the commit that
# last wrote the PDF means a rebuild is real, not toolchain drift.
declare -a SOURCES=("$DEFAULT_MD" "$META" "$TEMPLATE" "$CSS" "$ASSETS_DIR" "tools/build-partner-pdf.sh")

# Text that must never appear in the guide. Personal addresses, the removed
# --observer flag and its scripts, and links that only resolve inside this repo.
declare -a FORBIDDEN=(
    "grant@"
    "--observer"
    "migrate-node-naming"
    "setup-observer.sh"
    "setup-validator.sh"
    "](README.md"
    "](docs/"
    "](WGVPN.md"
    "](OPERATOR.md"
)

# ---- helpers ----------------------------------------------------------------

# _version_ge A B: succeed if dotted version A >= B (missing parts count as 0).
_version_ge() {
    awk -v a="$1" -v b="$2" 'BEGIN {
        na = split(a, x, "."); nb = split(b, y, ".")
        n = (na > nb) ? na : nb
        for (i = 1; i <= n; i++) {
            xi = (i <= na) ? x[i] + 0 : 0
            yi = (i <= nb) ? y[i] + 0 : 0
            if (xi > yi) exit 0
            if (xi < yi) exit 1
        }
        exit 0
    }'
}

_tool_version() {
    case "$1" in
        pandoc)     pandoc --version 2>/dev/null | awk 'NR == 1 { print $2 }' ;;
        weasyprint) weasyprint --version 2>/dev/null | awk 'NR == 1 { print $NF }' ;;
    esac
}

_install_hint() {
    local tool="$1"
    case "$(uname -s)" in
        Darwin)
            echo "  install: brew install pandoc weasyprint"
            ;;
        Linux)
            if [[ "$tool" == "pandoc" ]]; then
                echo "  install: apt's pandoc is too old (2.9 to 3.1); install the .deb from"
                echo "           https://github.com/jgm/pandoc/releases"
            else
                echo "  install: sudo apt-get install weasyprint (Ubuntu 24.04+)"
                echo "           or: pipx install weasyprint"
            fi
            ;;
        *)
            echo "  install: see https://pandoc.org/installing.html and"
            echo "           https://doc.courtbouillon.org/weasyprint/stable/first_steps.html"
            ;;
    esac
}

# _need TOOL MIN: exit 1 with an install hint unless TOOL is on PATH at >= MIN.
_need() {
    local tool="$1" min="$2" ver
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "error: ${tool} not found on PATH (need ${min} or later)" >&2
        _install_hint "$tool" >&2
        exit 1
    fi
    ver="$(_tool_version "$tool")"
    if [[ -z "$ver" ]] || ! _version_ge "$ver" "$min"; then
        echo "error: ${tool} ${ver:-(unknown version)} is too old (need ${min} or later)" >&2
        _install_hint "$tool" >&2
        exit 1
    fi
}

# _fenced_lines FILE out|in: print "LINENO:text" for the lines outside (out) or
# inside (in) fenced code blocks. Fence lines themselves are never printed.
_fenced_lines() {
    awk -v want="$2" '
        /^[[:space:]]*(```|~~~)/ { infence = !infence; next }
        (want == "in") == (infence == 1) { printf "%d:%s\n", NR, $0 }
    ' "$1"
}

# Report fenced code lines longer than MAX_CODE_LINE, measured from the fence's
# own indentation (pandoc strips that indentation inside list items).
_long_code_lines() {
    awk -v max="$MAX_CODE_LINE" '
        /^[[:space:]]*(```|~~~)/ {
            if (!infence) { match($0, /^[[:space:]]*/); ind = RLENGTH }
            infence = !infence
            next
        }
        infence && length($0) - ind > max {
            printf "    line %d: %d chars\n", NR, length($0) - ind
        }
    ' "$1"
}

_open() {
    if command -v open >/dev/null 2>&1; then
        open "$1"
    elif command -v xdg-open >/dev/null 2>&1; then
        xdg-open "$1" >/dev/null 2>&1 &
    else
        echo "warn: no 'open' or 'xdg-open' on PATH; open $1 yourself" >&2
    fi
}

# Count PDF pages and check for the support mailto link, with stdlib python only.
# WeasyPrint writes compressed object streams, so /Type /Page and the link URI are
# not visible in the raw bytes: inflate every Flate stream and search those too.
# Prints "<pages> <has_mailto 0|1>".
_pdf_facts() {
    python3 - "$1" "mailto:${CONTACT}" <<'PY'
import re
import sys
import zlib

data = open(sys.argv[1], "rb").read()
chunks = [data]
for m in re.finditer(rb"(?<!end)stream\r?\n", data):
    end = data.find(b"endstream", m.end())
    if end < 0:
        break
    try:
        chunks.append(zlib.decompressobj().decompress(data[m.end():end]))
    except zlib.error:
        pass
blob = b"\n".join(chunks)
pages = len(re.findall(rb"/Type\s*/Page(?![A-Za-z])", blob))
mailto = 1 if sys.argv[2].encode() in blob else 0
print(pages, mailto)
PY
}

# Succeed if no source changed (tracked or untracked) since commit $1.
_sources_clean_since() {
    local base="$1"
    git diff --quiet "$base" -- ${SOURCES[@]+"${SOURCES[@]}"} 2>/dev/null || return 1
    [[ -z "$(git ls-files --others --exclude-standard -- ${SOURCES[@]+"${SOURCES[@]}"} 2>/dev/null)" ]]
}

# ---- 1. tool checks ---------------------------------------------------------

_need pandoc 3.8
PANDOC_VER="$(_tool_version pandoc)"
WP_VER="not run"
if [[ $HTML_ONLY -eq 0 ]]; then
    _need weasyprint 61.0
    WP_VER="$(_tool_version weasyprint)"
    if ! command -v python3 >/dev/null 2>&1; then
        echo "error: python3 not found on PATH (used for the PDF sanity check)" >&2
        exit 1
    fi
fi

for f in "$MD" "$META" "$TEMPLATE" "$CSS"; do
    if [[ ! -f "$f" ]]; then
        echo "error: ${f} not found (repo root: ${REPO_ROOT})" >&2
        exit 1
    fi
done

# ---- 2. source lint ---------------------------------------------------------

lint_failed=0
_lint_error() {
    echo "error: lint: $*" >&2
    lint_failed=1
}

# Forbidden text fails the build wherever it appears, code blocks included: a
# removed flag in a command example is legacy material just the same.
for pat in "${FORBIDDEN[@]}"; do
    if hits="$(grep -n -F -e "$pat" "$MD")"; then
        _lint_error "${MD} contains forbidden text '${pat}':"
        printf '%s\n' "$hits" | sed 's/^/    line /' >&2
    fi
done
if hits="$(grep -n -i -w -e "legacy" "$MD")"; then
    _lint_error "${MD} mentions 'legacy' (drop legacy material from the partner guide):"
    printf '%s\n' "$hits" | sed 's/^/    line /' >&2
fi
if ! grep -q -F -e "$CONTACT" "$MD"; then
    _lint_error "${MD} never mentions ${CONTACT}"
fi

# Only the title may be a '# ' heading. Shell comments inside fenced code blocks
# look the same, so count outside fences only.
h1_count="$(_fenced_lines "$MD" out | grep -c '^[0-9]*:# ' || true)"
if [[ "$h1_count" != "1" ]]; then
    _lint_error "${MD} has ${h1_count} '# ' headings outside code blocks; it needs exactly one (the title)"
fi

if ! grep -q '^version:' "$META"; then
    _lint_error "${META} has no 'version:' line"
fi
if ! grep -q '^date:' "$META"; then
    _lint_error "${META} has no 'date:' line"
fi
if grep -q '^title:' "$META"; then
    _lint_error "${META} sets 'title:'; the title must come from the guide's '# ' heading"
fi

if [[ $lint_failed -ne 0 ]]; then
    echo "error: lint failed for ${MD}; nothing built" >&2
    exit 1
fi

long_lines="$(_long_code_lines "$MD")"
if [[ -n "$long_lines" ]]; then
    echo "warn: code lines longer than ${MAX_CODE_LINE} characters wrap in the PDF; break them with a trailing backslash:" >&2
    printf '%s\n' "$long_lines" >&2
fi

# ---- 3. pandoc --------------------------------------------------------------

mkdir -p "$BUILD_DIR"
rm -f "$HTML"
if ! pandoc "$MD" \
        --from=gfm --to=html5 --standalone \
        --template="$TEMPLATE" \
        --metadata-file="$META" \
        --shift-heading-level-by=-1 --number-sections --toc --toc-depth=2 \
        --syntax-highlighting=none \
        --css=../theme.css -V asset-dir=../assets \
        --fail-if-warnings \
        --output="$HTML"; then
    echo "error: pandoc failed on ${MD}" >&2
    exit 1
fi

# Every in-document link must land on an element id, or the PDF gets a dead link
# and the "(page N)" suffix prints nothing.
dangling="$(comm -23 \
    <(grep -o 'href="#[^"]*"' "$HTML" | sed -e 's/^href="#//' -e 's/"$//' | sort -u) \
    <(grep -oE '(^|[[:space:]])id="[^"]*"' "$HTML" | sed -e 's/^.*id="//' -e 's/"$//' | sort -u))"
if [[ -n "$dangling" ]]; then
    echo "error: internal links with no matching heading id in ${HTML}:" >&2
    printf '%s\n' "$dangling" | sed 's/^/    #/' >&2
    echo "  (heading ids are GitHub-style slugs: lower case, spaces to '-', punctuation dropped)" >&2
    exit 1
fi

# ---- 4. --html-only stops here ----------------------------------------------

if [[ $HTML_ONLY -eq 1 ]]; then
    echo "Wrote ${HTML}"
    if [[ $OPEN -eq 1 ]]; then
        _open "$HTML"
    fi
    echo "Done: pandoc ${PANDOC_VER}, WeasyPrint ${WP_VER}; HTML preview: ${HTML}"
    exit 0
fi

# ---- 5. WeasyPrint ----------------------------------------------------------

rm -f "$PDF_NEW" "$WP_LOG"
wp_rc=0
weasyprint "$HTML" "$PDF_NEW" 2>"$WP_LOG" || wp_rc=$?
if [[ -s "$WP_LOG" ]]; then
    sed 's/^/weasyprint: /' "$WP_LOG" >&2
fi
if [[ $wp_rc -ne 0 || ! -s "$PDF_NEW" ]]; then
    echo "error: weasyprint failed (exit ${wp_rc}); log: ${WP_LOG}" >&2
    exit 1
fi
# A missing anchor or font is a broken PDF. "Ignored" CSS warnings stay non-fatal.
if grep -q -E 'No anchor|Failed to load|cannot be loaded|ERROR' "$WP_LOG"; then
    echo "error: weasyprint reported a missing anchor or resource (see above); log: ${WP_LOG}" >&2
    exit 1
fi

# ---- 6. PDF sanity ----------------------------------------------------------

facts="$(_pdf_facts "$PDF_NEW")"
pages="${facts%% *}"
has_mailto="${facts##* }"
if [[ -z "$pages" || "$pages" -lt $MIN_PAGES || "$pages" -gt $MAX_PAGES ]]; then
    if [[ $OVERRIDE -eq 1 ]]; then
        echo "warn: ${PDF_NEW} has ${pages:-0} pages (outside ${MIN_PAGES} to ${MAX_PAGES}; ignored for PARTNER_MD)" >&2
    else
        echo "error: ${PDF_NEW} has ${pages:-0} pages; expected ${MIN_PAGES} to ${MAX_PAGES}" >&2
        exit 1
    fi
fi
if [[ "$has_mailto" != "1" ]]; then
    echo "error: ${PDF_NEW} has no mailto:${CONTACT} link" >&2
    exit 1
fi

if command -v pdftotext >/dev/null 2>&1; then
    txt="${BUILD_DIR}/${NAME}.txt"
    pdftotext -layout "$PDF_NEW" "$txt"
    text_failed=0
    for pat in "${FORBIDDEN[@]}"; do
        if grep -q -F -e "$pat" "$txt"; then
            echo "error: the PDF text contains forbidden text '${pat}'" >&2
            text_failed=1
        fi
    done
    if grep -q -i -w -e "legacy" "$txt"; then
        echo "error: the PDF text mentions 'legacy'" >&2
        text_failed=1
    fi
    if ! grep -q -F -e "$CONTACT" "$txt"; then
        echo "error: the PDF text never shows ${CONTACT}" >&2
        text_failed=1
    fi
    if [[ $text_failed -ne 0 ]]; then
        exit 1
    fi
fi

# ---- 7. anti-churn: replace the committed PDF only for a real change --------

result="$PDF"
if [[ $OVERRIDE -eq 1 ]]; then
    echo "PARTNER_MD is set: candidate PDF is ${PDF_NEW} (${pages} pages); ${PDF} left alone"
    result="$PDF_NEW"
elif [[ -f "$PDF" ]] && cmp -s "$PDF_NEW" "$PDF"; then
    echo "PDF unchanged: ${PDF} (${pages} pages)"
else
    base=""
    if [[ -f "$PDF" ]]; then
        base="$(git log -1 --format=%H -- "$PDF" 2>/dev/null || true)"
    fi
    if [[ -n "$base" && $FORCE -eq 0 ]] && _sources_clean_since "$base"; then
        echo "warn: toolchain drift, keeping the committed PDF, pass --force" >&2
        echo "  (${PDF_NEW} differs from ${PDF}, but no source changed since ${base:0:12})" >&2
        result="$PDF_NEW"
    else
        cp "$PDF_NEW" "$PDF"
        echo "Wrote ${PDF} (${pages} pages)"
        if [[ -n "$base" ]] \
                && ! git diff --quiet "$base" -- "$DEFAULT_MD" 2>/dev/null \
                && git diff --quiet "$base" -- "$META" 2>/dev/null; then
            echo "warn: ${DEFAULT_MD} changed since ${base:0:12} but ${META} did not; bump version and date" >&2
        fi
    fi
fi

if [[ $OPEN -eq 1 ]]; then
    _open "$result"
fi

# ---- 8. summary -------------------------------------------------------------

echo "Done: pandoc ${PANDOC_VER}, WeasyPrint ${WP_VER}; HTML preview: ${HTML}"
