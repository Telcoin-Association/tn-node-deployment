status: done

# V-OPS-2-fw checkpoint (firewall-setup.sh 1.6.0 verification)

Harness: /private/tmp/claude-501/-Users-grant-coding-telcoin-tn-node-deployment/eddb430f-f0dc-43fe-9180-65cd421b1e88/scratchpad/vops2-tests/fw/
(tlib.sh helpers, drv.sh driver, mkfx.sh fixtures, shims/ shims-ufw/ shims-caddy/, libs/{head,d1593ae,fb5f6cd}, run/{new,old,newpre};
tests t_p2p.sh t_enable.sh t_json.sh t_view.sh t_prel1.sh; adv/ adversarial launch files)
Root paths: TN_ROOT_PREFIX=<fixture> for fallback resolvers, node_meta_path, FW_CADDYFILE, fw unit path; plus a
test-only rewrite of lib/common.sh DEFAULT_INSTALL_DIR and tn_node_launch_target's docker-unit fallback to
${TN_ROOT_PREFIX:-}/... (readonly / literal, not overridable). sshd_config read from the host (no Port -> 22).
check_root stubbed after sourcing ($EUID). ufw shim writes status in one write (see harness note).

## Sections
- [x] S1 read firewall-setup.sh + library functions
- [x] S2 shims + fixtures
- [x] S3 fw_p2p_ports fixtures (3.2, 5, mawk): t_p2p.sh 116/116; adversarial fw_listener_port 40/40; legacy validator 2/2
- [x] S4 enable with/without Caddy site; failing allow: t_enable.sh 60 pass / 8 fail (all 8 = F1)
- [x] S5 JSON: t_json.sh 244/244; pinned baseline sha256 3c7c152a0ea6e4a06650d2543caa3da28f3b95c6e55899547f897ac5e65f5119
      (d1593ae firewall 1.5.2 + d1593ae lib, fixture default, ufw active, rules 22/43174/49590/49594)
- [x] S6 view-status: old crash reproduced (rc 1 after "Firewall is active", both bashes); new t_view 54/54 (+2 no-node)
- [x] S7 pre-L1 soft guard: t_prel1 74/74; no tn_resolve_node_type reference; only tn_node_info_* missing pre-L1, both guarded
- [x] S8 prose
- [x] S9 implementer t_fw.sh: 124/124 under /bin/bash 3.2.57 and bash 5.3.15
- [x] S10 report handed back

## Findings
- F1 (warn, pre-existing in d1593ae): `--json --enable` with a failing `ufw allow` (22/tcp, 49594/udp, 49595/udp,
  80/tcp) exits rc 1 with EMPTY stdout (no error, no done event): set -e ends the script inside
  apply_recommended_firewall / fw_p2p_allow. Enable correctly NOT run. Interactive enable likewise exits silently.
- F2 (note, pre-existing): json_fw_status default_in pipeline lacks the `|| true` view_status got; with
  `ufw status verbose` failing, `--json --status` exits rc 1 with empty stdout (old+new). View path survives but prints
  "Default inbound policy:  (recommend: deny)" (empty value).
- F3 (note, prose): "Kept TCP 80/443 open" is now printed on a plain enable where the rules were just added; the
  follow-up line shows --json flags to a human.
- F4 (note): --json --status is one object with no done event (pre-existing UI contract); p2p_ports lists the
  default 49590/49594 (allowed false) on a box with no node while desired has no P2P rules (per fw_p2p_ports doc).
- Harness note: lib ufw_active = `ufw status | grep -q` under pipefail races a multi-write ufw (SIGPIPE 141,
  34/300 with a bash printf shim); real ufw writes once. Library scope, note only.
