# Package A4b: release note, docs/testnet-addons.md, followup.md, partner guide (Markdown and metadata)

Read `tasks/spec-alerts-shared.md` first (all of it). Checkpoint: `tasks/ckpt-alerts-A4b.md`.
Scratch: the shared scratchpad path `/A4b/`.

## Files you own

- `CHANGELOG/scripts-v2.1.0.md`
- `docs/testnet-addons.md`
- `followup.md`
- `docs/partner/mno-node-guide/mno-node-guide.md`
- `docs/partner/mno-node-guide/metadata.yaml` (`version: "1.7"`; `date` stays `November 2026`)

Do NOT build or commit the PDF (the orchestrator builds it in the container in W5). Do not
touch `docs/partner/technical-specification/`.

## CHANGELOG/scripts-v2.1.0.md

- Intro: one sentence on private alerts; "It closes #47" -> "It closes #47 and #60".
- Component table: rows `setup-alerts | 2.1.0 (new)`, `lib/alerts (ALERTS_VERSION) | 2.1.0
  (new)`, `lib/tn-heartbeat (HEARTBEAT_VERSION) | 2.1.0 (new)`.
- `### Private alerts (#60)` after `### Host baseline (#43)` (:260-281): the design in the
  note's voice (what the runner checks, the reasons, the three providers, the files, the
  DynamicUser sandbox, no restart, lock + baseline, `check-node`, `remove-node`, the updater
  hint, the `--json` forms and exit codes).
- One-line bullets in the setup-node (:87), check-node (:133), update-scripts (:148),
  remove-node (:237) and lib/common (:251) subsections.
- `## New files, units and keys`: rows for the runner, both units, `targets`, `alerts.env`, the
  state dir, `ENABLE_ALERTS`.
- `## Before you update`: an item (opt-in; nothing happens unless you enable it).
- `## Refusals and warnings you may now see`: the strings of the shared spec (the `--http`
  refusal, "No target accepted the test heartbeat …", the `--target` argv warning, the
  `--allow-http` warning, "Pause or delete this node's monitor …").
- `## Left open`: the UI card, retiring the pull monitor, the maintenance marker.

## docs/testnet-addons.md

- A sentence under the add-ons table (not a row): private alerts are not a testnet add-on;
  link to OPERATOR §4.14.
- Mainnet bullet (:29-58): the alerts work there too.
- Health monitoring (:296): an opening paragraph that the push heartbeat is the way forward and
  alerts the operator, not the Association.
- Removing (:549): a sentence that `remove-node.sh` removes the alerts before the node stops.

## followup.md

- `## UI` (:278): the alerts card (fed by `setup-alerts.sh --json --status`; targets only on
  the helper's stdin, never argv).
- `## Add-ons` (:194): retire the pull monitor once the Association's Kuma takes pushes; a
  maintenance marker under `/run/telcoin` (bounded, root 0644) written by update-node,
  edit-config, setup-observability, install-caddy, `prepare-stake.sh --rotate-address` and the
  chain-data wipe before their own stop, which the runner reports as `up maintenance: …`
  (pausing the timer would not help: a push monitor alerts on silence); reword the #1696 item
  (:267-276) to concern the Association monitor's bind form only.
- `### setup-node` (:381): the re-run overwrite of live `ENABLE_*` values (pre-existing for VPN
  and observability; alerts reads its value back).
- `### update-node` (:445): the first-match `"number"` in the python-less fallback at
  update-node.sh:1144 can read a nested `latest_execution_block.number`.

## Partner guide

- New `### Private alerts` between the end of `### Testnet add-ons` (:1036) and `### Key
  lifecycle` (:1037): operator prose only; absolute GitHub URLs
  (`https://github.com/Telcoin-Association/tn-node-deployment/blob/main/…`); contact only
  `devs@telcoin.org`; none of the forbidden words (`--observer`, `migrate-node-naming`,
  `setup-observer.sh`, `setup-validator.sh`, "legacy", personal addresses, repo-relative
  links); cross-references as heading links that exist.
- Sentences at :36 (the Day-2 summary line), :178 (the ports table note: alerts need no inbound
  port), :285 and :294 (the setup walk-through items 4 and 13), :1087 (removal), and a row at
  :1593 (`### Other scripts`).
- `metadata.yaml`: `version: "1.7"`.
- Check your Markdown with `docker run --rm -u "$(id -u):$(id -g)" -e HOME=/tmp -v "$PWD:/w" -w /w tn-pdf-tools bash tools/build-partner-pdf.sh --html-only mno-node-guide`
  (it runs the forbidden-word, contact and heading-link checks); fix anything it reports.
