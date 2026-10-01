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

`OPERATOR.md` at the repo root is the operator runbook; `README.md` is the reference.
`docs/partner/mno-node-guide.md` is the partner guide for mobile network operators, the
source of the branded PDF beside it. When a change alters operator-visible behaviour
(flags, prompts, paths, ports), update `OPERATOR.md`, the README and the partner guide
together, then rebuild the PDF (see "Partner guide (MNO PDF)" below).

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

## Node role

The node binary has no `--observer` flag any more. It was removed upstream in
telcoin-network: v0.15.0-adiri accepts it as a hidden no-op and later releases reject it.
Role is derived each epoch from committee membership. Scripts decide the validator view
from the on-chain stake status (`getValidator` status Staked / PendingActivation / Active /
PendingExit) via `node_stake_status` / `node_is_staked_validator` in `lib/common.sh`.
Never add `--observer` / `--validator` behaviour back, and never emit `--observer` to the
binary. `update-node.sh` strips a leftover `--observer` from legacy launch files when
updating to v0.15.0-adiri or later.

## Partner guide (MNO PDF)

`docs/partner/mno-node-guide.pdf` is the guide the Association hands to prospective mobile
network operators. It is generated, never edited by hand. The source is
`docs/partner/mno-node-guide.md`; the look comes from `docs/partner/template.html`,
`docs/partner/theme.css` and the vendored logos and fonts under `docs/partner/assets/`;
the version, date and subtitle live in `docs/partner/metadata.yaml`.

- Rebuild with `bash tools/build-partner-pdf.sh` after changing the Markdown,
  `metadata.yaml`, `template.html`, `theme.css` or anything under `assets/`. Preview the
  HTML without WeasyPrint using `--html-only --open`.
- Bump `version` and `date` in `metadata.yaml` with every content change. The build warns
  when the Markdown changed and the metadata did not.
- The document title is the single `#` heading in the Markdown. Do not add a `title:` key
  to `metadata.yaml`, and keep no prose between the `#` heading and the first `##`.
- Partner readers never see legacy installs. The guide carries no `--observer`,
  `migrate-node-naming`, `setup-observer.sh` or `setup-validator.sh` material and no
  "legacy" wording, and its only contact is `support@telcoin.org`. The build script refuses
  the source otherwise.
- Links to other files in this repo are absolute URLs under
  `https://github.com/Telcoin-Association/tn-node-deployment/blob/main/`, because the PDF
  has no repo around it. Cross-references inside the guide are heading links such as
  `[Back up the keys now](#back-up-the-keys-now)`. Headings and prose carry no manual
  numbers; pandoc numbers the chapters at build time.
- Commit the PDF together with the sources that produced it. If only the toolchain changed
  (a pandoc or WeasyPrint upgrade), the script keeps the committed PDF and says so; pass
  `--force` to overwrite it deliberately.
- Reference toolchain: pandoc 3.11 and WeasyPrint 70.0 from Homebrew (`brew install pandoc
  weasyprint`). The script checks for pandoc 3.8+ and WeasyPrint 61+. Same inputs and same
  toolchain give byte-identical output; a second run prints "PDF unchanged".
- Nothing under `docs/partner/` or `tools/` is updater-tracked or carries a `.sha256`
  sidecar. The fonts are Geist and Geist Mono under the SIL Open Font License 1.1; keep
  `OFL.txt` beside them and record provenance in `docs/partner/assets/README.md`.

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
The same holds for the other docs: `OPERATOR.md`, `followup.md`, `CHANGELOG.md`,
`README.md`, `docs/` (the partner guide and its build inputs included) and `tools/` are
documentation or maintainer tooling, carry no `.sha256` sidecar, and must never be added
to the updater arrays. `README.md` must stay at the repo root, because
`update-scripts.sh` HEAD-probes it as its connectivity check.
