#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# tasks/verify-r2/V7/lib.sh -- shared helpers for the V7 SIG harness (sourced)
#
# Every key is a throwaway made in a temporary GNUPGHOME under V7_TMP; nothing
# reads or writes ~/.gnupg. A stage served over file:// stands in for GitHub:
# a curl shim on PATH maps the release URLs the updater and the installer use
# to files under SERVE and answers 22 (HTTP error) for a file that is not
# there.
#
#   V7_WT       the worktree under test (two levels above this file's dir)
#   V7_TMP      scratch dir of this run (created; removed by v7_cleanup)
#   chk NAME EXPECTED ACTUAL / chk_has NAME NEEDLE TEXT / chk_lacks ...
#   v7_keys     make the keys valid, second, expired, revoked, old, foreign
#   v7_sign OUT KEY FILE [expsig]   append KEY's armored signature over FILE
#   v7_sign_errsig OUT KEY FILE     append a signature gpgv answers ERRSIG 4
#   v7_shim BIN SERVE               write the curl shim into BIN
#   v7_build_release DIR            the worktree's tree as a release repo with
#                                   the throwaway keys as lib/release-keys
# bash 3.2 safe.
# =============================================================================

V7_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V7_WT="$(cd "${V7_HERE}/../../.." && pwd)"
V7_SCRATCH_ROOT="${V7_SCRATCH_ROOT:-/tmp/claude-1000/-home-drtnarg-coding-telcoin-tn-node-deployment/a63179cc-f715-4653-8076-ca7024820f15/scratchpad/V7}"
mkdir -p "$V7_SCRATCH_ROOT"
V7_TMP="$(mktemp -d "${V7_SCRATCH_ROOT}/run.XXXXXX")"
V7_TAG="scripts-v2.1.0"
V7_PASS=0
V7_FAIL=0
V7_FAILS=""
export GNUPGHOME="${V7_TMP}/gnupg"
mkdir -p "$GNUPGHOME"
chmod 700 "$GNUPGHOME"
V7_REAL_CURL="$(command -v curl || true)"
V7_REAL_GIT="$(command -v git || true)"
V7_REAL_GPG="$(command -v gpg || true)"

v7_cleanup() {
    local h
    for h in "$V7_TMP"/gnupg*; do
        [[ -d "$h" ]] || continue
        GNUPGHOME="$h" gpgconf --kill gpg-agent >/dev/null 2>&1 || true
    done
    if [[ "${V7_KEEP:-}" != "1" ]]; then
        rm -rf "$V7_TMP"
    fi
}
trap v7_cleanup EXIT

chk() {
    if [[ "$2" == "$3" ]]; then
        V7_PASS=$((V7_PASS + 1))
        printf 'ok    %s\n' "$1"
    else
        V7_FAIL=$((V7_FAIL + 1))
        V7_FAILS="${V7_FAILS}${1}
"
        printf 'FAIL  %s\n      expected: %s\n      actual:   %s\n' "$1" "$2" "$3"
    fi
}

chk_has() {
    case "$3" in
        *"$2"*) chk "$1" yes yes ;;
        *) chk "$1" "output containing [$2]" "$(printf '%s' "$3" | tail -5 | tr '\n' '|')" ;;
    esac
}

chk_lacks() {
    case "$3" in
        *"$2"*) chk "$1" "no [$2] in the output" "found it" ;;
        *) chk "$1" yes yes ;;
    esac
}

v7_finish() {
    printf '\n%s: %s passed, %s failed\n' "${0##*/}" "$V7_PASS" "$V7_FAIL"
    if [[ $V7_FAIL -ne 0 ]]; then
        printf 'failed checks:\n%s' "$V7_FAILS"
        exit 1
    fi
    exit 0
}

v7_sha() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi | awk '{print $1}'
}

g() {
    "$V7_REAL_GPG" --batch --no-tty --quiet --pinentry-mode loopback --passphrase '' "$@"
}

# v7_fpr NAME -- the fingerprint of throwaway key NAME.
v7_fpr() {
    cat "${V7_TMP}/keys/$1.fpr"
}

# v7_newkey NAME KIND -- KIND valid, expired (made in 2020, expired after 2
# days), old (made in 2020, never expires: signs with an expired signature) or
# revoked (the exported public key carries its revocation).
v7_newkey() {
    local name="$1" kind="$2" fpr home
    mkdir -p "${V7_TMP}/keys"
    case "$kind" in
        expired) g --faked-system-time 20200101T000000 --quick-gen-key "$name <$name@example.invalid>" ed25519 sign 2d 2>/dev/null ;;
        old) g --faked-system-time 20200101T000000 --quick-gen-key "$name <$name@example.invalid>" ed25519 sign never 2>/dev/null ;;
        *) g --quick-gen-key "$name <$name@example.invalid>" ed25519 sign 1y 2>/dev/null ;;
    esac
    fpr="$("$V7_REAL_GPG" --batch --with-colons --list-keys "<$name@example.invalid>" 2>/dev/null | awk -F: '$1 == "fpr" { print $10; exit }')"
    printf '%s\n' "$fpr" > "${V7_TMP}/keys/${name}.fpr"
    g --armor --export "$fpr" > "${V7_TMP}/keys/${name}.asc"
    if [[ "$kind" == revoked ]]; then
        home="${V7_TMP}/gnupg-rev-${name}"
        mkdir -p "$home"
        chmod 700 "$home"
        GNUPGHOME="$home" g --import "${V7_TMP}/keys/${name}.asc" 2>/dev/null
        sed 's/^:-----BEGIN/-----BEGIN/' "${GNUPGHOME}/openpgp-revocs.d/${fpr}.rev" | GNUPGHOME="$home" g --import 2>/dev/null
        GNUPGHOME="$home" g --armor --export "$fpr" > "${V7_TMP}/keys/${name}.asc"
    fi
}

v7_keys() {
    v7_newkey valid valid
    v7_newkey second valid
    v7_newkey expired expired
    v7_newkey revoked revoked
    v7_newkey old old
    v7_newkey foreign valid
}

# v7_sign OUT KEY FILE [expsig] -- append KEY's armored detached signature over
# FILE to OUT. The expired key signs in 2020 (when it was valid); expsig makes
# the old key sign in 2021 with a signature that expired a day later.
v7_sign() {
    local out="$1" key="$2" file="$3" fpr
    fpr="$(v7_fpr "$key")"
    if [[ "${4:-}" == expsig ]]; then
        g --faked-system-time 20210101T000000 --default-sig-expire 1d -u "${fpr}!" --armor --detach-sign -o - "$file" >> "$out" 2>/dev/null
    elif [[ "$key" == expired ]]; then
        g --faked-system-time 20200101T000100 -u "${fpr}!" --armor --detach-sign -o - "$file" >> "$out" 2>/dev/null
    else
        g -u "${fpr}!" --armor --detach-sign -o - "$file" >> "$out" 2>/dev/null
    fi
}

# v7_sign_errsig OUT KEY FILE -- append KEY's signature over FILE with its
# public-key algorithm byte set to 99: gpgv answers ERRSIG <id> 99 ... 4.
v7_sign_errsig() {
    local out="$1" fpr bin
    fpr="$(v7_fpr "$2")"
    bin="${V7_TMP}/errsig.$$.sig"
    g -u "${fpr}!" --detach-sign -o - "$3" > "$bin" 2>/dev/null
    python3 -I -c 'import sys
p = sys.argv[1]
b = bytearray(open(p, "rb").read())
assert b[0] == 0x88 and b[2] == 4
b[4] = 99
open(p, "wb").write(b)' "$bin"
    g --enarmor < "$bin" | sed -e 's/ARMORED FILE/SIGNATURE/' -e '/^Comment:/d' >> "$out"
    rm -f "$bin"
}

# v7_shim BIN SERVE -- curl on BIN that serves SERVE over file://:
#   .../tn-node-deployment/main/P            SERVE/main/P
#   .../tn-node-deployment/refs/tags/T/P     SERVE/tags/T/P
#   github.com/.../archive/refs/tags/T.tar.gz  SERVE/archive/T.tar.gz
#   https://install.telcoin.network          SERVE/installer
# Every call is logged to SERVE/curl.log.
v7_shim() {
    mkdir -p "$1"
    cat > "$1/curl" <<EOF
#!/usr/bin/env bash
SERVE="$2"
REAL="$V7_REAL_CURL"
EOF
    cat >> "$1/curl" <<'EOF'
out="" url="" head=0
while [ $# -gt 0 ]; do
    case "$1" in
        -o) out="$2"; shift ;;
        -fsSLI|-I) head=1 ;;
        --proto|--max-time) shift ;;
        https://*) url="$1" ;;
    esac
    shift
done
echo "curl ${url}" >> "$SERVE/curl.log"
p=""
case "$url" in
    https://raw.githubusercontent.com/Telcoin-Association/tn-node-deployment/main/*) p="$SERVE/main/${url#*/tn-node-deployment/main/}" ;;
    https://raw.githubusercontent.com/Telcoin-Association/tn-node-deployment/refs/tags/*) p="$SERVE/tags/${url#*/tn-node-deployment/refs/tags/}" ;;
    https://github.com/Telcoin-Association/tn-node-deployment/archive/refs/tags/*) p="$SERVE/archive/${url##*/}" ;;
    https://install.telcoin.network) p="$SERVE/installer" ;;
esac
[ -n "$p" ] && [ -f "$p" ] || exit 22
[ "$head" -eq 0 ] || exit 0
if [ -n "$out" ]; then exec "$REAL" -fsS -o "$out" "file://$p"; fi
exec "$REAL" -fsS "file://$p"
EOF
    chmod +x "$1/curl"
}

# v7_git ARGS -- git with a throwaway identity, no signing, no global config.
v7_git() {
    HOME="${V7_TMP}/home" GIT_CONFIG_NOSYSTEM=1 "$V7_REAL_GIT" -c user.name=v7 -c user.email=v7@example.invalid \
        -c commit.gpgsign=false -c tag.gpgsign=false "$@"
}

# v7_build_release DIR -- DIR: the worktree's committed tree as a git repo
# whose lib/release-keys holds the throwaway keys (grantkee.asc is the valid
# key; second, expired, revoked and old ride as SCRIPTS rows), with fresh
# sidecars, committed. The foreign key is not shipped.
v7_build_release() {
    local d="$1" k
    mkdir -p "$d" "${V7_TMP}/home"
    "$V7_REAL_GIT" -C "$V7_WT" archive HEAD | tar -xf - -C "$d"
    cp "${V7_TMP}/keys/valid.asc" "$d/lib/release-keys/grantkee.asc"
    for k in second expired revoked old; do
        cp "${V7_TMP}/keys/${k}.asc" "$d/lib/release-keys/${k}.asc"
    done
    awk '{ print }
        /^    "lib\/release-keys\/grantkee.asc:lib\/release-keys\/grantkee.asc:NONE"$/ {
            n = split("second expired revoked old", ks, " ")
            for (i = 1; i <= n; i++) printf "    \"lib/release-keys/%s.asc:lib/release-keys/%s.asc:NONE\"\n", ks[i], ks[i]
        }' "$d/update-scripts.sh" > "$d/update-scripts.sh.new"
    mv "$d/update-scripts.sh.new" "$d/update-scripts.sh"
    chmod +x "$d/update-scripts.sh"
    (cd "$d" && bash tools/gen-checksums.sh >/dev/null)
    v7_git -C "$d" init -q -b main
    v7_git -C "$d" add -A
    v7_git -C "$d" commit -q -m "V7 test tree"
}

# v7_serve_init SERVE REPO -- SERVE/tags/TAG: REPO's tree with its MANIFEST,
# MANIFEST.asc (the release commit); SERVE/main: RELEASE and README.md.
v7_serve_init() {
    local s="$1" r="$2"
    rm -rf "$s"
    mkdir -p "$s/main" "$s/pack/tn-node-deployment-${V7_TAG}" "$s/tags" "$s/archive"
    "$V7_REAL_GIT" -C "$r" archive HEAD | tar -xf - -C "$s/pack/tn-node-deployment-${V7_TAG}"
    ln -s "$s/pack/tn-node-deployment-${V7_TAG}" "$s/tags/${V7_TAG}"
    cp "$r/RELEASE" "$r/README.md" "$s/main/"
    cp "$r/install.sh" "$s/installer"
    : > "$s/curl.log"
}

# v7_serve_pack SERVE -- rebuild the tag archive from SERVE/pack.
v7_serve_pack() {
    rm -f "$1/archive/${V7_TAG}.tar.gz"
    tar -czf "$1/archive/${V7_TAG}.tar.gz" -C "$1/pack" "tn-node-deployment-${V7_TAG}"
}
