#!/usr/bin/env bash
# =============================================================================
# tasks/verify-r2/V7-IMG/t_scan.sh -- IMG check 7 (V7 spec) and the scan
# comparison: remove-node's container scan (custom_container_lines) and the UI
# helper's docker-detect (cmd_docker_detect, _docker_tn_names) over the same
# containers, through the docker stand-in on PATH. Both must count a container
# of each testnet repository (GAR, the old package, tn-testnet) and of
# tn-mainnet, by digest and by tag. Where they differ (the dev package, a name
# or tag that only contains -adiri, a repository that only starts like a
# package), the difference is printed as info lines and pinned, so a change on
# either side shows.
#
#   bash tasks/verify-r2/V7-IMG/t_scan.sh
#
# Verifier harness (round 2, V7-IMG). bash 3.2 safe.
# =============================================================================
# shellcheck source=tasks/verify-r2/V7-IMG/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
v7_docker_stub "$T/bin"
PATH="$T/bin:$PATH"
D1="$(v7_digest 31)"
# name, image (status is added for remove-node's three-column listing)
CT="$T/containers.txt"
cat > "$CT" <<EOF
c-gar-tag	${GAR}:v0.16.0-adiri
c-gar-dig	${GAR}@sha256:${D1}
c-old-dig	${GL}@sha256:${D1}
c-old-tag	${GL}:v1.0.0
c-tt-tag	${GT}:v0.17.0-adiri
c-tt-dig	${GT}@sha256:${D1}
c-tm-tag	${GM}:v1.0.0
c-tm-dig	${GM}@sha256:${D1}
c-tm-tagdig	${GM}:v1.0.0@sha256:${D1}
c-dev-dig	${GD}@sha256:${D1}
c-prefix	${GT}-evil@sha256:${D1}
c-namedadiri-adiri	docker.io/library/busybox:1.36
c-tagadiri	docker.io/library/busybox:v1-adiri
c-other	ghcr.io/someone-else/tn-mainnet:v1.0.0
c-web	nginx:1.27
EOF
awk -F '\t' '{ print $1 "\t" $2 "\tUp 1 hour" }' "$CT" > "$T/ps3.txt"
cp "$CT" "$T/ps2.txt"

mkdir -p "$T/h"
grep -v '^main "\$@"$' "$V7_REPO/remove-node.sh" > "$T/h/remove-node.sh"
ln -s "$V7_REPO/lib" "$T/h/lib"
RM_NAMES="$( V7_PS="$T/ps3.txt"; export V7_PS
             # shellcheck source=/dev/null
             source "$T/h/remove-node.sh" >/dev/null 2>&1
             set +e
             custom_container_lines | cut -f1 )"
UI_NAMES="$( V7_PS="$T/ps2.txt"; export V7_PS
             # shellcheck source=/dev/null
             . "$V7_REPO/ui/telcoin-ui-helper.sh" >/dev/null 2>&1
             HELPER_LIB="$V7_REPO/lib/common.sh"
             LIB_REQUIRE_ROOT=0
             set +e
             cmd_docker_detect )"
has() { if printf '%s\n' "$1" | grep -qxF -- "$2"; then echo yes; else echo no; fi; }
for c in c-gar-tag c-gar-dig c-old-dig c-old-tag c-tt-tag c-tt-dig c-tm-tag c-tm-dig; do
    check "remove-node scan counts $c" yes "$(has "$RM_NAMES" "$c")"
    check "UI docker-detect counts $c" yes "$(has "$UI_NAMES" "$c")"
done
for c in c-other c-web; do
    check "remove-node scan skips $c" no "$(has "$RM_NAMES" "$c")"
    check "UI docker-detect skips $c" no "$(has "$UI_NAMES" "$c")"
done
# The differences, pinned as measured on c0716f3 (remove-node: grep -E over the
# whole line; the UI: an exact tn_docker_repo_ok on testnet or mainnet).
check "differs: tn-dev counted by remove-node" yes "$(has "$RM_NAMES" c-dev-dig)"
# W2 fixed by IMG-2 (d2fc0b1): docker-detect also counts the devnet repositories.
check "W2 fixed: tn-dev counted by the UI" yes "$(has "$UI_NAMES" c-dev-dig)"
check "differs: tn-testnet-evil counted by remove-node (substring)" yes "$(has "$RM_NAMES" c-prefix)"
check "differs: tn-testnet-evil not counted by the UI" no "$(has "$UI_NAMES" c-prefix)"
check "differs: a container named *-adiri counted by remove-node" yes "$(has "$RM_NAMES" c-namedadiri-adiri)"
check "differs: busybox:v1-adiri counted by remove-node" yes "$(has "$RM_NAMES" c-tagadiri)"
check "differs: neither -adiri case counted by the UI" "no no" "$(has "$UI_NAMES" c-namedadiri-adiri) $(has "$UI_NAMES" c-tagadiri)"
check "tag and digest together: remove-node counts it" yes "$(has "$RM_NAMES" c-tm-tagdig)"
check "tag and digest together: the UI counts it" yes "$(has "$UI_NAMES" c-tm-tagdig)"
for c in $(cut -f1 "$CT"); do
    r="$(has "$RM_NAMES" "$c")"; u="$(has "$UI_NAMES" "$c")"
    if [[ "$r" != "$u" ]]; then
        printf 'info  scan difference: %s (%s): remove-node %s, UI %s\n' "$c" "$(awk -F '\t' -v n="$c" '$1 == n { print $2 }' "$CT")" "$r" "$u"
    fi
done
finish
