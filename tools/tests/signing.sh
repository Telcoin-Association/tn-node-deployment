#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# tools/tests/signing.sh -- release-signing helpers for the fixture tests
#
# Sourced (never run) by updater_manifest_test.sh and install_test.sh after
# tools/tests/lib.sh, with BIN set to a directory that is put first on PATH.
#
#   REAL_SSH        1 when ssh-keygen can make and use an ed25519 key here
#   newkey NAME     make key $TN_TEST_TMP/NAME; print its allowed-signers line
#   sign_file FILE KEYNAME   write FILE.sig with key NAME, namespace tn-node-scripts
#
# Where ssh-keygen is absent (the bash:3.2 image) a fake ssh-keygen with the
# same -Y sign / -Y verify interface goes into BIN: a "key" is a random token
# and a signature names the namespace, the token and the SHA-256 of the data.
# Tests report the real-signature checks as SKIP in that case.
#
# Maintainer tooling: not tracked by the updater, no .sha256 sidecar. bash 3.2 safe.
# =============================================================================


REAL_SSH=0
if command -v ssh-keygen >/dev/null 2>&1; then
    ssh-keygen -q -t ed25519 -N '' -C probe -f "$TN_TEST_TMP/probe" >/dev/null 2>&1 \
        && printf 'x\n' > "$TN_TEST_TMP/probe.txt" \
        && ssh-keygen -Y sign -f "$TN_TEST_TMP/probe" -n tn-node-scripts "$TN_TEST_TMP/probe.txt" >/dev/null 2>&1 \
        && REAL_SSH=1
fi
if [[ $REAL_SSH -eq 0 ]]; then
    cat > "$BIN/ssh-keygen" <<'EOF'
#!/usr/bin/env bash
# Fake ssh-keygen for hosts without OpenSSH. A "key" is a random token; a
# signature names the namespace, the token and the SHA-256 of the data.
h() { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi | awk '{print $1}'; }
mode="" key="" ns="" princ="" sig="" file=""
while [ $# -gt 0 ]; do
    case "$1" in
        -Y) mode="$2"; shift ;;
        -f) key="$2"; shift ;;
        -n) ns="$2"; shift ;;
        -I) princ="$2"; shift ;;
        -s) sig="$2"; shift ;;
        -t|-N|-C) shift ;;
        -q) ;;
        *) file="$1" ;;
    esac
    shift
done
case "$mode" in
    "")
        tok="k${RANDOM}${RANDOM}${RANDOM}$$"
        echo "FAKEKEY $tok" > "$key"
        echo "fake-ed25519 $tok" > "$key.pub" ;;
    sign)
        tok="$(awk '{print $2}' "$key")"
        printf 'FAKESIG %s %s %s\n' "$ns" "$tok" "$(h < "$file")" > "$file.sig" ;;
    verify)
        read -r magic sns stok shash < "$sig" || { echo "bad signature" >&2; exit 255; }
        [ "$magic" = FAKESIG ] && [ "$sns" = "$ns" ] || { echo "bad signature" >&2; exit 255; }
        grep -v '^[[:space:]]*#' "$key" | grep -F "$princ namespaces=\"$ns\" fake-ed25519 $stok" >/dev/null \
            || { echo "no principal matched" >&2; exit 255; }
        [ "$(h)" = "$shash" ] || { echo "signature verification failed" >&2; exit 255; }
        echo "Good \"$ns\" signature for $princ with FAKE key $stok" ;;
esac
EOF
    chmod +x "$BIN/ssh-keygen"
fi
export PATH="$BIN:$PATH"

# newkey NAME -- make a key; print its allowed-signers line.
newkey() {
    ssh-keygen -q -t ed25519 -N '' -C "$1" -f "$TN_TEST_TMP/$1" >/dev/null 2>&1
    printf 'release@telcoin.org namespaces="tn-node-scripts" %s\n' "$(awk '{print $1, $2}' "$TN_TEST_TMP/$1.pub")"
}

sign_file() {
    rm -f "$1.sig"
    ssh-keygen -Y sign -f "$TN_TEST_TMP/$2" -n tn-node-scripts "$1" >/dev/null 2>&1
}
