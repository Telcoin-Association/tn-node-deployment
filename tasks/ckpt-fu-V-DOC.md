status: done

# ckpt-fu-V-DOC — independent docs verifier (coordinator)

On start, read this file and continue from the first unfinished section.

## Sections
- [x] Fan-out: V-DOC-R1 (README to "WireGuard"), V-DOC-O (OPERATOR.md + dry runs), V-DOC-P (partner
      guide + metadata), V-DOC-C (README Changelog, CHANGELOG, AGENTS, followup). Their checkpoints:
      tasks/ckpt-fu-V-DOC-{R1,O,P,C}.md (all status: done).
- [x] M1 flags after script names: 37 script/flag pairs, 133 uses, all in the parsers' case arms; table flags OK
- [x] M2 edit-config --set fields and vocabularies (8 fields) match set_field
- [x] M3 .node-meta keys, TN_* variables, --json keys: all exist and are emitted where described
- [x] M4 anchors and links (gfm slugs; the PDF build uses --from=gfm): none broken in the tree
- [x] M5 no line-number references; partner-guide rules pass
- [x] M6 `bash tools/build-partner-pdf.sh`: "PDF unchanged" (44 pages), no warnings
- [x] M7 external URLs
- [x] Merge + spot-check sub-verifier reports (R1-1, R1-3, R1-4, O-2, O-3, P-F2, P-F3, P-F4, C-W2, C-W3 re-checked)
- [x] Final report (below)

## Side notes
- `bash update-scripts.sh --help` does not print help: it ignores arguments and runs the real update check
  against GitHub (no TTY here, so it installed nothing; tree unchanged). Finding 18.
- *.sha256 mtimes changed at 02:47:16 with identical content (another agent ran gen-checksums).

## Final report

V-DOC: independent verification of the uncommitted docs (README.md, OPERATOR.md, docs/partner/mno-node-guide.md + metadata.yaml + PDF, CHANGELOG.md, AGENTS.md, followup.md) against the code in 7fb7c8d..HEAD. No repo file was edited except the checkpoints tasks/ckpt-fu-V-DOC*.md. No git writes.

Totals: 3 errors, 15 warns, 22 notes. I re-checked every error and the main warns against the code myself.

### Errors
1. README.md, Web UI "Long-running actions": "During the epoch wait nothing has changed yet, so stopping there leaves the node as it was."
   - Evidence: true for updates, false for config saves. edit-config.sh `run_set` calls `set_field`, which writes the launch file, parameters.yaml or peers file, and only then `edit_restart`, where the epoch wait runs. The EXIT trap `edit_on_exit` only releases the lock and emits `done ok:false`; it never calls `edit_restore_backups`. A save aborted during the wait (the tab is left and the server kills the script) leaves the edit on disk, unapplied and unchecked. The next restart or reboot loads it, with no rollback.
   - Fix: limit the sentence to updates. Add: "a config save has already written its change; stopping during its wait leaves it on disk for the next restart, so save again or set the old value back." Alternatively, make `edit_on_exit` restore the backups when the restart never ran.
   - OPERATOR.md and the guide (Web UI bullet: "Leaving the tab during the wait cancels the update…") are right about updates but say nothing about config saves (warn).
2. mno-node-guide.md, Public RPC chapter ("check-node.sh also warns when `--http.api` or `--ws.api` … names `debug`, `trace`, `admin` or `all`") and the troubleshooting row ("The node serves `debug`, `trace`, `admin` or `all` methods").
   - Evidence: check-node.sh `risky_api_modules` returns 1 for a list that starts with `all` and matches only debug, trace and admin. v0.15.0 maps `all` to eth, net, web3 and rpc. README and OPERATOR list only debug, trace and admin.
   - Fix: drop `all` in both places.
3. OPERATOR.md 2.6 and the guide (same paragraph): "use `5) Manage trusted IP whitelist` to add your own IP or range first, then remove the blanket SSH rule from the same menu." This is a security issue.
   - Evidence: firewall-setup adds the blanket rule with `ufw allow ${ssh_port}/tcp`, which creates an IPv4 rule and a `(v6)` twin. The whitelist menu's `2) Remove a whitelist entry` deletes one rule number per run (`ufw --force delete "$rule_num"`) and gives no (v6) hint. Followed literally, the text leaves SSH open to everyone over IPv6 while the operator believes it is restricted. V-DOC-O rated this warn; I raised it because the exposure is silent.
   - Fix: "remove both blanket SSH rules, the IPv4 one and its (v6) twin; list the rules again before the second delete, because the numbers shift."

### Warns
4. OPERATOR.md 2.2 step 6 and the guide (same item): "BLS passphrase protection (not asked for Docker). This menu comes after the source build (20 to 40 minutes) or the Docker install and image pull."
   - Evidence: the sentence contradicts itself. setup-node `step_preflight` shows the menu only when `INSTALL_METHOD != docker`.
   - Fix: "…after the source build (20 to 40 minutes), or for an existing binary once setup has found it."
5. OPERATOR.md Web UI and the guide (same text): "checks the sudo whitelist … with `visudo` before it changes anything … If a step fails, the running UI, its helper and its whitelist stay as they were."
   - Evidence: install-ui.sh installs Python, pip, Flask and the system user (steps 2–3) before the visudo check (step 5). It replaces the live helper at step 6, before steps 7–10. Its own step-11 comment says "Stopped after step 6: old sudoers, new helper". README's wording ("before it changes anything that is running", with the four pre-checks) is correct.
   - Fix: use the README's wording, and say that a later failure leaves the new helper with the old whitelist and the installer should be run again.
6. OPERATOR.md 5.2 and the guide ("New install" block): one copyable block has `setup-node.sh --rpc-domain "$DOMAIN"` and then the `--public-ip 203.0.113.10   # behind NAT` variant. Pasted whole, it runs setup twice. This predates the docs pass.
   - Fix: split the block, or turn the second line into `# or, behind NAT: …`.
7. README.md "Restarts and the epoch boundary": "Every script that restarts the node checks first".
   - Evidence: migrate-node-naming.sh stops and starts the node with no wait. The UI's Start/Stop/Restart buttons (`sudo /bin/systemctl <action>`), trace toggles and node-name change (`systemctl restart --no-block` in the helper) restart at once.
   - Fix: name the scripts that wait (update-node, edit-config, install-caddy, observability, prepare-stake `--rotate-address`) and say the others restart immediately.
8. README.md setup-node flags, last paragraph: "In `--json` mode every input is checked before setup requires root … a keygen without `--address` …".
   - Evidence: `init_node_inputs` checks only a malformed address. A missing one is refused in `step_generate_keys` ("--address is missing: keygen needs …"). That happens after `json_require_root`, after preflight (possibly a 20–40 minute source build) and after step 4 (user, directories, .node-meta).
   - Fix: drop it from the list, or add a pre-root check.
9. README.md "What rpc-enable does": "With a `lib/common.sh` older than 1.6.0, rpc-enable warns and runs without the epoch wait …".
   - Evidence: install-caddy gates the wait on `tn_wait_restart_window` and `tn_local_rpc_url` (`caddy_lib_has`). Both shipped in lib 1.5.0 (1e2d2f1).
   - Fix: "older than 1.6.0: no automatic `--ws` and the python3 editor; older than 1.5.0: also no epoch wait and no update lock."
10. README.md "Editing the configuration" (and the OPERATOR/guide menu tables): nothing says that Refresh chain configs (item 11) copies the network's parameters.yaml over the node's (`cp …/parameters.yaml "${node_data_dir}/"`). That drops an `allow_private_forward_targets` value set with item 10 or `--set`.
    - Fix: tell the operator to set it again after a refresh.
11. README.md "Converting a unit-started node to a start wrapper" and OPERATOR.md 4.8 ("Give a unit-started Docker node a start wrapper") cover only Docker.
    - Evidence: installs from before setup v1.1.22 (87379f3) also start binary and source nodes straight from the unit (`Environment="TN_BLS_PASSPHRASE=…"`, `ExecStart=<binary> node …`). edit-config refuses bootstrap_peers for them too.
    - Fix: name them and give the binary variant, or say to re-run setup-node.sh.
12. OPERATOR.md chapter 9, the `unexpected argument '--observer'` row: the manual fix names only `/opt/telcoin/start-telcoin.sh` and `systemctl restart telcoin`.
    - Evidence: legacy role-named installs, the likeliest to carry the flag, use `start-telcoin-<role>.sh` and `telcoin-<role>` (`tn_node_launch_target`).
    - Fix: add the legacy names, and say that check-node's warning names the exact file.
13. OPERATOR.md and the guide edit-config field tables say of `allow_private_forward_targets`: "It is refused on testnet and mainnet". The guide's staking requirements also say "testnet and mainnet refuse it".
    - Evidence: `set_private_forward_targets` checks the chain id only for `true`. `false` is accepted everywhere, and is a no-op when the key is absent. README's table is precise.
    - Fix: "edit-config.sh refuses `true` on testnet and mainnet."
14. README.md "Validator Onboarding Flow": "Full staking guide: https://docs.telcoin.network/telcoin-network/staking/how-to-stake" returns HTTP 404 (the site root returns 200). The URL predates this pass but sits on an edited line.
    - Fix: drop it or point at the live page.
15. CHANGELOG.md Security has no bullet for update-node refusing refs that start with `-`.
    - Evidence: e28e8e5 added the guard for `--json --ref` and f9c47df for the interactive prompt; 7fb7c8d had no guard. This is option injection into git and docker running as root. It appears only under "Updates and restarts".
    - Fix: add a Security bullet.
16. AGENTS.md boundary-rule list leaves out `open-ui.sh`, an operator-facing script that runs on the operator's laptop.
    - Fix: add it next to `install.sh`.
17. followup.md "Maintainer tooling and CI": "Advisory shellcheck warnings remain: SC2206 in firewall-setup's `kuma_restricted_desc`, and SC2034 … in setup-observability and `lib/observability.sh`."
    - Evidence: `shellcheck -x --severity=warning $(git ls-files '*.sh')` reports about 30 warnings in 12 files: lib/common.sh 13, remove-node 5 (including 2× SC2115), update-scripts 2× SC2206, update-node 2× SC1090, and others.
    - Fix: list them, or scope the item to the files it names.
18. followup.md "`--help` gaps" leaves out update-scripts.sh, which ignores every argument.
    - Evidence: `update-scripts.sh --help` runs the real update check against GitHub, and on a TTY asks "Download and install all updates? [Y/n]" with yes as the default. I triggered it once while capturing help text; with no TTY it installed nothing.
    - Fix: add it to the item. In the script, answer `--help` with usage.

### Notes
19. README "Restarts…": "Observers and validators outside the current committee are not delayed" is narrower than the code. Only a node reporting `CvvActive` waits, so a committee member reporting `CvvInactive` is not delayed either.
20. README: "a source checkout at a release tag cannot git pull, and refresh says so". Refresh actually prints git's error plus "git pull failed in <dir>. Chain configs unchanged.", and never names the tag. This is the normal case for a testnet source build.
21. README, Bootstrap peers: "refused … before anything else happens". The launch-file, unit and absolute-path checks run first. Better: "before the map reaches the node binary".
22. Prepare-stake exit tables (README and guide) have three gaps:
    - no row for a declined rotation confirmation (exit 3, "Cancelled: nothing changed.")
    - no row for a failed keytool export (exit 2, "keytool could not export the stake() calldata …")
    - no row for a successful rotation (exit 0, "Rotated: …")

    The guide's exit-2 advice ("check the server's internet access") also does not fit the keytool case.
23. README quotes "To finish, run ... --rotate-address <new> --yes". The script prints "To finish, run: sudo bash prepare-stake.sh --rotate-address <0xNEW> --yes".
24. README "What the Setup Script Does" lists "Step 2: Network Selection", but setup picks the network inside Step 1 (`step_network` is never called; the headers go from Step 1 to Step 3). This predates the docs pass.
25. README Web UI validator view says the seat shows "in one of the next three". The server checks `(epoch, epoch+1, epoch+2)`, so it should read "this epoch or the next two".
26. README setup-node flags intro says the remaining flags are for `--json` runs. `--binary-path` also works interactively for an existing install.
27. README (the setup-node floor bullet and the lib/common entry) and lib/common.sh's refusal message: "v0.13.0-adiri, the first release with `keytool set-rpc`, proof-of-possession signing and state export" can read as set-rpc arriving in v0.13.0. It arrived in v0.12.0, as README's public RPC section says. Fix: "the first release that has all three".
28. README Security model: "renames it over the live drop-in as its last step". Step 12 (start/restart) follows the rename. The rest is accurate: `visudo -cf` at step 5, `mv` at step 11, and the EXIT trap removes a rejected candidate.
29. OPERATOR 1.5: the edit-config refresh takes only the network from `.node-meta`, not the public RPC.
30. OPERATOR 4.7: remove-node removes the service and container right after `Proceed with node removal?`; the per-item prompts start at the Docker image.
31. OPERATOR's chapter 3 example, 6.2 and the chapter 9 row say `rpc.telcoin.network` serves 2017 but leave out "(mainnet has not launched)".
32. OPERATOR 7.3: `TN_ASSUME_YES=true` also answers destructive prompts, such as `Remove chain data?`. Keys stay behind the typed DELETE.
33. OPERATOR 2.5 "regenerate keys and carry on" is about lost keys and works. V-DOC-O rated it warn; I downgraded it to a note. The real defect is in the script: answering Yes to `Overwrite existing keys?` always ends "Key generation failed.", because setup-node passes no `--force` and the v0.15.0 keytool refuses a non-empty `node-keys/`. This is a followup candidate. A doc hint could say: move `node-keys/` and `node-info.yaml` aside first.
34. Guide: "A `cast send` that reverts returns the same names". cast shows the error selector, and the name only when it can decode it.
35. Guide shows repo internals a partner cannot act on: "lib/common.sh and lib/fallback.sh are installed together or not at all", and "the script's `EVM_SYNC_THRESHOLD`".
36. CHANGELOG has three small gaps:
    - optional Security bullets for 1540751 (observability input validation) and 7acc653 (the 2 MB cap)
    - the "Updates and restarts" list leaves out prepare-stake `--rotate-address`
    - the intro's "every script below through update-scripts.sh" also covers install.sh and the tooling, but each entry says so in place
37. AGENTS.md has three small gaps:
    - the epoch-boundary paragraph leaves out prepare-stake
    - "before it stops the node or edits the files the restart depends on" reads as wait-before-edit, but edit-config and observability write the launch file first
    - the CI sentence leaves out Linux `bash -n`, shellcheck errors and the UI test job
38. README changelog: the install-caddy v1.3.0 correction paragraph is one unwrapped line of about 160 characters, and the update-scripts v1.1.70 entry leaves out "a failing `clear` no longer ends the run" (3c78a6d).
39. Pending push, not errors. The guide links to `blob/main/prepare-stake.sh`, which returns 404 today because origin/main is 29 commits behind. It also links to README anchors `#bootstrap-peers`, `#editing-the-configuration` and `#public-node-tuning`, which exist only in the uncommitted README. All three resolve once the docs commit is pushed.
40. Script issues found along the way (followup candidates):
    - update-node.sh tells an `existing` install to "replace the file at /opt/telcoin/telcoin-network manually", but since setup-node 1.3.0 the node runs the recorded `BINARY_PATH`.
    - The lib/fallback.sh deprecation comment is stale; followup already tracks it.

### Mechanical sweeps (all passed)
- **Flags and fields:**
  - Every `--flag` after a script name is in that script's `case` arms (37 pairs, 133 uses); table flags are fine.
  - All 8 edit-config `--set` fields and their vocabularies match `set_field`.
  - Every `.node-meta` key named is written by `write_node_meta` (NODE_TYPE is removed, as stated).
  - Every `TN_*` variable exists.
  - The JSON keys are emitted where described: `done`, `operator_guide`, `public_rpc{enabled,domain,http,ws}`, `p2p_ports{port,proto,label,allowed}`, `block_stale`, `role_source` network/local/cached/default, `seat_epoch`, `meta_domain`, `helper`.
- **Messages:** 36 code-font messages in troubleshooting and "prints/warns" contexts match the sources apart from placeholders.
- **Links and anchors:** every intra-doc anchor (89 in the guide, 44 in README and OPERATOR) and every cross-doc link resolves under gfm slug rules (the PDF build uses `--from=gfm`), and every repo URL points at a tracked file.
- **Line numbers and partner rules:** no line-number references anywhere. The guide has none of the banned terms, one `#` title, no prose before the first `##`, no numbered headings, and only support@telcoin.org as contact. metadata.yaml is 1.1 / 2 October 2026 with no `title:` key.
- **PDF build:** `bash tools/build-partner-pdf.sh` printed "PDF unchanged" (44 pages) with no warnings; sha256 is unchanged.
- **Facts:**
  - **Chain and endpoints:** chain ids 2017/32285/487; rpc.adiri.tel answers 0x7e1; rpc.telcoin.network answers 0x7e1 today; rpc.devnet answers 0x7e1d; telscan.io and www.telscan.xyz are up; the registry address and selectors match.
  - **Staking:** the stake is 1,000,000 TEL, and E→E+1→E+3 matches.
  - **Timing and limits:** epochs are 21600 s / six hours. The epoch wait is 300/90/1800 with the poll at 15 clamped to 5–20. The 2 MB cap = 2,000,000 bytes, and 413 was confirmed live on Caddy 2.8.4 and 2.11.4. The Caddy floor is 2.8.0, and the newest five backups are kept.
  - **Release floors:** the testnet floor is v0.13.0-adiri; set-rpc arrived in v0.12.0, state export in v0.13.0, `--state-export-keep` and `--bootstrap-peers` in v0.15.0.
  - **Script details:** edit-config menu items 5/11/12/13 match, as do the prepare-stake exit codes 0–4 and 129/130/143 and helper API 2.
  - **Changelog versions:** every changelog version matches its constant. update-scripts 1.1.70 versus 1.1.69 on disk is expected, and nothing is off by one.
- **Dry runs:**
  - The `cast` reads against rpc.adiri.tel read as documented (balanceOf 1; getValidator 7 words with status 3; stakeConfig 1e24…21600; the STAKE capture is exact).
  - The keytool export line as written (`-q --bls-passphrase-source no-passphrase … --calldata`) on the v0.15.0 build gives exactly one line starting 0x2fb0d025, and the doc's check prints "calldata OK". Without `-q` it gives two lines.
  - `set-rpc` needs no passphrase and edits `workers[0].rpc` only; `--clear` restores the file byte for byte.
- **Other checks:**
  - The README Security model order matches install-ui.sh.
  - AGENTS.md: the updater arrays (35 entries) match the committed sidecars exactly, nothing AGENTS.md calls maintainer-only is tracked, and AGENTS.md has no sidecar.
  - The CHANGELOG Security bullets each map to commits (2c423dc/d1593ae, babb69d/9df76cb, 8185d00/8c69378/59d10a0, 2025ea3/8feb576, 823e149, 3c78a6d, f918d4f/77e043b, ea86e22/f9c47df).
  - About 45 followup items were sampled: all are still open apart from finding 17, and every addition the docs notes asked for is present.

### Verdict per file
- **README.md:** Accurate for most of the new text: the prepare-stake rules, epoch-wait table, edit-config vocabulary, bootstrap peers, Caddy block v2, install-ui order, every changelog version and the commit claims. Fix one error (1) and six warns (7–11, 14) before commit. The notes are polish.
- **OPERATOR.md:** Every quoted message is in the scripts, and the staking, keytool and set-rpc commands work as written. Fix one error (3, shared with the guide) and the warns 4, 5, 6, 11, 12 and 13. Also add the config-save caveat from finding 1.
- **docs/partner/mno-node-guide.md:** Accurate apart from error 2 (`all`) and the shared error 3. Fix warns 4, 5, 6 and 13 too. The partner rules pass and its dry runs passed. After editing, rebuild the PDF. metadata.yaml's uncommitted 1.1 / 2 October 2026 bump already covers further edits before the commit.
- **metadata.yaml:** Correct.
- **CHANGELOG.md:** Versions and Security bullets are correct and tied to commits. Add the dash-ref Security bullet (15).
- **AGENTS.md:** Accurate against the tree and the updater arrays. Add open-ui.sh (16); the notes are optional.
- **followup.md:** Lists only open work. Correct the shellcheck item (17) and the `--help` item (18). Consider adding the script candidates from 1 (if the script is not fixed), 8, 33 and 40.

### Files the docs commit must include
README.md, OPERATOR.md, CHANGELOG.md, AGENTS.md, followup.md, docs/partner/mno-node-guide.md, docs/partner/metadata.yaml, docs/partner/mno-node-guide.pdf. Rebuild the PDF after any guide fix and commit it with its sources.

Do not include tasks/ (tasks/lessons.md included), .claude/, .DS_Store, docs/.DS_Store or docs/partner/build/ (gitignored). Docs have no `.sha256` sidecars. The update-scripts.sh 1.1.70 bump and its sidecar belong to the release commit.
