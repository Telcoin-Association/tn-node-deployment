status: done

Agent D1, scripts-v2.2.0 round. Files: OPERATOR.md, README.md only.

Completed sections:
- S1 OPERATOR.md: 291 Docker row (first signed testnet release v0.18.0-adiri; fallback when GitHub unreadable or lists none, plus rc-2 v0.16.0 fallback); 4.1 ~943 expiry dates of three keys; ~1369 ships three keys + sstanfield, v0.18.0-adiri first signed; ~1405 three fingerprints; gateway ~1795/1818-1820 testnet pinned, mainnet refuses; same-host example note (devnet image, testnet leave --image out); row "No testnet release is published" cause rewritten; row chain configs 2.1.0 fix -> installer one-liner.
- S2 OPERATOR.md: 4.1 new 2.1.0-host paragraph (keyed on [ERROR] line, warning before it, no "two lines") + updater hint sentences; section 9 new row keyed on the [ERROR] line (after "Release <tag> did not verify" row, which now points 2.1.0 hosts to it); 2.11 Updates: sudo -u ubuntu installer command for stacks on 2.1.0.
- S3 README.md: AWS para ~250 (stack on 2.1.0 sentence); 1109 Docker fallback (v0.18.0-adiri first signed); 1428 updater refusal bullet + hint; new "A host on scripts-v2.1.0" paragraph ~1464; 1475 three keys; 1491 three fingerprints; changelog setup-gateway 2.2.0 pins; update-scripts 2.2.0 keys (three, 172be74).
- S4 README.md changelog: update-scripts 2.2.0 hint bullet; telcoin-ui 2.1.3 click 8.5.1 line; gateway pin in setup-gateway 2.2.0 entry (which also covers lib/gateway 2.2.0).
- S5 sweep: OPERATOR ~1009 (--check fallback "while no release" -> "when GitHub unreadable or lists none"); README ~1502 node-release key line (was RSA 4E36 expires 2028-10-16 -> three ed25519 keys); README ~1511 fallback pointer wording. Left as history: README changelog lib/common v2.1.0 (~2488-2493), lib/common v2.0.0 (~2787, ~2799), update-scripts v2.0.0/v2.1.0 entries. Left out of scope: OPERATOR ~1255 UI snapshot note names v0.17.0-adiri (storage, not this round).
- S6 tests: p2p_reason_text_test.sh and network_hits_test.sh pass; release_keys, install, updater_manifest, release_scripts, cut_release tests (use README.md only as a fixture) all pass. diff --stat: OPERATOR.md 42 (+31/-11), README.md 35 (+23/-12).
