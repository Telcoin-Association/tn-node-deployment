status: done

Orchestrator checkpoint for the follow-ups round: what the orchestrator changed itself (beyond
the packages), the facts DOCS needs that no package checkpoint carries, and the follow-up items
collected from every hand-back. DOCS reads this with the package checkpoints
(`tasks/ckpt-fup-*.md`) and the verifier records (`tasks/verify-fup/*/`).

## Orchestrator changes on the integration branch (not in a package checkpoint)

- edit-config: a passphrase move (`--migrate-credential`, `--reseal`, the passphrase change)
  that ends rc 0 makes the host baseline again (`edit_cred_report` calls
  `edit_baseline_refresh`); not after a refused verify or a rolled-back switch. (c4322d4)
- setup-node, update-node, edit-config: `tn_mainnet_enabled` is in setup-node's required-helper
  list; the resolver comment and edit-config's `--json` and menu image refusals on mainnet say
  "give a mainnet release tag; a digest alone is taken only for a mainnet release this node has
  installed" (ac9a605, 8e2b533).
- setup-node `_preflight_docker`: on mainnet a `--docker-image` digest, or a digest typed at the
  prompt, is taken only when `.node-meta` records it as the image of a mainnet release
  (`tn_docker_resolve_ref`); the message: "Image refused (see above): on mainnet give the release
  tag with --release-tag, so the image comes from the signed release. Nothing on this host was
  changed." An image resolved from a release tag, or the newest release's, is not re-checked.
  (8e2b533; V1 ERROR-1)
- remove-node: the custom-container scan (`custom_container_lines`) also lists containers that
  run the ghcr repository image, by digest or by a mainnet tag, and offers each for removal.
  (6f06473)
- tools/tests/lib.sh: the BSD `stat` shim maps `%Y` to `%m` (the macOS CI runner); the library
  keeps plain GNU `stat -c`. ui/tests/install_ui_test.sh runs its administrator cases only with
  busybox `adduser`; both UI shell tests launch the script under test with the test's own bash.
- Verifier records: `tasks/verify-fup/V1..V6/` are committed as records; CI lints them like
  every tracked script.

## Facts for DOCS

- Versions at release prep (orchestrator, after DOCS): every updater-tracked script that changed
  goes to 2.1.0: check-node, edit-config, firewall-setup, install-caddy, remove-node,
  setup-node, setup-observability, setup-vpn, update-node, update-scripts, ui/install-ui
  (comment-only annotation; still a tracked change), `COMMON_VERSION` 2.1.0,
  `OBSERVABILITY_VERSION` 2.1.0 (config.alloy changed), `UI_VERSION` 2.1.0. `lib/fallback.sh`
  and `lib/testnet-addons.env` are unchanged. install.sh changed (expiry warning) and is a
  release file, not an array entry.
- `sha256(observability/config.alloy)` for the sync note is computed by the orchestrator at
  release prep (NET-2's header markers changed it after OBS measured 4c1527db…); DOCS writes the
  value the orchestrator hands over, and the upstream reference is deploy-networks-common
  branch `alloy-token-file-tls` 30a2813 (PR #8), "pending merge".
- The partner guide version is 1.6 (1.5 is on main from PR #58).
- Issue closing policy (user): this PR closes #47 only; #34 is closed already; the other 15
  stay open as trackers (comments posted 2026-11-03).
- Deferred to their own PRs: #39 (UI oneshots), 2-of-N signatures (#40), the committee
  address-manifest reader (#41).

## followup.md items collected this round (DOCS writes them; wording is theirs)

- setup-node `setup_keep_stored_passphrase` keeps a found `.cred` without decrypting it or
  checking it against the key; a `keytool verify` step belongs there once #1730 lands (KEYS).
- `tn_node_has_flag` has the same probe shape `tn_keytool_has` had before K-1 (a wrapper
  failure reads as "flag absent"); not changed (KEYS).
- Nothing runs `aide --check` on a schedule; `ui/telcoin-ui-helper.sh cmd_setup` does not pass
  `--host-baseline`; the audit rules are written before the AIDE step, so a failed init leaves
  the rules and no marker (status says so; the next `--host-baseline` run completes it) (AUDIT).
- The firewall's health-port edits in "Manage node ports" run without the update lock (FW).
- A `--json` keys removal of a node whose config dir is /etc/telcoin, while a legacy unit with
  /etc/telcoin/<role> remains, removes that other node's config too (pre-existing; FW).
- The UI does not render `persistent_reason`; the P2P sources field is only in the enable form
  (UI-S).
- A spoofed flood of 65535 distinct sources fills the nftables set; new sources then pass on to
  ufw unlimited (today's behaviour) (FW).
- Non-ASCII digits in `serial` (and `--expires DAYS`) stop the updater with an arithmetic error
  instead of "malformed"; fails closed (REL).
- Mainnet operators see testnet tag forms and adiri hostnames as examples in 13 messages
  annotated "shown on every network" (NET-2/V6 list); a neutral example host and per-network
  tag examples would remove the markers.
- `install_ui_test.sh` runs as the CI runner user, so only its non-root check gates (V6 N8).
- Upstream consumers of config.alloy (docker-compose.yml, start-*-node.sh heredocs) still use
  the environment token (deploy-networks-common PR #8 says so).
- Issue #30's ruleset JSON lacks the two contexts and `require_code_owner_review` is false
  until a second owner exists (user step; the #30 comment says so).
