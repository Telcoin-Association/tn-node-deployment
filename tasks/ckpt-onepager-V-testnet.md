status: done
completed: V1, V2, V3, V4, V5, Closing check, Closing check second pass

# Unit V (testnet half): verification of docs/partner/testnet-node-requirements/

Read-only verifier. Sources: guide = docs/partner/mno-node-guide/mno-node-guide.md (v1.9, this branch);
common = lib/common.sh; up@tag = telcoin-network v0.17.0-adiri:docs/src/getting-started/hardware-requirements.md;
up@main = same file at origin/main (5533ff73a, 2026-11-16).

## V1. Fact list from the sources (derived before reading the page)

### Network identity, endpoints
- F1 Testnet is Adiri, chain ID 2017 (`0x7e1`). guide 8, 207; common 19 (TESTNET_CHAIN_ID=2017).
- F2 Testnet public RPC `https://rpc.adiri.tel`. guide 207; common 21.
- F3 Explorer: guide 207 gives `https://telscan.io` or `https://www.telscan.xyz`; the scripts use only `https://telscan.io` (common 22 TESTNET_EXPLORER; MAINNET_EXPLORER is also telscan.io, common 29).
- F4 Public RPCs are HTTPS JSON-RPC only; WebSocket upgrade gets 405. guide 230.
- F5 `https://rpc.telcoin.network` is reserved for mainnet and today answers for testnet (2017). guide 233.
- F6 Testnet status page `https://status.adiri.telcoin.network/` (linked from UI Network tab). guide 997.
- F7 Install: `curl --proto '=https' --tlsv1.2 -fsSL https://install.telcoin.network | bash`, as normal user, no sudo; lands in `~/telcoin-node-scripts`. guide 252-256. Then `sudo bash ~/telcoin-node-scripts/setup-node.sh`. guide 279-281.
- F8 Contact: devs@telcoin.org for any question, validator onboarding, approval and hardware; "If you plan to validate, write before you buy hardware." guide 48-50, 117. (Upstream page says support@telcoin.org, up@tag 15, 427; the guide overrides.)
- F9 Mainnet not launched; chain 487; setup menu marks it coming soon; TN_MAINNET_ENABLED=0. guide 9, 208, 218-224; common 37.

### Epochs, validator path, stake
- F10 Testnet epochs are six hours (21600 s). guide 57, 830; common 58.
- F11 Four steps in order: Association approval ending in a ConsensusNFT minted to the execution address; stake; activation; committee selection. guide 77-82.
- F12 Validating only for GSMA-approved MNOs after Association approval; anyone can run a node without approval. guide 12-15, 1325.
- F13 Every node provisioned validator-capable; role from on-chain state each epoch. guide 17-20.
- F14 `activate()` mined in epoch E -> active at E+1; committee fixed two epochs ahead -> earliest seat E+3; on testnet's six-hour epochs 12 to 18 hours after `activate()`, depending on how much of E was left. guide 1494-1496.
  (Check: E+3 starts between 2 and 3 epochs after a point inside E, i.e. 12-18 h. Consistent.)
- F15 Stake is 1,000,000 TEL on testnet today; `prepare-stake.sh` reads the current amount. guide 1330. Code: prepare-stake.sh 996-1005 reads stakeConfig(getCurrentStakeVersion()) on the ConsensusRegistry `0x07e17e17...e1` (common 5330, 5337-5338, 5463-5483); common comment says 1e24 wei = 1,000,000 TEL on testnet today.
- F16 Validator prerequisites also: hardware at validator tier, P2P ports reachable, synced node, publicly routable RPC URL advertised in node-info.yaml, execution address funded with stake plus gas, Foundry `cast` + wallet. guide 1325-1331.

### Hardware
- F17 Guide table (physical cores): Observer follower min 2 cores / 8 GB, rec 4 / 16 GB; Observer public RPC min 4 / 16, rec 8 / 32; Validator min 8 cores / 32 GB ECC, rec 16 / 64 GB ECC. guide 102-106. Matches up@tag 28-36 exactly.
- F18 Cloud vCPUs usually hyperthreads: 8 vCPU ~ 4 physical cores. guide 99-100; up@tag 57 ("minimum tier's 8 physical cores are a 16-vCPU instance").
- F19 Storage same for every role: at least 2 TB TLC NVMe (10,000 write IOPS, 300 MB/s), 4 TB recommended; avoid QLC. guide 108-109. up@tag 28-29: min 2 TB TLC NVMe 10,000 write IOPS 300 MB/s 2.4 DWPD; rec 4 TB TLC NVMe 20,000 IOPS 500 MB/s 1.2 DWPD; observer storage "as validator min/rec". (Guide omits rec IOPS/MB/s and DWPD.)
- F20 Validator network: 200 Mbps symmetric min, 1 Gbps recommended; p95 RTT well below 1 s to at least 7 of the 10 committee members. guide 111-114; up@tag 28-29, 38, 396. Observer network 50 Mbps (up@tag 31-34) -- NOT in the guide.
- F21 Swap off and time sync (chrony or systemd-timesyncd) recommended on every node (guide 119); "The deployment scripts check neither, so set both up yourself" (guide 122). up@tag 405, 409, 467.
- F22 Drift: validator holds vote on header ahead of its clock until lead passed, on testnet today up to one second; rejects >5-6 s ahead (tolerance + 5 s vote timeout). guide 120-121. up@tag 409: 250 ms default, 1 s in datadir first started before sub-second timestamps; rejection at tolerance + vote_timeout (5.25 s at defaults).
- F23 Data dir on ext4 or xfs (fallocate); "The scripts do not check the filesystem." guide 124-126; up@tag 406. Address space unlimited (guide 127), bare-metal power saving off (guide 128).
- F24 setup-node.sh hardware check: one line per role (`[OK] Full node (follower): meets minimum` / `[WARN] Validator (minimum): below minimum`); only warns, never blocks; counts physical cores where it can; no check for ECC or NVMe. guide 130-134. Code: common 87-89 tiers node 2 cores/8 GB/2000 GB, rpc 4/16/2000, validator 8/32/2000 (disk = filesystem TOTAL size, 5% slack, common 2283-2308, 2337); check_hardware always returns 0 (common 2325-2328); compares logical CPUs when physical cannot be read (common 2332-2334, 2423-2424). Validator-recommended constants exist (common 90, 16/64/4000) but are not used in check_hardware's three role lines (common 2431-2440).

### OS, systemd, TPM
- F25 Use Ubuntu 24.04 LTS. guide 138. Mainnet only systemd >= 255 (guide 139; common 5837).
- F26 Testnet: >= 250 keeps BLS passphrase as encrypted credential (guide 140, 146; common 5836). 247-249 (Ubuntu 22.04): installs with a warning, passphrase in root-only file `/etc/telcoin/bls-passphrase` (guide 147, 338; common 5838). < 247 refused everywhere (guide 148). Debian 12 example for 250-254 (guide 146).
- F27 TPM 2.0 or vTPM lets setup bind the credential to the server; mainnet stops without one unless `--allow-no-tpm` (guide 150-151, 336). On testnet `host` (no TPM) only warns (guide 335).
- F28 Not macOS; Debian-family assumptions (apt) for source build, Docker install, Caddy, UI Python. guide 153-160.
- F29 Preflight refuses until CVE-2026-31431 ("Copy Fail") mitigation in place: `install algif_aead /bin/false` in a modprobe.d file and module not loaded; apply from https://copy.fail. guide 162-164.

### Ports
- F30 49590/UDP and 49594/UDP inbound from everywhere on every node (QUIC primary/worker P2P), including nodes that may never validate. guide 171-172, 181-182; common 75-76. They are conventions; the node uses the ports in its own multiaddrs. guide 183-185.
- F31 443/TCP inbound everywhere: Caddy, ONLY when it serves public RPC or the dashboard. guide 173. 80/TCP: Caddy cert issuance and http->https redirect, "Recommended with Caddy." guide 174.
- F32 8545, 8546 loopback only, never open; 9101 metrics loopback. guide 175-177; common 77, 79.
- F33 43174/TCP health check: testnet add-on, only when health monitor enabled; open to 104.155.184.201/32 plus your monitoring hosts; on v0.16.0-adiri listens on every interface, from next release 127.0.0.1 only. guide 178.
- F34 SSH from your admin IPs. guide 179. Open in every filtering layer (ufw, cloud firewall, NAT forwards). guide 187. Private alerts need no inbound port. guide 189.

### Releases and signatures
- F35 Scripts from signed tag `scripts-vX.Y.Z`, MANIFEST + MANIFEST.asc by Telcoin release keys, checked with gpgv. guide 267.
- F36 Guide: "Node releases are checked against the same keys ... accept the release only when a key they ship signed it." guide 268.
- F37 Guide: testnet Docker default is newest GitHub release by signed digest; "Until testnet has one (signed releases are planned to start with `v0.17.0-adiri`), the default is the newest image of the older repository, or `v0.16.0-adiri` ..." guide 312; same plan sentence guide 745. On testnet a source build of a tag whose signature cannot be checked goes ahead with a warning; on mainnet refused. guide 316.
- F38 CODE CONTRADICTS F37: common 1811-1827 -- `TN_UNSIGNED_RELEASE_TAG="v0.17.0-adiri"`, "the last testnet release cut without the signed pipeline ... no GitHub release, so no signed SHA256SUMS, IMAGE_DIGEST or tarball"; "the exception is removed with v0.17.1-adiri, which is signed". For that tag on testnet: source build takes the unsigned tag with a log line (still refuses a bad signature); Docker image is the digest the registry serves, no signed release asked for; release-tarball install has no exception (no tarball). So on testnet today the newest release is unsigned, and signed releases start with v0.17.1-adiri, not v0.17.0-adiri. -> guide 312/745 are GUIDE-DEFECTs.
- F39 Node runs release tags only: `vX.Y.Z-adiri` testnet. Floor `v0.13.0-adiri` on testnet. guide 269-270.
- F40 Image packages: testnet `ghcr.io/telcoin-association/tn-testnet` (common 1581), legacy `us-docker.pkg.dev/telcoin-network/tn-public/adiri` (common 1600); guide 217, 272, 312.
- F41 Release tarballs x86_64 Linux only. guide 317.

### Upstream drift (D1 candidates; tag vs main)
- DR1 Validator min disk: tag 10,000 write IOPS / 300 MB/s -> main 20,000 sustained write IOPS / 800 MiB/s (~840 MB/s). up@tag 28 vs up@main 29 (commits af0f1ccae, d4d53c115, storage v2 / tn-lmdb).
- DR2 Validator rec disk: tag 4 TB, 20,000 IOPS, 500 MB/s -> main 4 TB local NVMe, or 40,000 IOPS and 800 MiB/s on cloud block storage. up@main 30.
- DR3 RPC cache defaults 5000/2000 -> 1000/500 (affects RPC-observer RAM rationale, not the tier figures). up@main 473-485.
- Unchanged tag->main: CPU/RAM tiers, network 200 Mbps/1 Gbps, RTT rule, swap, ext4/xfs, address space, power saving, time sync text.

## V2. Rules applied (spec sections 5 and 6)

- R1 Guide v1.9 is the source of truth; the page states nothing the guide does not, in the guide's terms (spec 89-90).
- R2 One `# ` title then `## ` sections; no prose between title and first section (92-93).
- R3 Absolute https links only; no repo-relative or in-document `#anchor` link (94).
- R4 Only contact is devs@telcoin.org (95).
- R5 British spelling, plain sentences, no em dashes, no marketing words (96).
- R6 Code spans for ports, flags, file names, tags, hex chain IDs, typed URLs (98-99).
- R7 Never printed: current node version, scripts version, which node release starts signed releases, oldest supported node release; do not say or imply that every testnet node release is signed (100-102).
- D1 Disk: 2 TB TLC NVMe (10,000 write IOPS, 300 MB/s), 4 TB recommended; main's higher figures are DRIFT (106-109).
- D2 Testnet latency wording: "a p95 round-trip time well below 1 second to at least 7 of the 10 committee members" (110-111).
- D4 Page carries "email devs@telcoin.org with the planned hardware before buying anything for a validator" (117-118).
- D5 metadata keys: subtitle, badge, version "1.0", date November 2026, author Telcoin Association, description, contact devs@telcoin.org, repo-url, lang en-GB, toc-depth 0, no title (119-122).
- Page rule (spec 4, 84): no date beyond month-only `date:`.

## V3. Statement table (page at 7712ef7; PDF = build/ PDF, byte-identical; pdftotext and page-1.png read)

Code refs: common = lib/common.sh; setup = setup-node.sh; ps = prepare-stake.sh.

| # | Statement (as printed) | Source | Verdict |
|---|---|---|---|
| 1 | Badge "Testnet · chain ID 2017" | guide 8, 207; common 19 | OK |
| 2 | Title "Adiri testnet node requirements" | guide 8 | OK |
| 3 | Subtitle "Hardware, host, ports and install for a Telcoin Network node" | page scope | OK |
| 4 | "Version 1.0 · November 2026" | spec D5 (page version, not a node/scripts version, R7) | OK |
| 5 | metadata description | page scope | OK |
| 6 | metadata keys (contact, repo-url, lang en-GB, toc-depth 0, author, no title) | spec D5 | OK |
| 7 | Observer, follower min "2 cores, 8 GB RAM" | guide 104; up@tag 31; common 87 | OK |
| 8 | Observer, follower rec "4 cores, 16 GB RAM" | guide 104; up@tag 32 | OK |
| 9 | Observer, public RPC min "4 cores, 16 GB RAM" | guide 105; up@tag 34; common 88 | OK |
| 10 | Observer, public RPC rec "8 cores, 32 GB RAM" | guide 105; up@tag 35 | OK |
| 11 | Validator min "8 cores, 32 GB ECC RAM" | guide 106; up@tag 28; common 89 | OK |
| 12 | Validator rec "16 cores, 64 GB ECC RAM" | guide 106; up@tag 29; common 90 | OK |
| 13 | Storage, every role min "2 TB TLC NVMe (10,000 write IOPS, 300 MB/s)" | guide 108; up@tag 28, 31, 34; D1 | OK + DRIFT (up@main 29: 20,000 sustained write IOPS, 800 MiB/s) |
| 14 | Storage rec "4 TB" | guide 108; D1 | OK + DRIFT (up@main 30: local NVMe or 40,000 IOPS, 800 MiB/s). Note: up@tag 29 rec is also 20,000 IOPS, 500 MB/s, which the guide omits (guide omission, not a page finding) |
| 15 | Validator bandwidth min "200 Mbps symmetric" | guide 113; up@tag 28 | OK |
| 16 | Validator bandwidth rec "1 Gbps" | guide 113; up@tag 29 | OK |
| 17 | "CPU counts are physical cores; cloud vCPUs are usually hyperthreads, so an 8 vCPU instance has about 4." | guide 99-100; up@tag 57 | OK |
| 18 | "A validator also needs a p95 round-trip time well below 1 second to at least 7 of the 10 committee members." | guide 114; D2; up@tag 38, 396 (same on main) | OK |
| 19 | "Avoid QLC drives: they wear out under continuous chain writes." | guide 109; up@tag 531-534 | OK |
| 20 | "Every node: swap off, time sync on" | guide 119; up@tag 405, 409, 467 | OK |
| 21 | "data directory on ext4 or xfs" (every node) | guide 124-126; up@tag 406, 485 ("Linux as for validators") | OK |
| 22 | "the scripts check none of these" | guide 122, 126; grep of *.sh lib/*.sh ui/*.sh finds no swap, time-sync or fstype check (setup 388-405 only lists filesystems) | OK |
| 23 | IMPORTANT "Email devs@telcoin.org with your planned hardware before you buy anything for a validator." | guide 117; D4 | OK |
| 24 | Chain: EVM L1; Narwhal and Bullshark; reth, so Ethereum-style JSON-RPC | guide 5, 7 | OK |
| 25 | Chain ID "2017 (`0x7e1`)" | guide 207; common 19; live 0x7e1 | OK |
| 26 | Public RPC `https://rpc.adiri.tel` | guide 207; common 21; live | OK |
| 27 | "(no WebSocket)" | guide 230 | OK |
| 28 | Explorer `https://telscan.io` | guide 207; common 22; live 200 | OK |
| 29 | Status page `https://status.adiri.telcoin.network/` | guide 997; live 200 | OK |
| 30 | Epochs "Six hours" | guide 57; common 58 | OK |
| 31 | "Ubuntu 24.04 LTS." | guide 138 | OK |
| 32 | "macOS is not supported." | guide 153 | OK |
| 33 | "Debian 12 and Ubuntu 22.04 also install on testnet (systemd 247 or newer)" | guide 145-148; common 5838, 5869-5874; setup 458-462 | OK |
| 34 | "below systemd 250 the BLS passphrase stays in a root-only file" | guide 147, 338; common 5836, 5877-5878; setup 541-558 (auto stdin, with a warning) | OK |
| 35 | "Release tarballs are x86_64 Linux; on another architecture, build from source or use Docker." | guide 317 vs guide 745 (v0.16.0-adiri and older: no release page); common 1811-1813, 1823-1824 (v0.17.0-adiri: no tarball) | OVERSTATED: no testnet release has a tarball today |
| 36 | "A TPM 2.0 or vTPM is optional on testnet." | guide 150-151, 335; common 5885-5892; setup 564-571 (host key alone, warning) | OK |
| 37 | "Setup stops until the CVE-2026-31431 kernel mitigation (https://copy.fail) is in place." | guide 162-164; setup 382 (all networks); live 200 | OK |
| 38 | `49590`, `49594` UDP / Everywhere / P2P (QUIC), every node | guide 171-172; common 75-76 | OK |
| 39 | `443`, `80` TCP / Everywhere / "Public RPC, dashboard" | guide 173 (443: Caddy, only when it serves public RPC or the dashboard); guide 174 (80: certificate issuance and http-to-https redirect, recommended with Caddy) | WRONG for 80's purpose |
| 40 | `8545`, `8546` TCP / Loopback only / JSON-RPC | guide 175-176 | OK |
| 41 | `9101` TCP / Loopback only / Metrics | guide 177; common 79 | OK |
| 42 | `22` TCP / Your admin IPs / SSH (or your SSH port) | guide 179 | OK |
| 43 | "Open the UDP ports on every node, even one that may never validate, in every layer that filters traffic: `ufw`, the cloud firewall, NAT port forwards." | guide 181, 187 | OK |
| 44 | "Open `443` and `80` only if you serve public RPC or the dashboard." | guide 173-174; guide 1329 (validator prerequisite: publicly routable RPC URL advertised in node-info.yaml) | MISSING: every validator serves public RPC |
| 45 | "Run the installer without `sudo`, then run setup:" | guide 252, 279-281 | OK |
| 46 | `curl --proto '=https' --tlsv1.2 -fsSL https://install.telcoin.network \| bash` | guide 255; live 200 | OK |
| 47 | `sudo bash ~/telcoin-node-scripts/setup-node.sh` | guide 280 | OK |
| 48 | "Install methods: build from source, signed release, Docker, or a binary you supply." | guide 308-313 | OK (menu); the testnet caveat is fixed via #35 |
| 49 | "The node runs release tags only, `vX.Y.Z-adiri`; a branch, a commit id or `latest` is refused." | guide 269 | OK (rc tags run when named, guide 269; not material) |
| 50 | "Docker image: `ghcr.io/telcoin-association/tn-testnet`." | guide 217, 272 vs guide 312 (default from the older repository until testnet has a signed release); common 1593-1600, 1662-1676, 8482; commit 628a74d (v0.17.0-adiri image is us-docker.pkg.dev/telcoin-network/tn-public/adiri) | OVERSTATED: every testnet image today is in us-docker.pkg.dev |
| 51 | "The scripts come from a signed release tag and are checked with `gpgv` before anything installs." | guide 267 | OK |
| 52 | "Signed node releases are checked against the same keys." | guide 268 vs guide 316, 745; common 1811-1827, 8436-8444, 8475-8481 | OVERSTATED + RULE (R7: implies the node a testnet reader installs is signature-checked; no testnet release is signed today) |
| 53 | "Anyone can run a node: no approval is needed to install one, follow consensus and serve JSON-RPC." | guide 12-13 | OK |
| 54 | "Validating is a separate, on-chain step, only for GSMA-member mobile network operators the Telcoin Association has approved." | guide 6, 14-15, 1325 | OK (guide 15/1325 say "GSMA-approved"; guide 6 says "GSMA-member") |
| 55 | "It takes four steps:" | guide 77 | OK |
| 56 | "1. Approval: a ConsensusNFT minted to your execution address." | guide 79 | OK |
| 57 | "2. Stake: 1,000,000 TEL on testnet today; `prepare-stake.sh` reads the current amount." | guide 1330; ps 996-1005; common 5463-5483; live cast | OK |
| 58 | "3. Activation." | guide 81 | OK |
| 59 | "4. Committee selection: if `activate()` is mined in epoch E, the earliest seat is epoch E+3, 12 to 18 hours later." | guide 1494-1496 | OK |
| 60 | "Email devs@telcoin.org about running a node, validator onboarding, approval or hardware." | guide 48-49; R4 | OK |
| 61 | "Full operator guide (PDF): https://github.com/.../blob/main/docs/partner/mno-node-guide/mno-node-guide.pdf" | file on origin/main b89ada4, v1.9, identical to this branch | OK on content; LIVE 503 (see V4) |
| 62 | Footer "devs@telcoin.org · https://github.com/Telcoin-Association/tn-node-deployment" | D5; live 200 | OK |

Text rules: no em or en dash, no `#anchor` link, no US spelling found (grep); only contact devs@telcoin.org; no node or scripts version printed; one `# ` title, `## ` sections.

## V4. Live checks (2026-11-17, curl defaults, public endpoints printed on the page only)

- `eth_chainId` POST to https://rpc.adiri.tel: `{"jsonrpc":"2.0","id":1,"result":"0x7e1"}`. Matches the page.
- https://telscan.io: 200, no redirect.
- https://status.adiri.telcoin.network/: 200.
- https://install.telcoin.network: 200.
- https://copy.fail: 200.
- https://github.com/Telcoin-Association/tn-node-deployment (footer): 200.
- Guide PDF link (blob/main/.../mno-node-guide.pdf): 503, GitHub "Unicorn!" error page, on 4 tries over a few minutes. Not a 404: the file exists on origin/main (b89ada4, v1.9, no diff against this branch). A browser may still render it; not confirmed. A `raw/main` link (one character shorter) serves the file without the blob viewer; not tested, since it is outside the allowed request set.
- Stake, via `cast` (/home/drtnarg/.foundry/bin/cast) the way prepare-stake.sh does: getCurrentStakeVersion() on 0x07e17e17...e1 = 0; stakeConfig(0) word 0 = 0xd3c21bcecceda1000000 = 1,000,000 TEL. Matches the page.

## V5. Report

62 statements checked: 55 OK (2 of them also DRIFT), 5 findings, 1 live-check caveat (#61).

### Answers to the nine points

1. Signed releases (#52). Not exactly true for a testnet node today. It holds for signed releases (guide 268). But no testnet node release is signed yet. `v0.17.0-adiri`, the newest, is the one-tag exception (common 1811-1827): a source build takes the unsigned tag with a log line, and Docker takes the registry's digest. `v0.16.0-adiri` and older have no release page (guide 745). Testnet also accepts other unsigned tags with a warning (guide 316; common 8436-8444, 8475-8481). Rule R7 says the page must not imply that the node a reader installs is signature-checked. GUIDE-DEFECT, not printed on the page: guide 312 and 745 say signed releases "are planned to start with `v0.17.0-adiri`", but common 1814-1815 makes `v0.17.0-adiri` the last unsigned release, and signing starts with `v0.17.1-adiri`.
2. Ports 443 and 80 (#39, #44). No. Guide 174 gives port 80's purpose as Caddy certificate issuance and the http-to-https redirect, recommended with Caddy. It does not serve public RPC or the dashboard, which is what the row says. The sentence's condition matches guide 173-174, but it leaves out that every validator must advertise a publicly routable RPC URL (guide 1329).
3. systemd. Both statements are correct: guide 143-148 and 338; common 5836-5838 and 5869-5878; setup 458-462 and 541-558. Setup switches to the root-only file by itself below 250 on testnet and devnet, with a warning.
4. TPM. Correct: guide 150-151 and 335; common 5885-5892; setup 564-571. Without a TPM, testnet uses the host key alone and warns.
5. Hardware. Every figure matches guide 102-114, the upstream page at the tag (up@tag 28-38) and the scripts' minimum tiers (common 87-90). The scripts' check only warns, and does not check ECC, NVMe or IOPS. "Every node: swap off, time sync on, data directory on ext4 or xfs; the scripts check none of these." is correct: guide 119, 122 and 124-126; up@tag 405-409 and 467. A grep finds no swap, time-sync or filesystem-type check in the scripts. The disk figures have drifted on upstream `main` (see the drift list).
6. E+3. Correct: guide 1494-1496. `activate()` lands at some time t inside E = [s, s+6 h). E+3 starts at s+18 h, so the wait is more than 12 h and at most 18 h.
7. 1,000,000 TEL. Correct: guide 1330; ps 996-1005 and common 5463-5483. Read live with `cast`: stake version 0, 1e24 wei = 1,000,000 TEL.
8. Explorer. Yes: `https://telscan.io` is `TESTNET_EXPLORER` (common 22), the first of guide 207's two explorers, and it answers 200. The scripts never use `www.telscan.xyz`.
9. When the next node release is tagged: (a) the storage row. If that release is cut from upstream `main`, which carries #1834 and #1849 (not in `v0.17.0-adiri`, nor on `release/v0.17.0-adiri`), the upstream page at that tag will ask for 20,000 sustained write IOPS and 800 MiB/s minimum, and local NVMe or 40,000 IOPS recommended. The page's 10,000 IOPS / 300 MB/s then understates what to buy. (b) Three statements that are wrong today become true with the first signed release: the Docker image (#50), release tarballs (#35) and, in effect, #52. No other printed fact depends on the release: chain ID, RPC, epochs, systemd floors, and the stake, which is hedged with "today".

### Findings, by severity, with replacement wording (each no longer than the text it replaces)

1. OVERSTATED and RULE R7, medium-high (#52). "Signed node releases are checked against the same keys." (55 characters) -> "So are signed node releases; testnet runs unsigned too." (55). Sources: guide 268 and 316; common 1811-1827 and 8436-8444.
2. OVERSTATED, medium (#50). "Docker image: `ghcr.io/telcoin-association/tn-testnet`." (53) -> "Docker: `ghcr.io`, or the older `us-docker.pkg.dev`." (48). Sources: guide 312; common 1581, 1600 and 1662-1676; commit 628a74d (the `v0.17.0-adiri` image is `us-docker.pkg.dev/telcoin-network/tn-public/adiri`). Every testnet Docker install today pulls from `us-docker.pkg.dev`, so an operator who allows only `ghcr.io` outbound cannot pull the image.
3. MISSING, medium (#44). "Open `443` and `80` only if you serve public RPC or the dashboard." (62) -> "Open `443`, `80` for public RPC (validators need it) or dashboard." (62). Sources: guide 173-174 and 1329.
4. OVERSTATED, low-medium (#35). "Release tarballs are x86_64 Linux; on another architecture, build from source or use Docker." (92) -> "Release tarballs (x86_64 Linux) come only with signed releases; else use source or Docker." (90). Sources: guide 268, 311, 317 and 745; common 1823-1824. The statement stays true after the first signed release and names no release (R7).
5. WRONG, low (#39). Ports row purpose "Public RPC, dashboard" (21) -> "Caddy: RPC, dashboard" (21). Sources: guide 173-174; both of the guide's rows are Caddy.

Live-check caveat (#61): the guide PDF link returned 503 (GitHub's "Unicorn!" page) on 4 tries; it never returned 404. The file exists on `origin/main`. Someone should open it in a browser before the page goes out. Swapping `blob/main` for `raw/main` makes the link one character shorter and serves the file directly; I did not test it.

### Drift (spec D1: recorded, not findings)

- DR1 (#13). Validator minimum disk: 10,000 write IOPS and 300 MB/s at tag `v0.17.0-adiri`; 20,000 sustained write IOPS and 800 MiB/s (about 840 MB/s) on `main` (up@main 29; upstream commits af0f1ccae and d4d53c115).
- DR2 (#14). Recommended disk: at the tag, 4 TB with 20,000 IOPS and 500 MB/s; on `main`, 4 TB of local NVMe, or 40,000 IOPS and 800 MiB/s on cloud block storage (up@main 30).
- DR3. RPC cache defaults: 5000 blocks and 2000 receipts at the tag, 1000 and 500 on `main` (up@main 473-485). The RAM tiers do not change.
- Unchanged between the tag and `main`: CPU and RAM tiers, bandwidth, the round-trip-time rule, swap, ext4 or xfs, time sync and power saving.

### Notes for the orchestrator (not findings against the page)

- Guide omission: guide 108 gives no IOPS or MB/s for the 4 TB recommended disk. The upstream page at the tag gives 20,000 IOPS, 500 MB/s and 1.2 DWPD (up@tag 29).
- The guide does not give observer bandwidth; the upstream page gives 50 Mbps (up@tag 31-34). The page's "Validator bandwidth" row is accurate as far as it goes.
- The testnet-only port 43174 (health monitor add-on; guide 178) is not in the ports table. The table does not claim to be complete.
- The guide's eligibility lines say "GSMA-approved" (guide 15 and 1325), while the page uses "GSMA-member", which is guide 6's term. Acceptable.

## Closing check (after edits; `git diff HEAD` on the page; PDF rebuilt 11:19, still 1 page)

| # | Change | Verdict | Support |
|---|---|---|---|
| 1 | Removed "Signed node releases are checked against the same keys."; the bullet now ends "...checked with `gpgv` before anything installs." | CLOSED | guide 267. Nothing left says or implies that every testnet node release is signed (R7). |
| 2 | "Docker image: `ghcr.io/telcoin-association/tn-testnet`, or the older repository on `us-docker.pkg.dev`." | CLOSED | guide 312 ("on testnet also the older `us-docker.pkg.dev/telcoin-network/tn-public/adiri`"); common 1597-1600 (TN_TESTNET_LEGACY_IMAGE_REPO), 1662-1676, 8482. True today and after the first signed release. |
| 3 | "It needs a synced node that advertises a publicly routable RPC URL, then four steps:" | CLOSED for the finding: both requirements hold on testnet (guide 1328-1329; edit-config.sh refuses `allow_private_forward_targets: true` on testnet). NEW, low (UNSUPPORTED order): "then" puts sync and the RPC URL before step 1, Approval. The guide lists them as prerequisites of staking (guide 1307, 1323-1331), and guide 50 and 117 say to write before buying hardware, so approval can start before any node exists. Fix (78 characters, original 84): "Four steps; to stake, sync the node and advertise a publicly routable RPC URL:" Support: guide 1323-1329. | guide 1328-1329 |
| 4 | "Signed releases ship x86_64 Linux tarballs; otherwise build from source or use Docker." | CLOSED | guide 268 (SHA256SUMS lists the binary tarball), 311, 317 (published for x86_64 Linux); common 1813 and 1823-1824 (the unsigned release has no tarball). True today and after the first signed release; names no release (R7). `_tn_release_triple` (common 7636-7642) also knows aarch64, but the guide says only x86_64 is published, so there is no conflict. |
| 5 | Ports row purpose "Caddy: RPC, dashboard" | CLOSED | guide 173-174 |
| 6 | Contact: link text `docs/partner/mno-node-guide/mno-node-guide.pdf` "in the repository below", with the same absolute blob href | CLOSED | The href is absolute (R3). The file is on `origin/main` at v1.9. Live: 200 on this re-check, so the earlier 503s were transient. "below" points at the footer's repository URL, which is printed under it. |

Other changed lines: the ports sentence "Open `443` and `80` only if you serve public RPC or the dashboard." is unchanged. Read together with change 3, it no longer misleads a validator. No new problem in changes 1, 2 and 4-6.

Open: one low item (change 3, the word "then"). Verifier work is complete; the status stays in-progress until the page writer applies the fix or the orchestrator waives it.

Closing check, second pass: the line now reads "It takes four steps; before you stake, the node must be synced and advertise a publicly routable RPC URL:". This matches guide 1323-1329, where a synced node (1328) and the advertised routable RPC URL (1329) are prerequisites of staking, not of approval. The printed PDF is still one page. CLOSED; nothing is open.
