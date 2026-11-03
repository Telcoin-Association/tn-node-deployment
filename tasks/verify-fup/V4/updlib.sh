#!/usr/bin/env bash
# shellcheck shell=bash
# tasks/verify-fup/V4/updlib.sh -- release fixtures for the V4 updater tests.
# Sourced after v4lib.sh. bash 3.2 safe.

SRC="$T/src"
INST="$T/inst"
mkdir -p "$SRC" "$T/tmpdir"
printf 'README\n' > "$RAW/main/README.md"

# mkrel DIR UPDATER [SETUP_VERSION] -- a release tree: the given updater and
# small stand-ins for the other files.
mkrel() {
    rm -rf "$1"
    mkdir -p "$1/lib" "$1/ui"
    cp "$2" "$1/update-scripts.sh"
    printf '# test signers\n%s\n' "$KEY1_LINE" > "$1/lib/allowed_signers"
    printf '#!/usr/bin/env bash\nreadonly SCRIPT_VERSION="%s"\n' "${3:-1.0.0}" > "$1/setup-node.sh"
    printf '#!/usr/bin/env bash\nreadonly COMMON_VERSION="1.0.0"\n' > "$1/lib/common.sh"
    printf 'UI_VERSION = "1.0.0"\n' > "$1/ui/server.py"
}

# hdr TAG SERIAL [MIN] -- the four lines every manifest carries.
hdr() { printf 'format=1\nrelease=%s\nserial=%s\nmin_updater=%s\n' "$1" "$2" "${3:-1.0.0}"; }

# mkman DIR HEADER_TEXT -- MANIFEST = HEADER_TEXT (verbatim, newline-ended
# lines) then one sha256 line per file, sorted by path.
mkman() {
    local d="$1" p
    {
        printf '%s' "$2"
        (cd "$d" && find . -type f ! -name MANIFEST ! -name MANIFEST.sig ! -name '*.sha256' | sed 's|^\./||' | LC_ALL=C sort) \
            | while IFS= read -r p; do printf 'sha256  %s  %s\n' "$(_h "$d/$p")" "$p"; done
    } > "$d/MANIFEST"
}

sign() { sign_file "$1/MANIFEST" "${2:-v4key1}"; }

# publish DIR TAG -- serve DIR as release TAG and point RELEASE at it.
publish() {
    rm -rf "$RAW/refs/tags/$2"
    mkdir -p "$RAW/refs/tags"
    cp -R "$1" "$RAW/refs/tags/$2"
    printf '%s 2027-03-01\n' "$2" > "$RAW/main/RELEASE"
}

# install_from DIR -- INST becomes a copy of DIR (files and the record).
install_from() {
    rm -rf "$INST"
    cp -R "$1" "$INST"
    chmod +x "$INST/update-scripts.sh"
}

tree_sig() {
    (cd "$INST" && find . -print | LC_ALL=C sort \
        && find . -type f -print | LC_ALL=C sort | while IFS= read -r f; do printf '%s %s\n' "$(_h "$f")" "$f"; done)
}

# run_upd ANSWER [ARGS...] -- run INST's updater from RUN_CWD (default $T);
# OUT and RC get its output and status.
run_upd() {
    local ans="$1"
    shift
    : > "$T/curl.log"
    OUT="$(cd "${RUN_CWD:-$T}" && printf '%s\n' "$ans" | TMPDIR="$T/tmpdir" TERM=dumb bash "${UPD:-$INST/update-scripts.sh}" "$@" 2>&1)"
    RC=$?
}

# run_check [ARGS...] -- update-scripts.sh --check with no stdin.
run_check() {
    : > "$T/curl.log"
    OUT="$(cd "${RUN_CWD:-$T}" && TMPDIR="$T/tmpdir" TERM=dumb bash "${UPD:-$INST/update-scripts.sh}" --check "$@" < /dev/null 2>&1)"
    RC=$?
}
