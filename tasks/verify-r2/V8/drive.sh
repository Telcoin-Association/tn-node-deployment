#!/usr/bin/env bash
# V8 driver: sources etc/release.sh (which only defines functions when sourced), replaces the
# calls that reach git, gh, docker, gpg or the network with recorders, and runs one scenario
# against the real release.sh functions. Usage: drive.sh SCENARIO TAG. Parameters come from
# the environment (IDG, SUMS_MODE, REG, REG_SEQ, ISO, OUT_FEATURES, ...), see each scenario.
# Nothing here writes outside a temporary directory under SCRATCH.
TN=${TN:-/home/drtnarg/coding/telcoin/tn-r2-packages}
# shellcheck source=/dev/null
source "$TN/etc/release.sh"
scenario=$1
tag=$2
WORK=$(mktemp -d "${SCRATCH:?set SCRATCH}/drive.XXXXXX")
CALLS=$WORK/calls
: >"$CALLS"
FAKE_COMMIT=0123456789abcdef0123456789abcdef01234567
FAKE_D=sha256:$(printf '%064d' 0 | tr 0 a)
OLD_D=sha256:$(printf '%064d' 0 | tr 0 b)

rec() { printf '%s\n' "$*" >>"$CALLS"; }

finish() {
    local rc=$? rd
    printf -- '--- calls\n'
    cat "$CALLS"
    rd=$WORK/cwd/$ARTIFACT_ROOT/$tag
    if [ -d "$rd" ]; then
        printf -- '--- local artifacts: %s\n' "$(cd "$rd" && ls | tr '\n' ' ')"
        if [ -f "$rd/IMAGE_DIGEST" ]; then printf 'IMAGE_DIGEST=%s\n' "$(cat "$rd/IMAGE_DIGEST")"; fi
    fi
    printf -- '--- rc=%s\n' "$rc"
    rm -rf "$WORK"
    exit "$rc"
}
trap finish EXIT

# The IMAGE_DIGEST content: IDG with @SELF@ replaced by IMAGE and @D@ by a valid digest;
# printf %b turns \n into a second line and \r, \0 into those bytes. Default: the right
# package and a valid digest, then a newline (IDG_RAW=1: no final newline).
write_idg() {
    local idg=${IDG-@SELF@@@D@}
    idg=${idg//@SELF@/$IMAGE}
    idg=${idg//@D@/$FAKE_D}
    if [ "${IDG_RAW:-}" = 1 ]; then
        printf '%b' "$idg" >"$1"
    else
        printf '%b\n' "$idg" >"$1"
    fi
}

# A release directory: IMAGE_DIGEST, an empty tarball, and SHA256SUMS listing IMAGE_DIGEST as
# SUMS_MODE says (ok, missing, twice, wronghash).
make_dir() {
    local d=$1 h t
    mkdir -p "$d"
    write_idg "$d/IMAGE_DIGEST"
    : >"$d/$TARBALL"
    h=$(sha256_hex "$d/IMAGE_DIGEST")
    t=$(sha256_hex "$d/$TARBALL")
    case "${SUMS_MODE:-ok}" in
        ok) printf '%s  IMAGE_DIGEST\n%s  %s\n' "$h" "$t" "$TARBALL" >"$d/SHA256SUMS" ;;
        missing) printf '%s  %s\n' "$t" "$TARBALL" >"$d/SHA256SUMS" ;;
        twice) printf '%s  IMAGE_DIGEST\n%s  IMAGE_DIGEST\n%s  %s\n' "$h" "$h" "$t" "$TARBALL" >"$d/SHA256SUMS" ;;
        wronghash) printf '%064d  IMAGE_DIGEST\n%s  %s\n' 0 "$t" "$TARBALL" >"$d/SHA256SUMS" ;;
    esac
}

# Stubs shared by the sign and verify scenarios: the release has IMAGE_DIGEST, SHA256SUMS and
# the tarball; the registry serves REG (default the valid digest) for every ref. The real
# check_release_files runs (so check_image_digest_file and check_digest_package run), except
# with ISO=1, which replaces it so that only the new check_sums_package is exercised.
stub_release_files() {
    need() { :; }
    require_docker() { :; }
    check_tag() {
        COMMIT=$FAKE_COMMIT
        rec "check_tag $*"
    }
    release_state() {
        REL_EXISTS=1 REL_DRAFT=true REL_PRERELEASE=$PRERELEASE REL_AUTHOR=$BOT_LOGIN
        REL_ASSETS=$(printf '%s\n' IMAGE_DIGEST SHA256SUMS "$TARBALL")
        REL_ASSET_IDS=''
    }
    release_fetch() {
        make_dir "$1"
        shift
        rec "release_fetch $*"
    }
    check_fetched_digests() { :; }
    check_sums() { rec "check_sums (stubbed)"; }
    check_tarball() {
        mkdir -p "$2/telcoin-network-$TAG-$TRIPLE"
        printf 'bin\n' >"$2/telcoin-network-$TAG-$TRIPLE/telcoin-network"
    }
    image_binary() {
        printf 'bin\n' >"$2"
        rec "image_binary $1"
    }
    check_version_output() { rec "check_version_output $1"; }
    registry_digest() {
        rec "registry_digest $*"
        printf '%s\n' "${REG-$FAKE_D}"
    }
    docker() { rec "docker $*"; }
    if [ "${ISO:-}" = 1 ]; then
        check_release_files() {
            rec "check_release_files (stubbed by ISO=1)"
            D=$FAKE_D
        }
    fi
}

parse_tag "$tag"
init_env
mkdir -p "$WORK/cwd"
cd "$WORK/cwd"

case "$scenario" in
    init)
        printf 'CHANNEL=%s PACKAGE=%s REPO=%s IMAGE=%s DRY_RUN=%s ALIAS=%s\n' \
            "$CHANNEL" "$PACKAGE" "$REPO" "$IMAGE" "$DRY_RUN" "$ALIAS"
        ;;
    digest)
        check_digest_package "$(printf '%b' "${IDG//@SELF@/$IMAGE}")"
        printf 'PASSED check_digest_package\n'
        ;;
    sums)
        make_dir "$WORK/d"
        check_sums_package "$WORK/d" "${ADVICE:-}"
        printf 'PASSED check_sums_package\n'
        ;;
    file)
        registry_digest() {
            rec "registry_digest $*"
            printf '%s\n' "${REG-$FAKE_D}"
        }
        make_dir "$WORK/d"
        check_image_digest_file "$WORK/d"
        printf 'PASSED check_image_digest_file D=%s\n' "$D"
        ;;
    sign)
        stub_release_files
        resolve_signing_key() { SIGN_HANDLE=tester SIGN_FPR=FPR SIGN_KEY=KEY; }
        check_build_sums_hash() { rec "check_build_sums_hash"; }
        confirm() { rec "confirm $1"; }
        gpg() {
            rec "gpg $*"
            printf 'STOP: reached gpg, the signature would be made now\n'
            exit 0
        }
        cmd_sign
        ;;
    verify)
        stub_release_files
        cmd_verify "${ALLOW_UNSIGNED:-1}"
        ;;
    publish)
        need() { :; }
        fetch_tag() { :; }
        check_scripts_from_main() { :; }
        cmd_verify() {
            rec "cmd_verify $*"
            COMMIT=$FAKE_COMMIT D=$FAKE_D REL_DRAFT=true REL_ASSET_IDS=x
        }
        check_release_body() { :; }
        record_release_body() { :; }
        published_versions() { :; }
        require_registry_login() { :; }
        confirm() { rec "confirm $1"; }
        check_assets_unchanged() { rec "check_assets_unchanged"; }
        gh_run() { rec "gh $*"; }
        registry_digest() {
            rec "registry_digest $*"
            case "$1" in
                "$TAG") printf '%s\n' "${REG_TAG-$FAKE_D}" ;;
                "$ALIAS")
                    if [ -f "$WORK/moved" ]; then printf '%s\n' "$FAKE_D"; else printf '%s\n' "$OLD_D"; fi
                    ;;
            esac
        }
        docker() {
            rec "docker $*"
            case "$*" in "buildx imagetools create"*) : >"$WORK/moved" ;; esac
        }
        cmd_publish
        ;;
    draft)
        tag_commit() { printf '%s\n' "$FAKE_COMMIT"; }
        load_allowlist() { :; }
        release_state() { REL_EXISTS=1 REL_DRAFT=true REL_AUTHOR=$BOT_LOGIN REL_ASSETS=IMAGE_DIGEST; }
        release_fetch() {
            mkdir -p "$1"
            write_idg "$1/IMAGE_DIGEST"
            rec "release_fetch $*"
        }
        render_notes() {
            rec "render_notes digest=[$1]"
            printf 'notes\n'
        }
        gh_run() { rec "gh $*"; }
        cmd_draft
        ;;
    checktag)
        check_tag() { rec "check_tag $*"; }
        cmd_check_tag
        ;;
    build)
        # REG_SEQ: what successive registry_digest calls see, comma separated: D (the pushed
        # digest), none (404), denied (401/403: "denied" with first-push, else the real die),
        # or a literal digest.
        uname() { case "$1" in -s) echo Linux ;; -m) echo x86_64 ;; esac; }
        need() { :; }
        require_docker() { :; }
        require_registry_login() { rec "require_registry_login"; }
        fetch_tag() { :; }
        check_scripts_from_main() { :; }
        check_tag() {
            COMMIT=$FAKE_COMMIT
            rec "check_tag $*"
        }
        release_state() {
            REL_EXISTS=1 REL_DRAFT=${REL_DRAFT_X:-true} REL_AUTHOR=$BOT_LOGIN
            REL_ASSETS=${REL_ASSETS_X:-}
        }
        registry_digest() {
            local n v
            n=$(($(cat "$WORK/regn" 2>/dev/null || echo 0) + 1))
            echo "$n" >"$WORK/regn"
            rec "registry_digest $* (call $n)"
            v=$(printf '%s\n' "${REG_SEQ:-}" | tr ',' '\n' | sed -n "${n}p")
            case "$v" in
                D) printf '%s\n' "$FAKE_D" ;;
                none | '') : ;;
                denied)
                    if [ "${2:-}" = first-push ]; then printf 'denied\n'; else die 2 "stub registry: HTTP 403"; fi
                    ;;
                *) printf '%s\n' "$v" ;;
            esac
        }
        git() {
            case "$*" in
                "worktree add"*)
                    mkdir -p "$BUILD_WT"
                    : >"$BUILD_WT/LICENSE-APACHE"
                    : >"$BUILD_WT/LICENSE-MIT"
                    : >"$BUILD_WT/NOTICE"
                    ;;
                "-C $BUILD_WT rev-parse HEAD") echo "$FAKE_COMMIT" ;;
                "-C $BUILD_WT submodule"*) : ;;
                "-C $BUILD_WT rev-parse HEAD:tn-contracts" | "-C $BUILD_WT/tn-contracts rev-parse HEAD") echo cccc ;;
                "log -1 --format=%ct"*) echo 1700000000 ;;
                "cat-file blob"*) echo cfg ;;
                *)
                    rec "git (unhandled) $*"
                    return 1
                    ;;
            esac
        }
        docker() {
            rec "docker $*"
            case "$1" in
                buildx)
                    case "$2" in
                        inspect) printf 'Name: default\nDriver: docker\n' ;;
                        imagetools)
                            # login_digest: what the docker login sees for $4 (IMAGE:TAG).
                            # LOGIN: D (the digest), none (not found), error (a network
                            # failure), nodigest, d-then-warning, or a literal answer.
                            case "${LOGIN:-none}" in
                                D) printf '%s\n' "$FAKE_D" ;;
                                none)
                                    printf 'ERROR: %s: not found\n' "$4" >&2
                                    return 1
                                    ;;
                                error)
                                    printf 'ERROR: failed to do request: dial tcp: lookup ghcr.io: no such host\n' >&2
                                    return 1
                                    ;;
                                nodigest) printf 'Name: %s\n' "$4" ;;
                                d-then-warning) printf '%s\nWARNING: attestation manifest not found\n' "$FAKE_D" ;;
                                *) printf '%s\n' "$LOGIN" ;;
                            esac
                            ;;
                    esac
                    ;;
                image)
                    case "$*" in
                        *Entrypoint*) printf '%s\n' 'null ["telcoin","node"]' ;;
                        *RepoDigests*) printf '["%s@%s"]\n' "$IMAGE" "$FAKE_D" ;;
                    esac
                    ;;
                create) printf 'ctr123\n' ;;
                cp)
                    case "$2" in
                        *:/usr/local/sbin/telcoin) return 1 ;;
                        *) printf 'bin\n' >"$3" ;;
                    esac
                    ;;
                run)
                    printf 'telcoin-network-cli Version: %s\nCommit SHA: %s\nBuild Features: %s\n' \
                        "$VERSION" "$FAKE_COMMIT" "${OUT_FEATURES-$FEATURES}"
                    ;;
                *) : ;;
            esac
        }
        release_upload() { rec "release_upload $*"; }
        render_notes() { rec "render_notes $1"; }
        release_set_notes() { rec "release_set_notes"; }
        cmd_verify() { rec "cmd_verify $*"; }
        cmd_build
        ;;
    regreal)
        # The real registry_digest with curl and sleep stubbed: TOKEN_CODE answers the token
        # request (fail: curl itself fails), MANIFEST_CODE the manifest HEAD (a 200 carries a
        # docker-content-digest header). MODE is passed as the second argument.
        sleep() { rec "sleep $*"; }
        curl() {
            local out='' prev='' a url=''
            for a in "$@"; do
                if [ "$prev" = -o ]; then out=$a; fi
                prev=$a
                url=$a
            done
            rec "curl $url"
            case "$url" in
                *"/token?"*)
                    if [ "${TOKEN_CODE:-200}" = fail ]; then return 7; fi
                    printf '{"token":"tok"}\n' >"$out"
                    printf '%s' "${TOKEN_CODE:-200}"
                    ;;
                *)
                    printf 'HTTP/2 %s\r\ndocker-content-digest: %s\r\n' "${MANIFEST_CODE:-200}" "$FAKE_D" >"$out"
                    printf '%s' "${MANIFEST_CODE:-200}"
                    ;;
            esac
        }
        regout=$(registry_digest "$TAG" "${MODE:-}")
        printf 'registry_digest printed [%s]\n' "$regout"
        ;;
    *)
        printf 'unknown scenario %s\n' "$scenario" >&2
        exit 64
        ;;
esac
