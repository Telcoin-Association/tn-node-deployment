# Lessons

## Bash: no apostrophes / single quotes inside `${var:-default}` defaults

**Symptom:** `bash -n install-caddy.sh` reported `syntax error near unexpected
token '('` on a line whose `(` was harmlessly inside a double-quoted string — and
the *real* offending code was ~14 lines earlier.

**Cause:** a default value contained an apostrophe:
`note="... (-> ${pub:-this host's inbound public IP}) ..."`. Even inside double
quotes and inside `${...:-...}`, bash treats that `'` as a quote delimiter and pairs
it with the *next* single quote in the file (here, the opening `'` of a later
`printf '{...}'` format string). Everything between is mis-quoted, desyncing all the
double-quote accounting, so the parser blows up on a much later line.

**Rule:** never put `'` (including apostrophes in prose) inside a `${var:-word}` /
`:+` / `:=` default. Rephrase to avoid the apostrophe. The codebase already follows
this — e.g. `${pub:-this servers public IP}` (no apostrophe in "servers"). Match it.

**Bonus:** when `bash -n` points at a line that looks obviously fine, suspect an
unbalanced quote *earlier* in the file, not the reported line.

## Bash: `local a; a="$(cmd)" b` runs `b` as a command and drops `a`

**Symptom:** shellcheck SC2154 ("b is referenced but not assigned") on a resolver I
wrote as `local etc; etc="$(_tn_etc)" var; ...; printf '%s' "$var"` — and at runtime
`$var`/`$etc` would have been **empty**. `bash -n` passed (valid syntax) so it nearly
slipped through; only shellcheck + a fixture unit test caught it.

**Cause:** `etc="$(_tn_etc)" var` is parsed as *run the command `var` with the env var
`etc` set for that one command*. Prefix assignments are temporary — `etc` is NOT
retained in the shell afterward — and `var` (or `t`, `n`, …) is executed as a bogus
command. Six resolver functions had this shape; every one was silently broken.

**Rule:** declare all locals on the `local` line, then assign on their own lines:
`local etc var; etc="$(_tn_etc)"; var="$(_tn_var)"`. Never trail a bare word after a
`VAR="$(...)"` assignment expecting it to be another local. Always shellcheck +
fixture-test library resolvers before building consumers on top of them.

## Verifying bash scripts that gate on `check_root` / do real side effects

To unit-test functions in a script that ends with `main "$@"` and whose interactive
path calls `check_root` + real installers: strip the trailing `main "$@"` into a temp
copy (`grep -v '^main "\$@"$'`), symlink `lib/` next to it so `source lib/common.sh`
resolves, `source` it, then override the side-effecting/network functions with stubs
and call the target function directly. Drive `read` prompts via piped stdin. Note:
`read -p` shows its prompt **only when stdin is a TTY**, so a piped harness won't see
prompt text — assert on resulting behavior/state instead. For network-dependent
helpers (curl/dig/hostname), prefer PATH shims that echo env-var-controlled values so
every branch is deterministic.

## Release hygiene: editing a tracked file is not done until versions + .sha256 are refreshed

**Symptom:** I edited `setup-vpn.sh` and bumped only its own `SCRIPT_VERSION`, then
declared the task complete. The user had to remind me to bump `update-scripts.sh` and
regenerate the `.sha256` sidecars.

**Cause:** `update-scripts.sh` fetches every tracked file from GitHub and verifies it
against a committed `<file>.sha256` sidecar; CI fails if any sidecar is stale. So a
content change to a tracked file leaves its sidecar (and the operator-facing verification)
out of sync until regenerated. The repo's release convention also bumps the updater itself
and adds a README changelog entry on each release (see commit 03bfc07,
`chore(release): refresh checksums...`).

**Rule:** after editing ANY updater-tracked file (anything in the `SCRIPTS`,
`UI_BUNDLE`, or `TESTNET_ADDONS_BUNDLE` arrays of `update-scripts.sh`), do ALL of:
1. bump that file's own version var (`SCRIPT_VERSION` / `COMMON_VERSION` / `UI_VERSION` / …);
2. bump `update-scripts.sh`'s `SCRIPT_VERSION` (release marker so updaters re-bootstrap);
3. run `bash tools/gen-checksums.sh` and commit the changed sidecars (it regenerates all 34;
   only the touched files' sidecars actually change — verify with `git status -- '*.sha256'`);
4. add a `### <script> vX.Y.Z` entry to the README Changelog.

**Rule of thumb:** "I changed a `.sh`/`.py`/`.env` that operators fetch" ⇒ versions +
`gen-checksums.sh` + changelog, every time. Don't call it done before that.
