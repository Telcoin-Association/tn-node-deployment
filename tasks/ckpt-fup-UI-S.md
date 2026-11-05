status: done

# UI-S checkpoint (branch fup/UI-S, base ac9a605)

- [x] S1 flag tie: 7b24dfc ui/server: the mainnet switch is tied to the library's by a test
- [x] S2 status link: 49649c0 ui: the Network tab links the status page of the node's network
- [x] S3 helper: 0d4d68f ui helper: firewall-enable takes a P2P source list after the SSH one
- [x] S4 server + page: 70ef78c ui: the System tab firewall form takes P2P sources, and the card shows the P2P list and the new-flow limit (coded to the final FW shape the orchestrator sent)
- [x] S5 unit: 0d3865b ui: the Node Manager UI unit forbids core dumps
- [x] S6 gates (all green, below)

Follow-up round (V5 findings, orchestrator 2026-11-03):
- [x] F1 (N4) 88ccdc8 api_firewall_enable: a non-string ssh_from / p2p_from is "must be text" (400), checked before `or ""`; pytest
- [x] F2 (N5) d94c0cc p2p_sources_kept: [] readable without the key, null unreadable, null + p2p_sources_note when the key is doubled; card shows the note; pytest
- [x] F3 (N1) ef30bc2 new-flow limit wording: packets per minute of new, unanswered flows per source; row, tooltip, render test
- [x] F4 docs notes: enable-form-only P2P field (N6); "no adiri status host" correction
- [x] F5 gates + cherry-pick check against hardening-followups + check-network-hits.sh

## Operator-visible changes

- Network tab: the "status page" link now follows the node's network. Testnet links
  https://status.adiri.telcoin.network/; mainnet (no page yet), devnet and an unknown network show no link.
- System tab, Firewall card, enable form (shown while ufw is off): a new "P2P sources" field next to "SSH sources".
  Same rule as the SSH list: at most 16 addresses or CIDRs of /8 or narrower, split on commas, spaces or new lines;
  never /0 or the unspecified address. When given, the P2P ports accept only those sources (the confirm dialog says
  peers outside the list cannot reach the node). When empty, the engine uses P2P_ALLOW_FROM from .node-meta, else every
  address (with firewall-setup.sh's new-flow limit).
- Firewall card: new rows "P2P sources" (the kept list; "every address" when .node-meta has no P2P_ALLOW_FROM line
  or there is no .node-meta; "P2P_ALLOW_FROM is set more than once in .node-meta; remove the extra lines on the server"
  when the key is doubled; "—" when .node-meta cannot be read) and, when the engine reports it, "P2P new-flow limit":
  "active, N packets per minute of new, unanswered flows per source after a burst of B" (+ " (not restored at boot)"
  when persistent is false), or "inactive: <reason in words>".
- Error texts for a bad source now name the list: "SSH sources: not an address or a CIDR of /8 or narrower: X",
  "P2P sources: …", "at most 16 P2P sources", "p2p_from must be text". A list that is not text (0, false, [], a
  number) is "ssh_from must be text" / "p2p_from must be text" (400); absent or null means no list.
- Helper: `telcoin-ui-helper firewall-enable [<ssh-sources>|-] [<p2p-sources>]`; refuses a list starting with `/`
  ("invalid P2P source list: /x (a file path is not taken here; give addresses or CIDRs joined by commas)"), a non comma
  list, a bad entry, more than 16, a third argument, and an engine copy without --p2p-from (update-scripts.sh hint).
- ui/telcoin-ui.service: LimitCORE=0.

## Docs notes

- P2P field: System tab > Firewall > enable form, "P2P sources (optional)". Rule above. API: POST /api/firewall/enable
  takes `p2p_from` (string) beside `ssh_from`; the server calls `sudo -n telcoin-ui-helper firewall-enable [<ssh>|-] [<p2p>]`
  ("-" = no SSH list); the helper passes `--ssh-from <ssh>` and `--p2p-from <p2p>` to firewall-setup.sh --json --enable,
  from `/`, never a file path. Sudoers is unchanged (the existing `firewall-enable *` line allows it).
  GET /api/firewall adds `p2p_sources`, read as the engine's meta_get reads P2P_ALLOW_FROM: the list; [] when there is
  no such line or no .node-meta; null when .node-meta cannot be read; null plus `p2p_sources_note` ("P2P_ALLOW_FROM is
  set more than once in .node-meta; remove the extra lines on the server") when the key is doubled. It passes the
  engine's `p2p_new_flow_limit` {active, rate, burst, reason, persistent} through. Limit row: "active, N packets per
  minute of new, unanswered flows per source after a burst of B"; tooltip: it counts the packets of P2P flows the node
  has not answered yet, per source (an IPv4 address or an IPv6 /64), answered flows are not limited. Reason words:
  p2p-list "a P2P source list is set", nft-missing "nftables is not installed", not-applied "not applied yet; enable the
  firewall", unreadable "state could not be read".
  The P2P sources field exists only in the enable form, shown while ufw is inactive, so the UI cannot set or change a
  P2P list once the firewall is on: the operator runs `firewall-setup.sh --enable --p2p-from LIST` on the host. The UI
  cannot drop a stored P2P list either: `firewall-setup.sh --enable --p2p-anywhere` on the host.
- Status link rule: /api/network/status carries `status_page` from server STATUS_PAGE_LINKS (per network slug; only
  testnet has one). The page renders the link only for an https URL; index.html names no adiri status host (it still
  carries the node7.adiri.telcoin.network placeholder at DEFAULT_RPC_HOST, annotated by NET-2).
- LimitCORE=0 on ui/telcoin-ui.service (inherited by the helpers it runs under sudo; a dump would hold the UI token or a
  setup passphrase). NoNewPrivileges stays unset (sudo).
- Flag tie: ui/test_mainnet_flag.py fails unless lib/common.sh `readonly TN_MAINNET_ENABLED=<0|1>`, ui/server.py
  TN_MAINNET_ENABLED and index.html `const SETUP_MAINNET_ENABLED` agree; the mainnet release flips all three together.

## Tests run

Follow-up round (F1-F3, on fup/UI-S at ef30bc2):
- pytest exact gate command: python:3.10-slim 281 passed, 1147 subtests; python:3.12-slim 281 passed, 1147 subtests.
- helper_test.sh: bash 5.3.9 548/0; bash:3.2 548/0 (helper unchanged this round).
- install_ui_test.sh: host 1/0 (root cases SKIP), ubuntu:24.04 as root 13/0. open_ui_test.sh 9/0. py_compile ok.
- Cherry-pick check: `git archive hardening-followups` into the scratchpad, `git apply --check` of the three new
  commits: every hunk applies (index.html hunks at offset 2, no fuzz). On that tree: `bash tools/check-network-hits.sh`
  exit 0 ("clean, 148 annotated hit(s) in 23 file(s) scanned"); pytest (3.10) 281 passed; helper_test.sh 548/0.
- node:22-slim `node --check` on the page script ok; fwP2pSourcesText (note, null, [], list) and fwNewFlowLimitText
  (active, not persistent, p2p-list) exercised.

First round:
- pytest, exact gate command, python:3.10-slim: 277 passed, 1125 subtests (baseline 258); python:3.12-slim: 277 passed, 1125 subtests.
- ui/tests/helper_test.sh: bash 5.3.9: 548 checks, 0 failed; bash:3.2 (3.2.57): 548 checks, 0 failed (baseline 505).
- ui/tests/install_ui_test.sh: host (not root) 1/0 with root cases SKIP; ubuntu:24.04 as root 13/0.
- ui/tests/open_ui_test.sh: 9/0.
- bash -n (bash 5.3 and bash:3.2) on ui/telcoin-ui-helper.sh and ui/tests/helper_test.sh: ok.
- tools/check-bash32.sh on both: clean. shellcheck -x --severity=error, host 0.11.0 and koalaman/shellcheck:v0.9.0: 0 findings.
- systemd-analyze verify --man=no on a temp copy of ui/telcoin-ui.service: only "Command /opt/telcoin-ui-venv/bin/python is not
  executable" (plus host xfs_scrub noise); identical to the base unit.
- python3 -m py_compile ui/server.py: ok. check-perl-interp on ui/*.sh: clean. passphrase_print_test 4/0, root_write_pipe_test 2/0.
- Extra: node:22-slim `node --check` on the page's inline script: ok; statusPageLink, fwSources, fwP2pSourcesText and
  fwNewFlowLimitText exercised in node with the FW shapes (active/persistent, the four reasons, null, absent).

## Open issues

- Spec naming: `STATUS_PAGE_BASE` already exists in ui/server.py as the Uptime Kuma API host (https://status.telscan.xyz,
  used for /api/status-page/<slug> of every network), so the per-network link is a new constant `STATUS_PAGE_LINKS`
  (helper `status_page_link`) and the JSON field is `status_page`. NET-2's suggested reason text "status page per network
  (server STATUS_PAGE_BASE)" should name STATUS_PAGE_LINKS; the marker used is `# network-gated: status page per network`.
- Spec: the helper's generic argv check (_arg_ok) refuses any argument starting with `-`, so `--p2p-from LIST` could not be
  a helper argument without touching main; the P2P list is the second positional and "-" marks "no SSH list".
- An existing helper case "firewall-enable refuses a second argument" became "refuses a third argument".
- ui/dev/serve.py (not owned) has no p2p_new_flow_limit in its FIREWALL fixture; the dev page shows no limit row until it gains one.
- At ac9a605, firewall-setup.sh desired_firewall_rules reports the P2P rules' source as "anywhere" even with a P2P list, so the card's "Expected configuration" rows do not show it (FW's file; may be fixed in FW's landed branch).
