# Public RPC follow-ups

Loose ends from the install-caddy 1.3.0 / setup-node 1.1.0 change set. Not tracked by
the updater; no sidecar. Line numbers are as of 2026-09-30 (install-caddy.sh was still
being edited, so trust the function names over the numbers).

## Node Manager UI

- Setup wizard: the Public card is still disabled "coming soon"
  (`ui/static/index.html:2814`). Enable it and ask for the public RPC domain (+ optional
  inbound IP), then pass `--rpc-domain` through `ui/server.py:2837`/`:2886` and
  `ui/telcoin-ui-helper.sh:673`.
- Stop sending `--rpc-public true` without a domain (`ui/telcoin-ui-helper.sh:673`,
  fed by `rpc_public` at `ui/static/index.html:2899`). setup-node 1.1.0 now warns and
  stays private when that arrives alone.
- RPC card: add an "advertised" badge from the new `rpc-status` keys
  (`advertised_http`, `advertised_ws`, `ws_listening`) in the enabled view
  (`ui/static/index.html:2241`); swap the `rpc.example.com` placeholder (`:2255`) for
  the node's own name (`nodeN.<suffix>`).
- Dashboard card: warn that its hostname must differ from the RPC name and suggest
  `dashboard.<node-domain>` (`ui/static/index.html:2118`, placeholder at `:2123`).
- Pass `--move-dashboard-to`: `cmd_rpc_enable` (`ui/telcoin-ui-helper.sh:525`) and the
  `rpc-enable` call in `ui/server.py:3125` accept only domain + IP today, so the UI
  can't resolve the same-domain clash install-caddy now reports.

## Scripts

- `lib/common.sh:1967` `tn_node_inject_flags`: the awk matches the first line with
  `--http`, comment lines included. install-caddy guards against that with its own
  check (`caddy_launch_inject_target`, `install-caddy.sh:1138`); the helper should skip
  comments itself so other callers (setup-observability, lib/observability) are safe.
- `lib/common.sh:144` `confirm()` uses `${response,,}`, which is a bad substitution
  under bash 3.2, so any interactive `confirm` breaks on macOS `/bin/bash`.
  Pre-existing; use `tr '[:upper:]' '[:lower:]'`.
- `install-caddy.sh:539` (`caddy_swap_in`) writes a new `Caddyfile.bak.<ts>` on every
  swap and never prunes them. Keep the last N, or document a cleanup.
- `firewall-setup.sh:282` (`apply_recommended_firewall`): only `--reset` re-adds
  80/443. If Caddy was set up while ufw was off, `caddy_open_ports`
  (`install-caddy.sh:379`) skipped them, and a later non-reset enable leaves 80/443
  closed under a live site.
- `check-node.sh:670`: the wss probe waits the full `--max-time 8` on a healthy node,
  because a successful upgrade keeps the connection open. Stop reading after the
  status line, or use a shorter timeout for the 101 case.
- `install-caddy.sh:1004` (`caddy_restart_node_guarded`): `rpc-enable` restarts the
  node without checking for an upcoming epoch boundary. Only matters for committee
  members; consider warning or waiting when the node is in the committee.
