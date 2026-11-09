status: done

Package A4a (issue #60, branch private-alerts). Spec: tasks/spec-alerts-A4a.md; shared: tasks/spec-alerts-shared.md.

## Sections
- [x] O1 OPERATOR.md §4.14 Private alerts (before ## 5. Public RPC): OPERATOR.md:1135-1334
- [x] O2 OPERATOR.md short additions: §1.3 Ports row :161; §2.2 item 4 sentence :249, item 13 sentence :258; §4.1 refresh paragraph + command :555-559; §4.6 pointer :858; §4.7 removal-order sentence :905 and wipe sentence :914; §7.3 row :1825
- [x] R1 README scripts table rows: setup-alerts.sh :32, lib/alerts.sh + lib/tn-heartbeat.sh :34
- [x] R2 README ## Private alerts (every network): :453-500
- [x] R3 README Health Monitoring pointer sentence: :449
- [x] R4 README quick reference ### Scripts line: :1575-1576
- [x] R5 README System Layout rows :266, :275-277, :279, :285; ownership-exception paragraph :290-292; .node-meta ENABLE_ALERTS row :328
- [x] R6 README ## Testnet Add-ons: "Three" -> "Four" :1643 (the count was wrong: health, logs, metrics, VPN), new Metrics shipping bullet :1654, "Private alerts are not one of them" :1660
- [x] R7 README changelog: ### setup-alerts v2.1.0 entry :1779; bullets under update-scripts :1772, lib/common.sh :1823, setup-node :1878, check-node :1924, remove-node :1960 (each ends with "(#60)"; the entries keep their "Full release note" line)
- [x] C1 Re-read code in the checkout, reconcile strings (lib/alerts.sh, setup-node.sh, check-node.sh, remove-node.sh, update-scripts.sh; setup-alerts.sh and lib/tn-heartbeat.sh did not exist yet)
- [x] C2 Checks: heading cross-refs resolve, git diff --check, no adiri / hub address in new text

Extra (beyond the enumerated list, same file): README "What the Setup Script Does", Step 1 bullet (:201) gained "and, on every network, [private alerts](#private-alerts-every-network), which it sets up once the node runs".

## Operator-visible changes
Docs only. OPERATOR.md gains §4.14 Private alerts and pointers in §1.3, §2.2, §4.1, §4.6, §4.7, §7.3. README gains the Private alerts section, the scripts, layout and .node-meta rows, the quick-reference line, the corrected add-on count and the changelog entry and bullets. No section was renumbered.

## Docs notes
Strings the docs quote (V1: compare each with the code):
- setup-alerts menu: `1) Status` .. `7) Exit` (spec §8); prompts `Provider: 1) Uptime Kuma push URL 2) healthchecks.io ping URL 3) JSON webhook [1-3]:`, `URL (input hidden):`, `Add another? [y/N]`, `Interval in seconds [60]:`; post-enable `Set the monitor's heartbeat interval to about <2 x interval> s with 1-2 retries: a node update or a restart you run yourself shows as a short down.`; `--target` warning (spec §8 text).
- CLI: `--json` + exactly one of `--status|--enable|--test|--refresh|--disable`; `--targets-stdin`, `TN_ALERT_TARGETS`, `--target kind=url`; `--interval` (60, 30-3600), `--stall-after` (180, >= interval + 30, <= 86400), `--inactive-after` (900, >= stall, <= 86400), `--label`, `--allow-http`. Non-json forms used in the docs: `--enable` (setup-node runs it) and `--refresh` (the updater prints it) only. `done` fields and `applied` values per spec §8. Exit 0/1/2/3 per spec §8.
- lib/alerts.sh (as in the checkout): the --http refusal; `No target accepted the test heartbeat; private alerts were not enabled. Check the URLs and run this again.`; `No target accepted the test heartbeat; the previous targets were put back.`; `Private alerts are off; nothing to refresh.`; `Pause or delete this node's monitor: a push monitor alerts on silence.`; `last run Ns ago: up, ...`; `last run not checked (run with sudo)`; test lines `Target N kind@host: accepted (200)` / `failed (000 timeout)`; systemd 247 floor.
- setup-node (as in the checkout): `Set up private alerts once the node is running?`; `The node is not running yet, so private alerts stay pending. Once it runs: sudo bash setup-alerts.sh`; summary `Private alerts: on` / `Private alerts: pending. To finish: sudo bash setup-alerts.sh`.
- update-scripts (as in the checkout): `The heartbeat runner or its library changed. Reinstall them on the host:` + `  sudo bash <dir>/setup-alerts.sh --refresh`.
- Runner (spec §5, not yet in the checkout): every down reason of the probe table, the up message forms (`CvvActive block 1234567 epoch 42`, `rpc answering`, `service telcoin restarting (activating, 30s)`, `starting: rpc not answering yet`, ` (health <code>)` suffix), the log line forms (`up: ... | 1 kuma@... ok 200, ...`, `status up -> down: <reason>`, `every target failed`, `config: ...`), push why codes, the webhook body, user agent `tn-heartbeat/<version>`, exit 0/1/2.
- Paths: `/usr/local/libexec/telcoin/tn-heartbeat`, `/etc/systemd/system/telcoin-heartbeat.{service,timer}`, `/etc/telcoin/alerts/{targets,alerts.env}`, `/var/lib/private/telcoin-heartbeat/state`, `ENABLE_ALERTS=true|pending|false`.

## Tests run
- `git diff --check OPERATOR.md README.md`: clean.
- Anchor check (python over the added lines of both files): every link resolves (`#private-alerts-every-network`, `#testnet-add-ons`, `OPERATOR.md#414-private-alerts`, `OPERATOR.md#73-other-scripts`, `CHANGELOG/scripts-v2.1.0.md`).
- Every "section N.N" in the added OPERATOR lines (1.3, 2.2, 4.1, 4.2, 4.3, 4.6, 4.7, 4.11, 4.13, 4.14) matches a `### N.N` heading.
- Added table rows: column counts consistent per table; no unescaped `|` inside a code span.
- Added lines scanned for `adiri`, `104.155`, `10.100.` and em-dashes: one `adiri` (the pre-existing "Adiri testnet" on README :201, a line extended, not new text) and one em-dash (the changelog heading the spec pins).

## Open issues
1. setup-alerts.sh and lib/tn-heartbeat.sh were not in the checkout when this finished. Everything the docs say about the menu, prompts, `done` fields, exit codes, probe reasons, log lines, why codes and the webhook body comes from the shared spec §5 and §8; V1 should compare once A1a and A2 land. Not pinned by the spec, so the docs avoid them: whether `--test`, `--status` and `--disable` work without `--json`, and the text of the `--allow-http` warning.
2. setup-node.sh `prompt_alerts` (A3a) says "Each heartbeat says up or down, the reason, the node mode, block and epoch, and this host's label; nothing else." Under spec §5 only the webhook body carries the label (Kuma gets status, msg and ping; healthchecks gets `<status>: <message>`), and a Kuma push also carries the RPC response time. The docs follow §5. Suggested text for A3a: "Each heartbeat says up or down with the reason (node mode, block and epoch); a webhook also gets this host's label and the network. Nothing else is sent."
3. The code differs from the shared spec in three places, and the docs follow the code: the setup-node summary reads `Private alerts: pending. To finish: sudo bash setup-alerts.sh` (spec §9: `pending: sudo bash setup-alerts.sh`); `alerts_status` counts more issues than spec §7 lists (no run recorded, targets file missing or not regular, runner missing, alerts.env missing or out of step with the node's service or RPC); the test result lines are `Target N kind@host: accepted (code)` / `failed (code why)`.
4. The README Testnet Add-ons intro said "Three" with three bullets, but four add-ons exist (docs/testnet-addons.md says four). It is now "Four", with a Metrics shipping bullet.

## Verifier fixes (F-C)
status: done. Findings from tasks/ckpt-alerts-V1d.md owned by A4a, plus the section 13 decisions of tasks/spec-alerts-shared.md (B1-B4).
- [x] W-O1 OPERATOR derived stall/inactive defaults (table + options sentence)
- [x] W-O2 OPERATOR provider prompt lines
- [x] W-O3 OPERATOR runner log lines
- [x] W-O4 OPERATOR 7.3 done fields
- [x] W-O5 OPERATOR runner version, not file
- [x] W-R1 README derived defaults (table + paragraph)
- [x] W-R2 README runner version (:500, :1926)
- [x] N-O1 OPERATOR flags on an enabled node (rewritten: applied, alerts:refreshed): new lead-in "Change the interval, the thresholds or the label." after the refresh paragraph
- [x] N-O2 OPERATOR refresh --label
- [x] N-O3 OPERATOR quiet off line
- [x] N-O4 OPERATOR 120 s in that state
- [x] N-O5 OPERATOR consensus header unreadable
- [x] N-O6 OPERATOR (health timeout)
- [x] N-O7 OPERATOR changed on first run
- [x] N-O8 OPERATOR command line the scripts run
- [x] N-O9 OPERATOR test exit 0/1
- [x] N-O10 OPERATOR plain --test / --disable examples
- [x] N-R1 README 120 s in that state
- [x] N-R2 README changed on first run
- [x] N-R3 README command line the scripts run
- [x] N-R4 README flags on an enabled node (rewritten) + refresh --label
- [x] N-R5 README status line before the run line
- [x] B1 failed fresh enable leaves .node-meta as it was (OPERATOR 4.14 + 7.3, README section + changelog)
- [x] B2 thresholds/label on an enabled node (OPERATOR 4.14 + 7.3, README section + changelog)
- [x] B3 status without root: unknown (run with sudo), enabled null, timer is-enabled (OPERATOR and README)
- [x] B4 healthchecks `#` refused like `?` (OPERATOR and README)
- [x] C checks: anchors, section refs, git diff --check, em-dash/adiri scan (links and `section N.N` on added lines resolve; edited table rows keep their column counts; diff --check clean; no new em-dash; the one `adiri` hit is the pre-existing README:201 line)

Where (final line numbers): OPERATOR.md 1153, 1156-1157, 1162, 1173, 1182, 1192, 1218-1220, 1235, 1238, 1260-1268, 1282, 1286-1296 (new lead-in "Change the interval, the thresholds or the label."), 1303 (plain --disable), 1332-1335, 1347-1348, 1843 (7.3 row). README.md 472, 474-475, 483-484, 486, 488, 500, 1797-1801 (setup-alerts changelog bullet), 1929.

## Unconfirmed
Code read at the end of the round (lib/alerts.sh 17:04, lib/tn-heartbeat.sh 17:00, setup-alerts.sh 16:16, still the pre-fix copy):
- Landed and matching: the failed fresh enable leaves .node-meta as it was (`_alerts_enable_undo` keep-meta + meta_unset, lib/alerts.sh:700-727); `alerts_refresh [FN] [INTERVAL STALL INACTIVE]` replaces only the given values (lib/alerts.sh:952-1030) and `alerts_enable` on an enabled node runs targets then refresh, ALERTS_APPLIED "targets-changed refreshed" (lib/alerts.sh:803-829); `Private alerts: unknown (run with sudo)` with `systemctl is-enabled` (lib/alerts.sh:1131-1162); healthchecks `#` refused (lib/tn-heartbeat.sh:177).
- Not landed yet, documented as decided: setup-alerts.sh still warns `... are not applied; to change them, run --disable and then --enable.` (:648) and refuses `--interval`/`--stall-after`/`--inactive-after` with `--refresh` (:985-986), so `--refresh --interval 120` (OPERATOR:1290, README:488) and the four flags with `--refresh` in the 7.3 row are unconfirmed.
- Not landed: `"enabled":null` in the `--status` JSON (sa_do_status still prints `"${ALERTS_ST_ENABLED:-false}"` as a string), OPERATOR 7.3 row and README:500.
- Not landed: `applied` holding two items (`sa_finish` takes one item; the done of an enable with targets and flags lists `alerts:targets-changed` then `alerts:refreshed` per section 13).
- Assumed from "derived defaults apply only when the interval is explicit and the other two are not": an `--interval` given alone on an enabled node also sets stall and inactive from it (OPERATOR:1293 "360 and 900 seconds for an interval of 120", README:488). The docs say nothing about `--interval` with only one of the two thresholds.
- The new lib path returns 2 (exit 3) when targets changed but the refresh of the new settings failed (lib/alerts.sh:824-826); the docs only say the new values apply once a target accepted the test.
