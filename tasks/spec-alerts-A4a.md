# Package A4a: OPERATOR.md and README.md

Read `tasks/spec-alerts-shared.md` first (all of it: you document the contract). Checkpoint:
`tasks/ckpt-alerts-A4a.md`. Scratch: the shared scratchpad path `/A4a/`.

## Files you own

- `OPERATOR.md`
- `README.md`

The code is being written in parallel; write from the shared spec, and name only what it pins
(flags, paths, messages, fields, exit codes). V1 checks docs against code afterwards.

## OPERATOR.md

- New **§4.14 Private alerts** before `## 5. Public RPC` (:1125). Do not renumber anything
  (about 26 cross-references point at the existing numbers). Contents: what it does and that it
  is not a testnet add-on (every network, the Association not involved); the probe table (check,
  down reason, default threshold); what leaves the host (status, reason, mode, block, epoch, the
  host label; nothing else; URLs stay in a root 0600 file); targets per provider with an
  example URL each (Kuma: paste the push URL from the monitor's page; the query part is dropped;
  healthchecks.io: the ping URL; webhook: the exact JSON body); enable (menu, during setup, the
  stdin form `printf 'kuma https://…\n' | sudo bash setup-alerts.sh --json --enable
  --targets-stdin`), test, change targets, refresh after `update-scripts.sh`, disable (pause the
  monitor first); what an update or a restart you run yourself looks like (a short down; set
  the monitor's heartbeat interval to about twice the push interval with 1-2 retries); the
  files table (runner, two units, `targets`, `alerts.env`, the state dir
  `/var/lib/private/telcoin-heartbeat`, `ENABLE_ALERTS` in `.node-meta`); lock and baseline,
  never a node restart; what check-node reports; troubleshooting (`systemctl status
  telcoin-heartbeat.timer`, `journalctl -u telcoin-heartbeat -n 20`, the state file as root).
- Short additions: §1.3 Ports (:148: no inbound port; outbound HTTPS to the monitor), §2.2
  Run setup items 4 and 13 (:233-263: a sentence each, not new items), §4.6 a pointer after the
  add-ons (:850 area: "For alerts that reach you, on every network, see §4.14"), §4.7 Remove
  (:880: the alerts are removed before the node stops; pause the monitor), §4.13 (:1076: a
  refresh bullet is not needed there; instead §4.1 Keep the scripts current gets the
  `setup-alerts.sh --refresh` sentence), §7.3 Other scripts (:1602: a row with the `--json`
  forms and exit codes).

## README.md

- Scripts table: a row for `setup-alerts.sh` after `setup-vpn.sh` (:30 area) and a lib row for
  `lib/alerts.sh` + `lib/tn-heartbeat.sh`.
- New `## Private alerts (every network)` between the Health Monitoring section's end (:436)
  and `## Validator Onboarding Flow` (:438): shorter than OPERATOR §4.14, same facts.
- Health Monitoring (:423): one sentence that the push add-on is the way forward and works on
  every network.
- Quick reference `### Scripts` (:1494): a line for setup-alerts.
- System Layout (~:256) rows for the runner, units, `/etc/telcoin/alerts/`, the state dir; the
  `.node-meta` table (~:311) a row for `ENABLE_ALERTS`.
- `## Testnet Add-ons` (:1574): "Three optional" -> "Four" only if the count is wrong today
  (check: health, logs, metrics, VPN); add a sentence that private alerts are not one of them.
- Changelog: `### setup-alerts v2.1.0 — private alerts on every network (new)` right below the
  update-scripts v2.1.0 entry (:1683-1699), and one bullet each under setup-node (:1760),
  check-node (:1804), remove-node (:1836), update-scripts (:1683) and lib/common (:1700), each
  ending with the release-note link the neighbouring bullets use.

Keep the voice of each file. No em-dashes in new prose (the files use them in existing
headings; leave those).
