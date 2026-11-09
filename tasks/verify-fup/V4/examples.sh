#!/usr/bin/env bash
# tasks/verify-fup/V4/examples.sh -- print sample update-scripts.sh --check
# reports and the --help exit-status text for the record (records/check-examples.txt).
set -u
# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/v4lib.sh"
# shellcheck source=/dev/null
. "$V4_DIR/updlib.sh"
export V4_TODAY=2027-03-15
U="$V4_REPO/update-scripts.sh"
R1="$SRC/r1"; mkrel "$R1" "$U" 1.0.0; mkman "$R1" "$(hdr scripts-v1.0.0 1)"$'\n'"date=2027-01-01"$'\n'"expires=2027-03-10"$'\n'; sign "$R1"
R2="$SRC/r2"; mkrel "$R2" "$U" 1.1.0; mkman "$R2" "$(hdr scripts-v1.1.0 2)"$'\n'"date=2027-03-01"$'\n'"expires=2027-05-30"$'\n'; sign "$R2"; publish "$R2" scripts-v1.1.0
show() { printf '\n### %s (rc %s)\n%s\n' "$1" "$RC" "$(plain "$OUT")"; }
install_from "$R2"; run_check; show "installed = newest, fresh (today 2027-03-15)"
install_from "$R1"; run_check; show "installed R1 expired, newest R2 fresh: pending"
export V4_CURL_FAIL=7; run_check; show "installed R1 expired, network down"; unset V4_CURL_FAIL
rm -f "$INST/MANIFEST.sig"; run_check; show "installed MANIFEST.sig missing"
rm -f "$INST/MANIFEST"; run_check; show "nothing installed"
run_upd "" --help; printf '\n### --help (tail)\n%s\n' "$(plain "$OUT" | tail -n 22)"
