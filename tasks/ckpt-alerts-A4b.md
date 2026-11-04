status: done

Package A4b (issue #60, branch private-alerts). Spec: tasks/spec-alerts-A4b.md; shared: tasks/spec-alerts-shared.md.

## Sections
- [x] 1. CHANGELOG/scripts-v2.1.0.md: intro, component rows, `### Private alerts (#60)`, subsection bullets, new-files rows, Before you update, Refusals and warnings, Left open
- [x] 2. docs/testnet-addons.md: sentence under the add-ons table, mainnet bullet, Health monitoring opening, Removing sentence
- [x] 3. followup.md: UI card, retire the pull monitor, maintenance marker, #1696 reword, setup-node re-run overwrite, update-node first-match number
- [x] 4. Partner guide: `### Private alerts`, sentences at Day-2 summary, ports note, walk-through items 4 and 13, removal, Other scripts row; metadata.yaml 1.7
- [x] 5. HTML-only build check of the guide
- [x] 6. Re-read lib/alerts.sh, lib/tn-heartbeat.sh, setup-alerts.sh (if present) and adjust strings; git diff --check

## Operator-visible changes
None (docs only). Files: CHANGELOG/scripts-v2.1.0.md, docs/testnet-addons.md, followup.md,
docs/partner/mno-node-guide/mno-node-guide.md, docs/partner/mno-node-guide/metadata.yaml (1.6 -> 1.7,
date unchanged "November 2026").

## Docs notes
- Release note: intro sentence + "It closes #47 and #60" (:11-16); component rows setup-alerts,
  lib/alerts, lib/tn-heartbeat (:23, :29-30); bullets in setup-node (:105), check-node (:153),
  update-scripts (:172), remove-node (:260), lib/common sentence (:270); Host baseline now says
  "the four add-ons and setup-alerts" (:291-293); `### Private alerts (#60)` (:296-389); new-files
  rows (:442-447); env var row `TN_ALERT_TARGETS` (:456); Before you update item 7 (:474-476);
  six Refusals rows (:494-499); Left open #60 (:522-524).
- docs/testnet-addons.md: sentence under the table (:15-18), mainnet bullet (:61-62), Health
  monitoring opening paragraph (:304-309), Removing paragraph (:581-585). Links
  `../OPERATOR.md#414-private-alerts` (heading `### 4.14 Private alerts` exists in OPERATOR.md).
- followup.md: #1696 item reworded to the Association monitor's bind form, plus "retire the pull
  monitor" and "maintenance marker" items (Add-ons, :268-291); UI card (:295-298); setup-node
  re-run overwrite (:423-427); update-node `_uc_header_number` first-match number (:506-511).
- Guide: Day-2 summary (:36), ports note (:189-191), walk-through items 4 (:288) and 13 (:297),
  `### Private alerts` (:1040-1106), removal sentence (:1159), Other scripts row (:1677). Links to
  README `#private-alerts-every-network` (heading `## Private alerts (every network)` exists).
- Strings taken from the code already in the checkout: setup-node summary
  `Private alerts: pending. To finish: sudo bash setup-alerts.sh` (the shared spec said
  `pending: sudo bash setup-alerts.sh`); remove-node's reason for removing before the stop ("so the
  heartbeat does not push the stop as a failure"); update-scripts hint text matches the spec.

## Tests run
- `docker run --rm -u "$(id -u):$(id -g)" -e HOME=/tmp -v "$PWD:/w" -w /w tn-pdf-tools bash tools/build-partner-pdf.sh --html-only mno-node-guide`:
  rc 0, no warnings after the webhook JSON was wrapped (a first run warned about a 173-character
  code line). Forbidden-word, contact and heading-link checks pass. PDF not built.
- `git diff --check` on the five files: clean. Added lines hold no em-dash, "legacy",
  `--observer`, `migrate-node-naming`, `setup-observer.sh`, `setup-validator.sh`, other contact or
  attribution trailer.

## Open issues
- lib/alerts.sh, lib/tn-heartbeat.sh and setup-alerts.sh did not exist in the checkout when this
  package finished, so every string from them is as the shared spec pins it and is unconfirmed:
  the `--http` refusal, "No target accepted the test heartbeat; private alerts were not enabled.
  Check the URLs and run this again." / "...; the previous targets were put back.", the `--target`
  argv warning, `http needs --allow-http (the token travels in clear text)`, "Pause or delete this
  node's monitor: a push monitor alerts on silence.", the menu labels (`1) Status` ...
  `6) Disable private alerts`), `Interval in seconds [60]:`, the down reasons, the `done` fields and
  the exit codes. V1 should check them against the code.
- The A4b spec asks for "the `--allow-http` warning" in the Refusals table, but the shared spec
  pins no warning for passing `--allow-http`, only the refusal `http needs --allow-http (the token
  travels in clear text)`. The release note lists that refusal. If setup-alerts.sh prints a
  warning when `--allow-http` is used, add its text as a row.
- The guide's down-message example `consensus stalled at header 812 for 240s` follows the pinned
  pattern `consensus stalled at header N for Ns`; confirm the runner prints the unit as `240s`.
- The README anchor `#private-alerts-every-network` and the OPERATOR anchor `#414-private-alerts`
  depend on A4a keeping those headings.

## Verifier fixes (F-D)
- [x] E-C1 release note: done fields per action
- [x] W-C1 release note: derived stall/inactive defaults
- [x] W-C2 release note: what leaves the host, per kind
- [x] N-C1 release note: #60 closes; Left open names the followup.md items
- [x] N-C2 release note: TN_ALERT_TARGETS row (`--enable`, with or without `--json`)
- [x] N-C3 release note: check-node issue list
- [x] N-C4 release note: `changed` true on the first run
- [x] S13 release note: failed fresh enable leaves .node-meta; explicit flags on an enabled node; status without root; healthchecks fragment refusal row
- [x] E-G1 guide: done fields
- [x] W-G1 guide: derived thresholds
- [x] W-G2 guide: grace only while starting or stopping; another chain at once
- [x] W-G3 guide: what leaves the server, per kind
- [x] N-G1 guide: check-node issues "such as"
- [x] N-G2 guide: `changed` on the first run
- [x] S13 guide: explicit flags on an enabled node; status without root
- [x] W-A1 AGENTS.md: push contract per kind
- [x] S13 AGENTS.md: undo restores ENABLE_ALERTS (unset when absent)
- [x] N-F1 followup.md: not needed (explicit flags now apply); #60 provenance only
- [x] docs/testnet-addons.md: re-checked, no change needed
- [x] HTML-only guide build, git diff --check, link check

Results: HTML-only guide build rc 0, no warnings (pandoc 3.8.3); `git diff --check HEAD` on the
five files clean; no em-dash, attribution trailer or guide-forbidden word on added lines; no
heading link added or changed. W-A1 was owned by A3b; F-D applied it. N-F1 dropped (section 13:
explicit flags now apply on an enabled node). docs/testnet-addons.md unchanged (none of the four
behaviour changes touches what it says).

## Unconfirmed
Written from spec section 13; the code in the checkout (setup-alerts.sh, lib/alerts.sh,
lib/tn-heartbeat.sh) did not carry these yet when F-D finished:
- A failed fresh enable leaves `.node-meta` as it was (`meta_unset ENABLE_ALERTS` when the key
  was absent; `keep-meta` mode of `alerts_disable`): release note enable bullet, AGENTS.md
  Private alerts bullet. The code still runs `alerts_disable "" no-hint` in the undo.
- `--interval`, `--stall-after`, `--inactive-after` and `--label` on an enabled node (with
  `--enable`, with or without targets, or `--refresh`) replace the stored values and restart the
  timer; `applied` is `["alerts:refreshed"]` or `["alerts:targets-changed","alerts:refreshed"]`:
  release note `--json` bullet, guide Private alerts (`--refresh --interval 120` example) and
  Other scripts row. The code still warns "... are not applied; to change them, run --disable and
  then --enable." (setup-alerts.sh:647-649), `sa_finish` takes one applied item, and `--help`
  lists the timing options under `--enable` only.
- `--status` without root when `.node-meta` cannot be read: `unknown (run with sudo)`,
  `"enabled":null`, on/off from `systemctl is-enabled telcoin-heartbeat.timer`: release note
  `--json` bullet, guide Other scripts row. The code still prints `"enabled":"false"` there.
- healthchecks URL with `#` refused, `HB_ERR="healthchecks: a query string or fragment is not
  allowed"`: release note healthchecks bullet and new Refusals row. lib/tn-heartbeat.sh:176 still
  says "a query string is not allowed" and refuses only `?`. OPERATOR.md:1182 and README.md:483
  (A4a's files) still say only "a query string is refused".
