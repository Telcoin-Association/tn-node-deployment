# UI-S: UI follow-ups (issues #45, #41, #43, #47)

Read `tasks/spec-fup-shared.md` first. Worktree `~/coding/telcoin/tnd-fup-UI-S`, branch
`fup/UI-S`, checkpoint `tasks/ckpt-fup-UI-S.md`.

## Goal

The UI's mainnet switch cannot drift from the library's, the System tab can set a P2P source
list, the status link follows the node's network, and the UI unit forbids core dumps.

## Owned files

`ui/server.py`, `ui/telcoin-ui-helper.sh` (the firewall verbs only; LIB-A edits `cmd_setup`:
do not touch it), `ui/static/index.html`, `ui/telcoin-ui.service`, `ui/test_*.py`,
`ui/tests/helper_test.sh` (firewall cases only; LIB-A appends setup cases: put yours in a
`# UI-S firewall` block at the end).

## Facts (main 1187ddb)

- ui/server.py: `TN_MAINNET_ENABLED = False` :2856, used :2872 (release lists);
  `UI_VERSION = "2.0.1"` :78 (orchestrator bumps). LIB-A adds `readonly TN_MAINNET_ENABLED=0`
  to lib/common.sh (the repo copy is at `../lib/common.sh` relative to `ui/`; the installed
  engine copy is `/opt/telcoin-ui-update/lib/common.sh`).
- ui/static/index.html: :1603 hard-coded `<a href="https://status.adiri.telcoin.network/">`
  status link; firewall card `#fwCard` :3136; `p2p_ports` rendering :3191; the firewall
  enable form posts the SSH source list (grep `firewall-enable` / `ssh_from` in server.py
  and index.html).
- ui/telcoin-ui-helper.sh: `cmd_firewall_enable [<sources>]` :1355 passes `--ssh-from` (comma
  list, at most 16 entries, each `validate_health_src`-accepted); `FIREWALL_SCRIPT` :126.
  firewall-setup.sh accepts `--p2p-from <list|file>` (FW adds an nft meter when no list is
  set; the helper never passes a file path: it runs from `/` and refuses anything but a
  comma list).
- ui/telcoin-ui.service: no `LimitCORE`; `NoNewPrivileges` intentionally absent (sudo), keep
  that comment. #39 (oneshots, sudoers, TCP 8080) is deferred: do not touch sudoers or ports.
- Tests: `ui/test_*.py` 258 pass under pytest 9.2.0 (`python:3.10-slim`), `helper_test.sh`
  494 checks under bash 5 and 3.2.

## Required behaviour

1. A pytest in `ui/test_server_contract.py` (or a new `ui/test_mainnet_flag.py`) reads
   `../lib/common.sh`, parses `readonly TN_MAINNET_ENABLED=<0|1>` and asserts
   `server.TN_MAINNET_ENABLED == (value == "1")`, with a message that says both must change
   together. A one-line comment at :2856 points at the library constant.
2. Status link: the server exposes `STATUS_PAGE_BASE` per network (testnet
   `https://status.adiri.telcoin.network/`, mainnet: no page is known yet, so the link is
   hidden; devnet hidden) in the JSON the page already loads for the network (grep how
   `network` reaches the page); index.html renders the link from it and never hard-codes
   the adiri host. Mark the server constant line `# network-gated: status page per network`
   (NET-2's lint will look for that marker on adiri hits).
3. System tab firewall form: a "P2P sources" field (same validation as the SSH list: comma
   list, at most 16, each address or CIDR; empty = open with the nft limit); the server
   passes it to the helper; `cmd_firewall_enable` gains a second argument (or `--p2p-from
   LIST`; keep the first positional for SSH so existing callers work) and passes
   `--p2p-from`; the helper refuses a value with `/` at the start or anything that is not a
   comma list. The firewall status card shows the P2P list and the new-flow limit line FW
   adds to the `--json` status (field name agreed with FW: `p2p_new_flow_limit` object with
   `active`, `rate`, `burst`, `reason`; if FW's branch is not in your worktree, code to that
   shape and say so).
4. `ui/telcoin-ui.service`: `LimitCORE=0` with a one-line comment.

## Tests

pytest: the flag tie (both values), the status link per network, the firewall form's P2P
field validation and the helper argv (the tests stub the helper); `helper_test.sh`:
`firewall-enable` with SSH only, SSH + P2P list, a bad P2P list, a leading `/`; run pytest
in `python:3.10-slim` with `--require-hashes` from the two requirement files; `helper_test.sh`
under bash 5.3 and `bash:3.2`; `systemd-analyze verify ui/telcoin-ui.service` (host; the
ExecStart path may not exist: use `--man=no` and accept the "not found" note only); `bash -n`,
`check-bash32`, shellcheck 0.9 + 0.11 on the helper.

## Docs notes to hand over

The P2P field, the status link rule, `LimitCORE=0` on the UI unit, the flag tie.
