status: done

# ckpt-fup-AUDIT-2

## Sections
- [x] 0. Read specs, AUDIT checkpoint, AGENTS sections, lessons, lib helpers
- [x] 1. install-caddy.sh refresh point (8c1e773)
- [x] 2. firewall-setup.sh refresh point (d492708)
- [x] 3. setup-vpn.sh refresh point (73c1b81)
- [x] 4. setup-observability.sh refresh point (fc9632b)
- [x] 5. Tests (host_baseline_test.sh AUDIT-2 block; firewall_signal_test.sh, firewall_reset_test.sh) (a33ca19)
- [x] 6. Gates (all green, see Tests run)

## Plan (from section 0)
Principle: refresh after each successful operation that writes (or may write) a file the
AIDE config covers (/opt/telcoin, /usr/local/libexec/telcoin, /etc/telcoin minus the
credential and alloy/ingest-token, the node unit, the binary). An operation that only
writes outside those paths does not refresh (a refresh with no legitimate change would
only absorb whatever else changed since the last baseline).
- install-caddy: caddy_baseline_refresh (caddy_wait_say) at the end of do_rpc_enable and
  do_rpc_disable, before caddy_node_unlock (lock still held). Every rpc path (json, phase,
  menu) runs through them; die exits before. Dashboard enable/disable: no refresh (Caddyfile,
  /etc/caddy, caddy drop-in, apt files and ufw only).
- firewall-setup: fw_baseline_say + fw_baseline_refresh; after the persist block in
  enable_firewall, json_fw_enable (before the done event), main --enable/--reset; after
  fw_p2p_limit_sync in manage_node_ports; after kuma_extra_add/remove success.
- setup-vpn (no --json): tn_host_baseline_refresh with no FN (print_* by level); after
  install_selfheal_units in do_enable, after the VPN_MAINTAINER_ROOT meta_set in
  do_sync_keys, after the ENABLE_VPN=false write in do_disable.
- setup-observability: so_baseline_refresh (addons_say) after addons_say; before json_done
  ok:true in run_json_mode; in run_rotate_cli after the rotate; menu actions' success
  branches. Avoid OBS hunks (so_on_exit before run_rotate_cli, main trap lines).

## Operator-visible changes
- On a host with HOST_BASELINE=true, the four add-ons now make the AIDE baseline again
  (aide --update, new database moved into place) after a change that went through, so
  `sudo aide --config=/etc/aide/telcoin-node.conf --check` no longer lists their own
  writes. The lines are the library's: "AIDE baseline made again after the change:
  /var/lib/aide/telcoin-node.db" (info/log) or a warning; in --json runs they are log/warn
  events before the done event. A failure is a warning; exit codes and done events are
  unchanged. Without the marker, or with an older lib/common.sh, nothing is printed.

## Docs notes
Refresh points (add to the update-node/edit-config list in OPERATOR/README "host baseline"):
- install-caddy.sh: after an rpc-enable or rpc-disable succeeds (every path: --json
  rpc-enable/rpc-disable, --phase, the menu), the baseline is made again, after the
  .node-meta PUBLIC_RPC_* write, the node launch / node-info.yaml edit and the restart,
  before the update lock is released. The dashboard site (enable/disable) does not
  refresh: it writes only /etc/caddy, Caddy's systemd drop-in, the apt source and ufw.
- firewall-setup.sh: after the recommended defaults are applied (menu option 2,
  --enable, --reset, --json --enable; after the SSH_ALLOW_FROM/P2P_ALLOW_FROM lists are
  stored), after Manage node ports opens the P2P ports (the limit file
  /etc/telcoin/p2p-limit.nft rewritten or removed), and after a health-port source is
  added or removed (KUMA_EXTRA_SRC), the baseline is made again. --json --port and the
  SSH/whitelist screens write nothing the baseline covers.
- setup-vpn.sh: after the enable flow succeeds, after --sync-keys with
  --grant-maintainer-root / --revoke-maintainer-root (VPN_MAINTAINER_ROOT), and after
  --disable (ENABLE_VPN=false), the baseline is made again. --sync-keys without a root
  flag, --selfheal and --apply-firewall write only /etc/wgvpn, sudoers, the self-heal
  units and ufw, and do not refresh.
- setup-observability.sh: after each change that went through, the baseline is made
  again: in --json mode once, after all requested actions and before the done event; after
  --rotate-token; in the menu after enable/disable log or metrics shipping, Rotate the
  ingest token, Enable health monitoring (once --healthcheck is on the node command and
  recorded) and Disable health monitoring. alloy/ingest-token stays excluded.
- Not after: a refused or failed operation (die/exit/json_fail/ok:false paths), a
  cancelled prompt.
- Open issue 6 of the AUDIT checkpoint ("the add-ons ... outside the refresh points") is
  closed by this package; "nothing runs aide --check on a schedule" still holds.

## Tests run
- host_baseline_test.sh: bash 5.3 169 checks 0 fail 3 skip (not root); bash:3.2 178/0/1;
  ubuntu:24.04 root 178/0/1. The AUDIT-2 block is 46 checks, none skipped anywhere.
- firewall_signal_test.sh 204/0/0 and firewall_reset_test.sh 286/0/1 (bash 5.3),
  284/0/3 (bash:3.2, ubuntu:24.04).
- Fixtures that source the four scripts (host_baseline, caddy, restart_window, addon_oldlib,
  firewall_signal, firewall_reset, remove, sshd_dropin, vpn_enable, vpn_selfheal, obs) plus
  root_write_pipe and passphrase_print: bash 5.3 13 files 0 failed (1797 checks, 4 skip);
  bash:3.2 13/0 (1791, 8 skip); ubuntu:24.04 root 13/0 (1791, 8 skip). obs_test with
  TN_UPSTREAM_ALLOY_CONFIG (mounted read-only into the containers).
- Full suite bash 5.3: 61 files, 0 failed (4904 checks, 53 skip).
- bash -n (5.3 and bash:3.2), tools/check-bash32.sh, shellcheck -x --severity=error 0.11 and
  koalaman/shellcheck:v0.9.0 on the four scripts and the three tests: clean.
  check-network-hits.sh rc 0; check-perl-interp on every tracked *.sh: clean.
- Mutants (each restored from a backup copy afterwards): no refresh in do_rpc_enable; obs
  refresh after the done event; fw_baseline_say ignoring --json; a refresh on the vpn
  disable cancel path; the obs refresh without its declare -F guard; no refresh in the
  firewall CLI path and in Manage node ports: every one fails a check.
- OBS cherry-pick check: `git diff 3b760cc fup/OBS -- setup-observability.sh` (so_on_exit,
  the menu trap) applies to this branch's file with patch --dry-run, 3 hunks, offsets only.

## Open issues
1. setup-observability.sh has no common success point for the menu: each action
   (enable/disable logs and metrics, rotate, enable/disable health) reports its own
   result and returns 0 either way. So the file has 9 call lines, not one: 7 added lines
   (two as an else branch) and 2 one-line ifs extended with `so_baseline_refresh;` in
   enable_logging and enable_metrics. None is near OBS's hunks (so_on_exit before
   run_rotate_cli, the trap lines in main); the dry run above applies cleanly.
2. Tests for setup-observability live in host_baseline_test.sh, not obs_test.sh, which
   already drives rotate_token and run_json_mode: OBS's branch appends a 155-line block
   before obs_test.sh's finish and edits the rotate tests, so an addition there would
   conflict at cherry-pick. caddy_test.sh and vpn_enable_test.sh do not drive the
   rpc-enable/disable or enable/sync/disable flows, so those drivers are new too.
3. Pre-existing, not changed: firewall-setup's Manage node ports (p2p-limit.nft) and the
   health-port source edits (KUMA_EXTRA_SRC through meta_set) write without the update
   lock, and an apply without a source list holds no lock either; their refresh therefore
   runs without it too. A refresh racing update-node's could leave a stale database
   (status and --check say so; `sudo ./setup-node.sh --host-baseline` makes it again).
   Taking the lock there changes when the menu blocks update-node; left for FW to decide.
4. firewall-setup --json --enable refreshes after an apply that returned 0 and the lists
   are stored, before it reads `ufw_active` for the done event's ok; a host where ufw is
   inactive right after a successful `ufw --force enable` gets ok:false with the baseline
   already matching the files written.
5. AUDIT checkpoint Open issue 6 (add-ons outside the refresh points) is closed by this
   package; DOCS should drop that caveat and keep "nothing runs aide --check on a schedule".
