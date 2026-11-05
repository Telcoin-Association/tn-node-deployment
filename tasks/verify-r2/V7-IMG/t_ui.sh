#!/usr/bin/env bash
# =============================================================================
# tasks/verify-r2/V7-IMG/t_ui.sh -- IMG check 6 (V7 spec): the UI twins agree
# with the library. The library's answers (tn_docker_repo_for, repos_for,
# pull_repos_for, pull_repo_ok over a repository matrix, tn_docker_image_allowed
# with digests required, and tn_docker_resolve_ref's accept/refuse for a list of
# references, the release lookup stubbed) are written to a file; a Python
# script then holds ui/server.py's IMAGE_REPO, DOCKER_REPO, docker_pull_repo_ok,
# image_allowed, pull_image_allowed and docker_image_choice to them, and the
# page's IMAGE_REPO (ui/static/index.html) to the server's. The helper's
# docker_image_ok (ui/telcoin-ui-helper.sh) is run against the same matrix.
# Python: python3 when it imports flask, else python:3.12-slim in docker with
# ui/requirements.txt (hash-pinned), else SKIP.
#
#   bash tasks/verify-r2/V7-IMG/t_ui.sh
#
# Verifier harness (round 2, V7-IMG). bash 3.2 safe.
# =============================================================================
# shellcheck source=tasks/verify-r2/V7-IMG/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
mkdir -p "$T/root/etc/telcoin"
TN_ROOT_PREFIX="$T/root"
eval "$(tn_test_source_common)"
unset TN_DOCKER_REQUIRE_DIGEST

REPOS="$GT $GM $GL $GD $GAR ${GT}/ GHCR.IO/TELCOIN-ASSOCIATION/TN-TESTNET docker.io/${GM} ${GM}x"
REFS="v0.17.0-adiri v1.0.0 v1.0.0-rc1 v0.17.0-adiri-rc1 latest ${GT}:v0.17.0-adiri ${GM}:v1.0.0 ${GT}:v1.0.0 ${GM}:v0.17.0-adiri
${GL}:v0.17.0-adiri ${GL}:v1.0.0 ${GAR}:v0.17.0-adiri ${GD}:v0.17.0-adiri ${GT}:latest
${GT}@sha256:${D64} ${GM}@sha256:${D64} ${GL}@sha256:${D64} ${GD}@sha256:${D64} ${GAR}@sha256:${D64}
${GT}/:v0.17.0-adiri ${GT}@sha256:$(printf '%s' "$D64" | tr a-f A-F) GHCR.IO/TELCOIN-ASSOCIATION/TN-TESTNET:v0.17.0-adiri"
tn_docker_image_for_tag() { tn_release_tag_ok "$1" "$2" || return 3; printf '%s@sha256:%s\n' "$(tn_docker_repo_for "$1")" "$D64"; }
LIB="$T/lib.txt"
{
    for n in testnet mainnet devnet; do
        printf 'repo_for %s %s\n' "$n" "$(tn_docker_repo_for "$n" 2>/dev/null)"
        printf 'repos_for %s %s\n' "$n" "$(tn_docker_repos_for "$n" 2>/dev/null)"
        printf 'pull_repos_for %s %s\n' "$n" "$(tn_docker_pull_repos_for "$n" 2>/dev/null)"
        for r in $REPOS; do
            ok=0; tn_docker_pull_repo_ok "$n" "$r" && ok=1
            printf 'pull_repo_ok %s %s %s\n' "$n" "$r" "$ok"
            ok=0; TN_DOCKER_REQUIRE_DIGEST=1 tn_docker_image_allowed "${r}@sha256:${D64}" "$n" && ok=1
            printf 'image_allowed %s %s %s\n' "$n" "${r}@sha256:${D64}" "$ok"
        done
    done
    for n in testnet mainnet; do
        printf 'NETWORK=%s\n' "$n" > "$T/root/etc/telcoin/.node-meta"
        for ref in $REFS; do
            ok=0; tn_docker_resolve_ref "$n" "$ref" >/dev/null 2>&1 && ok=1
            printf 'resolve %s %s %s\n' "$n" "$ref" "$ok"
        done
    done
} > "$LIB"

# the helper's docker_image_ok (the pull rule) over the same matrix
HELPER="$V7_REPO/ui/telcoin-ui-helper.sh"
for n in testnet mainnet; do
    for r in $REPOS; do
        want="$(sed -n "s|^pull_repo_ok ${n} ${r} ||p" "$LIB")"
        allowed="$(sed -n "s|^image_allowed ${n} ${r}@sha256:${D64} ||p" "$LIB")"
        [[ "$want" == 1 && "$allowed" == 1 ]] && want=1 || want=0
        # A fresh bash: this shell already sourced lib/common.sh, whose readonly
        # constants a second source (the helper's _lib_run) would trip over.
        # shellcheck disable=SC2016
        got="$("${BASH:-bash}" -c '. "$1" >/dev/null 2>&1; HELPER_LIB="$2"; LIB_REQUIRE_ROOT=0; set +e
                if docker_image_ok "$3" "$4" >/dev/null 2>&1; then echo 1; else echo 0; fi' \
                _ "$HELPER" "$V7_REPO/lib/common.sh" "${r}@sha256:${D64}" "$n")"
        check "helper docker_image_ok $n ${r}@sha256:" "$want" "$got"
    done
done

cat > "$T/t_ui.py" <<'PY'
import json, re, sys
repo, libf = sys.argv[1], sys.argv[2]
sys.path.insert(0, repo + "/ui")
import server  # noqa: E402
lib = {}
for line in open(libf):
    parts = line.rstrip("\n").split(" ")
    kind = parts[0]
    lib.setdefault(kind, []).append(parts[1:])
res = []
def check(name, want, got):
    res.append((name, want == got, want, got))
for net, *val in lib["repo_for"]:
    check("IMAGE_REPO %s" % net, " ".join(val), server.IMAGE_REPO.get(net, ""))
for net, *val in lib["repos_for"]:
    check("DOCKER_REPO %s (order kept)" % net, " ".join(val), " ".join(server.DOCKER_REPO.get(net, ())))
for net, *val in lib["pull_repos_for"]:
    check("pull repos %s" % net, " ".join(val), " ".join(r for r in server.DOCKER_REPO.get(net, ()) if server.docker_pull_repo_ok(net, r)))
for net, r, ok in lib["pull_repo_ok"]:
    check("docker_pull_repo_ok %s %s" % (net, r), ok == "1", server.docker_pull_repo_ok(net, r))
for net, img, ok in lib["image_allowed"]:
    check("image_allowed %s %s" % (net, img), ok == "1", server.image_allowed(img, net))
    pull = dict(((n, x), o) for n, x, o in lib["pull_repo_ok"])[(net, img.split("@", 1)[0])] == "1"
    check("pull_image_allowed %s %s" % (net, img), ok == "1" and pull, server.pull_image_allowed(img, net))
notes = []
for net, ref, ok in lib["resolve"]:
    tag, dig, err = server.docker_image_choice(ref, net)
    ui_ok = err is None and bool(tag or dig)
    if net == "mainnet" and "@sha256:" in ref and ok == "0" and ui_ok:
        notes.append("NOTE docker_image_choice mainnet takes %s (a digest alone); the library refuses it without a .node-meta record" % ref)
        continue
    check("docker_image_choice %s %s matches tn_docker_resolve_ref" % (net, ref), ok == "1", ui_ok)
page = open(repo + "/ui/static/index.html").read()
m = re.search(r"const IMAGE_REPO = \{mainnet:'([^']*)', testnet:'([^']*)'\};", page)
check("index.html IMAGE_REPO mainnet", server.IMAGE_REPO["mainnet"], m.group(1) if m else None)
check("index.html IMAGE_REPO testnet", server.IMAGE_REPO["testnet"], m.group(2) if m else None)
check("server never offers the old package for a new pull (any network)", False,
      any(server.docker_pull_repo_ok(n, server.GHCR_LEGACY_IMAGE_REPO) for n in ("testnet", "mainnet", "devnet")))
check("server: tn-dev pull only on devnet", [False, False, True],
      [server.docker_pull_repo_ok(n, server.DEV_IMAGE_REPO) for n in ("testnet", "mainnet", "devnet")])
for name, ok, want, got in res:
    print(("ok    %s" % name) if ok else ("FAIL  %s\n      want %r got %r" % (name, want, got)))
for n in notes:
    print("info  " + n)
PY
pyrun() {
    if command -v python3 >/dev/null 2>&1 && python3 -c 'import flask' >/dev/null 2>&1; then
        python3 -I "$T/t_ui.py" "$V7_REPO" "$LIB"
        return
    fi
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        cp "$T/t_ui.py" "$LIB" "$V7_REPO/ui/requirements.txt" "$T/" 2>/dev/null
        docker run --rm -e PYTHONDONTWRITEBYTECODE=1 -v "$V7_REPO:/w:ro" -v "$T:/t:ro" python:3.12-slim sh -c \
            'python -m pip install -q --require-hashes -r /w/ui/requirements.txt >/dev/null 2>&1 && python -I /t/t_ui.py /w /t/lib.txt'
        return
    fi
    echo "SKIP"
}
out="$(pyrun 2>&1)"
if [[ "$out" == SKIP ]]; then
    skip "server.py twins" "neither flask nor docker here"
else
    printf '%s\n' "$out" | grep -v '^ok ' || true
    n_ok="$(printf '%s\n' "$out" | grep -c '^ok ')" || n_ok=0
    n_fail="$(printf '%s\n' "$out" | grep -c '^FAIL ')" || n_fail=0
    CHECKS=$((CHECKS + n_ok + n_fail))
    FAILS=$((FAILS + n_fail))
    printf 'ok    server.py twins: %s python checks passed\n' "$n_ok"
    if [[ "$n_ok" -eq 0 ]]; then
        FAILS=$((FAILS + 1))
        printf 'FAIL  server.py twins: the python part did not run\n%s\n' "$out"
    fi
fi
finish
