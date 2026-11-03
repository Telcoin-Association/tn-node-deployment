# FW: per-source P2P new-flow limit (issue #41)

Read `tasks/spec-fup-shared.md` first. Worktree `~/coding/telcoin/tnd-fup-FW`, branch
`fup/FW`, checkpoint `tasks/ckpt-fup-FW.md`.

## Goal

When the P2P ports are open to the world (no `--p2p-from` list), an nftables meter limits how
fast any one source may open new UDP flows to them, so a flood from one address cannot
exhaust the node; committee peers with established flows are never touched.

## Owned files

`firewall-setup.sh`, tests `tools/tests/firewall_reset_test.sh`,
`tools/tests/firewall_signal_test.sh`, `tools/tests/fwstub.sh`.

## Facts (main 1187ddb)

- firewall-setup.sh: `fw_p2p_ports` :299 (one "port label" line per P2P port, primary and
  workers), `fw_p2p_allow` :381 (per-source `ufw allow from S to any port P proto udp` and
  delete of the open rule when `FW_P2P_SRCS` is non-empty, else `ufw allow P/udp`),
  `fw_src_list` :401, `fw_load_p2p_srcs` :510 (`--p2p-from` or `P2P_ALLOW_FROM` in
  `.node-meta`), `apply_recommended_firewall [--reset]` :866 (`--reset` runs `ufw --force
  reset` first). The `--json` mode and its `done` event exist (grep `json_event`).
- ufw on Ubuntu 24.04 sits on nftables (`iptables-nft`); a separate table `inet tn_p2p` with
  its own chain at `hook input priority -10` (before ufw's filter chains at priority 0) can
  drop excess NEW flows and `accept`s nothing (it returns to ufw for the rest), so ufw's
  rules keep deciding. Decision 6: `ct state new udp dport {ports} meter tn_p2p_src { ip
  saddr limit rate over RATE/minute burst BURST packets } drop` plus the `ip6 saddr` twin;
  defaults 20/minute burst 40; `TN_P2P_NEW_FLOW_RATE` / `TN_P2P_NEW_FLOW_BURST` (positive
  integers) override; `.node-meta` records nothing new (the table is derived each run).
- `nft` is in `nftables` (installed on 24.04 by default, but a minimal image may lack it).

## Required behaviour

1. `fw_p2p_allow` without a source list: after the ufw rules, write the table atomically
   (`nft -f -` from a heredoc with `table inet tn_p2p` deleted-then-added in one
   transaction: `add table inet tn_p2p` + `delete table inet tn_p2p` pattern, or `nft -f`
   of a file that starts with `table inet tn_p2p {}` + `delete table`; test which form is
   idempotent on 24.04's nft 1.0.9 in `ubuntu:24.04` with `--privileged` off: `nft` needs
   netlink, so prove the file parses with `nft -c -f` and keep the apply itself stubbed).
   With a source list: delete the table if present (the allowlist replaces the meter).
   `--reset`: delete the table. When `nft` is absent: `print_warn` once ("nftables (nft) is
   not installed, so the P2P new-flow limit is not applied; P2P stays open to every
   source") and continue (rc 0).
2. The ports in the set are exactly `fw_p2p_ports`'s; rate/burst from the env with
   validation (bad value → rc 1 with a message, before anything changes).
3. Status (`--status` / `--json` status): a line/field saying the limit is active with its
   rate and burst, or absent and why (list set, nft missing, not applied).
4. Never touch established flows (`ct state new` only), never accept in the table.

## Tests

`fwstub.sh` gains an `nft` stub that records argv and stdin to a log (and a mode where
`command -v nft` fails: a PATH without it). `firewall_reset_test.sh`: open P2P → the table
text has both ports, `ct state new`, the v4 and v6 meters, the defaults; env overrides;
bad env values refused; with `--p2p-from 10.0.0.0/8,2001:db8::/32` and with a list file →
no table and a delete; `--reset` deletes; nft absent → warning, rc 0, ufw rules still
applied; IPv6 P2P source rules (the existing per-source path with an IPv6 CIDR) and the
list-file path are covered. `firewall_signal_test.sh`: a SIGTERM mid-apply leaves no
half-written table (the write is one transaction). Run under bash 5.3, `bash:3.2`,
`ubuntu:24.04` (with `nft -c -f` on the rendered text if `nftables` can be installed in the
container: `apt-get install -y nftables`; record the result, SKIP when not).

## Docs notes to hand over

The rule, defaults, env names, when it is and is not applied, the warning, the status line,
`--reset`, and "the signed address-manifest reader waits on the Association's format".
