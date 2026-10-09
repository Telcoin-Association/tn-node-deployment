status: done
completed:
- [x] 0. backups: v-sn/harness.sh.pre-v-sn2, v-sn/tpl/install-caddy.sh.pre-v-sn2
- [x] 1. classified all 19 original FAILs -> all (i) obsolete expectation / fixture artefact; no setup-node.sh defect
  - G2 F-pubbare/F-pubtrue/F-pubyes JSON x2 (6): bare --phase=finalize w/o keygen/UI argv -> "Node binary not found" rc1 after the correct log event
  - G2 F-pubbare-int x2 (2): EMPTY stdin -> script (correctly) continues to welcome; bash32 also hit lib common.sh:144 ${response,,}
  - G5 S1b*/S4hb*, G6 I1b* (6): perl rewrite skipped lib fallback.sh printf '%s/etc|var/...' + common.sh ${TN_ROOT_PREFIX:-}/etc -> resolver probed HOST /var/lib/telcoin
  - G5 S6b* (4): spec 2 NODE_STARTED gate -> step proceeds; G5 I2 (1): reason text changed
- [x] 2. harness updated: seam S1b (lib rewrite + WARN), stub install-caddy via lib tn_resolve_data_dir (+FX_DNS=spaced, skip if ni missing, $STUBLOG.ni), G2 nodomain_json/nodomain_int/pubcase_dom + value-missing x3 both modes + TRUE/Yes +/- domain + --rpc-domain "" + label63/64 + F-uitrue; G5 S1 tightened (--public-ip space form, ni path), S4h exact path, S6 new semantics, S8 custom data-dir, S9 spaced DNS; G6 I2/I2n/I2act declined-start gate
- [x] 3. full run -> v-sn/run-postfix2.txt: TALLY PASS=204 FAIL=0
