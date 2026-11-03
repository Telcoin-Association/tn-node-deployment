status: done

# FW checkpoint (issue #41: per-source P2P new-flow limit)

- [x] S0 read specs, verify anchors, decide nft form (nft -c -f proof in ubuntu:24.04)
  - anchors (grep, fup/FW at 6cbf52e): fw_p2p_ports :299, fw_p2p_allow :381, fw_src_list :410,
    fw_load_p2p_srcs :510, fw_preflight :559, view_status :708, apply_recommended_firewall :894,
    fw_apply_rules :951, json_fw_status :1977, main :2151. --status without --json opens the menu
    (no CLI status mode); the status line goes in view_status, the field in json_fw_status.
  - nft -c needs netlink on 1.0.9: `docker run --rm -v ... ubuntu:24.04 ... nft -c -f` gives
    "netlink: Error: cache initialization failed: Operation not permitted" rc 1 for every file.
    Re-ran with `--cap-add NET_ADMIN` (no --privileged; the container's own network namespace,
    host ruleset untouched): nft 1.0.9 (Old Doc Yak #3) `nft -c -f` rc 0 on the set form, the
    meter form, the add+delete pair and `destroy`.
  - Decision: one `nft -f -` transaction per write: `table inet tn_p2p` (add: no-op when present)
    + `delete table inet tn_p2p` + the full `table inet tn_p2p { ... }`. Applied twice in a row:
    rc 0 both times, one table. Delete-only program (add + delete) applied on an absent table and
    twice in a row: rc 0, no table left. `destroy` also works on 1.0.9 with this kernel but needs
    kernel 6.3+, so the add+delete pair is used (works on every nft/kernel). A program with a
    parse error leaves the previous table intact (rc 1, old rules listed).
  - Form: explicit dynamic sets tn_p2p_src4 / tn_p2p_src6 (flags dynamic,timeout, size 65535,
    timeout = time a full burst takes to refill, 60s..1d) + `update @set { ip saddr limit rate over
    R/minute burst B packets } drop`; the meter form lists identically but `meter` is the old
    syntax. Listing prints `burst B packets` even for burst 5 (status parses it).
  - Functional proof in the private netns: 60 new flows + 10 packets of one unanswered flow from
    127.0.0.1 to 49590/49594: counter 30 dropped, 40 (the burst) passed; set element shows
    `127.0.0.1 limit rate over 20/minute burst 40 packets expires 1m59s`.
- [x] S1 firewall-setup.sh: env validation, table render, apply/delete, nft-absent warning, --reset
      delete, status line and --json field (one commit: 66b8e4c; the status code shares the
      helpers, so S1 and the old S2 are one section)
- [x] S2 tests: fwstub.sh nft stub, firewall_reset_test.sh cases, firewall_signal_test.sh case
      (commit 88c6dd6)
- [x] S3 gates (bash 5.3, bash 3.2, ubuntu:24.04, bash -n, check-bash32, shellcheck x2, root_write_pipe, full suite)


## Follow-up round (coordinator decisions on open issues 1-4)

- [x] F1 firewall-setup.sh: boot copy (/etc/telcoin/p2p-limit.nft 0640 + telcoin-p2p-limit.service
      0644, enabled not started; disabled + removed with the delete), IPv6 set keyed on the /64,
      "Manage node ports" calls fw_p2p_limit_sync after it opens the P2P ports, `persistent` in
      the status line and JSON (commit 9ca623e)
  - /64 proof: nft 1.0.9 `nft -c -f` rc 0 with the masked key; applied in `docker run --cap-add
    NET_ADMIN --sysctl net.ipv6.conf.all.disable_ipv6=0 --sysctl net.ipv6.conf.lo.disable_ipv6=0
    ubuntu:24.04` (nftables, iproute2, netcat-openbsd): 30 new flows from 2001:db8:1:2::a and 30
    from 2001:db8:1:2::b to 49590 -> ONE element `2001:db8:1:2:: limit rate over 20/minute burst
    40 packets`, counter 20 dropped (40 passed); a flow from 2001:db8:9::1 adds its own element
    `2001:db8:9::`. Listing: `update @tn_p2p_src6 { ip6 saddr & ffff:ffff:ffff:ffff:: limit rate
    over 20/minute burst 40 packets }`.
  - `systemd-analyze verify --man=no` (systemd 259, host) on the unit rendered with /usr/sbin/nft
    in a temp dir: rc 0 (only unrelated xfs_scrub host-unit notes).
- [x] F2 tests for F1 (fwstub systemctl state, reset test, signal test) (commit 6194f76)
- [x] F3 remove-node.sh: `_rm_p2p_limit` (new function before remove_node_host_files) + one call in
      remove_node_host_files after its file loop (runs only when no other node remains: menu,
      leftovers, --json keys scope) (commit 4a17057)
- [x] F4 `# FW` block in tools/tests/remove_test.sh after `# KEYS` + an nft stub inserted after the
      first stub loop so no real nft runs anywhere in the file (commit e911cde)
- [x] F6 (coordinator, from UI-S) desired_firewall_rules: P2P rows name the P2P source list when set,
      joined with commas like the SSH row, "anywhere" without one (commits ed4f758, 09e2862)
- [x] F5 gates (bash 5.3, bash:3.2, ubuntu:24.04, lints, systemd-analyze, full suite)

## Round 3 (V5 findings: W1-W5, N1-N3, docs corrections)

- [x] R1 firewall-setup.sh: W1 env check before the menu's confirm, W2 boot copy compared with the
      live table + in-flight marker finished/reported by the EXIT trap, W3 update lock on every
      enable/--reset/menu apply, W4 "unknown (... not usable)" rows (SSH too), N1 wording, N3 menu
      sync on the already-open branch (commit e21da11)
- [x] R2 tests for R1 (reset test 319 checks, signal test 220) (commit 39fb1b1)
- [x] R3 remove-node.sh: W5 keep p2p-limit.nft while another node remains (json keys: _rm_p2p_keep,
      shred_key_files optional KEEP, _rm_config_dir), N2 leftover check/listing includes the
      p2p-limit unit (teardown via remove_node_host_files) (commit 908bd12)
- [x] R4 remove_test.sh `# FW` block cases for R3, inserted before "# The JSON full removal takes
      it too." (340 checks) (commit e32088a); signal-test lock cases moved to a testnet fixture (ffcddb5)
- [x] R5 gates + an integration check (integration tip + my patches in a scratch copy:
      check-network-hits, full suite 61 files)
- facts: nft 1.0.9 lists a one-port set as `udp dport 49590` (no braces), sorts set elements
  ascending (`{ 49600, 49590, 49594 }` -> `{ 49590, 49594, 49600 }`), does not merge consecutive
  ports. firewall-setup.sh has no --help text (no usage function, `*) shift`).

## Round 4 (V6 W3: the health-port block of the status screen on mainnet)

- [x] Q1 firewall-setup.sh view_status: the Uptime Kuma block only when is_testnet_like; else one
      line that the health port stays closed here, and a warning without the testnet address when
      it is open anyway (commit 3ab7ed5)
- [x] Q2 firewall_reset_test.sh: mainnet closed, mainnet open (anywhere, monitor rule), testnet
      unchanged (336 checks; the 10 new mainnet checks fail on e32088a) (commit c7a2246)
- [x] Q3 gates

## Operator-visible changes

- Every enable path (`--enable`, `--reset`, `--json --enable`, the menu's "Enable recommended
  defaults") on a host with a node and no P2P source list now writes the nftables table
  `inet tn_p2p` after the ufw rules are complete, and prints
  `  ->  P2P new-flow limit: UDP 49590 and 49594 accept at most 20 new flows per minute from one address after a burst of 40 (nftables table inet tn_p2p).`
- With a P2P source list (`--p2p-from`, `P2P_ALLOW_FROM`), or without a node, the table is
  deleted when it is there. A ufw step that fails never reaches the table.
- `TN_P2P_NEW_FLOW_RATE` / `TN_P2P_NEW_FLOW_BURST` override 20 / 40 for the run; a bad value
  stops the run in the preflight, nothing changed, rc 1.
- No nft: a warning, rc 0, ufw rules applied as before.
- Status screen: a "New-flow limit:" line under the P2P port lines. `--json --status`: new field
  `p2p_new_flow_limit`.

## Docs notes

(Current as of round 3; supersedes rounds 1 and 2.)

- Rule (`nft list table inet tn_p2p` at the defaults; the program written uses `timeout 120s` and
  `priority -10`):
  ```
  table inet tn_p2p {
      set tn_p2p_src4 { type ipv4_addr; size 65535; flags dynamic,timeout; timeout 2m }
      set tn_p2p_src6 { type ipv6_addr; size 65535; flags dynamic,timeout; timeout 2m }
      chain input {
          type filter hook input priority filter - 10; policy accept;
          ct state new udp dport { 49590, 49594 } update @tn_p2p_src4 { ip saddr limit rate over 20/minute burst 40 packets } drop
          ct state new udp dport { 49590, 49594 } update @tn_p2p_src6 { ip6 saddr & ffff:ffff:ffff:ffff:: limit rate over 20/minute burst 40 packets } drop
      }
  }
  ```
  What it counts: packets of new, not yet answered UDP flows (conntrack state new: every datagram
  of a flow the node has not answered yet counts, not only the first). Once the node answers, the
  flow is established and never matches. Per source: one IPv4 address, or one IPv6 /64 (every
  address of a /64 is one entry). Ports = the node's P2P ports (primary, worker 0, workers 1+), the
  same list ufw opens; nft lists one port without braces. Chain at priority -10, before ufw's
  chains at 0; drops only; accepts nothing (policy accept hands every other packet to ufw, which
  still decides). A source's entry expires after it sent no such packet for ceil(burst*60/rate) s,
  at least 60, at most 86400 (120 s at the defaults). Each set holds at most 65535 sources; once a
  set is full, new sources go on to ufw unlimited (sources already in it stay limited).
- Defaults: rate 20 packets of new, not yet answered flows per minute per source, burst 40.
- Env: `TN_P2P_NEW_FLOW_RATE` (packets of new, not yet answered P2P flows per minute from one IPv4
  address or IPv6 /64), `TN_P2P_NEW_FLOW_BURST` (such packets one source may send before the rate
  applies); whole numbers 1-100000, no leading zeros; unset or empty = default. Read on every run,
  not stored (`.node-meta` records nothing), so a later enable without them (the UI's firewall
  enable, a plain `--enable`, any `sudo` that drops them) goes back to 20/40. Through sudo:
  `sudo TN_P2P_NEW_FLOW_RATE=30 TN_P2P_NEW_FLOW_BURST=60 bash firewall-setup.sh --enable`.
  A bad value refuses before any change (rc 1; `--json`: error event + done ok:false rc 1) on every
  path, the menu's "Manage node ports" included (checked before it asks or opens a port), and even
  with a P2P list set:
  `TN_P2P_NEW_FLOW_RATE is 'X', not a whole number from 1 to 100000 (packets of new, not yet answered P2P flows per minute from one IPv4 address or IPv6 /64); nothing was changed.`
  `TN_P2P_NEW_FLOW_BURST is 'X', not a whole number from 1 to 100000 (packets of new, not yet answered P2P flows one source may send before the per-minute rate applies); nothing was changed.`
- Update lock (new in round 3): every `--enable`, `--reset`, `--json --enable`, the menu's "Enable
  recommended defaults" and "Manage node ports" change takes the update lock
  (`/run/telcoin/update.lock`) around ufw, the table and its boot copy; a held lock refuses before
  any change with the library's `Another update is already running (PID N).` / `Wait for it to
  finish, or verify with: ps -fp N` (`--json`: an error event and done ok:false naming it). The CLI
  and `--json` runs release it at exit (also on TERM, INT, HUP); the menu paths release it when
  their change is done (the menu does not hold it while it waits at a prompt). `--status` takes no
  lock.
- Boot copy: with the table, firewall-setup.sh writes `/etc/telcoin/p2p-limit.nft` (root:root
  0640, the program it just loaded: `table inet tn_p2p` / `delete table inet tn_p2p` / the table)
  and `/etc/systemd/system/telcoin-p2p-limit.service` (root:root 0644), both through
  tn_write_root_file, then `systemctl daemon-reload` and `systemctl enable
  telcoin-p2p-limit.service` (not started). Unit: `Type=oneshot`, `RemainAfterExit=yes`,
  `After=ufw.service network-pre.target`, `ConditionPathExists=/etc/telcoin/p2p-limit.nft`,
  `ExecStart=<nft> -f /etc/telcoin/p2p-limit.nft`, `ExecStop=-<nft> delete table inet tn_p2p`,
  `WantedBy=multi-user.target`; `<nft>` = `command -v nft` at write time (/usr/sbin/nft on Ubuntu).
  Stopping the unit deletes the table. Info line:
  `telcoin-p2p-limit.service loads it again at boot (from /etc/telcoin/p2p-limit.nft).`
  A boot copy that cannot be written is a warning, the table stays loaded, rc 0:
  `The P2P new-flow limit is loaded now but will not come back after a reboot: <why>. Fix that and run --enable again.`
  When the limit is not wanted (P2P source list, no node, `--reset` to a list, nft missing) the unit
  is disabled and stopped, both files removed, daemon-reload. A program nft refuses, or a failed ufw
  step, writes no boot copy.
- A run stopped while the limit changes (new in round 3): the table and its boot copy are changed
  under an in-flight marker that the exit trap handles. A removal is finished:
  `Stopped (exit N) while the P2P new-flow limit was being removed; the removal was finished.`
  After a write, when the loaded table is the one the run wrote, its boot copy is written:
  `Stopped (exit N) after the P2P new-flow limit was loaded; its boot copy was written too.`
  (or `..., and its boot copy could not be written, so a reboot would not load it; run --enable again.`);
  when nft did not get to load it, both stay:
  `Stopped (exit N) before the P2P new-flow limit was loaded; the previous limit and its boot copy stay as they were.`
  (stderr; in `--json` the error event and the done event's error.)
- When applied: `--enable`, `--reset`, `--json --enable`, the menu's "Enable recommended defaults"
  (after `ufw --force enable` succeeded), and the menu's "Manage node ports" (after it opens the P2P
  ports, and also when they were all open already, so a changed port set always rewrites the table
  and its boot copy; with a P2P list it deletes them; declining the prompt changes nothing). Only
  with a node installed and no P2P source list (no `--p2p-from`, no `P2P_ALLOW_FROM`, or
  `--p2p-anywhere`). One `nft -f -` transaction (`table inet tn_p2p`, `delete table inet tn_p2p`,
  the full table): a rerun replaces it; a refused program leaves the previous table.
- `--reset`: the table and its boot copy are replaced whole: written again when P2P is open to
  every source, deleted (unit disabled, files removed) with a P2P list or without a node.
- remove-node.sh: when the last node goes (menu removal, `--json` full removal, the leftover
  cleanup), it disables and stops telcoin-p2p-limit.service, removes it and
  /etc/telcoin/p2p-limit.nft and deletes the table when nft is there (`Removed …`,
  `Deleted the P2P new-flow limit (nftables table inet tn_p2p)`; refused:
  `Could not delete the nftables table inet tn_p2p; remove it with: sudo nft delete table inet tn_p2p`).
  While another node unit remains, all of it stays: the `--json` keys removal of one node keeps
  /etc/telcoin/p2p-limit.nft (not shredded, not removed with the config directory) and logs
  `Keeping /etc/telcoin/p2p-limit.nft: another node unit remains here, and the P2P new-flow limit stays whole for it`;
  the menu removes every node in one run, so the last one takes the limit. The leftover check and
  listing include the boot unit
  (`/etc/systemd/system/telcoin-p2p-limit.service (the P2P new-flow limit, and its nftables table)`),
  so a host with only the unit and the table left is cleaned up.
- Warning without nft (once, rc 0; not shown with a P2P list):
  `nftables (nft) is not installed, so the P2P new-flow limit is not applied; P2P stays open to every source`
  (a boot copy left from before is removed, since it could not run).
- Other warnings (rc 0): `nft did not load the P2P new-flow limit (exit N: <first line>); table inet tn_p2p stays as it was. The ufw rules are applied.`
  and `The P2P new-flow limit (nftables table inet tn_p2p) could not be removed (exit N: <msg>); remove it with: sudo nft delete table inet tn_p2p`.
- Info line on write: `P2P new-flow limit: UDP 49590 and 49594 accept at most 20 packets of new, not yet answered flows per minute from one IPv4 address or IPv6 /64 after a burst of 40 (nftables table inet tn_p2p).`
- Status screen (under the P2P port lines):
  - active: `[OK]  New-flow limit: at most 20 packets of new, not yet answered P2P flows per minute from one IPv4 address or IPv6 /64 after a burst of 40 (nftables table inet tn_p2p)`, then one of
    `[OK]  New-flow limit at boot: loaded by telcoin-p2p-limit.service (enabled)`,
    `[WARN] New-flow limit at boot: /etc/telcoin/p2p-limit.nft holds another rate, burst or port set than the loaded table, so a reboot would load that one; run Enable recommended defaults (or --enable) again`,
    `[WARN] New-flow limit at boot: not restored after a reboot (/etc/telcoin/p2p-limit.nft is missing); run Enable recommended defaults (or --enable) again`,
    `[WARN] New-flow limit at boot: not restored after a reboot (telcoin-p2p-limit.service is not enabled); run Enable recommended defaults (or --enable) again`
  - `->  New-flow limit: not used; the P2P ports take only the P2P source list (P2P_ALLOW_FROM)`
  - `[WARN] New-flow limit: not applied; nftables (nft) is not installed, so P2P stays open to every source`
  - `[WARN] New-flow limit: not applied; run Enable recommended defaults (or --enable) to add it`
  - `[WARN] New-flow limit: unknown; nft cannot list table inet tn_p2p, or P2P_ALLOW_FROM in .node-meta cannot be read`
  - inactive with the unit enabled adds `[WARN] New-flow limit at boot: telcoin-p2p-limit.service is enabled but the table is not loaded; check: systemctl status telcoin-p2p-limit.service`
- `--json --status` field (round 3 adds `persistent_reason`):
  `"p2p_new_flow_limit":{"active":true,"rate":20,"burst":40,"reason":null,"persistent":true,"persistent_reason":null}`
  (rate and burst read back from `nft list table inet tn_p2p`), else
  `{"active":false,"rate":null,"burst":null,"reason":"p2p-list"|"nft-missing"|"not-applied"|"unreadable","persistent":…,"persistent_reason":…}`.
  `persistent` is true when /etc/telcoin/p2p-limit.nft exists, `systemctl is-enabled` reports the
  unit enabled and, while the table is loaded, the file holds the same rate, burst and port set
  (port order does not matter); `persistent_reason` is then null, else `"boot-file-missing"`,
  `"unit-not-enabled"` or `"boot-copy-differs"`.
- Expected-configuration rows (status screen and `desired` in `--json --status`): the P2P rows'
  `source` is the P2P source list in force (the run's `--p2p-from`, else `P2P_ALLOW_FROM`) joined
  with commas, like the SSH row; `anywhere` only without a list or with `--p2p-anywhere`; and
  `unknown (P2P source list not usable)` when the stored list cannot be read (a key set more than
  once, an invalid entry; every enable refuses such a list too). The SSH row does the same:
  `unknown (SSH source list not usable)`. The MISSING line says `-- MISSING (expected from <list>)`.
- firewall-setup.sh has no `--help` text, so no help wording to change.
- Status screen, health port (round 4): the "Uptime Kuma health monitoring -- TCP 43174" block
  shows only on testnet and devnet (unchanged there: `[ERROR] TCP 43174 is CLOSED -- health
  monitoring will fail`, `[OK]  TCP 43174 open to the Association monitor only (...)`, `[WARN] TCP
  43174 open to Anywhere -- consider restricting to <monitor> (menu: Manage node ports)`). On any
  other network (mainnet) one line instead:
  `->  Health port TCP 43174 stays closed: health monitoring is a testnet-only add-on`, or, when a
  rule opens it anyway (to anywhere or to the monitor),
  `[WARN] Health port TCP 43174 is open, although no monitor uses it on this network; Manage node ports (or --enable) closes it`
  (no testnet address; the raw ufw rule list above it still shows whatever rule exists).
- UI (from the coordinator): the UI card shows `persistent` with "(not restored at boot)" and does
  not render `persistent_reason` yet; the field is in the JSON for operators, and the card change
  is a UI-S follow-up.
- "The signed address-manifest reader waits on the Association's format" (spec: hand over as is).

## Tests run (round 4, committed tip c7a2246)

- bash 5.3.9: firewall_reset 336/0/1 skip; firewall_signal 220/0/0; remove_test 340/0/0;
  root_write_pipe 2/0.
- bash:3.2 and ubuntu:24.04 (root): firewall_reset 334/0/3 skips; firewall_signal 220; remove_test
  340; root_write_pipe 2; all 0 failed.
- bash -n (5.3, 3.2), check-bash32, shellcheck 0.11 and v0.9.0 on firewall-setup.sh and the reset
  test: clean; no new warning-level findings; systemd-analyze verify on the unit: rc 0.
- The 10 new mainnet checks fail on e32088a; the V6 repro (`tasks/verify-fup/V6/kuma_mainnet_repro.sh`
  from the integration branch) prints the testnet address and the CLOSED error before, and neither
  after (the new lines: `[WARN] Health port TCP 43174 is open, although no monitor uses it on this
  network; Manage node ports (or --enable) closes it` / `->  Health port TCP 43174 stays closed:
  health monitoring is a testnet-only add-on`).
- Integration check: `hardening-followups` 224a6a4 exported, `git diff e32088a HEAD --
  firewall-setup.sh tools/tests/` applies cleanly (`git apply --check`, full context);
  check-network-hits clean (148 annotated hits, 23 files) rc 0; the V6 repro there shows neither
  line; full suite 61 files, 0 failed.
- Full suite on fup/FW (bash 5.3.9): 59 files, 0 failed.

## Tests run (round 3, committed tip e32088a)

- bash 5.3.9: firewall_reset 319 checks 0 failed 1 skip (real nft -c); firewall_signal 220/0/0;
  remove_test 340/0/0; root_write_pipe 2/0; passphrase_print 4/0.
- bash:3.2 (3.2.57): firewall_reset 317/0/3 skips (systemd-analyze, real nft -c, python3);
  firewall_signal 220/0/0; remove_test 340/0/0; root_write_pipe 2/0.
- ubuntu:24.04 root (bash 5.2.21): same counts as bash:3.2.
- bash -n (5.3 and 3.2) on firewall-setup.sh, remove-node.sh, fwstub.sh and the three tests: clean;
  check-bash32 clean; shellcheck -x --severity=error 0.11.0 and v0.9.0: rc 0; no new warning-level
  findings vs 6cbf52e in firewall-setup.sh or remove-node.sh; check-perl-interp rc 0.
- systemd-analyze verify --man=no on the unit rendered with /usr/sbin/nft: rc 0.
- Full suite on fup/FW (bash 5.3.9): 59 files, 0 failed.
- Integration check: `git archive hardening-followups` (02adda6) into a scratch dir, `git diff
  09e2862 HEAD -- firewall-setup.sh remove-node.sh tools/tests/` applied with `git apply -C1`
  (one hunk needed the context cut to 2 lines: OBS changed a comment 3 lines below my json_remove
  edit; a 3-way cherry-pick should take it cleanly). There: `bash tools/check-network-hits.sh`
  "clean, 148 annotated hit(s) in 23 file(s)" rc 0; full suite 61 files, 0 failed (remove_test 352
  with the OBS and NET-2 blocks, firewall_reset 319, firewall_signal 220).
- Each new check was run against the code before its fix (old tree in a scratch dir): the round-3
  firewall checks fail on 09e2862 (W1-W4, N1, N3: 40+ FAILs), the lock-held checks fail on the
  old code once on a testnet fixture (30 FAILs), the new remove_test checks fail on the round-2
  remove-node.sh (9 FAILs).

## Tests run (round 2, committed tip 09e2862)

- bash 5.3.9: firewall_reset 283 checks 0 failed 1 skip (real nft -c: host run is not root);
  firewall_signal 185/0/0; remove_test 326/0/0; root_write_pipe 2/0; passphrase_print 4/0.
- bash:3.2 (3.2.57): firewall_reset 281/0/3 skips (systemd-analyze, real nft -c, python3);
  firewall_signal 185/0/0; remove_test 326/0/0; root_write_pipe 2/0.
- ubuntu:24.04 root (bash 5.2.21): same counts as bash:3.2 (281/0/3, 185, 326, 2).
- ubuntu:24.04 + nftables 1.0.9 + `--cap-add NET_ADMIN`: firewall_reset 283/0/2 skips
  (systemd-analyze, python3); both real `nft -c -f` checks pass.
- `systemd-analyze verify --man=no` (systemd 259, host) on the unit rendered with /usr/sbin/nft in
  a temp dir: rc 0 (only notes about unrelated xfs_scrub host units); also a check inside
  firewall_reset_test.sh where systemd runs (host: ok).
- `bash -n` bash 5.3 and bash:3.2 on firewall-setup.sh, remove-node.sh, fwstub.sh and the three
  tests: clean. `check-bash32.sh firewall-setup.sh remove-node.sh tools/tests/fwstub.sh`: clean.
- shellcheck -x --severity=error 0.11.0 and v0.9.0 on those six files: rc 0; no new warning-level
  findings in firewall-setup.sh or remove-node.sh vs their bases. check-perl-interp: rc 0.
- Full suite `bash tools/tests/run.sh` (bash 5.3.9): 59 files, 0 failed.
- /64 proof: see F1 above.

## Tests run (round 1)

All on the committed tip 88c6dd6 (branch fup/FW: 66b8e4c, 88c6dd6 on 6cbf52e).
- `bash tools/tests/run.sh tools/tests/firewall_reset_test.sh tools/tests/firewall_signal_test.sh`
  (bash 5.3.9): reset 224 checks 0 failed 1 skip (real nft -c: non-root host); signal 166/0/0.
- `docker run --rm -v "$PWD:/w" -w /w bash:3.2 bash tools/tests/run.sh <same two>` (3.2.57):
  reset 223/0/2 skips (real nft -c; no python3 for the JSON parse check); signal 166/0/0.
- `docker run --rm -v "$PWD:/w" -w /w ubuntu:24.04 bash tools/tests/run.sh <same two>` (root,
  bash 5.2.21): reset 223/0/2 skips (same two); signal 166/0/0.
- Same in ubuntu:24.04 with nftables 1.0.9 installed and `--cap-add NET_ADMIN` (own netns):
  reset 225/0/1 skip (python3 only), the two real `nft -c -f` checks pass; signal 166/0/0.
- `bash -n` (bash 5.3 and bash:3.2) on firewall-setup.sh, fwstub.sh and both tests: clean.
- `bash tools/check-bash32.sh firewall-setup.sh tools/tests/fwstub.sh`: clean, 2 files (also
  clean with the two tests added: 4 files).
- `shellcheck -x --severity=error` 0.11.0 (host) and koalaman/shellcheck:v0.9.0 on the four
  files: rc 0. Warning severity: no new warnings vs 6cbf52e (one test SC2034 went away).
- `bash tools/tests/run.sh tools/tests/root_write_pipe_test.sh tools/tests/passphrase_print_test.sh`:
  both exit 0; `git ls-files -z '*.sh' | xargs -0 bash tools/check-perl-interp.sh`: rc 0.
- Full suite `bash tools/tests/run.sh` (bash 5.3.9): 59 test files, 0 failed.
- nft proof (S0): the rendered text for two ports at the defaults, one port at 30/5, and rate/burst
  extremes 1/100000, 100000/100000, 100000/1: `nft -c -f` rc 0 on nft 1.0.9 in ubuntu:24.04
  (`docker run --rm --cap-add NET_ADMIN -v "$S:/s" -v "$PWD:/w:ro" ubuntu:24.04 bash /s/real2.sh`,
  apt-get install nftables first). Without NET_ADMIN, `nft -c` fails ("cache initialization
  failed: Operation not permitted") for any program. Applied for real in that private netns:
  each written twice in a row rc 0; `fw_p2p_limit_sync` and `fw_p2p_limit_state` run against the
  real nft: "on 20 40", "on 7 5" after the overrides, delete then "off not-applied", no-node
  delete; the status parse reads the real listing. 1/999999999 (the first draft's bound) was
  refused by the kernel ("Value too large for defined data type"), so the bound is now 1-100000.

## Open issues

1. Set size 65535 per family: a spoofed flood of distinct sources can fill a set; then new sources
   go on to ufw unlimited (fail-open to the pre-limit behaviour). Documented, unchanged.
2. Env overrides are not stored (decision 6): the UI's enable and later plain enables go back to
   20/40. Documented, unchanged.
3. Stopping telcoin-p2p-limit.service (`systemctl stop`, shutdown) deletes the table on purpose.
4. The JSON field gained `persistent_reason` (round 3) besides `persistent` (round 2); UI-S must read
   them (shape above).
5. The update lock covers the P2P part of "Manage node ports" (open + table + boot copy); the
   health-port part of that menu (apply_kuma_rule, the testnet choices) runs after it without the
   lock, as before: it touches no table or boot copy and sits behind a prompt. Say if it should be
   locked too.
6. W5 was fixed in json_remove only. The menu's remove_keys has the same shred + `rm -rf` of
   /etc/telcoin, but the menu removes every node unit in one run (remove_all_nodes), so the last
   unit's remove_node_host_files tears the limit down whole; no partial state remains.
7. Pre-existing, not changed: when the node removed by `--json` keys has /etc/telcoin as its config
   dir while a legacy unit with /etc/telcoin/<role> remains, `rm -rf /etc/telcoin` takes the other
   node's config too (now everything but p2p-limit.nft). Outside FW; flagging it.

## Spec vs code

- Spec says to write the table inside `fw_p2p_allow`. It is written by `fw_p2p_limit_sync`,
  called by `apply_recommended_firewall` after the ufw apply finished. `fw_p2p_allow` runs in the
  middle of the ufw sequence, inside the snapshot/restore window, and from "Manage node ports";
  with the write after the ufw apply, a failed or interrupted ufw apply never changes the table.
- Spec: "`nft -c -f` ... parse-only, netlink unavailable". On nft 1.0.9, `nft -c` needs netlink
  (cache initialization) and CAP_NET_ADMIN; the proof ran with `--cap-add NET_ADMIN` in the
  container's own network namespace (no --privileged, host ruleset untouched). The fixture probes
  whether the nft it finds can run `-c` and skips the check otherwise.
- Anchors drifted on 6cbf52e: fw_src_list :410 (spec :401), apply_recommended_firewall :894
  (spec :866); the rest matched. `--status` without `--json` opens the menu (there is no CLI
  status mode); the status line is in the menu's status screen (view_status).
- "bad value -> rc 1 before anything changes": validated in fw_preflight even when a P2P list is
  set (then the values are unused).
