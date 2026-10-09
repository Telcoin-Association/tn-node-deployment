status: done
agent: V-OPS-1 (independent verifier, install-caddy.sh 1.4.0 @ 7acc653 on lib/common.sh 1.6.0 + uncommitted flock-release diff)
harness dir: <scratchpad>/vops1-tests/ (h.sh helpers, driver.sh, shims/, caddyshim/, work*/ path-rewritten copies, live/ stubs + client, t2_live.sh t3.sh t4.sh t5.sh t67.sh t8.sh t9.sh)
path override: copy with only `readonly CADDYFILE`/`CADDYFILE_ORIG` rewritten to ${TNV_FIX}/etc/caddy/...; TN_ROOT_PREFIX for /etc/telcoin, data dir and unit; driver stubs check_root and a prefix-aware tn_node_launch_target (DEFAULT_INSTALL_DIR is readonly); tn_wait_restart_window recording stub (off for item 8).

completed sections:
- [x] 1 block v2 rendering: validate + fmt-stable (fmt output byte-identical, --diff empty) on caddy 2.11.4 and 2.8.4; page rules hold; request_body only in default handle; adapt: 405 static, header !Upgrade, (?i) regexps
- [x] 2 live: t2_live.sh 19/19 on 2.11.4 and 19/19 on 2.8.4
- [x] 3 phases/JSON: t3.sh 36/36 on 3.2 and 5.3
- [x] 4 advertise flow: t4.sh 49/51 both bashes (2 fails = finding 1)
- [x] 5 ws preflight: t5.sh 29/29 both bashes
- [x] 6+7 meta/backups/ports/version: t67.sh 24/24 both bashes
- [x] 8 pre-L1 degradation: t8.sh 20/20 both bashes
- [x] 9 adversarial: t9.sh 16/16 both bashes + reports
- [x] 10 static: bash -n 3.2/5, shellcheck -x clean at every severity, check-bash32 clean, no common/ text, no --observer/--validator
- [x] 11 cross-check: t_a 111/111 (3.2, 5.3), t_json 121/121 (3.2, 5.3), t_live 60/60
- [x] 12 prose

## Tests run
See sections. Extras: real tn_wait_restart_window integration emits valid log events; interactive menu enable/disable smoke on both bashes; probes for findings 1, 2, 3, 5, 7.

## Open issues (findings, no error-level)
1. warn: restart-guard / advertise warnings use print_* not caddy_say -> absent from --json stream (node-info missing, no service, RPC not answering, launch restored, restart progress); run ends done ok:true.
2. warn: rpc-disable un-advertises (epoch wait + restart + guard) before removing the vhost; the public endpoint stays live through the wait.
3. warn: caddy_validate_domain accepts IPv4 literals and uppercase without normalising (UI/helper refuse ^[0-9.]+$ and lowercase); uppercase defeats keytool read-back -> python writes uppercase.
4. warn: no update lock; rpc-enable edits the launch file and restarts while another process holds tn_acquire_update_lock.
5. note: epoch wait runs before a launch edit that turns out refused/no-op; with node-info unchanged the run waits then changes nothing.
6. note: 3 MB POST: upstream gets 2,000,000 bytes then the cut (never complete); C.5 "never reaches the stub" not literal.
7. note: do_check_dns_json does not validate the domain (-f/etc/hosts reaches dig as an option); UI/helper validate first.
8. note: trailing value-less flag -> shift 2 under set -e -> silent rc 1, no done, no message.
9. note: json_escape leaves other control characters unescaped (latent).
10. note: workers 1+ advertised by 1.3.0 stay advertised after rpc-disable (spec'd worker-0 semantics).
11. note: hand-edited v2 block -> block_stale false; kept by dashboard toggles; overwritten by same-host rpc-enable (backup has it).
12. note (prose): page and human status always show wss://; rollback die text; "version ()"; JSON step text says restarting when none follows; steps emitted before a clash refusal.
