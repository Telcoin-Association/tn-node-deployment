#!/usr/bin/env bash
# =============================================================================
# tools/check-terraform.sh -- the static checks of terraform/, every tool run
# from a Docker image pinned by digest
#
#   bash tools/check-terraform.sh [--only fmt|validate|test|tflint|checkov]...
#                                 [--root DIR]...
#
# For each Terraform root that exists among terraform/modules/host-plan,
# terraform/aws, terraform/gcp and terraform/azure, in that order:
#   fmt       terraform fmt -check -recursive -diff
#   validate  terraform init -backend=false (-lockfile=readonly when the root
#             has a .terraform.lock.hcl), then terraform validate
#   test      the same init, then terraform test
# then over terraform/ as a whole (or over each --root given):
#   tflint    tflint --init and tflint --recursive, with terraform/.tflint.hcl,
#             which pins the aws, google and azurerm rulesets
#   checkov   checkov with terraform/.checkov.yaml
# --only picks one of these (repeat it for more); --root DIR, relative to the
# repository root, checks DIR instead of the default roots (repeat it too).
#
# Nothing here needs cloud credentials, and none can reach a container: no
# host environment is passed in except GITHUB_TOKEN to tflint (it lifts the
# GitHub rate limit on the ruleset download), and no home directory is
# mounted. Only init and tflint --init get a network, to fetch providers and
# rulesets; fmt, validate, test and checkov run with --network none, so a
# test that reached a real provider instead of a mock fails. Nothing runs plan
# or apply outside terraform test.
#
# Containers run as the calling user, so the .terraform/ directories they leave
# in each root belong to you (.gitignore keeps them out of git). Providers and
# rulesets are cached in ${XDG_CACHE_HOME:-~/.cache}/tn-check-terraform;
# TN_TF_CACHE_DIR names another directory.
#
# Exit status:
#   0  every check passed
#   1  a check failed; each failure is named in the summary on stderr
#   2  the checks cannot run: a usage error, no docker, a --root that is not a
#      directory of the repository
#
# Maintainer tooling: update-scripts.sh does not track tools/ and this file has
# no .sha256 sidecar. bash 3.2 safe.
# =============================================================================

set -uo pipefail

readonly TF_IMAGE="hashicorp/terraform:1.17.2@sha256:6e9c1e647c31a960dc9b59e13272f9111d90010c10b717f77ffb324767660475"
readonly TFLINT_IMAGE="ghcr.io/terraform-linters/tflint:v0.66.0@sha256:65b9944a9274c4989492c1d79998c2801664bf8a55fddb4bd3a9e6d73a006ddc"
readonly CHECKOV_IMAGE="bridgecrew/checkov:3.4.11@sha256:68da9ede242807850ab346b533dc1e4d2b00e15a9e6b4b595654d39c7f2e2566"

readonly DEFAULT_ROOTS="terraform/modules/host-plan terraform/aws terraform/gcp terraform/azure"
readonly ALL_STEPS="fmt validate test tflint checkov"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ONLY=""
ROOTS=""
FAILED=""

usage() {
    cat <<'EOF'
usage: tools/check-terraform.sh [--only fmt|validate|test|tflint|checkov]... [--root DIR]...
EOF
}

say() { printf '==> %s\n' "$*" >&2; }

fail() {
    FAILED="${FAILED}${FAILED:+
}  $*"
    printf 'FAILED: %s\n' "$*" >&2
}

want() {
    [[ -z "$ONLY" ]] && return 0
    case " $ONLY " in *" $1 "*) return 0 ;; esac
    return 1
}

# run_tf NET DIR ARGS... -- terraform in DIR (relative to the repository root),
# with the network NET (none, or bridge for init).
run_tf() {
    local net="$1" dir="$2"
    shift 2
    docker run --rm --network "$net" -u "$(id -u):$(id -g)" \
        -e HOME=/tmp -e CHECKPOINT_DISABLE=1 -e TF_IN_AUTOMATION=1 -e TF_INPUT=0 \
        -e TF_PLUGIN_CACHE_DIR=/cache/terraform-plugins \
        -v "${REPO}:/w" -v "${CACHE}:/cache" -w "/w/${dir}" \
        "$TF_IMAGE" "$@"
}

# tf_init DIR -- init without a backend, holding a root that has a lock file to
# it. Once per root (validate and test share it): a failure is named once and
# the root's later steps are skipped.
INIT_OK=""
INIT_BAD=""
tf_init() {
    local dir="$1" lock=""
    case " $INIT_OK " in *" $dir "*) return 0 ;; esac
    case " $INIT_BAD " in *" $dir "*) return 1 ;; esac
    [[ -f "${REPO}/${dir}/.terraform.lock.hcl" ]] && lock="-lockfile=readonly"
    say "terraform init ${dir}"
    # shellcheck disable=SC2086  # lock is one word or none
    if run_tf bridge "$dir" init -backend=false -no-color $lock; then
        INIT_OK="${INIT_OK} ${dir}"
        return 0
    fi
    INIT_BAD="${INIT_BAD} ${dir}"
    fail "terraform init ${dir}"
    return 1
}

check_root() {
    local dir="$1"
    if want fmt; then
        say "terraform fmt ${dir}"
        run_tf none "$dir" fmt -check -recursive -diff -no-color || fail "terraform fmt ${dir}"
    fi
    if want validate && tf_init "$dir"; then
        say "terraform validate ${dir}"
        run_tf none "$dir" validate -no-color || fail "terraform validate ${dir}"
    fi
    if want test && tf_init "$dir"; then
        say "terraform test ${dir}"
        run_tf none "$dir" test -no-color || fail "terraform test ${dir}"
    fi
}

run_tflint() {
    local dir="$1" tok=()
    [[ -n "${GITHUB_TOKEN:-}" ]] && tok=(-e GITHUB_TOKEN)
    say "tflint ${dir}"
    # The plugins are cached; --init only downloads what the cache lacks.
    docker run --rm -u "$(id -u):$(id -g)" -e HOME=/tmp \
        -e TFLINT_PLUGIN_DIR=/cache/tflint-plugins ${tok[@]+"${tok[@]}"} \
        -v "${REPO}:/w" -v "${CACHE}:/cache" -w "/w/${dir}" \
        "$TFLINT_IMAGE" --init --config=/w/terraform/.tflint.hcl \
        || { fail "tflint --init ${dir}"; return; }
    docker run --rm --network none -u "$(id -u):$(id -g)" -e HOME=/tmp \
        -e TFLINT_PLUGIN_DIR=/cache/tflint-plugins \
        -v "${REPO}:/w" -v "${CACHE}:/cache" -w "/w/${dir}" \
        "$TFLINT_IMAGE" --recursive --config=/w/terraform/.tflint.hcl --no-color \
        || fail "tflint ${dir}"
}

run_checkov() {
    local dir="$1"
    say "checkov ${dir}"
    docker run --rm --network none -u "$(id -u):$(id -g)" -e HOME=/tmp \
        -v "${REPO}:/w" -w /w --entrypoint checkov \
        "$CHECKOV_IMAGE" --config-file /w/terraform/.checkov.yaml -d "/w/${dir}" \
        || fail "checkov ${dir}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --only)
            [[ $# -ge 2 ]] || { usage >&2; exit 2; }
            case " $ALL_STEPS " in
                *" $2 "*) ONLY="${ONLY} $2" ;;
                *) printf 'check-terraform: --only takes one of: %s (not %s)\n' "$ALL_STEPS" "$2" >&2; exit 2 ;;
            esac
            shift 2 ;;
        --only=*)
            set -- --only "${1#*=}" "${@:2}" ;;
        --root)
            [[ $# -ge 2 ]] || { usage >&2; exit 2; }
            ROOTS="${ROOTS} ${2%/}"
            shift 2 ;;
        --root=*)
            set -- --root "${1#*=}" "${@:2}" ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'check-terraform: unknown argument %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
done

if ! command -v docker >/dev/null 2>&1; then
    printf 'check-terraform: docker is required: every tool runs from a pinned image.\n' >&2
    exit 2
fi

for d in $ROOTS; do
    case "$d" in
        /*|*..*) printf 'check-terraform: --root %s must be a path inside the repository, relative to its root.\n' "$d" >&2; exit 2 ;;
    esac
    if [[ ! -d "${REPO}/${d}" ]]; then
        printf 'check-terraform: --root %s is not a directory.\n' "$d" >&2
        exit 2
    fi
done

CACHE="${TN_TF_CACHE_DIR:-${XDG_CACHE_HOME:-${HOME}/.cache}/tn-check-terraform}"
mkdir -p "${CACHE}/terraform-plugins" "${CACHE}/tflint-plugins" || {
    printf 'check-terraform: cannot create the cache directory %s.\n' "$CACHE" >&2
    exit 2
}

tf_roots="$ROOTS"
if [[ -z "$tf_roots" ]]; then
    for d in $DEFAULT_ROOTS; do
        [[ -d "${REPO}/${d}" ]] && tf_roots="${tf_roots} ${d}"
    done
fi

for d in $tf_roots; do
    check_root "$d"
done

# The linters read every root at once unless the run names its roots.
lint_dirs="${ROOTS:-terraform}"
for d in $lint_dirs; do
    want tflint && run_tflint "$d"
    want checkov && run_checkov "$d"
done

if [[ -n "$FAILED" ]]; then
    printf '\ncheck-terraform: failed:\n%s\n' "$FAILED" >&2
    exit 1
fi
say "all checks passed"
exit 0
