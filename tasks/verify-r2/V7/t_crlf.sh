#!/usr/bin/env bash
# =============================================================================
# tasks/verify-r2/V7/t_crlf.sh -- V7 SIG: a release whose key file has CRLF
# line endings, end to end: prepare, sign, --check --require-sig, install.sh.
#
#   bash tasks/verify-r2/V7/t_crlf.sh          (host: gpg and gpgv)
# bash 3.2 safe.
# =============================================================================

set -u
# shellcheck source=tasks/verify-r2/V7/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
R="${V7_TMP}/repo"
v7_keys
v7_build_release "$R"
sed 's/$/\r/' "${V7_TMP}/keys/valid.asc" > "$R/lib/release-keys/grantkee.asc"
(cd "$R" && bash tools/gen-checksums.sh >/dev/null)
v7_git -C "$R" add -A
v7_git -C "$R" commit -q -m "crlf key"
RC=0; OUT="$(cd "$R" && HOME="${V7_TMP}/home" bash tools/release-scripts.sh --serial 1 "$V7_TAG" 2>&1)" || RC=$?
chk "crlf key: prepare accepts it" 0 "$RC"
chk "crlf key: install.sh embeds it with its CRs" 1 "$(grep -c $'^-----BEGIN PGP PUBLIC KEY BLOCK-----\r$' "$R/install.sh")"
v7_sign "$R/MANIFEST.asc" valid "$R/MANIFEST"
RC=0; OUT="$(cd "$R" && bash tools/release-scripts.sh --check --require-sig --tag "$V7_TAG" 2>&1)" || RC=$?
chk "crlf key: --check --require-sig passes" 0 "$RC"
v7_git -C "$R" add MANIFEST MANIFEST.asc RELEASE install.sh
v7_git -C "$R" commit -q -m "release"
v7_serve_init "${V7_TMP}/serve" "$R"
v7_serve_pack "${V7_TMP}/serve"
v7_shim "${V7_TMP}/bin" "${V7_TMP}/serve"
mkdir -p "${V7_TMP}/ih"
RC=0; OUT="$(PATH="${V7_TMP}/bin:$PATH" HOME="${V7_TMP}/ih" bash "$R/install.sh" --yes 2>&1)" || RC=$?
chk "crlf key: the released install.sh installs (it refuses: the finding)" 0 "$RC"
printf '   install.sh: %s\n' "$(printf '%s\n' "$OUT" | grep -m1 'ERROR' || true)"
mkdir -p "${V7_TMP}/h/lib/release-keys"
cp "$R/update-scripts.sh" "${V7_TMP}/h/"
cp "$R"/lib/release-keys/*.asc "${V7_TMP}/h/lib/release-keys/"
RC=0; OUT="$(printf 'n\n' | PATH="${V7_TMP}/bin:$PATH" TERM=dumb bash "${V7_TMP}/h/update-scripts.sh" 2>&1)" || RC=$?
chk "crlf key: update-scripts.sh with the CRLF key verifies" 0 "$RC"
v7_finish
