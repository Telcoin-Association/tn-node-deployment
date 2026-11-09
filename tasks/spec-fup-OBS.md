# OBS: ingest token off the environment, explicit TLS, rotation (issues #35, #43)

Read `tasks/spec-fup-shared.md` first. Worktree `~/coding/telcoin/tnd-fup-OBS`, branch
`fup/OBS`, checkpoint `tasks/ckpt-fup-OBS.md`.

## Goal

The hub ingest token lives in one root-owned file that only Alloy can read, never in argv,
the unit text, the container's environment or `docker inspect`; the push endpoints pin TLS
1.3 and the hub's server name; an operator can rotate the token in place; remove-node
shreds it.

## Owned files

`lib/observability.sh`, `setup-observability.sh`, `observability/config.alloy` (vendored; see
the upstream step), `remove-node.sh` (one shred call in the observability teardown; KEYS and
AUDIT touch the same file elsewhere: add, do not reflow), tests `tools/tests/obs_test.sh`,
`tools/tests/remove_test.sh` (append a `# OBS` block at the end; KEYS appends its own).

## Facts (main 1187ddb)

- lib/observability.sh: `obs_write_config_alloy` :231 renders the config from
  `observability/config.alloy` beside the scripts or, when absent, `_obs_alloy_fallback` :327
  (embedded copy; `bearer_token = sys.env("OBS_INGEST_TOKEN")` :379 and :431);
  `_obs_write_env_file DEST TOKEN` :443 writes `TN_NODE… OBS_PUSH_URL OBS_INGEST_TOKEN=…` (and
  the metrics lines) with umask 077 into `${OBS_ETC_DIR}/telcoin-alloy.env`;
  `obs_write_alloy_native_unit TOKEN` :689 → `obs_alloy_unit_text BIN ENVF GRP DD` (the unit
  has `EnvironmentFile=`, `InaccessiblePaths` at :640 naming the stale `/etc/credstore.encrypted`
  with `-` prefixes); `obs_run_alloy_docker TOKEN LOGDIR` :716 renders a unit whose ExecStart
  is `docker run --rm --name telcoin-alloy … --env-file ${envf} -v …config.alloy:ro -v logs:ro
  -v ${OBS_DATA_DIR}:${OBS_DATA_DIR} …` (hardening flags: `--cap-drop=ALL`, read-only,
  image user 473:473 per the comment above it); `obs_existing_token` :1322 reads the env line.
  `OBS_ETC_DIR` is `/etc/telcoin/alloy`; the service group is `telcoin-alloy` (grep
  `create_service_user`/`telcoin-alloy` for how the native unit's user and the `telcoin-log`
  group are set).
- setup-observability.sh: tokens arrive via `--token-stdin` (one line of stdin), `--token`,
  `TN_OBS_TOKEN`, else the stored one (:582-609); `main_menu` :638; `--json` :380+.
- observability/config.alloy: logs endpoint :75-77, metrics endpoint :138-140, both
  `bearer_token = sys.env("OBS_INGEST_TOKEN")`. Vendored from the deploy-networks-common
  repository (`git@github.com:Telcoin-Association/deploy-networks-common.git`), checked out as
  the submodule `~/coding/telcoin/adiri-genesis/common` (today on branch `wgvpn-sudoers-guard`
  9b2c8f2; `origin/main` is dc57dfe after a fetch). The sync note in docs/testnet-addons.md
  :540+ says: everything from the first `local.file_match` to EOF must be byte-identical to
  upstream; the header differs by design; the note records `sha256(observability/config.alloy)`
  (:45 of the section) and DOCS updates it from your notes.
- Hub hosts (lib/testnet-addons.env): `obs.adiri.telcoin.network` for both push URLs on
  testnet; devnet URLs are empty variables. The `server_name` must come from the effective
  push URL's host at render time (`obs_effective_push_url`), never a literal in the vendored
  blocks, so the same config serves every network: put the `tls_config` block in the
  vendored file with `server_name = sys.env("OBS_PUSH_HOST")` (and the metrics twin) and set
  that variable in the env file from the URL's host; `min_version = "TLS13"`.
- Alloy `loki.write` / `prometheus.remote_write` endpoints accept `bearer_token_file`
  (a path) and a `tls_config { server_name, min_version }` block (Alloy 1.5.1). Systemd
  `LoadCredential=ingest-token:/etc/telcoin/alloy/ingest-token` exposes it at
  `$CREDENTIALS_DIRECTORY/ingest-token` to the service; Alloy's `sys.env()` reads
  `CREDENTIALS_DIRECTORY`.
- remove-node.sh: `_rm_shred FILE…` :375 (shred + rm); the observability teardown already
  removes `${OBS_ETC_DIR}` (grep `alloy` in remove-node.sh and `obs_disable`).

## Required behaviour

1. Token file `/etc/telcoin/alloy/ingest-token`, root:telcoin-alloy 0640, one line, written
   with `tn_write_root_file` from the token value (never through a pipe, never in argv:
   the writers take the value in a variable as today). `_obs_write_env_file` stops writing
   `OBS_INGEST_TOKEN=`; it writes `OBS_PUSH_HOST=<host of the logs push URL>` and
   `OBS_METRICS_PUSH_HOST=<host of the metrics URL>`.
2. Native unit: `LoadCredential=ingest-token:/etc/telcoin/alloy/ingest-token`; `LimitCORE=0`;
   `InaccessiblePaths` names `/etc/telcoin/bls-passphrase.cred` instead of
   `/etc/credstore.encrypted` (keep the `-` prefix so a missing path is not an error).
   Config: `bearer_token_file = sys.env("CREDENTIALS_DIRECTORY") + "/ingest-token"` in both
   endpoints, plus `tls_config { server_name = sys.env("OBS_PUSH_HOST"), min_version = "TLS13" }`
   (metrics: `OBS_METRICS_PUSH_HOST`). Check the exact Alloy syntax against the Alloy 1.5
   reference (`loki.write` endpoint block: `bearer_token_file`, `tls_config`; string concat
   with `+` is River syntax) and note the reference in the checkpoint.
3. Docker sidecar: bind-mount the token file read-only at a fixed container path
   (`/run/credentials/telcoin-alloy/ingest-token`), pass `--group-add <gid of telcoin-alloy>`
   so the image's user 473 can read a 0640 root:telcoin-alloy file, and set
   `CREDENTIALS_DIRECTORY=/run/credentials/telcoin-alloy` in the env file for the Docker
   runtime only, so one config serves both. `LimitCORE=0` on the sidecar unit too. If the
   image's user cannot read the mount in a real run (test with the real image under
   `docker` on this box if available, else reason from the uid/gid and say so), fall back to
   `--mount type=bind,…,readonly` plus `--user 473:<gid>` and record why.
4. Migration: when the old env file holds `OBS_INGEST_TOKEN=`, `obs_enable` and the new
   `--rotate-token` move the value into the token file, rewrite the env file without it,
   and say so once. `obs_existing_token` reads the token file first, then the legacy env line.
5. `setup-observability.sh --rotate-token` (`--token-stdin` / `--token` / `TN_OBS_TOKEN` as
   for enable; a menu entry; `--json --rotate-token` with a `done` event): writes the token
   file, restarts Alloy (native or sidecar), checks it stays active for a few seconds and
   reports; a failed restart puts the previous token file back and restarts again
   (rollback), rc 1. No node restart, so no guard or epoch wait.
6. `obs_disable` / remove-node: `_rm_shred` the token file; `obs_status` reports "token
   file present (0640 root:telcoin-alloy)" without the value; the token never appears in
   `systemctl show`, `docker inspect` output (no `-e`, no env-file line for it) or any log.
7. Upstream first: in `~/coding/telcoin/adiri-genesis/common`, `git fetch origin && git
   checkout -b alloy-token-file-tls origin/main`, edit
   `observability/node-agent/config.alloy` (the two endpoint blocks only: `bearer_token_file`,
   `tls_config`, and the header comment lines that describe the environment variables), commit
   on that branch with a behaviour message, DO NOT PUSH (the orchestrator opens the PR). Then
   vendor: copy the functional part (from `local.file_match` to EOF) over
   `observability/config.alloy` so the sync-note diff is empty, update the vendored header
   (environment variable list, "upstream branch alloy-token-file-tls <sha>, pending merge"),
   and update `_obs_alloy_fallback` to the same blocks. Record the upstream commit sha and
   the new `sha256sum observability/config.alloy` in the checkpoint for DOCS.

## Tests

`obs_test.sh` (170 checks today; keep every existing one green): token file mode/owner and
content from a stubbed `tn_write_root_file`/`install`; env file has no `OBS_INGEST_TOKEN`
and has the two host variables; native unit text contains `LoadCredential=`, `LimitCORE=0`,
the `.cred` path and not `credstore.encrypted`; `systemd-analyze verify` on the rendered
unit (host has systemd; SKIP under `bash:3.2`); the Docker ExecStart has the mount,
`--group-add`, no `OBS_INGEST_TOKEN`; rendered config has `bearer_token_file` and
`tls_config` with `TLS13` in both pipelines; legacy env migration; `obs_existing_token`
order; `--rotate-token` interactive, `--json` and rollback paths with a stubbed `systemctl`
(is-active sequences); the vendored functional blocks equal the upstream branch file
(the sync-note diff, with the upstream path from an env var so the test SKIPs when the
checkout is absent). `remove_test.sh`: the token file is shredded. Run under bash 5.3,
`bash:3.2`, `ubuntu:24.04`; `bash -n`; `check-bash32`; shellcheck 0.9 + 0.11;
`root_write_pipe_test.sh`; `passphrase_print_test.sh`.

## Docs notes to hand over

File paths and modes, the env variables now and before, the migration message, the
`--rotate-token` usage (stdin form), what `obs_status` shows, the TLS pin, the new
`sha256(observability/config.alloy)` line and the upstream sha for the sync note, and the
"per-node tokens on the hub" remainder of #35.
