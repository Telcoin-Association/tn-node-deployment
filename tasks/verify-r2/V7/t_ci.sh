#!/usr/bin/env bash
# =============================================================================
# tasks/verify-r2/V7/t_ci.sh -- V7 SIG item 7: the CI manifest grep, the VM
# assertion P0-05, CODEOWNERS, and what is left of the SSH signing words in
# code, workflows and tests (tasks/, CHANGELOG/, README.md, OPERATOR.md and
# the partner guide are DOCS-2's and only listed).
#
#   bash tasks/verify-r2/V7/t_ci.sh
# bash 3.2 safe.
# =============================================================================

set -u
# shellcheck source=tasks/verify-r2/V7/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
cd "$V7_WT" || exit 2

line="$(grep -n "grep -qxE 'MANIFEST|MANIFEST" .github/workflows/ci.yml)"
chk "ci.yml: one manifest grep" 1 "$(printf '%s\n' "$line" | grep -c .)"
re="$(printf '%s\n' "$line" | sed "s/.*grep -qxE '\\([^']*\\)'.*/\\1/")"
chk "ci.yml: the grep is MANIFEST|MANIFEST\\.asc|RELEASE" 'MANIFEST|MANIFEST\.asc|RELEASE' "$re"
for p in MANIFEST MANIFEST.asc RELEASE; do
    chk "ci.yml grep matches ${p}" yes "$(printf '%s\n' "$p" | grep -qxE "$re" && echo yes || echo no)"
done
for p in MANIFEST.sig MANIFESTxasc lib/MANIFEST install.sh; do
    chk "ci.yml grep does not match ${p}" no "$(printf '%s\n' "$p" | grep -qxE "$re" && echo yes || echo no)"
done
chk "ci.yml: the tag path runs --check --tag" 1 "$(grep -c 'bash tools/release-scripts.sh --check --tag "$REF_NAME"' .github/workflows/ci.yml)"
chk "ci.yml: a release change runs --check --require-sig" 1 "$(grep -c 'bash tools/release-scripts.sh --check --require-sig$' .github/workflows/ci.yml)"
chk "publish-installer.yml: checks the tag before publishing" 1 "$(grep -c 'bash tools/release-scripts.sh --check --tag "$TAG"' .github/workflows/publish-installer.yml)"
chk "P0-05: asserts gpgv" 1 "$(grep -c 'command -v gpgv' tools/tests/vm.d/P0-05.sh)"
chk "P0-05: no ssh-keygen" 0 "$(grep -c 'ssh-keygen' tools/tests/vm.d/P0-05.sh)"
chk "P0-05: runs the four fixtures" 1 "$(grep -c 'for t in updater_manifest_test.sh install_test.sh release_scripts_test.sh cut_release_test.sh' tools/tests/vm.d/P0-05.sh)"
chk "CODEOWNERS: /lib/release-keys/ has three owners" "@grantkee @sstanfield @MavenRain" "$(awk '$1 == "/lib/release-keys/" { $1 = ""; sub(/^ /, ""); print }' .github/CODEOWNERS)"
chk "CODEOWNERS: /MANIFEST.asc has three owners" "@grantkee @sstanfield @MavenRain" "$(awk '$1 == "/MANIFEST.asc" { $1 = ""; sub(/^ /, ""); print }' .github/CODEOWNERS)"
chk "CODEOWNERS: no /lib/allowed_signers or /MANIFEST.sig" 0 "$(grep -c -E '^/(lib/allowed_signers|MANIFEST\.sig)' .github/CODEOWNERS)"
chk "lib/allowed_signers and its sidecar are gone" "no no" "$([[ -e lib/allowed_signers ]] && echo yes || echo no) $(git ls-files --error-unmatch lib/allowed_signers.sha256 >/dev/null 2>&1 && echo yes || echo no)"
chk "update-scripts.sh SCRIPTS has no lib/allowed_signers row" 0 "$(grep -c 'allowed_signers' update-scripts.sh)"
chk "lib/release-keys/README says the keys sign script releases" yes "$(grep -qiE 'script release' lib/release-keys/README && echo yes || echo no)"

words='allowed_signers|MANIFEST\.sig|ssh-keygen|tn-node-scripts|release@telcoin\.org'
# Code, workflows, tests and shipped non-markdown files; the VPN tooling's own
# use of ssh-keygen -lf (key fingerprints, not release signing) is left out.
code="$(git grep -n -I -E "$words" -- . ':!tasks/' ':!*.md' ':!docs/' 2>/dev/null \
    | grep -v -E '^(setup-vpn\.sh|tools/tests/vpn_selfheal_test\.sh|lib/wgvpn/peers/ssh/KEYS):' || true)"
printf '   code/workflow/test hits:\n%s\n' "$(printf '%s\n' "$code" | sed 's/^/     /')"
chk "no SSH signing words left in code, workflows and tests" 0 "$(printf '%s\n' "$code" | grep -c .)"
docs="$(git grep -c -I -E "$words" -- '*.md' ':!tasks/' 2>/dev/null || true)"
printf '   markdown still naming them (file:count; DOCS-2, VPN fingerprint lines included):\n%s\n' "$(printf '%s\n' "$docs" | sed 's/^/     /')"
v7_finish
