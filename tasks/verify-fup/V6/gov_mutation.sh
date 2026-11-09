#!/usr/bin/env bash
# V6 GOV mutation run: applies one mutation at a time to a temp copy of the
# workflows and runs tools/tests/ci_pins_test.sh on it. "caught" = the test
# fails. Usage: bash gov_mutation.sh [REV]   (default HEAD)
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$here/../../.." && pwd)"
REV="${1:-HEAD}"
SH="${BASH:-bash}"
T="$(mktemp -d)"
trap 'rm -rf "${T:?}"' EXIT
mkdir -p "$T/clean"
git -C "$REPO" archive "$REV" .github tools lib | tar -x -C "$T/clean"
CI=.github/workflows/ci.yml
PI=.github/workflows/publish-installer.yml

fresh() { rm -rf "${T:?}/m"; cp -R "$T/clean" "$T/m"; }
pins() { (cd "$T/m" && "$SH" tools/tests/ci_pins_test.sh > "$T/out" 2>&1); }
# edit FILE AWKPROG -- rewrite FILE in the copy through awk
edit() { awk "$2" "$T/m/$1" > "$T/tmpf" && cat "$T/tmpf" > "$T/m/$1"; }

caught=0
missed=0
want_caught() {
    if pins; then
        missed=$((missed + 1)); printf 'MISSED  %s\n' "$1"
    else
        caught=$((caught + 1)); printf 'caught  %s  (%s)\n' "$1" "$(grep -m1 -E '^ *(FAIL|not ok|✗)|FAIL' "$T/out" | cut -c1-110)"
    fi
}

fresh
if pins; then printf 'baseline: ci_pins_test.sh passes on the clean copy\n'; else printf 'baseline FAILED\n'; cat "$T/out"; exit 1; fi

fresh; edit "$CI" '{ if ($0 == "    name: hardening lints") $0 = "    name: hardening lint"; print }'
want_caught "rename job: hardening lints -> hardening lint"
fresh; edit "$CI" '{ if ($0 == "    name: shellcheck") $0 = "    name: hardening lints"; print }'
want_caught "two jobs with one display name"
fresh; edit "$CI" '/- name: network hits/ { skip = 1; next } skip && /run: bash tools\/check-network-hits.sh/ { skip = 0; next } { print }'
want_caught "drop the network hits step"
fresh; edit "$PI" '{ print } /CNAME/ { print "          touch _site/.nojekyll                      # skip Jekyll processing" }'
want_caught "restore touch _site/.nojekyll"
fresh; edit "$CI" '{ print } /- name: network hits/ { print "        continue-on-error: true" }'
want_caught "continue-on-error on the network hits step"
fresh; edit "$CI" '{ print } /^  ui-tests:$/ { print "    continue-on-error: true" }'
want_caught "continue-on-error on the ui-tests job"
fresh; edit "$CI" '/run: \/bin\/bash ui\/tests\/install_ui_test.sh/ { next } { print }'
want_caught "drop install_ui_test.sh from parse-macos"
fresh; edit "$CI" '{ if ($0 ~ /run: python -m pytest -q ui/) print "        run: python -m pytest -q ui || python -m unittest discover -s ui"; else print }'
want_caught "re-add a unittest fallback"
# Probes for steps that still name the command but no longer gate:
fresh; edit "$CI" '{ if ($0 ~ /run: bash tools\/check-network-hits.sh/) print "        run: bash tools/check-network-hits.sh || true"; else print }'
want_caught "PROBE network hits step neutered with || true"
fresh; edit "$CI" '{ print } /- name: network hits/ { print "        if: false" }'
want_caught "PROBE network hits step disabled with if: false"
fresh; edit "$CI" '{ print } /^  fixture-tests:$/ { print "    continue-on-error: true" }'
want_caught "PROBE continue-on-error on fixture-tests (a required job not in the list)"
fresh; edit "$CI" '{ print } /^  checksums:$/ { print "    if: false" }'
want_caught "PROBE checksums job disabled with if: false"

printf '\n%d caught, %d missed\n' "$caught" "$missed"
