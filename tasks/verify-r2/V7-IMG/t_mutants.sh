#!/usr/bin/env bash
# =============================================================================
# tasks/verify-r2/V7-IMG/t_mutants.sh -- mutation runs for IMG (V7 spec checks
# 4 and 8). Each mutant breaks one refusal branch, the call order (resolve ->
# pull -> feature check -> start), a repository rule, the floor, a UI twin or
# a --json tail, in its own scratch copy of the committed tree (git archive
# HEAD; the tree itself is never touched). Then the IMG fixtures
# (tools/tests/<name>_test.sh of the copy, run with the bash running this) and
# ui/tests/helper_test.sh run against the copy, and this harness's t_*.sh with
# V7IMG_REPO set to it; mutants tagged ui also run pytest (python:3.12-slim,
# when docker is there) and t_ui.sh. A mutant whose edit cannot be applied is
# reported NOT-APPLIED (a stale anchor), never counted as caught.
#
#   bash tasks/verify-r2/V7-IMG/t_mutants.sh            # every mutant
#   bash tasks/verify-r2/V7-IMG/t_mutants.sh M13 M16    # the named ones
#
# V7IMG_MUT_DIR (default: a dir in TN_TEST_TMP) holds the copies and logs;
# V7IMG_JOBS (default 8) mutants run at once. One line per mutant:
#   <id> <tag> fixtures=<failing fixture files or ->  harness=<failing t_*.sh or ->  <description>
# then the counts. Verifier harness (round 2, V7-IMG). bash 3.2 safe.
# =============================================================================
# shellcheck source=tasks/verify-r2/V7-IMG/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
SRC="$V7_REPO"
OUT="${V7IMG_MUT_DIR:-$T/mut}"
JOBS="${V7IMG_JOBS:-8}"
mkdir -p "$OUT"
FIXTURES="docker_image network_detect setup_release release_fetch remove source_ref storage_migration update_guard"
HARNESS="t_repos t_feature t_floor t_digest t_order t_scan"

# mut_sub FILE ANCHOR OLD NEW -- replace the first OLD (a literal string within one
# line) on or after the first line holding ANCHOR (a literal; empty: the top).
# NEW may hold newlines. rc 3 when no such OLD exists (the file is not changed).
mut_sub() {
    MS_A="$2" MS_O="$3" MS_N="$4" awk '
        BEGIN { a = ENVIRON["MS_A"]; o = ENVIRON["MS_O"]; n = ENVIRON["MS_N"]; seen = (a == ""); done = 0 }
        {
            if (!seen && index($0, a) > 0) seen = 1
            if (seen && !done) {
                i = index($0, o)
                if (i > 0) { $0 = substr($0, 1, i - 1) n substr($0, i + length(o)); done = 1 }
            }
            print
        }
        END { if (!done) exit 3 }' "$1" > "$1.mut" || { rm -f "$1.mut"; return 3; }
    mv "$1.mut" "$1"
}

NL='
'
FN_IMG='tn_docker_image_network_ok() {'
FN_VER='tn_release_version_ok() {'
# mut_desc ID -- "<tag> <description>"; tag lib|setup|update|edit|floor|ui|scan.
mut_desc() {
    case "$1" in
        M01) echo "lib feature check: one-line rule removed (missing/doubled line accepted)" ;;
        M02) echo "lib feature check: docker run failure ignored" ;;
        M03) echo "lib feature check: features never judged" ;;
        M04) echo "lib feature check: unknown network accepted" ;;
        M05) echo "lib feature check: image not by digest accepted" ;;
        M06) echo "lib feature check: testnet skipped like devnet" ;;
        M07) echo "lib feature check: --pull=never dropped (implicit pull)" ;;
        M08) echo "lib feature check: --network none dropped" ;;
        M09) echo "lib feature check: no timeout" ;;
        M10) echo "lib version rule: mainnet accepts any feature" ;;
        M11) echo "lib version rule: testnet without adiri accepted" ;;
        M12) echo "lib version rule: testnet unknown feature accepted" ;;
        M13) echo "setup: feature check call removed" ;;
        M14) echo "setup: feature check before the pull (order)" ;;
        M15) echo "setup: feature check refusal ignored" ;;
        M16) echo "update: feature check call removed" ;;
        M17) echo "update: pending state written before the check (order)" ;;
        M18) echo "update: check run as devnet (skipped)" ;;
        M19) echo "update: interactive prepare passes no network" ;;
        M20) echo "edit --set: feature check call removed" ;;
        M21) echo "edit menu: feature check call removed" ;;
        M22) echo "edit --set: swap before the check (order)" ;;
        M23) echo "lib pull rule: old package no longer refused" ;;
        M24) echo "lib resolve_ref: old-package case and final pull rule removed" ;;
        M25) echo "lib: tn-dev in TN_TESTNET_IMAGE_REPOS" ;;
        M26) echo "lib: mainnet repos_for adds tn-testnet" ;;
        M27) echo "lib: repo_for testnet names the old package" ;;
        M28) echo "lib fetch_release_image: pull rule half removed" ;;
        M29) echo "lib fetch_release_image: package check removed" ;;
        M30) echo "lib image_for_tag: registry fallback adds the old package" ;;
        M31) echo "lib image_for_tag: registry fallback on mainnet" ;;
        M32) echo "lib resolve_ref: mainnet digest-alone rule removed" ;;
        M33) echo "floor: mainnet takes the testnet floor" ;;
        M34) echo "floor: unknown network has no floor" ;;
        M35) echo "floor: storage_migrating_upgrade ignores its network" ;;
        M36) echo "floor: downgrade check always uses the testnet floor" ;;
        M37) echo "floor: devnet floor 0.16.0" ;;
        M38) echo "ui server: docker_pull_repo_ok takes the old package" ;;
        M39) echo "ui server: DOCKER_REPO mainnet adds tn-testnet" ;;
        M40) echo "ui helper: docker_image_ok drops the pull rule" ;;
        M41) echo "remove-node scan: tn-mainnet dropped" ;;
        M42) echo "remove-node scan: tn-testnet dropped" ;;
        M43) echo "ui helper docker-detect: mainnet half dropped" ;;
        M44) echo "setup --json: setup_fail sends no error event" ;;
        M45) echo "update --json: a refused pull goes on to done ok:true" ;;
        M46) echo "edit --set: feature refusal returns 0" ;;
        M47) echo "lib repo_ok: substring match instead of exact" ;;
        M48) echo "lib resolve_ref: <repo>:<tag> split guard dropped" ;;
        M49) echo "lib image_allowed: uppercase digest accepted" ;;
        *) return 1 ;;
    esac
}
mut_tag() {
    case "$1" in
        M13|M14|M15|M44) echo setup ;;
        M16|M17|M18|M19|M45) echo update ;;
        M20|M21|M22|M46) echo edit ;;
        M33|M34|M35|M36|M37) echo floor ;;
        M23|M25|M26|M27|M38|M39|M40|M47) echo ui ;;
        M41|M42|M43) echo scan ;;
        *) echo lib ;;
    esac
}
# mut_apply ID DIR -- make the edit in the copy DIR.
mut_apply() {
    local d="$2"
    case "$1" in
        M01) mut_sub "$d/lib/common.sh" "$FN_IMG" 'if [[ "$n" != "1" ]]; then' 'if false; then' ;;
        M02) mut_sub "$d/lib/common.sh" "$FN_IMG" 'if [[ $rc -ne 0 ]]; then' 'if false; then' ;;
        M03) mut_sub "$d/lib/common.sh" "$FN_IMG" 'if ! tn_release_version_ok "$out" "$net" "" >/dev/null 2>&1; then' 'if false; then' ;;
        M04) mut_sub "$d/lib/common.sh" "$FN_IMG" '        testnet|mainnet) ;;' '        *) ;;' ;;
        M05) mut_sub "$d/lib/common.sh" "$FN_IMG" 'if [[ "$img" != *@sha256:* || "$img" == -* || "$img" =~ [[:space:]] ]]; then' 'if false; then' ;;
        M06) mut_sub "$d/lib/common.sh" "$FN_IMG" '        devnet)' '        devnet|testnet)' ;;
        M07) mut_sub "$d/lib/common.sh" "$FN_IMG" 'docker run --rm --pull=never --network none' 'docker run --rm --network none' ;;
        M08) mut_sub "$d/lib/common.sh" "$FN_IMG" 'docker run --rm --pull=never --network none' 'docker run --rm --pull=never' ;;
        M09) mut_sub "$d/lib/common.sh" "$FN_IMG" 'tmo=(timeout 60)' 'tmo=()' ;;
        M10) mut_sub "$d/lib/common.sh" "$FN_VER" 'if [[ -n "$feats" ]]; then' 'if false; then' ;;
        M11) mut_sub "$d/lib/common.sh" "$FN_VER" 'if [[ "$has_adiri" -ne 1 ]]; then' 'if false; then' ;;
        M12) mut_sub "$d/lib/common.sh" 'a testnet build has adiri (and faucet) only." >&2' '                        return 1' '                        :' ;;
        M13) mut_sub "$d/setup-node.sh" "" '    if ! tn_docker_image_network_ok "$NETWORK" "$DOCKER_IMAGE" setup_progress; then' '    if false; then' ;;
        M14) mut_sub "$d/setup-node.sh" "" '    if ! tn_docker_image_network_ok "$NETWORK" "$DOCKER_IMAGE" setup_progress; then' '    if false; then' \
                 && mut_sub "$d/setup-node.sh" "" '    if ! docker pull "$DOCKER_IMAGE" 9>&-; then' "    tn_docker_image_network_ok \"\$NETWORK\" \"\$DOCKER_IMAGE\" setup_progress || setup_fail \"not a \${NETWORK} image\"${NL}    if ! docker pull \"\$DOCKER_IMAGE\" 9>&-; then" ;;
        M15) mut_sub "$d/setup-node.sh" '    if ! tn_docker_image_network_ok "$NETWORK" "$DOCKER_IMAGE" setup_progress; then' '        setup_fail "Refusing the image ${DOCKER_IMAGE}: it is not a ${NETWORK} image' '        : "Refusing the image ${DOCKER_IMAGE}: it is not a ${NETWORK} image' ;;
        M16) mut_sub "$d/update-node.sh" "" '    if ! tn_docker_image_network_ok "$net" "$img" update_wait_say; then' '    if false; then' ;;
        M17) mut_sub "$d/update-node.sh" "" '    if ! tn_docker_image_network_ok "$net" "$img" update_wait_say; then' '    if false; then' \
                 && mut_sub "$d/update-node.sh" "" "    if ! printf '%s\\n' \"\$state\" | write_pending_state; then" "    printf '%s\\n' \"\$state\" | write_pending_state${NL}    tn_docker_image_network_ok \"\$net\" \"\$img\" update_wait_say || return 1${NL}    if false; then" ;;
        M18) mut_sub "$d/update-node.sh" "" '    if ! tn_docker_image_network_ok "$net" "$img" update_wait_say; then' '    if ! tn_docker_image_network_ok devnet "$img" update_wait_say; then' ;;
        M19) mut_sub "$d/update-node.sh" "" '    docker_pull_target "$DOCKER_TARGET_IMAGE" "$current" "$DOCKER_TARGET_TAG" "$net" || return 1' '    docker_pull_target "$DOCKER_TARGET_IMAGE" "$current" "$DOCKER_TARGET_TAG" || return 1' ;;
        M20) mut_sub "$d/edit-config.sh" "" '    if ! tn_docker_image_network_ok "$net" "$new_image" edit_wait_say; then' '    if false; then' ;;
        M21) mut_sub "$d/edit-config.sh" "" '    if ! tn_docker_image_network_ok "$net" "$new_image"; then' '    if false; then' ;;
        M22) mut_sub "$d/edit-config.sh" "" '    if ! tn_docker_image_network_ok "$net" "$new_image" edit_wait_say; then' "    swap_docker_image \"\$new_image\" || return 1${NL}    if ! tn_docker_image_network_ok \"\$net\" \"\$new_image\" edit_wait_say; then" ;;
        M23) mut_sub "$d/lib/common.sh" "tn_docker_pull_repo_ok() {" '[[ "$repo" != "$TN_GHCR_LEGACY_IMAGE_REPO" ]] || return 1' ':' ;;
        M24) mut_sub "$d/lib/common.sh" "tn_docker_resolve_ref() {" '"$TN_GHCR_LEGACY_IMAGE_REPO"@*|"$TN_GHCR_LEGACY_IMAGE_REPO":*)' 'V7-never-matches)' \
                 && mut_sub "$d/lib/common.sh" "tn_docker_resolve_ref() {" '        || ! tn_docker_pull_repo_ok "$net" "${img%%@*}"; then' '        ; then' ;;
        M25) mut_sub "$d/lib/common.sh" "" 'readonly TN_TESTNET_IMAGE_REPOS="${GAR_IMAGE_BASE} ${TN_GHCR_LEGACY_IMAGE_REPO} ${TN_TESTNET_IMAGE_REPO}"' 'readonly TN_TESTNET_IMAGE_REPOS="${GAR_IMAGE_BASE} ${TN_GHCR_LEGACY_IMAGE_REPO} ${TN_TESTNET_IMAGE_REPO} ${TN_DEV_IMAGE_REPO}"' ;;
        M26) mut_sub "$d/lib/common.sh" "tn_docker_repos_for() {" "        *) printf '%s\\n' \"\$def\" ;;" "        *) printf '%s\\n' \"\$def \$TN_TESTNET_IMAGE_REPO\" ;;" ;;
        M27) mut_sub "$d/lib/common.sh" "tn_docker_repo_for() {" 'testnet) repo="$TN_TESTNET_IMAGE_REPO" ;;' 'testnet) repo="$TN_GHCR_LEGACY_IMAGE_REPO" ;;' ;;
        M28) mut_sub "$d/lib/common.sh" "tn_fetch_release_image() {" '        || ! tn_docker_pull_repo_ok "$net" "${img%%@*}"; then' '        ; then' ;;
        M29) mut_sub "$d/lib/common.sh" "tn_fetch_release_image() {" 'if ! TN_DOCKER_REQUIRE_DIGEST=1 tn_docker_image_allowed "$img" "$net" \' 'if false \' \
                 && mut_sub "$d/lib/common.sh" "tn_fetch_release_image() {" '        || ! tn_docker_pull_repo_ok "$net" "${img%%@*}"; then' '        ; then' ;;
        M30) mut_sub "$d/lib/common.sh" "tn_docker_image_for_tag() {" 'for r in "$repo" "$TN_TESTNET_LEGACY_IMAGE_REPO"; do' 'for r in "$repo" "$TN_GHCR_LEGACY_IMAGE_REPO" "$TN_TESTNET_LEGACY_IMAGE_REPO"; do' ;;
        M31) mut_sub "$d/lib/common.sh" "tn_docker_image_for_tag() {" 'if [[ $rc -ne 2 || "$net" != "testnet" ]]; then' 'if [[ $rc -ne 2 ]]; then' ;;
        M32) mut_sub "$d/lib/common.sh" "tn_docker_resolve_ref() {" 'if [[ -z "$tag" && "$net" == "mainnet" ]]; then' 'if false; then' ;;
        M33) mut_sub "$d/update-node.sh" "storage_migration_floor() {" "        mainnet) printf '%s\\n' \"\$STORAGE_MIGRATION_FLOOR_MAINNET\" ;;" "        mainnet) printf '%s\\n' \"\$STORAGE_MIGRATION_FLOOR_TESTNET\" ;;" ;;
        M34) mut_sub "$d/update-node.sh" "storage_migration_floor() {" "        *) printf '%s\\n' \"\$STORAGE_MIGRATION_FLOOR_TESTNET\" ;;" "        *) printf '\\n' ;;" ;;
        M35) mut_sub "$d/update-node.sh" "" '    floor="$(storage_migration_floor "${3:-}")"' '    floor="$(storage_migration_floor testnet)"' ;;
        M36) mut_sub "$d/update-node.sh" "update_downgrade_check() {" '    floor="$(storage_migration_floor)"' '    floor="$STORAGE_MIGRATION_FLOOR_TESTNET"' ;;
        M37) mut_sub "$d/update-node.sh" "" 'readonly STORAGE_MIGRATION_FLOOR_DEVNET=""' 'readonly STORAGE_MIGRATION_FLOOR_DEVNET="0.16.0"' ;;
        M38) mut_sub "$d/ui/server.py" "" '    return repo != GHCR_LEGACY_IMAGE_REPO and docker_repo_ok(network, repo)' '    return docker_repo_ok(network, repo)' ;;
        M39) mut_sub "$d/ui/server.py" "" '    "mainnet": (MAINNET_IMAGE_REPO,),' '    "mainnet": (MAINNET_IMAGE_REPO, TESTNET_IMAGE_REPO),' ;;
        M40) mut_sub "$d/ui/telcoin-ui-helper.sh" "" '&& _lib_req tn_docker_pull_repo_ok "$2" "${1%%@*}" >/dev/null' '&& true' ;;
        M41) mut_sub "$d/remove-node.sh" "" '(telcoin-network|tn-mainnet|tn-testnet|tn-dev)' '(telcoin-network|tn-testnet|tn-dev)' ;;
        M42) mut_sub "$d/remove-node.sh" "" '(telcoin-network|tn-mainnet|tn-testnet|tn-dev)' '(telcoin-network|tn-mainnet|tn-dev)' ;;
        M43) mut_sub "$d/ui/telcoin-ui-helper.sh" "" 'if tn_docker_repo_ok testnet "$repo" || tn_docker_repo_ok mainnet "$repo"; then' 'if tn_docker_repo_ok testnet "$repo"; then' ;;
        M44) mut_sub "$d/setup-node.sh" "setup_fail() {" '        json_event error "$1"' '        :' ;;
        M45) mut_sub "$d/update-node.sh" "" 'json_event error "the image ${DOCKER_TARGET_IMAGE} was not prepared (see the warning above)"; return 1' 'json_event warn "the image ${DOCKER_TARGET_IMAGE} was not prepared (see the warning above)"' ;;
        M46) mut_sub "$d/edit-config.sh" 'edit_error "refusing ${new_image}: it is not a ${net} image (see above); the image is not changed"' '        return 1' '        return 0' ;;
        M47) mut_sub "$d/lib/common.sh" "tn_docker_repo_ok() {" '        *" ${repo} "*) return 0 ;;' '        *"${repo}"*) return 0 ;;' ;;
        M48) mut_sub "$d/lib/common.sh" "tn_docker_resolve_ref() {" 'if [[ "${arg%:*}" != *@* ]] && tn_docker_pull_repo_ok "$net" "${arg%:*}"; then' 'if tn_docker_pull_repo_ok "$net" "${arg%:*}"; then' ;;
        M49) mut_sub "$d/lib/common.sh" "tn_docker_image_allowed() {" '[[ "$rest" =~ ^[0-9a-f]{64}$ ]] || return 1' '[[ "$rest" =~ ^[0-9a-fA-F]{64}$ ]] || return 1' ;;
        *) return 1 ;;
    esac
}

# run_one ID -- copy, mutate, run; writes $OUT/ID.result.
run_one() {
    local id="$1" d="$OUT/$1" tag f fx="" hx="" rc
    tag="$(mut_tag "$id")"
    rm -rf "$d"
    mkdir -p "$d/tree" "$d/log"
    git -C "$SRC" archive HEAD | tar -x -C "$d/tree"
    if ! mut_apply "$id" "$d/tree" 2>"$d/log/apply.err"; then
        printf '%s %s NOT-APPLIED  %s\n' "$id" "$tag" "$(mut_desc "$id")" > "$OUT/$id.result"
        return 0
    fi
    for f in $FIXTURES; do
        rc=0
        ( cd "$d/tree" && "${BASH:-bash}" "tools/tests/${f}_test.sh" ) > "$d/log/$f.log" 2>&1 || rc=$?
        [[ $rc -eq 0 ]] || fx="${fx:+${fx},}${f}"
    done
    rc=0
    ( cd "$d/tree" && "${BASH:-bash}" ui/tests/helper_test.sh ) > "$d/log/helper.log" 2>&1 || rc=$?
    [[ $rc -eq 0 ]] || fx="${fx:+${fx},}helper"
    if [[ "$tag" == ui ]] && command -v docker >/dev/null 2>&1; then
        rc=0
        docker run --rm -e PYTHONDONTWRITEBYTECODE=1 -v "$d/tree:/w:ro" -w /w python:3.12-slim sh -c \
            'python -m pip install -q --require-hashes -r ui/requirements.txt -r ui/tests/requirements-dev.txt >/dev/null 2>&1 && python -m pytest -q -p no:cacheprovider ui' \
            > "$d/log/pytest.log" 2>&1 || rc=$?
        [[ $rc -eq 0 ]] || fx="${fx:+${fx},}pytest"
    fi
    local hs="$HARNESS"
    [[ "$tag" != ui ]] || hs="$hs t_ui"
    for f in $hs; do
        rc=0
        V7IMG_REPO="$d/tree" "${BASH:-bash}" "$V7_DIR/$f.sh" > "$d/log/$f.log" 2>&1 || rc=$?
        [[ $rc -eq 0 ]] || hx="${hx:+${hx},}${f}"
    done
    printf '%s %s fixtures=%s  harness=%s  %s\n' "$id" "$tag" "${fx:--}" "${hx:--}" "$(mut_desc "$id")" > "$OUT/$id.result"
    rm -rf "$d/tree"
}

ids=""
if [[ $# -gt 0 ]]; then
    ids="$*"
else
    n=1
    while mut_desc "$(printf 'M%02d' "$n")" >/dev/null; do
        ids="$ids $(printf 'M%02d' "$n")"
        n=$((n + 1))
    done
fi
for id in $ids; do
    mut_desc "$id" >/dev/null || { printf 'unknown mutant %s\n' "$id" >&2; exit 2; }
    while [[ "$(jobs -r | wc -l | tr -d ' ')" -ge "$JOBS" ]]; do
        sleep 1
    done
    run_one "$id" &
done
wait
total=0; na=0; byfx=0; byh=0; any=0
for id in $ids; do
    line="$(cat "$OUT/$id.result")"
    printf '%s\n' "$line"
    total=$((total + 1))
    case "$line" in
        *NOT-APPLIED*) na=$((na + 1)); continue ;;
    esac
    f="$(printf '%s' "$line" | sed -n 's/.* fixtures=\([^ ]*\) .*/\1/p')"
    h="$(printf '%s' "$line" | sed -n 's/.* harness=\([^ ]*\) .*/\1/p')"
    [[ "$f" == - ]] || byfx=$((byfx + 1))
    [[ "$h" == - ]] || byh=$((byh + 1))
    if [[ "$f" != - || "$h" != - ]]; then any=$((any + 1)); fi
done
printf '\nmutants %s, not applied %s; caught by the fixtures %s/%s, by this harness %s/%s, by either %s/%s\n' \
    "$total" "$na" "$byfx" "$((total - na))" "$byh" "$((total - na))" "$any" "$((total - na))"
check "every mutant applied" 0 "$na"
finish
