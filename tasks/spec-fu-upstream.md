# Upstream docs package (UP): telcoin-network branch and devnet-genesis

Read `tasks/spec-fu-shared.md` first (ground rules, verified facts, endpoints). This package is
the only one that commits in other repos. Nothing is pushed.

## telcoin-network (`/Users/grant/coding/telcoin/tn-5`)

Setup (tags are already fetched; local `main` is one commit behind `origin/main`, which is fine):
`git -C /Users/grant/coding/telcoin/tn-5 switch -c docs/operator-docs-backlog origin/main`.
Do not touch local `main`. One commit per topic, style `docs(scope): …` as in the upstream log
(`git log --oneline -40 origin/main` shows the convention). No trailers of any kind.

Version facts for wording (checked against the tags): `keytool set-rpc`, `generate --rpc-http`
and `generate pop` exist from v0.12.0-adiri; `--enable-state-export` from v0.13.0-adiri;
`--state-export-keep` and `--bootstrap-peers` from v0.15.0-adiri; `export-staking-args` from
v0.11.0-adiri or earlier.

| # | Commit | Files |
|---|---|---|
| 1 | `docs(staking): match the live ConsensusRegistry ABI` | `docs/src/staking/how-to-stake.md` (compressed key and 48-byte proof, `stake(bytes,(bytes))`, calldata from `keytool export-staking-args`, stake amount from `getCurrentStakeVersion()` + `stakeConfig(uint8)`, `delegateStake` and `delegationDigest` with `deadline`, `unstake(address,bool)` and when it is eligible, `--chain adiri` in the start example), `docs/src/staking/how-staking-works.md` (`epochDuration` is seconds), `README.md`, `etc/README.md`, the CLI README (`crates/telcoin-network-cli/README.md`) |
| 2 | `docs(staking): stop advising --force key regeneration` | `how-to-stake.md` error table and closing note: a registered BLS key is never released, so regenerating destroys the only key for a staked validator; point to `keytool generate pop --address` |
| 3 | `docs(network): correct the worker P2P port and drop default-port claims` | `docs/src/getting-started/validator-operations.md`, CLI README port table and examples (49595 → 49594, "convention" not "default"), `how-to-stake.md`, root `README.md` keygen example |
| 4 | `docs(cli): document the p2p_info.workers node-info shape` | CLI README sample and field list (legacy `worker:` still read) |
| 5 | `docs(operations): tell validators how to advertise an RPC endpoint` | `validator-operations.md` new subsection: node RPC on loopback, an `https://` URL through a TLS proxy, never a private address; CLI README pointer |
| 6 | `docs: name the canonical RPC endpoints and explorers` | `docs/src/networks-and-rpc-endpoints.md` (Adiri stays `https://rpc.adiri.tel`; explorers `telscan.io` and `www.telscan.xyz`; mainnet, not yet launched, will use `https://rpc.telcoin.network`, chain id 487; no WebSocket through the balanced URL), `docs/src/getting-started/faucet.md` (malformed link, alternate explorer) |
| 7 | `docs: route the hardware contact to support@telcoin.org` | `docs/src/getting-started/hardware-requirements.md` |
| 8 | `docs(chain-configs): explain that the testnet genesis predates the registry fork` | `chain-configs/README.md` only; `chain-configs/testnet/genesis.yaml` is consensus-critical and is not edited |

No sweep of the `rpc-methods` pages: they already use the canonical testnet hostname. Before
each claim, read the code it describes (the keytool clap definitions under
`crates/telcoin-network-cli/src/`, the registry ABI in the `tn-contracts` submodule or its
bindings) so every selector, signature and port in the prose is checked against source, not
memory. Verify with `mdbook build docs -d <scratchpad>/tn5-book` at the end.

## devnet-genesis (`/Users/grant/coding/telcoin/devnet-genesis`)

One commit on `main`, `config: node 5 is an observer by committee membership`: the `config.sh`
comment that describes node 5 as `node --observer` becomes "outside the genesis committee, so the
binary runs it as an observer; there is no `--observer` flag". Nothing else changes; the
`tn-node-deployment` submodule pointer is not bumped, because the new commits are not pushed.
Commit only `config.sh` (never `.claude/` or `tasks/`).
