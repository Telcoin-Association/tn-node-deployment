# AGENTS.md

Orientation for AI agents and human maintainers working in this repository. This
file is documentation only. It is not shipped to nodes and is not tracked by the
updater, so it has no `.sha256` sidecar and must not be added to `update-scripts.sh`.

## What this repo is

`tn-node-deployment` is the **public, standalone operator repo**
(`github.com/Telcoin-Association/tn-node-deployment`). Node operators clone it and
run it **alone**. They do not have the maintainer's `devnet-genesis/` checkout or
its `common/` submodule.

That `common/` submodule — `config-caddy.sh`, `dns.sh`, `ops-agent-install.sh`, the
WireGuard hub, the observability backend, the GCP plumbing — is **maintainer-only**
and is **never shipped to operators**. None of it exists on an operator box. Assume
any path under `common/` or `devnet-genesis/` is absent at runtime for a real operator.

## The boundary rule

Operator-facing scripts must **not** depend on any `common/` script at runtime. That
covers:

`setup-node.sh`, `migrate-node-naming.sh`, `check-node.sh`, `update-node.sh`,
`update-scripts.sh`, `firewall-setup.sh`, `setup-vpn.sh`, `setup-observability.sh`,
`install-caddy.sh`, `remove-node.sh`, and everything under `lib/` and `ui/`.

A comment in one of these may *mention* a `common/` script for provenance, but only
if it is clearly marked maintainer-only. A runtime call, a `source`, or a "now run X"
instruction that points at `common/` is a bug: the operator does not have that file.

**Future agents — do NOT "fix" a `config-caddy.sh` comment by adding an operator
dependency on it.** On an operator box the public RPC proxy is repointed with
`install-caddy.sh` (in this repo). The maintainer fleet path
(`devnet-genesis/tasks/migrate-fleet-staggered.sh` → `common/config-caddy.sh`)
already works and is out of scope for this repo. Leave those as provenance comments.

## Vendored files

Some files are **vendored from `adiri-genesis`** and kept in sync by hand:

- `lib/wgvpn/*` — the WireGuard node bootstrap and hub coordinates
- `observability/config.alloy`
- the maintainer SSH public keys under `lib/wgvpn/peers/ssh/`

Before editing any of these, read the **"Sync note (vendored files)"** section in
`docs/testnet-addons.md`. It records what each file mirrors upstream, which parts must
stay byte-identical, and how to re-vendor without drifting.

## Self-update and integrity contract

Operators stay current with `update-scripts.sh`, which fetches each tracked file from
`raw.githubusercontent.com/Telcoin-Association/tn-node-deployment/main` and verifies it
against a committed `<file>.sha256` sidecar before installing it.

- The set of tracked files is the `SCRIPTS`, `UI_BUNDLE`, and `TESTNET_ADDONS_BUNDLE`
  arrays in `update-scripts.sh`. That is the single source of truth for what operators
  receive.
- `tools/gen-checksums.sh` regenerates every sidecar from those three arrays, so the
  sidecars can never name a different set than the updater downloads.
- `.github/workflows/ci.yml` fails the build on any stale or missing sidecar, and on
  any bash-4 syntax — it parse-checks every `*.sh` under macOS `/bin/bash`, which is
  3.2, because operators can run on macOS.

So after you edit any tracked file:

1. Bump its version constant (`SCRIPT_VERSION`, `COMMON_VERSION`, `UI_VERSION`, etc.)
   so `update-scripts.sh` offers the change to operators.
2. Run `bash tools/gen-checksums.sh` and commit the refreshed `*.sha256` sidecars.
3. Keep it bash 3.2 / Ubuntu safe: indexed arrays only — no `declare -A`, no
   `${var,,}`, no `mapfile`/`readarray`, no `&>>`.

`AGENTS.md` itself is intentionally untracked (docs are not shipped to nodes), so it
has no sidecar and is absent from the updater arrays. Keep it that way.
