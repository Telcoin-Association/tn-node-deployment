#!/usr/bin/env bash
# shellcheck shell=bash
# tasks/verify-fup/V4/instlib.sh -- install.sh fixtures for V4. Sourced after
# v4lib.sh. bash 3.2 safe.

# tagged_copy INSTALLER TAG OUT -- INSTALLER with TN_SCRIPTS_TAG and the signer
# block written in (key1), the way tools/release-scripts.sh rewrites it.
tagged_copy() {
    printf '# test signers\n%s\n' "$KEY1_LINE" > "$T/signers.txt"
    awk -v tag="$2" -v sf="$T/signers.txt" -v q="'" '
        /^readonly TN_SCRIPTS_TAG=/ { print "readonly TN_SCRIPTS_TAG=\"" tag "\""; next }
        skipping && $0 == "TN_ALLOWED_SIGNERS" { skipping = 0 }
        skipping { next }
        { print }
        index($0, "<<" q "TN_ALLOWED_SIGNERS" q) {
            while ((getline line < sf) > 0) print line
            close(sf)
            skipping = 1
        }
    ' "$1" > "$3"
}

# irel DIR TAG HEADER_TEXT [KEY] -- a release tree whose MANIFEST is
# HEADER_TEXT then the sha lines, signed with KEY (default v4key1).
irel() {
    local d="$1" p
    rm -rf "$d"
    mkdir -p "$d/lib" "$d/ui"
    cp "$V4_REPO/update-scripts.sh" "$d/update-scripts.sh"
    printf '# test signers\n%s\n' "$KEY1_LINE" > "$d/lib/allowed_signers"
    printf '#!/usr/bin/env bash\necho setup\n' > "$d/setup-node.sh"
    printf 'UI_VERSION = "1.0.0"\n' > "$d/ui/server.py"
    printf 'docs\n' > "$d/README.md"
    {
        printf '%s' "$3"
        for p in lib/allowed_signers setup-node.sh ui/server.py update-scripts.sh; do
            printf 'sha256  %s  %s\n' "$(_h "$d/$p")" "$p"
        done
    } > "$d/MANIFEST"
    sign_file "$d/MANIFEST" "${4:-v4key1}"
}

# pack DIR TAG -- serve DIR as the GitHub archive of TAG.
pack() {
    local top="tn-node-deployment-$2"
    rm -rf "${T:?}/pack"
    mkdir -p "$T/pack"
    cp -R "$1" "$T/pack/$top"
    (cd "$T/pack" && tar -czf "$T/archives/$2.tar.gz" "$top")
}

# run_inst COPY -- a fresh HOME each run; OUT, RC, IDIR (the install dir).
run_inst() {
    rm -rf "$T/home"
    mkdir -p "$T/home"
    : > "$T/curl.log"
    OUT="$(HOME="$T/home" TERM=dumb bash "$1" --yes < /dev/null 2>&1)"
    RC=$?
    IDIR="$T/home/telcoin-node-scripts"
}
installed() { [[ -f "$IDIR/MANIFEST" && -f "$IDIR/setup-node.sh" ]] && echo yes || echo no; }
