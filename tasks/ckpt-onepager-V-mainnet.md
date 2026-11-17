status: done
completed: V1, V2, V3, V4, V5

# Unit V (mainnet) — verification of docs/partner/mainnet-node-requirements (af19f36)

Guide = docs/partner/mno-node-guide/mno-node-guide.md (v1.9). `c:` = lib/common.sh.

## V1. Facts derived from the sources (before reading the page)

### Network status / switch
- F1. Mainnet has not launched; menu lists it as coming soon. Guide 9, 211, 218; c:3100 `(coming soon)`.
- F2. `TN_MAINNET_ENABLED=0` (c:37); tested by `tn_mainnet_enabled` (c:41-43) at: menu `2)` (c:3117, message `Mainnet has not launched yet.` c:3126), `--json --network mainnet` (setup-node.sh:3357-3358), UI helper (ui/telcoin-ui-helper.sh:1552-1553). Guide 220-225.
- F3. The release that launches mainnet sets the switch to 1 with the chain-config pins and the oldest mainnet node release; `update-scripts.sh` brings it. Guide 227; c:31-36. Setting the switch by hand gains nothing: no pins -> chain-config check refuses (guide 228; c:7176-7178, c:7470-7472 Docker refused with no pins). `MIN_SOURCE_VERSION_MAINNET=""` (c:123): "mainnet gets its floor at launch" (guide 270).
- F4. Two settings still open: mainnet chain-config SHA-256 pins, and the public RPC (set at launch). Guide 211-214.

### Endpoints
- F5. Mainnet chain ID 487 (0x1e7). c:26; guide 208.
- F6. Mainnet public RPC: `https://rpc.telcoin.network` "is planned and set at launch" (guide 208, 214); c:28 comment "the planned public endpoint". Today it answers for the testnet, chain 2017 (guide 233).
- F7. Mainnet explorer: guide 208 "Not launched yet". c:29 `MAINNET_EXPLORER="https://telscan.io"` = the testnet explorer (c:22), read only after `tn_mainnet_enabled` (c:3117-3122, setup-node.sh:3357-3360): a placeholder copy, not a decided mainnet explorer. Guide wording stands.
- F8. Image package `ghcr.io/telcoin-association/tn-mainnet` is set (c:1580; guide 217, 272).

### Epochs
- F9. Guide 830: "On the six-hour epochs of mainnet and testnet (21600 seconds)". c:57 `MAINNET_EPOCH_DURATION="21600"`, used only for the blind restart wait (c:53-56). Upstream v0.17.0-adiri crates/telcoin-network-cli/src/genesis/mod.rs:570-575: `MAINNET_EPOCH_DURATION_SECS = 21_600`, "6 hours ... (issue #1512) ... the gate below pins it", "the mainnet target of issue #1512"; the committed mainnet genesis is a placeholder (mod.rs:565). So: a stated target pinned by upstream's genesis-regeneration gate, not a launched genesis.

### OS
- F10. Ubuntu 24.04 LTS; mainnet installs only on systemd 255+ (guide 138-139, 145-148; c:5837 `TN_MAINNET_MIN_SYSTEMD=255`, enforced c:5873-5875 for any net not testnet/devnet).
- F11. TPM 2.0 or vTPM; a mainnet install stops without one unless `--allow-no-tpm` (guide 150-151, 336; c:5886-5895; setup-node.sh:561-565).
- F12. BLS passphrase: not empty, no line break, no leading/trailing whitespace; on mainnet at least 16 bytes (guide 195; c:1750, 1762-1766; setup-node.sh:1722).
- F13. `--passphrase-method stdin` refused on mainnet (guide 338; setup-node.sh:550-552, 3699).
- F14. Log target: `journal` default on mainnet, capped by journald drop-in SystemMaxUse=4G, SystemKeepFree=2G (guide 573; setup-node.sh:2747-2749; c:3563, 4084-4095). `file` default on testnet.
- F15. Copy Fail (CVE-2026-31431) mitigation required by preflight; <https://copy.fail> (guide 162-164).

### Ports / firewall
- F16. Ports: 49590/udp and 49594/udp everywhere inbound; 443/80 tcp only with Caddy; 8545/8546/9101 loopback only; 43174 testnet add-on; 22 admin IPs (guide 169-179).
- F17. Mainnet refuses RPC bound to 0.0.0.0: edit-config `set_rpc_addr` (edit-config.sh:2742-2745 "a mainnet node keeps its RPC on 127.0.0.1; public RPC goes through install-caddy.sh"); guide 866.
- F18. Firewall on mainnet: an enable with no SSH source list stored or given stops "...give the SSH sources with --ssh-from CIDR[,CIDR] (or --ssh-anywhere to keep SSH open to every address)" (firewall-setup.sh:2168-2170; guide 436). Menu: Enter with no sources asks `Keep SSH open to every address anyway?`, No cancels, Yes proceeds open (firewall-setup.sh:2788-2796; guide 415). So it needs SSH sources OR an explicit keep-open choice.

### Install / releases
- F19. Node runs release tags only: `vX.Y.Z` on mainnet, finals only, no rc (c:1793; guide 269).
- F20. Mainnet source build needs a tag signed by a release key; unverifiable signature refuses on mainnet (c:8811-8822; guide 316). Unsigned exception testnet-only (c:1825-1826).
- F21. Mainnet Docker: image named by release tag, digest from the signed release; a digest alone only when .node-meta records it as a mainnet release image the node installed (guide 273; setup-node.sh:1037-1042; c:8500-8502). Mainnet never falls back to registry/default (c:1629, 1654-1656).
- F22. Docker install on mainnet is refused today: no mainnet pins -> `tn_docker_network_ok` refuses (c:7470-7472; guide 216).
- F23. Testnet add-ons: add-on scripts `require_testnet` (c:9207-9213; setup-vpn.sh:1551, setup-observability.sh:649/901/909); a mainnet install refuses a host with an add-on present (setup-node.sh:2085-2089; guide 1013-1014). Note: `tn_testnet_addons_present` also counts a managed Caddy edge (c:9279-9299), so a mainnet setup also refuses a host where install-caddy.sh already runs — not in the guide; does not make "add-ons refused" false.
- F24. `install-caddy.sh` on mainnet refuses dashboard and public RPC on a staked validator, and on any node it cannot confirm is not one (no VALIDATOR_ADDRESS, unreadable stake, unknown network); message suggests a separate RPC node (install-caddy.sh:2331-2355, 49-50; guide 1199-1200).

### Validating
- F25. Validator steps: Association approval (ConsensusNFT), stake, activation, committee selection (guide 77-82). Only GSMA-approved MNOs after Association approval (guide 15).
- F26. Prerequisite: a publicly routable RPC URL advertised in `node-info.yaml`; other nodes forward user txs to committee's advertised URLs and skip private addresses (guide 1329, 1195).
- F27. Stake: 1,000,000 TEL on testnet today; `prepare-stake.sh` reads the current amount (guide 1330; prepare-stake.sh:996-1000 `stakeConfig(getCurrentStakeVersion())` via `tn_stake_amount_wei`).
- F28. `activate()` mined in epoch E -> active E+1; committee fixed two epochs ahead, earliest seat E+3 (guide 1494-1495; prepare-stake.sh:1306, 1321; check-node.sh:1600). Guide 1496's "12 to 18 hours" is stated for testnet's six-hour epochs.
- F29. Contact devs@telcoin.org; validators write before buying hardware (guide 48-50).

### Upstream latency (telcoin-network v0.17.0-adiri docs/src/getting-started/hardware-requirements.md)
- F30. Line 38: "Every validator tier also needs a p95 round-trip time well below 1 s to at least 7 of the 10 committee members". Line 396 same. Line 171: a header needs votes from ⌊2N/3⌋ + 1 committee members, "which is 7 of 10" [^quorum]; line 394 "about 1.5 round trips to the quorum". So upstream itself names ⌊2N/3⌋+1 the quorum and 7 of 10 its value at N=10.

## V2. Rules applied (spec sections 5, 6, 8a)
- R5: guide v1.9 is the source of truth, in its terms; one `# ` title then `## ` only, no prose before first section; absolute https links only; only contact devs@telcoin.org; British spelling, no em dashes, no marketing words; tables/short lists; code spans for ports, flags, files, tags, hex chain IDs, typed URLs; never print current node version, scripts version, which release starts signing, oldest supported release; do not imply every testnet node release is signed.
- D2: mainnet latency wording "well below 1 second to a quorum of the committee", to be settled here against upstream.
- D3: no mainnet stake figure. D4: email before buying validator hardware. D5: metadata keys.
- 8a: 443/80 belong to Caddy; validator needs a synced node advertising a publicly routable RPC URL before staking.

## V3. Statement table (page af19f36: .md, metadata.yaml, pdftotext, build/page-1.png)

Hardware lines identical to the testnet page (diff): table rows, CPU bullet, QLC bullet, every-node bullet, email callout. Those cite the testnet verifier's rows (tasks/ckpt-onepager-V-testnet.md, "T#n"). `ic` = install-caddy.sh, `su` = setup-node.sh, `fw` = firewall-setup.sh, `ec` = edit-config.sh, `ps` = prepare-stake.sh, `up` = upstream hardware page at v0.17.0-adiri.

| # | Statement (as printed) | Source | Verdict |
|---|---|---|---|
| 1 | Badge "Mainnet · not launched" | guide 9, 211; c:37 | OK |
| 2 | Title "Mainnet node requirements" | guide 208 | OK |
| 3 | Subtitle "Hardware, host, ports and install for a Telcoin Network node" | page scope | OK |
| 4 | "Version 1.0 · November 2026" | D5 (page version, not a node or scripts version) | OK |
| 5 | metadata description "...ahead of the mainnet launch..." | guide 211 | OK |
| 6 | metadata keys (no title, contact, repo-url, lang en-GB, toc-depth 0, header comment) | D5 | OK |
| 7 | WARNING "Mainnet has not launched" | guide 211 | OK |
| 8 | "the scripts refuse it" | guide 220-225; c:37, 3117-3126; su:3357-3358; ui/telcoin-ui-helper.sh:1552-1553 | OK |
| 9 | "until `update-scripts.sh` brings the scripts release that launches it" | guide 227 (switch to 1 with pins and floor; "update-scripts.sh brings it"); c:31-36 | OK (a fresh host gets that release from the installer instead; not misleading) |
| 10-19 | Hardware table, 10 cells | T#7-16 (guide 104-113; up 28-35; c:87-90) | OK (drift DR1/DR2 as on testnet) |
| 20 | "CPU counts are physical cores; ... 8 vCPU instance has about 4." | T#17 | OK |
| 21 | "A validator also needs a p95 round-trip time well below 1 second to a quorum of the committee." | D2; up 38, 396 ("at least 7 of the 10"), up 171 ("votes from ⌊2N/3⌋ + 1 committee members ... which is 7 of 10"), up 394 ("about 1.5 round trips to the quorum"); guide 114 per T#18 | OK: upstream itself names that set "the quorum" and defines it as ⌊2N/3⌋+1; "a quorum" = at least that many members. Final wording: unchanged |
| 22 | "Avoid QLC drives: they wear out under continuous chain writes." | T#19 | OK |
| 23 | "Every node: swap off, time sync on, data directory on ext4 or xfs; the scripts check none of these." | T#20-22 | OK |
| 24 | IMPORTANT "Email devs@telcoin.org with your planned hardware before you buy anything for a validator." | T#23; guide 50; D4 | OK |
| 25 | Chain ID "487 (`0x1e7`)" | guide 208; c:26 | OK |
| 26 | Public RPC "`https://rpc.telcoin.network`, set at launch" | guide 208 ("is planned and set at launch"), 211-214 (the public RPC is one of two settings still open), 233 ("reserved for mainnet"); c:25,28 ("the planned public endpoint") | OVERSTATED (low-medium): drops "planned"; "X, set at launch" reads as a decided endpoint that goes live at launch |
| 27 | "today it answers for the testnet" | guide 233; live V4 | OK (see V4) |
| 28 | Explorer "Not launched yet" | guide 208. c:29 `MAINNET_EXPLORER="https://telscan.io"` is a copy of the testnet explorer (c:22), read only once the switch is 1 (c:3117-3122; su:3357-3360) | OK |
| 29 | Epochs "Six hours" | guide 830 ("the six-hour epochs of mainnet and testnet (21600 seconds)"); c:57 (fallback only, c:53-56); upstream genesis/mod.rs:570-575 (mainnet target 21_600, pinned by the regeneration gate, issue #1512) | OK (fixed for good by the launch genesis; see point 4) |
| 30 | "Ubuntu 24.04 LTS only (systemd 255 or newer)." | guide 138-139, 145-148; c:5837, 5873-5875 | OK (the code checks systemd >= 255, not the distribution; guide 139 "which means Ubuntu 24.04") |
| 31 | "Release tarballs are x86_64 Linux; on another architecture, build from source or use Docker." | guide 317, 311 | OK (mainnet has no release of any kind yet; every mainnet release is signed, guide 268-269) |
| 32 | "macOS is not supported." | guide 153 | OK |
| 33 | "A BLS passphrase of at least 16 bytes" | guide 195; c:1750, 1762-1766; su:1722 | OK (the base rules, not empty/no line break/no edge whitespace, are left out; not misleading) |
| 34 | "and a TPM 2.0 or vTPM unless you pass `--allow-no-tpm`" | guide 150-151, 336; c:5886-5895; su:561-565 | OK |
| 35 | "Logs go to the systemd journal by default." | guide 573; su:2747-2749; c:3563 | OK |
| 36 | "Setup stops until the CVE-2026-31431 kernel mitigation (https://copy.fail) is in place." | guide 162-164; T#37 | OK |
| 37 | `49590`, `49594` UDP / Everywhere / P2P (QUIC), every node | guide 171-172, 181; c:75-76 | OK |
| 38 | `443`, `80` TCP / Everywhere / Caddy: RPC, dashboard | guide 173-174 | OK |
| 39 | `8545`, `8546` TCP / Loopback only / JSON-RPC | guide 175-176 | OK |
| 40 | `9101` TCP / Loopback only / Metrics | guide 177; c:79 | OK |
| 41 | `22` TCP / Your admin IPs / SSH (or your SSH port) | guide 179 | OK |
| 42 | "Open the UDP ports on every node, in every layer that filters traffic (`ufw`, cloud firewall, NAT)." | guide 181, 187 | OK |
| 43 | "Open `443` and `80` only for public RPC or the dashboard." | guide 173-174 | OK |
| 44 | "Mainnet refuses JSON-RPC on a public address" | guide 866 ("binds it to `0.0.0.0`, which mainnet refuses"); ec:2742-2745 ("a mainnet node keeps its RPC on 127.0.0.1; public RPC goes through install-caddy.sh"); su:2774, 2783 (setup always writes `--http.addr 127.0.0.1`) | OVERSTATED (low-medium): true of reth's own bind; false of public RPC through Caddy, which mainnet allows on a node that is not a staked validator (ic:2339-2352) and which row 43 just told the reader to open 443/80 for |
| 45 | "enabling the firewall needs SSH sources" | guide 415, 436; fw:2168-2170, 2788-2796 | OVERSTATED (low): it needs SSH sources or an explicit choice to keep SSH open (`--ssh-anywhere`, or Yes to `Keep SSH open to every address anyway?`) |
| 46 | "Run the installer without `sudo`, then run setup:" | guide 252, 279-281 (T#45) | OK (the refusal follows directly; see point 10) |
| 47 | `curl --proto '=https' --tlsv1.2 -fsSL https://install.telcoin.network \| bash` | T#46; live V4 | OK |
| 48 | `sudo bash ~/telcoin-node-scripts/setup-node.sh` | T#47 | OK |
| 49 | "Setup's `2) Mainnet` choice is refused until launch." | guide 223; c:3116-3130 | OK |
| 50 | "Signed release tags only, `vX.Y.Z`, for a source build too." | guide 269, 311, 316; c:1793, 8811-8822; su:1037-1042 | OVERSTATED (low): true of source, release and Docker; `4) I already have it` (guide 313; c:3149, 3159; su:1123-1157) runs a binary you supply with no tag, signature or build-feature check on mainnet |
| 51 | "Docker: `ghcr.io/telcoin-association/tn-mainnet`, by release tag; the signed release gives the digest." | guide 217, 272-273; c:1580, 8500-8502; su:1037-1052 | OK (a digest alone passes only for a mainnet release the node recorded, guide 273; fine to omit) |
| 52 | "Testnet add-ons are refused, and so is a server that has one." | guide 1013-1014; c:9207-9213; su:2085-2089 | OK (code also counts a managed Caddy edge as present, c:9279-9299; not in the guide, note only) |
| 53 | "`install-caddy.sh` refuses public RPC and the dashboard on a staked validator." | guide 1199-1200; ic:2331-2355, 49-50 | OK on its own; MISSING with row 56 (see point 8): the guide's resolution, a separate RPC node (guide 1200; ic:2353), is not on the page |
| 54 | "Anyone can run a node." | guide 12-13 | OK |
| 55 | "Validating is an on-chain step, only for GSMA-member mobile network operators the Telcoin Association has approved." | guide 6, 14-15 (T#54) | OK |
| 56 | "It takes four steps; before you stake, sync the node and advertise a publicly routable RPC URL:" | guide 77, 1328-1329 | OK on its own; see row 53 |
| 57 | "1. Approval: a ConsensusNFT minted to your execution address." | guide 79 | OK |
| 58 | "2. Stake: `prepare-stake.sh` reads the amount on chain." | guide 1330; ps:996-1000 (`stakeConfig(getCurrentStakeVersion())` from the network RPC); D3 | OK |
| 59 | "3. Activation." | guide 81 | OK |
| 60 | "4. Committee selection: if `activate()` is mined in epoch E, the earliest seat is epoch E+3." | guide 1494-1495; ps:1306, 1321; check-node.sh:1600 | OK (no hours printed: guide 1496 gives hours for testnet only) |
| 61 | "Email devs@telcoin.org about running a node, validator onboarding, approval or hardware." | guide 48-49 | OK |
| 62 | "The full operator guide is `docs/partner/mno-node-guide/mno-node-guide.pdf` in the repository below." (href blob/main) | T#61, closing check #6; live V4 | OK (see V4) |
| 63 | Footer "devs@telcoin.org · https://github.com/Telcoin-Association/tn-node-deployment" | D5 | OK |

Text rules (spec 5): no em/en dash, no US spelling hit, no anchor or relative link, only devs@telcoin.org, one `# ` title then `## `, no node or scripts version printed (grep). Printed PDF: 1 page; left column ends with row 45, right with row 62, both just above the footer.

## V4. Live checks (2026-11-17 17:37 UTC, curl defaults, public endpoints printed on the page only)

- `eth_chainId` POST to https://rpc.telcoin.network: `{"jsonrpc":"2.0","id":1,"result":"0x7e1"}`, chain 2017, the testnet. Matches "today it answers for the testnet" (row 27) and guide 233.
- https://install.telcoin.network: 200 (first try).
- https://copy.fail: 200 (first try).
- Guide PDF href https://github.com/Telcoin-Association/tn-node-deployment/blob/main/docs/partner/mno-node-guide/mno-node-guide.pdf: 200 (first try). The testnet verifier's earlier 503s did not recur.

## V5. Report

63 statements checked (rows 1-63): 58 OK, 5 not OK (rows 26, 44, 45, 50, and the MISSING on 53/56). No WRONG, no GUIDE-DEFECT, no RULE. Nothing on the page says or implies that a mainnet node installs today.

### Answers to the eleven points

1. Latency (row 21). Upstream supports it. Lines 38 and 396 say "at least 7 of the 10 committee members". Line 171 gives the general form: a header needs votes from ⌊2N/3⌋ + 1 committee members, "which is 7 of 10". Line 394 calls that set "the quorum" ("about 1.5 round trips to the quorum"). So "a quorum of the committee" is upstream's own general term for its 7 of 10, and it prints no committee size (D2). Final wording, unchanged: "A validator also needs a p95 round-trip time well below 1 second to a quorum of the committee."
2. Status line (rows 7-9). Every part is true. "Has not launched": guide 211. "The scripts refuse it": guide 220-225. `TN_MAINNET_ENABLED=0` (c:37) is tested at the menu (c:3117-3126), at `--json --network mainnet` (su:3357-3358) and in the UI helper (ui/telcoin-ui-helper.sh:1552-1553). "Until `update-scripts.sh` brings the scripts release that launches it": guide 227 and c:31-36 (the switch goes to 1 together with the pins and the mainnet floor). Flipping the switch by hand gains nothing (guide 228; c:7470-7472). A host that installs the scripts after launch gets that release from the installer instead, which is not misleading.
3. Public RPC and Explorer. RPC cell: OVERSTATED. Guide 208 says "is planned and set at launch", and guide 211-214 list the public RPC as one of two settings still open. The page drops "planned", so "X, set at launch" reads as a decided endpoint that only goes live at launch. "Today it answers for the testnet" is true: live, it returns `0x7e1`. Explorer cell "Not launched yet" is right. `MAINNET_EXPLORER="https://telscan.io"` (c:29) is a copy of `TESTNET_EXPLORER` (c:22), read only once the switch is 1 (c:3117-3122; su:3357-3360). It is a placeholder, not a decided mainnet explorer.
4. Epochs "Six hours" (row 29). This is more than a script default. Guide 830 states it for mainnet ("the six-hour epochs of mainnet and testnet (21600 seconds)"). c:57 is only the blind-wait fallback (c:53-56). Upstream v0.17.0-adiri `crates/telcoin-network-cli/src/genesis/mod.rs:570-575` sets `MAINNET_EPOCH_DURATION_SECS = 21_600`, "the mainnet target" (issue #1512), and the genesis regeneration gate pins it. It becomes final only with the launch genesis; the committed one is a placeholder (mod.rs:565). OK.
5. OS bullets (rows 30-36): all OK. Ubuntu 24.04 / systemd 255: guide 138-139; c:5837, 5873-5875. Tarballs: guide 317. macOS: guide 153. 16 bytes: guide 195; c:1762-1766; su:1722. TPM / `--allow-no-tpm`: guide 150-151, 336; c:5886-5895; su:561-565. Journal by default: guide 573; su:2747-2749. Copy Fail: guide 162-164.
6. Ports sentence (rows 44-45). Both halves are OVERSTATED. Mainnet refuses a `0.0.0.0` reth bind (guide 866; ec:2742-2745; setup always writes `--http.addr 127.0.0.1`, su:2774, 2783). But mainnet does allow JSON-RPC on a public address through Caddy, on any node that is not a staked validator (ic:2339-2352). Row 43, one line above, tells the reader to open 443 and 80 for exactly that. "Needs SSH sources" is also overstated: an enable goes through with `--ssh-anywhere` (fw:2168-2170; guide 436) or with Yes to `Keep SSH open to every address anyway?` (fw:2788-2796; guide 415).
7. Install bullets. (a) Signed tags: true for source (c:8818-8822; guide 316), release (guide 311) and Docker (guide 273). OVERSTATED: `4) I already have it` (guide 313; c:3149, 3159; su:1123-1157) runs a binary you supply on mainnet, with no tag, signature or build-feature check. (b) Docker by tag with the digest from the signed release: OK (guide 272-273; su:1037-1052; c:8500-8502). (c) Add-ons: OK (guide 1013-1014; c:9207-9213; su:2085-2089). (d) Caddy: OK on its own (guide 1199; ic:2331-2355). See 8.
8. Yes, the page leaves a contradiction. Row 56 says to advertise a publicly routable RPC URL before staking. Row 53 says Caddy refuses public RPC on a staked validator, and row 43 ties 443 and 80 to public RPC. The guide resolves it at 1200: "Its message suggests serving public RPC from a separate RPC node." `install-caddy.sh:2353` says the same: "public RPC from a separate RPC node". One clause fixes it, at the same length: "`install-caddy.sh` refuses staked validators; public RPC goes on another node." (76 characters; original 76.)
9. Stake and E+3: OK. Stake: guide 1330; ps:996-1000 reads `stakeConfig(getCurrentStakeVersion())` from the network's RPC, with no figure printed (D3). E+3: guide 1494-1495; ps:1306, 1321; check-node.sh:1600. No hours are printed, correctly: guide 1496 gives hours for testnet only.
10. No. The WARNING band at the top says the scripts refuse mainnet, and the line directly under the two commands says `2) Mainnet` is refused until launch (guide 223; c:3116-3130). Today those commands install the scripts and a testnet node only. Today a mainnet Docker install is also refused for lack of pins (c:7470-7472; guide 216).
11. Undecided or launch-dependent content: (a) the RPC URL, which is planned (finding 3). (b) Six-hour epochs and chain ID 487: guide-stated and in the scripts (c:26, c:57) and upstream's target (`genesis/mod.rs`: "chain id 0x1e7 (487), unchanged from the committed genesis"), final only with the launch genesis. (c) The disk figures: guide v1.9 equals upstream at the tag, but upstream `main` has raised them (drift DR1/DR2 in the testnet report). If launch ships from `main`, the storage row understates what to buy. False on launch day, as intended: the badge, the WARNING, "set at launch; today it answers for the testnet", "Explorer: Not launched yet" and "`2) Mainnet` is refused until launch". metadata.yaml's comment already says to change the badge with the launch update. Nothing invented.

### Findings, by severity, with replacement wording (none longer than the text it replaces)

1. MISSING, medium (rows 53 and 56; point 8). "`install-caddy.sh` refuses public RPC and the dashboard on a staked validator." (76) -> "`install-caddy.sh` refuses staked validators; public RPC goes on another node." (76). Sources: guide 1199-1200; ic:2331-2355, especially 2353.
2. OVERSTATED, low-medium (row 44) and low (row 45), one sentence. "Mainnet refuses JSON-RPC on a public address; enabling the firewall needs SSH sources." (86) -> "Mainnet keeps RPC on `127.0.0.1`; the firewall asks for SSH sources." (66). Sources: guide 866 and ec:2744 ("a mainnet node keeps its RPC on 127.0.0.1; public RPC goes through install-caddy.sh"); guide 413-415 and 436; fw:2168-2170, 2788-2796. "Asks for" is true of the menu, which asks, and of the CLI, which stops until you give sources or `--ssh-anywhere`. If more room is wanted: "...; the firewall needs SSH sources or `--ssh-anywhere`." (81 in all).
3. OVERSTATED, low-medium (row 26; point 3). "`https://rpc.telcoin.network`, set at launch; today it answers for the testnet" (76) -> "`https://rpc.telcoin.network`, planned, set at launch; now serves the testnet" (75). Sources: guide 208, 211-214 and 233; c:25 and 28.
4. OVERSTATED, low (row 50; point 7a). "Signed release tags only, `vX.Y.Z`, for a source build too." (57) -> "Source, release, Docker: signed `vX.Y.Z` release tags only." (57). Sources: guide 269, 273, 311, 313, 315 and 316; c:8818-8822; su:1037-1042.

### Notes for the orchestrator (not findings against the page)

- Script, before launch: `MAINNET_EXPLORER` (c:29) equals the testnet explorer. If the launch release keeps it, setup's summary prints `Explorer=https://telscan.io` for a mainnet node (su:3172).
- Script vs guide: `tn_testnet_addons_present` (c:9279-9299) also counts a Caddyfile managed by the Node Manager. A mainnet setup therefore refuses a host where `install-caddy.sh` already ran (su:2085-2089). Guide 1013-1014 does not say so: install the node first, then Caddy.
- Guide: 269 ("The node runs release tags only") does not except `4) I already have it` (313), which mainnet accepts unchecked. That is consistent with how the guide describes 313, but a reader of 269 would assume every mainnet node binary is a signed release.
- Guide gap behind finding 1: the guide never says outright that a mainnet validator's advertised `node-info.yaml` RPC URL may be served by a separate RPC node. 1200 only reports Caddy's suggestion. Whether forwarding works that way is a protocol question; worth confirming with the node team before launch.
- Layout: finding 1 has the same length and finding 3 is shorter. Finding 2 removes 20 characters and adds one code span. Finding 4 has the same length, with the code span unchanged. None should add a line; rebuild and check that the page is still 1 page.

## Closing check (git diff HEAD on the page; PDF and page-1.png rebuilt 11:40, 1 page)

| # | Change (as printed) | Verdict | Support |
|---|---|---|---|
| 1 | "`install-caddy.sh` refuses public RPC and the dashboard on a staked validator; it suggests a separate RPC node." | CLOSED | guide 1199-1200 (the guide's own verb); ic:2353 ("public RPC from a separate RPC node"). Point 8: the contradiction is gone. A reader who must advertise a publicly routable RPC URL (row 56) is now told where public RPC goes once Caddy refuses. The last step, putting the separate node's URL in `node-info.yaml`, is left for the reader to infer. The guide stops at the same place (V5 note 4), so the page cannot go further until the guide does. That gap is the guide's, not open on the page. No new problem; the bullet still wraps to 2 lines. |
| 2 | "Mainnet keeps RPC on `127.0.0.1`; the firewall asks for SSH sources." | CLOSED | guide 866; ec:2742-2745; su:2774, 2783; guide 413-415, 436; fw:2168-2170, 2788-2796. It now agrees with the line above it (443/80 for public RPC through Caddy) and the 8545/8546 loopback rows. No new problem. |
| 3 | "`https://rpc.telcoin.network` is planned and set at launch; today it serves the testnet" | CLOSED | guide 208 verbatim, 233; live `eth_chainId` = `0x7e1`. The cell still takes 2 lines. No new problem. |
| 4 | "Source, release, Docker: signed `vX.Y.Z` release tags only." | CLOSED | guide 269, 273, 311, 315-316; c:8818-8822; su:1037-1042. `4) I already have it` is no longer covered by the claim. It partly repeats the Docker bullet below, which is harmless. No new problem. |

Layout: pdfinfo shows 1 page. In page-1.png both columns end just above the footer; the left ends "...the firewall asks for SSH sources.", the right "repository below.". Changes 1 and 3 are longer than my proposals but take no extra line.

Nothing open on the page. The four orchestrator notes in V5 stand: explorer constant, Caddy counted as an add-on, guide 269 vs 313, and the advertised-URL gap in the guide.
