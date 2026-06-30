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
