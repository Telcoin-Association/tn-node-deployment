#!/usr/bin/env bash
# =============================================================================
# tools/tests/ci_pins_test.sh -- workflow hygiene in .github/workflows/*.yml
#
#   bash tools/tests/ci_pins_test.sh
#
# Every `uses:` names a full 40-hex commit SHA with the tag in a comment; every
# workflow has a top-level `permissions:` and every job its own; no workflow
# runs on pull_request_target; every checkout sets persist-credentials: false;
# CODEOWNERS and dependabot.yml exist. Each display name the main-branch
# ruleset requires names exactly one job; the hardening lints, the UI tests
# and the macOS job run the lints and the UI shell tests directly, with no
# fallback for a missing file; no required job, and no step of one, carries
# an if: or a continue-on-error, except the advisory shellcheck run; no run
# line in them ends a failure with || true, || : or || exit 0; the Pages site
# gets no .nojekyll. Plain text checks (no YAML parser), so they assume the
# two-space layout the workflows use. bash 3.2 safe.
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

# job_table FILE -- "id|display name" for each named job of FILE (the job key
# at two spaces under jobs:, its name: key at four), quotes removed.
job_table() {
    awk -v q="'" '
        /^jobs:/ { injobs = 1; next }
        /^[^[:space:]#]/ { injobs = 0 }
        injobs && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { id = $1; sub(/:$/, "", id); next }
        injobs && /^    name:[[:space:]]/ {
            sub(/^    name:[[:space:]]*/, ""); sub(/[[:space:]]+$/, "")
            c = substr($0, 1, 1)
            if (length($0) > 1 && (c == "\"" || c == q) && substr($0, length($0), 1) == c)
                $0 = substr($0, 2, length($0) - 2)
            print id "|" $0
        }
    ' "$1"
}

# job_names FILE -- the display name of each job of FILE.
job_names() {
    job_table "$1" | sed 's/^[^|]*|//'
}

# job_id FILE NAME -- the id of the job of FILE whose display name is NAME.
job_id() {
    job_table "$1" | awk -v n="$2" '{
        i = index($0, "|")
        if (substr($0, i + 1) == n) { print substr($0, 1, i - 1); exit }
    }'
}

# job_body FILE JOB -- the lines of job JOB of FILE (its key at two spaces
# under jobs:), comment lines left out.
job_body() {
    awk -v job="$2" '
        /^jobs:/ { injobs = 1; next }
        /^[^[:space:]#]/ { injobs = 0 }
        injobs && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { cur = $1; sub(/:$/, "", cur); next }
        injobs && cur == job && !/^[[:space:]]*#/ { print }
    ' "$1"
}

# count_line LINE TEXT -- how many lines of TEXT are exactly LINE.
count_line() {
    printf '%s\n' "$2" | grep -cxF -- "$1"
}

# has STRING TEXT -- yes when STRING appears in TEXT, else no.
has() {
    if printf '%s\n' "$2" | grep -qF -- "$1"; then echo yes; else echo no; fi
}

# job_gates JOB -- read the lines of job JOB (job_body) and print each if: and
# each continue-on-error other than false, on the job ("JOB: job: KEY: VALUE")
# or on a step ("JOB: step \"NAME\": KEY: VALUE"). Job keys sit at four
# spaces, step keys after "      - " or at eight spaces.
job_gates() {
    awk -v job="$1" '
        function val(line) {
            sub(/^[^:]*:[[:space:]]*/, "", line); sub(/[[:space:]]+$/, "", line)
            return line
        }
        function key(line,   v) {
            v = val(line)
            if (line ~ /^name:/) sname = v
            else if (line ~ /^if:/) flags = flags SUBSEP "if: " v
            else if (line ~ /^continue-on-error:/ && v != "false") flags = flags SUBSEP "continue-on-error: " v
        }
        function flush(   n, i, f) {
            if (instep && flags != "") {
                n = split(substr(flags, 2), f, SUBSEP)
                for (i = 1; i <= n; i++) print job ": step \"" sname "\": " f[i]
            }
            instep = 0; sname = ""; flags = ""
        }
        /^    [A-Za-z_-]+:/ {
            flush()
            if ($0 ~ /^    if:/) print job ": job: if: " val($0)
            if ($0 ~ /^    continue-on-error:/ && val($0) != "false")
                print job ": job: continue-on-error: " val($0)
            next
        }
        /^      - / { flush(); instep = 1; key(substr($0, 9)); next }
        instep && /^        [A-Za-z_-]+:/ { key(substr($0, 9)) }
        END { flush() }
    '
}

# The ruleset requires status checks by display name, not job id, so a renamed
# job (or two jobs with one name) leaves a required check that never reports.
all_names="$(for f in "${workflows[@]}"; do job_names "$f"; done)"
req_jobs=""
n_req=0
while IFS='|' read -r wf name; do
    n_req=$((n_req + 1))
    in_wf="$(job_names "$GH/workflows/$wf")"
    check "$wf: required check \"$name\" names exactly one job" "$wf=1 all=1" \
        "$wf=$(count_line "$name" "$in_wf") all=$(count_line "$name" "$all_names")"
    id="$(job_id "$GH/workflows/$wf" "$name")"
    [[ -n "$id" ]] && req_jobs="${req_jobs}${wf}|${id}
"
done <<'EOF'
ci.yml|bash -n (Linux)
ci.yml|bash -n and bash-3.2 lint (macOS bash 3.2)
ci.yml|shellcheck
ci.yml|fixture tests (Linux bash 5)
ci.yml|fixture tests (macOS bash 3.2)
ci.yml|hardening lints
ci.yml|release manifest
ci.yml|Node Manager UI tests
ci.yml|checksum freshness
integration.yml|Ubuntu 24.04 VM assertions
EOF

check "every required check names a job" "$n_req" "$(printf '%s' "$req_jobs" | grep -c .)"

lint_job="$(job_body "$GH/workflows/ci.yml" hardening-lint)"
ui_job="$(job_body "$GH/workflows/ci.yml" ui-tests)"
mac_job="$(job_body "$GH/workflows/ci.yml" parse-macos)"

check "hardening-lint runs the passphrase-print lint" "yes" "$(has 'bash tools/tests/passphrase_print_test.sh' "$lint_job")"
check "hardening-lint runs the network-hits lint" "yes" "$(has 'bash tools/check-network-hits.sh' "$lint_job")"
check "hardening-lint runs the perl interpolation lint" "yes" "$(has 'bash tools/check-perl-interp.sh' "$lint_job")"
check_lacks "hardening-lint: no fallback for a missing lint" "if [ -f" "$lint_job"
check "ui-tests installs the test requirements by hash" "yes" \
    "$(has '--require-hashes -r ui/tests/requirements-dev.txt' "$ui_job")"
check "ui-tests runs pytest" "yes" "$(has 'python -m pytest' "$ui_job")"
check_lacks "ui-tests: no fallback for a missing requirements file" "if [ -f" "$ui_job"
check_lacks "ui-tests: no unittest fallback" "unittest" "$ui_job"
for t in helper_test.sh install_ui_test.sh open_ui_test.sh; do
    check "ui-tests runs ui/tests/$t" "yes" "$(has "bash ui/tests/$t" "$ui_job")"
    check "parse-macos runs ui/tests/$t under /bin/bash" "yes" "$(has "/bin/bash ui/tests/$t" "$mac_job")"
done
check "fixture-tests runs the suite" "yes" "$(has 'bash tools/tests/run.sh' "$(job_body "$GH/workflows/ci.yml" fixture-tests)")"
check "fixture-tests-macos runs the suite under /bin/bash" "yes" \
    "$(has '/bin/bash tools/tests/run.sh' "$(job_body "$GH/workflows/ci.yml" fixture-tests-macos)")"
check "checksums regenerates the sidecars" "yes" "$(has 'bash tools/gen-checksums.sh' "$(job_body "$GH/workflows/ci.yml" checksums)")"

# A skipped required check counts as passed, and continue-on-error turns a
# failure into a pass, so neither may sit on a required job or on a step of
# one. The one exception is the advisory shellcheck run at warning severity.
check "required jobs: no if:, no continue-on-error but the advisory shellcheck run" \
    'shellcheck: step "shellcheck (warnings -- advisory)": continue-on-error: true' \
    "$(printf '%s' "$req_jobs" | while IFS='|' read -r wf id; do
        job_body "$GH/workflows/$wf" "$id" | job_gates "$id"
    done)"
check "required jobs: no run line ends a failure with || true, || : or || exit 0" "" \
    "$(printf '%s' "$req_jobs" | while IFS='|' read -r wf id; do
        job_body "$GH/workflows/$wf" "$id" |
            grep -E '[|][|][[:space:]]*(true|:|exit[[:space:]]+0)([[:space:];)]|$)' |
            sed "s/^[[:space:]]*/${id}: /"
    done)"

check "publish-installer: no .nojekyll" "0" "$(grep -c '\.nojekyll' "$GH/workflows/publish-installer.yml")"

finish
