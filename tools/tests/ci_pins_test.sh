#!/usr/bin/env bash
# =============================================================================
# tools/tests/ci_pins_test.sh -- workflow hygiene in .github/workflows/*.yml
#
#   bash tools/tests/ci_pins_test.sh
#
# Every `uses:` names a full 40-hex commit SHA with the tag in a comment; every
# workflow has a top-level `permissions:` and every job its own; no workflow
# runs on pull_request_target; every checkout sets persist-credentials: false;
# CODEOWNERS and dependabot.yml exist. Plain text checks (no YAML parser), so
# they assume the two-space layout the workflows use. bash 3.2 safe.
# =============================================================================

set -u

# shellcheck source=tools/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GH="$TN_TEST_REPO/.github"

workflows=()
for f in "$GH"/workflows/*.yml "$GH"/workflows/*.yaml; do
    [[ -f "$f" ]] && workflows+=("$f")
done
check "workflows found" "yes" "$([[ ${#workflows[@]} -ge 3 ]] && echo yes || echo no)"

for f in "${workflows[@]}"; do
    n="${f#"$GH"/workflows/}"
    check "$n: every uses: is a SHA pin with its tag" "" \
        "$(grep -nE '^[[:space:]-]*uses:' "$f" | grep -vE 'uses: [A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+@[0-9a-f]{40} # v[0-9]+(\.[0-9]+)*$')"
    check "$n: top-level permissions" "1" "$(grep -c '^permissions:' "$f")"
    check "$n: every job declares permissions" "" "$(awk '
        /^jobs:/ { injobs = 1; next }
        /^[^[:space:]#]/ { injobs = 0 }
        injobs && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ {
            if (job != "" && !perm) print job
            job = $1; perm = 0; next
        }
        injobs && /^    permissions:/ { perm = 1 }
        END { if (job != "" && !perm) print job }
    ' "$f")"
    check "$n: no pull_request_target" "0" "$(grep -c 'pull_request_target' "$f")"
    check "$n: every checkout drops its credentials" \
        "$(grep -c 'uses: actions/checkout@' "$f")" "$(grep -c 'persist-credentials: false' "$f")"
done

check "publish-installer: deploys only from a release tag" "2" \
    "$(grep -c "if: startsWith(github.ref, 'refs/tags/scripts-v')" "$GH/workflows/publish-installer.yml")"
check "publish-installer: checks the signed manifest" "1" \
    "$(grep -c 'bash tools/release-scripts.sh --check --tag "$TAG"' "$GH/workflows/publish-installer.yml")"
check "publish-installer: pages write only on deploy" "1" "$(grep -c 'pages: write' "$GH/workflows/publish-installer.yml")"
check "CODEOWNERS exists with a default owner" "1" "$(grep -cE '^\*[[:space:]]+@' "$GH/CODEOWNERS" 2>/dev/null)"
check "dependabot covers github-actions and pip" "2" "$(grep -cE 'package-ecosystem: (github-actions|pip)$' "$GH/dependabot.yml" 2>/dev/null)"
check "ci.yml keeps the ruleset check names" "" "$(for j in parse-linux parse-macos shellcheck ui-tests checksums; do
    grep -q "^  ${j}:$" "$GH/workflows/ci.yml" || echo "$j"
done)"

finish
