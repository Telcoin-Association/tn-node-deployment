#!/usr/bin/env bash
# V4: the 2.0.0 updater and installer (main 1187ddb, extracted by run.sh into
# cache/) accept manifests carrying date= and expires=: their parse functions,
# a full 2.0.0 installer run, and full 2.0.0 updater runs (same updater, and
# the 2.0.0 -> tip self-replacement path with an expired release).
set -u
# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/v4lib.sh"
# shellcheck source=/dev/null
. "$V4_DIR/updlib.sh"
# shellcheck source=/dev/null
. "$V4_DIR/instlib.sh"

U200="$V4_CACHE/update-scripts-2.0.0.sh"
I200="$V4_CACHE/install-2.0.0.sh"
if [[ ! -f "$U200" || ! -f "$I200" ]]; then
    skip "2.0.0 compatibility" "cache/ has no 2.0.0 copies (run.sh extracts them with git on the host)"
    finish
fi
check "cache holds update-scripts 2.0.0" '2.0.0' "$(sed -n 's/^readonly SCRIPT_VERSION="\(.*\)"$/\1/p' "$U200")"
TIP="$V4_REPO/update-scripts.sh"
export V4_TODAY=2027-03-15
KEYS_FRESH="date=2027-03-01"$'\n'"expires=2027-05-30"$'\n'
KEYS_EXP="date=2027-03-01"$'\n'"expires=2027-03-10"$'\n'

# --- 1. the 2.0.0 parse_manifest, cut from the 2.0.0 updater ----------------------
TN_SCRIPTS_TAG_RE='^scripts-v[0-9]+\.[0-9]+\.[0-9]+$'
print_error() { printf 'ERROR %s\n' "$*"; }
eval "$(sed -n '/^path_ok() {/,/^}/p; /^manifest_bad() {/,/^}/p; /^manifest_sha_for() {/,/^}/p; /^parse_manifest() {/,/^}/p' "$U200")"
M_PATHS=(); M_SHAS=()
P="$SRC/p"
for c in "keys after min_updater|$(hdr scripts-v1.1.0 2)"$'\n'"$KEYS_FRESH" \
         "keys before format|${KEYS_EXP}$(hdr scripts-v1.1.0 2)"$'\n' \
         "no keys|$(hdr scripts-v1.1.0 2)"$'\n' \
         "malformed expires (2.0.0 does not read it)|$(hdr scripts-v1.1.0 2)"$'\n'"expires=2027-02-30"$'\n'; do
    name="${c%%|*}"
    mkrel "$P" "$TIP" 1.1.0
    mkman "$P" "${c#*|}"
    out="$(parse_manifest "$P/MANIFEST" 2>&1; echo "rc=$? serial=$M_SERIAL")"
    check "2.0.0 parse_manifest, $name: accepted" "rc=0 serial=2" "$(printf '%s\n' "$out" | tail -n 1)"
done

# --- 2. a full 2.0.0 installer run on a release carrying the keys ----------------------
TAG=scripts-v1.0.0
COPY="$T/install-200.sh"
tagged_copy "$I200" "$TAG" "$COPY"
H="format=1"$'\n'"release=$TAG"$'\n'"serial=3"$'\n'"min_updater=1.0.0"$'\n'
REL="$T/rel"
irel "$REL" "$TAG" "${H}${KEYS_EXP}"; pack "$REL" "$TAG"; run_inst "$COPY"
check_rc "2.0.0 installer, expired keys: rc 0" 0 "$RC"
check "2.0.0 installer, expired keys: installed" yes "$(installed)"
hasnt "2.0.0 installer: no expiry warning (it knows nothing of expires=)" "expired" "$OUT"
irel "$REL" "$TAG" "${KEYS_FRESH}${H}"; pack "$REL" "$TAG"; run_inst "$COPY"
check_rc "2.0.0 installer, keys before format: rc 0" 0 "$RC"

# --- 3. full 2.0.0 updater runs ------------------------------------------------------
R1="$SRC/r1"; mkrel "$R1" "$U200" 1.0.0; mkman "$R1" "$(hdr scripts-v2.0.0 1)"$'\n'; sign "$R1"
R2="$SRC/r2"
# a. the release ships the same 2.0.0 updater and the new keys
mkrel "$R2" "$U200" 1.1.0; mkman "$R2" "$(hdr scripts-v2.1.0 2)"$'\n'"$KEYS_FRESH"; sign "$R2"; publish "$R2" scripts-v2.1.0
install_from "$R1"
run_upd y
check_rc "2.0.0 updater, same updater + keys: rc 0" 0 "$RC"
check "2.0.0 updater, same updater + keys: record is R2" "$(_h "$R2/MANIFEST")" "$(_h "$INST/MANIFEST")"
check "2.0.0 updater, same updater + keys: setup-node updated" "$(_h "$R2/setup-node.sh")" "$(_h "$INST/setup-node.sh")"
# b. the release ships the tip updater and has expired: 2.0.0 relaunches the tip copy
mkrel "$R2" "$TIP" 1.1.0; mkman "$R2" "$(hdr scripts-v2.1.0 2)"$'\n'"$KEYS_EXP"; sign "$R2"; publish "$R2" scripts-v2.1.0
install_from "$R1"
run_upd y
check_rc "2.0.0 -> tip, expired: rc 0" 0 "$RC"
has "2.0.0 -> tip, expired: relaunched the release copy" "copy of update-scripts.sh to install the release" "$OUT"
check "2.0.0 -> tip, expired: warning exactly once" 1 "$(count "expired on 2027-03-10" "$OUT")"
has "2.0.0 -> tip, expired: warning text" "Script release scripts-v2.1.0 expired on 2027-03-10; a newer signed release is overdue. Installing it anyway." "$OUT"
check "2.0.0 -> tip, expired: tip updater installed" "$(_h "$TIP")" "$(_h "$INST/update-scripts.sh")"
check "2.0.0 -> tip, expired: record is R2" "$(_h "$R2/MANIFEST")" "$(_h "$INST/MANIFEST")"
check "2.0.0 -> tip: no staging dir left" "" "$(cd "$INST" && find . -maxdepth 1 -name '.tn-update.*')"
run_check
check_rc "after 2.0.0 -> tip: tip --check rc 1 (installed expired)" 1 "$RC"
has "after 2.0.0 -> tip: --check names the expiry" "Installed release scripts-v2.1.0 expired on 2027-03-10 (5 days ago)" "$OUT"
# c. tip updater, fresh
mkrel "$R2" "$TIP" 1.1.0; mkman "$R2" "$(hdr scripts-v2.1.0 2)"$'\n'"$KEYS_FRESH"; sign "$R2"; publish "$R2" scripts-v2.1.0
install_from "$R1"
run_upd y
check_rc "2.0.0 -> tip, fresh: rc 0" 0 "$RC"
hasnt "2.0.0 -> tip, fresh: no warning" "expired" "$OUT"
run_check
check_rc "after 2.0.0 -> tip fresh: --check rc 0" 0 "$RC"
# d. tip updater, malformed expires: 2.0.0 parses it, the tip copy refuses; tree unchanged
mkrel "$R2" "$TIP" 1.1.0; mkman "$R2" "$(hdr scripts-v2.1.0 2)"$'\n'"expires=2027-02-30"$'\n'; sign "$R2"; publish "$R2" scripts-v2.1.0
install_from "$R1"
before="$(tree_sig)"
run_upd y
check_rc "2.0.0 -> tip, malformed expires: rc 1" 1 "$RC"
check "2.0.0 -> tip, malformed expires: tree byte-identical" "$before" "$(tree_sig)"
has "2.0.0 -> tip, malformed expires: tip copy says why" "release manifest is malformed (expires 2027-02-30)" "$OUT"

finish
