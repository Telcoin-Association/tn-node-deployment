status: done

# V-OPS-2-ps checkpoint (prepare-stake.sh 1.0.0)

Harness: /private/tmp/claude-501/-Users-grant-coding-telcoin-tn-node-deployment/eddb430f-f0dc-43fe-9180-65cd421b1e88/scratchpad/vops2-tests/ps/
Driver: `bash t_ps.sh <bash> [regex]` (lib_t.sh, shims/, app/ = script + lib with DEFAULT_INSTALL_DIR rooted at TN_ROOT_PREFIX)
Roots: TN_ROOT_PREFIX for /etc/telcoin, /var/lib/telcoin, /etc/systemd/system; path-rewritten app/lib/common.sh
(DEFAULT_INSTALL_DIR and the legacy-unit fallback only) for /opt/telcoin.
Extra: units/ (keccak checksum vs cast, decimal helpers vs python), shims-docker/ (docker stand-in running the real
binary), shims-live/ (no curl shim, live read-only), flockshim/ (python flock on fd 9).

## Sections
- [x] read prepare-stake.sh in full
- [x] read library functions it calls
- [x] build shims + fixtures (real v0.15.0 keys in keys/base, passphrase with space ; $(x))
- [x] prepare-flow exit codes
- [x] amount / calldata / json
- [x] passphrase argv/env (env.log/argv.log of every PATH child + tnbin; TTY prompt via script(1); docker runner)
- [x] rotation (refusals, happy path, failure, lock mkdir + flock shim)
- [x] hard guard 1.5.0 (+1.4.0, + missing lib)
- [x] live read-only (stake amount == cast; committee addr nothing-to-do; unwhitelisted exit 3; cast call accepts the printed calldata)
- [x] adversarial (bad addr, checksum, upper, CRLF)
- [x] private-key grep, prose
- [x] implementer tests cross-check (t_d 260/0, t_rot 215/0, t_units 13/0 under both bashes)

## Results
- t_ps.sh: bash 3.2 108 pass / 2 fail; bash 5.3 108 pass / 2 fail (both: CRLF .node-meta)
- units: 120 checksums vs cast + 153 decimal vectors vs python identical under both bashes
- docker runner + TTY prompt + passphrase-in-env prepare: pass under both bashes
- 463 captured outputs: passphrase in none; 180 runs: 0 cast, 0 eth_send*

## Findings
- F0 warn: signals (t_sig.sh): SIGTERM to the script during generate pop -> JSON {"ok":true,"exit":0,"state":"error"},
  keytool finishes after the EXIT trap released the lock (node-info rotated, .node-meta old, no restart); bash 5 +
  SIGINT to the group also ok:true exit 0 (bash 3.2 ok:false 130).
- F1 warn: CRLF .node-meta -> NETWORK="testnet\r" -> exit 1 "NETWORK=testnet\r in ... is not testnet..." (CR in msg); meta_get keeps CR.
- F2 warn (confirms parent M1): --private-key "$VALIDATOR_KEY" advice puts the key in cast's argv; cast 1.5.1 has no env var for it; --account exists.
- N1 note: balance short -> warning + commands printed + exit 3 state not-ready (documented; directive said warning).
- N2 note: spec says 256-bit via python3; implementation is pure bash limbs (verified exact).
- N3 note: rotation prints the .node-meta mismatch warning suggesting the very --rotate-address being run.
- N4 note: keytool stderr cut at 300 chars mid-word + " ." artifact in the rollback message.
