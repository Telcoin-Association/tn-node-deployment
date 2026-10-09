status: done

Package UI-1: ui/telcoin-ui-helper.sh, ui/install-ui.sh, ui/tests/helper_test.sh (new).

## Sections
- [x] 1 helper token handling and `helper-version`
- [x] 2 helper node resolution and engine argv
- [x] 3 helper hostname checks and `rpc-enable`
- [x] 4 installer reorder and sudoers (with TRANSITIONAL block)
- [x] 5 installer comments and `tr`
- [x] 6 tests written and passing under both bashes
- [x] 7 closing headings

## Notes
- Helper: `HELPER_API=2`, `helper-version`. `legacy_arity` + main drop a leading
  observer|validator only when argc > token-free arity (update-prepare 1, config-set 2,
  set-hostname 1, the other eleven 0) and refuse anything left over ("too many arguments
  for <sub>: ..."). rpc-enable refuses a 4th argument. No other subcommand is touched.
- Paths are plain assignments: UNIT_DIR ETC_DIR VAR_DIR LOG_DIR OPT_DIR UPDATE_SCRIPT
  CONFIG_SCRIPT FIREWALL_SCRIPT SETUP_SCRIPT CADDY_SCRIPT LOGROTATE_CONF. `main` runs only
  under `[[ "${BASH_SOURCE[0]}" == "$0" ]]`.
- Resolution: node_service / node_meta_path / node_data_dir / node_wrapper / node_log_path,
  token ignored entirely. Deliberate difference from tn_resolve_data_dir: an absolute
  DATA_DIR that does not exist is still returned, so set-hostname dies with "data dir not
  found: <dir>" instead of writing where the node does not read.
- Engines already ignore role flags (update-node.sh LEGACY_ROLE_FLAG, edit-config.sh).
  setup-node.sh reads only TN_BLS_PASSPHRASE from env, so dropping TN_SETUP_RPC_PUBLIC /
  TN_SETUP_INSTANCE from env_keep is safe.
- Installer: A.3 order, SCRIPT_VERSION 1.4.0; candidate via
  `mktemp /etc/sudoers.d/.telcoin-ui.XXXXXX`, chmod 440, visudo -cf, EXIT trap removes it
  if the run stops before step 11; helper via `install ... .new` + `mv -f`; UPDATE_DIR and
  lib/ now created unconditionally. Pre-existing bug fixed: unescaped backticks in the
  unquoted sudoers heredoc ran `telcoin.service` as a command on every install.

## Operator-visible changes
- `install-ui.sh` (and `--update`) now validates the new sudoers whitelist before
  changing anything and installs it last. If Flask cannot be installed, a ui/ source file
  is missing, the helper source does not parse, or visudo rejects the whitelist, the
  installer stops and the running UI, its helper and its sudoers file stay as they were.
  A failure after the helper step leaves the old whitelist with the new helper, which
  still accepts the old calls.
- The install log no longer shows "telcoin.service: command not found".
- `/opt/telcoin-ui-update/` no longer gets `setup-observer.sh` / `setup-validator.sh`;
  copies left by earlier versions are removed. UI setup runs `setup-node.sh` directly.
- Tracing enabled from the UI registers the node with Jaeger as `telcoin` (previously
  `telcoin-observer` / `telcoin-validator`).
- On a box with both legacy units, UI node actions target `telcoin-validator`; a box with
  one legacy unit always gets that unit, whatever role the UI shows.
- Dashboard and public RPC hostnames must pass the strict rule (two or more labels,
  letters/digits/inner hyphens, labels up to 63, at most 253, not an IPv4 address). With
  today's server.py a name it accepts but the helper refuses (e.g. `localhost`) now fails
  with the helper's "invalid domain" message instead of reaching install-caddy.sh.
- New capabilities that need UI-2/UI-3 to surface: `helper-version`, setup with
  TN_SETUP_RPC_DOMAIN (sent as `--rpc-domain`), `rpc-enable ... <dashboard-host>`
  (`--move-dashboard-to`).

## Changelog text
### install-ui v1.4.0 — sudoers whitelist installed last; helper API 2
The installer builds the new sudoers whitelist under a dotted name in `/etc/sudoers.d`
(sudo ignores it), checks it with `visudo -c`, and renames it over
`/etc/sudoers.d/telcoin-ui` only after the helper, the engine copies, the UI files, the
logrotate seed and the unit are installed. If Flask cannot be installed, a source file is
missing or visudo rejects the whitelist, it stops before anything of the UI changes; a
failure after the helper step leaves the old whitelist, which the new helper still serves.
The whitelist adds `helper-version` and the no-argument forms of the node subcommands,
keeps the old `observer|validator` lines in a block marked TRANSITIONAL until telcoin-ui
1.9.0, keeps `TN_SETUP_RPC_DOMAIN` across sudo and drops `TN_SETUP_RPC_PUBLIC` and
`TN_SETUP_INSTANCE`. The engine copies in `/opt/telcoin-ui-update/` no longer include the
deprecated `setup-observer.sh` and `setup-validator.sh`, and copies left by earlier
versions are removed. The start and enable prompts lowercase with `tr` (bash 3.2 safe),
and the sudoers comment no longer runs `telcoin.service` as a command on every install.

### telcoin-ui-helper (helper API 2) — no role argument, strict hostnames, dashboard move
`helper-version` prints 2. The node subcommands (tracing, updates, restart count, log
clear, config edit, hostname, add-on status, metadata, setup) take no `observer|validator`
argument: the helper finds the node the way `lib/fallback.sh` does (unit `telcoin`, then
`telcoin-validator`, then `telcoin-observer`; the unified `.node-meta`, then the legacy
role dirs; the meta's `DATA_DIR`). A leading role from an older server.py is dropped when
the call has one argument more than the subcommand takes, so `set-hostname validator`
still names the node "validator". Engine calls carry no role flag, setup calls
`setup-node.sh` directly with `--rpc-domain` from `TN_SETUP_RPC_DOMAIN` and never sends
`--rpc-public`, and tracing registers the node as `telcoin`.
`rpc-enable <host> [<ip>|-] [<dashboard-host>]` passes `--move-dashboard-to` and refuses a
dashboard host equal to the RPC host. Dashboard and RPC hostnames follow the strict rule
shared with the server and browser: at most 253 characters, two or more labels of
letters, digits and inner hyphens up to 63 characters each, not an IPv4 address. Tests:
`ui/tests/helper_test.sh` (bash 3.2 and 5).

## Tests run
- `TMPDIR=<scratchpad> /bin/bash ui/tests/helper_test.sh` → 169 checks, 0 failed (bash 3.2.57).
- `TMPDIR=<scratchpad> bash ui/tests/helper_test.sh` → 169 checks, 0 failed (bash 5.3.15).
  Temp dir removed afterwards in both.
- Mutation check (scratch copies of the helper, test unchanged): 13 deliberate breaks, all
  caught — no token strip (36 fails), strip even at arity (3), `--observer` back on
  update-check (2), main always runs (2), observer before validator (5), no IPv4 refusal
  (6), no same-host refusal (2), `--rpc-public` back (6), node-name telcoin-observer (7),
  no move-dashboard flag (2), DATA_DIR ignored (3), 64-char label allowed (5), no
  leftover-argument refusal (5).
- `/bin/bash -n` and `bash -n` on all three files: clean.
- `shellcheck -x --severity=error` on all three files: clean. `--severity=warning`: helper
  and test clean; installer only the pre-existing SC2034 (SCRIPT_VERSION unused, as on HEAD).
- Generated sudoers (heredoc expanded as the installer does): `visudo -cf` "parsed OK"
  (macOS sudo 1.9). Content vs A.2: 9 systemctl lines identical to HEAD; 23 exact and 14
  wildcard helper lines exactly the A.2 lists; 6 firewall-port lines; TRANSITIONAL block
  identical to the 28 old token lines, same order; env_keep diff vs HEAD is
  -TN_SETUP_INSTANCE -TN_SETUP_RPC_PUBLIC +TN_SETUP_RPC_DOMAIN. Heredoc expansion writes
  nothing to stderr (HEAD prints "telcoin.service: command not found").
- Installer harness (scratchpad/install_harness.sh, not committed): path-rewritten copy of
  install-ui.sh on a temp root with recording shims, run under /bin/bash 3.2 and bash 5,
  0 failures. Scenarios: --update happy path (order pip3 < id/useradd < visudo < helper
  .new + mv < engine < server.py < chown < daemon-reload < sudoers mv < restart; stale
  shim copies removed; no candidate or .new left); visudo rejects (live sudoers and helper
  untouched, candidate removed, UI files not written); engine copy fails after the helper
  (live sudoers untouched, new helper in place, candidate removed, no restart); Flask fails
  (nothing touched, stopped at step 2); fresh-install prompts N/N, empty/y, n/Y, Y/n.
- Docker not needed (no container used).

## Open issues
- TRANSITIONAL lines to remove in UI-4, in `ui/install-ui.sh` between
  `# TRANSITIONAL: removed once ui/server.py 1.9.0 ships.` and `# END TRANSITIONAL`
  (remove both markers and the five comment lines after the first marker too). Each line
  is `${SVC_USER} ALL=(ALL) NOPASSWD: /usr/local/sbin/telcoin-ui-helper ` followed by:
  tracing-enable observer | tracing-enable validator | tracing-disable observer |
  tracing-disable validator | update-check observer | update-check validator |
  update-prepare observer * | update-prepare validator * | update-apply observer |
  update-apply validator | update-discard observer | update-discard validator |
  restart-count observer | restart-count validator | log-clear observer |
  log-clear validator | config-set observer * | config-set validator * |
  set-hostname observer * | set-hostname validator * | addons-status observer |
  addons-status validator | meta-cat observer | meta-cat validator |
  setup-keygen observer | setup-keygen validator | setup-finalize observer |
  setup-finalize validator (28 lines). After removal, re-run `visudo -cf` on the
  expanded heredoc and `ui/tests/helper_test.sh`; the helper keeps accepting the token
  form, so it needs no change.
- ui/server.py (UI-2) must:
  1. drop the role token from the 14 node calls: tracing-enable, tracing-disable,
     update-check, update-prepare <ref>, update-apply, update-discard, restart-count,
     log-clear, config-set <field> <value>, set-hostname <name>, addons-status, meta-cat,
     setup-keygen, setup-finalize;
  2. call exactly `["sudo","-n",HELPER,"helper-version"]` and require output `2`;
  3. in `_setup_env`, set `TN_SETUP_RPC_DOMAIN` (normalised, strict-checked) and stop
     setting `TN_SETUP_RPC_PUBLIC` / `TN_SETUP_INSTANCE` (sudo now strips both);
  4. build rpc-enable as `[..., "rpc-enable", d] + ([ip or "-"] if ip or move) + ([move] if move)`;
     the helper refuses move == host (case-insensitive) and an invalid dashboard host;
  5. apply the strict hostname rule before caddy-dns-check, rpc-dns-check, caddy-enable,
     rpc-enable (until then the helper refuses what `_CADDY_DOMAIN_RE` lets through);
  6. Jaeger `resolve_service`: the helper now writes `--node-name telcoin`; today's server
     looks only for `telcoin-<role>`, so tracing lookups miss until A.5's "prefer `telcoin`,
     then any `telcoin-*`" lands. Operators only get the helper with the UI bundle (gated
     on UI_VERSION in UI-4), so this bites only a manual install-ui run from main in between.
- For the A.7 cross-file test (test_server_contract.py): the sudoers text is the heredoc
  `cat > "${SUDOERS_TMP}" <<EOF` ... `EOF` in ui/install-ui.sh, lines use the literal path
  `/usr/local/sbin/telcoin-ui-helper` and the literal user via `${SVC_USER}`; step headers
  are `# ---- N. <title> ---` for N = 1..12 in the A.3 order.
- Lint tool (core package): `ui/install-ui.sh` no longer has the two `${var,,}`; the
  "known bash-4 constructs" list in spec-fu-shared.md must drop them.
- README "Security model" (docs owner): it says the installer "removes it and stops if
  `visudo -c` rejects it". Now a rejected new whitelist is discarded and the live file is
  left in place; the whitelist is installed last. Could also mention `helper-version`.
- `ui/tests/helper_test.sh` is picked up by CI's `bash -n` and shellcheck jobs through
  `git ls-files '*.sh'`; nothing executes it yet. Suggest a CI step running it under
  `bash` (ubuntu) and `/bin/bash` (macos); ci.yml is not in this package. It is not
  updater-tracked and needs no sidecar. Its file mode is 755 (chmod +x on disk).
- Unrelated working-tree changes seen and left alone: ui/static/index.html, ui/dev/.

## Follow-up: config-set fields
Request (coordinator, after UI-2a/2b): edit-config 1.3.0 (9ff00af) added --set fields and
metrics=off; teach the helper's config-set allowlist and the server's validation the same
fields and patterns. Files: ui/telcoin-ui-helper.sh, ui/server.py, ui/tests/helper_test.sh,
ui/test_server_contract.py. No version bumps, no git writes, not index.html.

- [x] F1 helper cmd_config_set accepts metrics=off, bootstrap_peers, state_export,
      allow_private_forward_targets (bash -n 3.2/5, shellcheck error, check-bash32: clean)
- [x] F2 server.py config-set validation, same fields and patterns, 400 otherwise
      (CONFIG_VALUE_RE table; CONFIG_FIELDS derived from it; fullmatch; py_compile ok,
      parses with the 3.10 grammar)
- [x] F3 test rows: ui/tests/helper_test.sh and ui/test_server_contract.py
- [x] F4 checks: helper_test under /bin/bash and bash; unittest discover (121 before);
      bash -n both; shellcheck -x --severity=error helper; tools/check-bash32.sh helper;
      py_compile server.py
- [x] F5 report: counts and exact field/pattern list

Notes:
- docker unavailable (`docker info` hung; stopped), so the bootstrap_peers error-echo
  question below could not be checked against the node binary.

Fields and patterns shipped (helper `[[ =~ ]]` and server `CONFIG_VALUE_RE`, identical text;
ConfigSetTest compares them):
- primary_listener, worker_listener  `^/(ip4|ip6)/[^/]+/udp/[0-9]+/quic-v1$` (unchanged)
- metrics                            `^(off|([0-9]{1,3}\.){3}[0-9]{1,3}:[0-9]{1,5})$` (adds off)
- verbosity                          `^-v{1,5}$` (unchanged)
- docker_image                       `^[A-Za-z0-9._/:@-]+$` plus a `:` (unchanged)
- bootstrap_peers                    `^(none|/[A-Za-z0-9._/-]+)$` (new)
- state_export                       `^(off|unlimited|[1-9][0-9]{0,5})$` (new)
- allow_private_forward_targets      `^(true|false)$` (new)
Anything else: helper dies ("field not editable" / "invalid ..."), server 400
`{"error": "field not editable"}` or `{"error": "invalid value for field"}`.

Server: CONFIG_VALUE_RE table, CONFIG_FIELDS = tuple(CONFIG_VALUE_RE), config_value_ok uses
fullmatch (a trailing newline fails, as in bash) and `[0-9]` (the old metrics regex used
`\d`, which also matches non-ASCII digits).

Results:
- ui/tests/helper_test.sh: 205 checks, 0 failed under /bin/bash 3.2.57 and bash 5.3.15
  (169 before; +14 accepted rows, +19 refused rows, +2 token comparisons, +1 argv check).
- unittest discover -s ui: 126 tests OK (121 before; +5 in ConfigSetTest: parity of
  fields and patterns with the helper source, 14 accepted rows reach the helper unchanged,
  18 refused rows get 400 with no helper call, unknown fields 400, trailing newline refused).
- bash -n (3.2 and 5): helper and test clean. shellcheck -x --severity=error: helper and
  test clean. tools/check-bash32.sh on helper and test: clean. py_compile ui/server.py: ok;
  it also parses with the 3.10 grammar (ast feature_version).
- Mismatch check (scratch copies): 6 deliberate helper/server divergences, each caught
  (helper ones by helper_test and the parity test; server ones by ConfigSetTest).

Follow-up open issues:
- bootstrap_peers can echo file content (not verified by running: docker hung, no local
  binary). From the source: tn-5 parses --bootstrap-peers with a clap 4 value_parser over
  serde_yaml, and clap's error line is `error: invalid value '<value>' for ...`;
  edit-config's set_bootstrap_peers relays that first `error:` line in its error event. So
  a path to a root-only file that is not a peers map would echo the file's first line
  back to the UI caller, and any local user can reach 127.0.0.1:8080. Shipped the pattern
  as specified; a decision is needed: (a) edit-config stops relaying the node's message
  (or strips the quoted value) for bootstrap_peers; (b) the helper accepts only paths the
  UI user could read itself (runuser -u telcoin-ui -- test -r) or a fixed directory; (c)
  accept, since the localhost UI already drives root actions.
- ui/static/index.html gets no inputs for the new fields this round (as instructed). They
  are reachable only through GET /api/config/<t>/set?field=...&value=..., and
  GET /api/config/<t> does not report their current values.
- Sidecars now stale: ui/telcoin-ui-helper.sh.sha256 and ui/server.py.sha256 (run
  tools/gen-checksums.sh with the commit). No version bumps, as instructed.
- The helper and server check shapes only; edit-config.sh does the semantic checks (file
  exists and is readable, at most 64 KiB, the node accepts it, the release has the flag,
  true refused on testnet and mainnet).
