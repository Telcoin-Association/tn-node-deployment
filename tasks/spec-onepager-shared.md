# Shared spec: node requirements one-pagers (2026-11-17)

Branch `docs/node-requirements-one-pagers`, based on `origin/main` b89ada4. Repo root
`/home/drtnarg/coding/telcoin/tn-node-deployment` (called ROOT below). One checkout, shared by
every unit. Agents never commit, stage, stash or switch branch; the orchestrator commits.

## 1. What is being made

Two one-page A4 PDFs for prospective node operators, committed as partner documents and built
by `tools/build-partner-pdf.sh` (pandoc, then WeasyPrint):

| Document | Directory | Title (the single `# ` heading) |
|---|---|---|
| `testnet-node-requirements` | `docs/partner/testnet-node-requirements/` | Adiri testnet node requirements |
| `mainnet-node-requirements` | `docs/partner/mainnet-node-requirements/` | Mainnet node requirements |

Each directory holds `<doc>.md`, `metadata.yaml`, `template.html`, `theme.css` and the built
`<doc>.pdf`. The two `template.html` files are byte-identical, and so are the two `theme.css`
files: every difference between the networks lives in the Markdown and `metadata.yaml`.

## 2. Units and file ownership

| Unit | Owns (may write) | Checkpoint |
|---|---|---|
| S | `tools/build-partner-pdf.sh` | `tasks/ckpt-onepager-S.md` |
| T | `docs/partner/testnet-node-requirements/**` | `tasks/ckpt-onepager-T.md` |
| M | `docs/partner/mainnet-node-requirements/**` | `tasks/ckpt-onepager-M.md` |
| V | nothing but its checkpoint and report | `tasks/ckpt-onepager-V.md` |
| D | `AGENTS.md`, `README.md`, `docs/partner/assets/README.md`, `CHANGELOG.md` | `tasks/ckpt-onepager-D.md` |

A unit that needs a change outside its files says so in its hand-back and does not make it.

## 3. Commands (absolute paths always, never `$PWD`)

Build one document in the container (pandoc 3.8.3, WeasyPrint 70.0, poppler):

```bash
docker run --rm -u "$(id -u):$(id -g)" -e HOME=/tmp \
  -v /home/drtnarg/coding/telcoin/tn-node-deployment:/w -w /w \
  tn-pdf-tools bash tools/build-partner-pdf.sh <doc>
```

Look at the page (the PNG lands in the gitignored `build/` directory; read it with the Read tool):

```bash
docker run --rm -u "$(id -u):$(id -g)" -e HOME=/tmp \
  -v /home/drtnarg/coding/telcoin/tn-node-deployment:/w -w /w \
  tn-pdf-tools pdftoppm -png -r 110 docs/partner/<doc>/<doc>.pdf docs/partner/<doc>/build/page
```

`-r 200` on a cropped region (`-x -y -W -H`) is the way to check small text. `pdftotext -layout`,
`pdffonts` and `pdfinfo` are in the same image.

What the script enforces for a one-pager: exactly one page; one `# ` heading; `toc-depth: 0`;
`contact: devs@telcoin.org` in `metadata.yaml` and the address in the Markdown and in the PDF
text; a `mailto:devs@telcoin.org` link in the PDF; no `title:` in `metadata.yaml`; none of the
forbidden strings (see `FORBIDDEN` in the script) and not the word "legacy", in the Markdown or
in the PDF text; every `href="#..."` must land on an element id. A first build prints
`Wrote ... (1 pages)`; a second build of unchanged sources prints `PDF unchanged`. Never pass
`--force`.

## 4. Page rules

- A4, one page, no cover page, no contents, no running header, no page number.
- Header band across the full width: the guide's navy gradient (`#183988` to `#080821`) with
  `logos/telcoin-network-light.svg`, the title, the subtitle and `Version <version> · <date>`.
- A short status label in the header, driven by a `badge:` key in `metadata.yaml`, so the
  mainnet page can say it has not launched while the template stays identical.
- Body: a full-width block, then two columns. As built by unit T: CSS multi-column on a
  wrapper, not on `main`, because WeasyPrint 70 lays a `column-span: all` box out wider than
  its multi-column parent. The Markdown carries three raw-HTML hooks, with blank lines around
  the Markdown inside them: `<div class="wide">` (full width, holds the hardware table),
  `<div class="columns">` (the rest) and `<div class="col-break"></div>` (starts the right
  column). A table's first column never wraps, so its labels stay short. No flexbox.
- Footer strip: `logos/telcoin-association-dark.svg`, `<a href="mailto:$contact$">$contact$</a>`
  and the repo URL from `repo-url`.
- Look: the guide's brand tokens (`docs/partner/mno-node-guide/theme.css` lines 12-17), Geist
  for text, Geist Mono for code, the guide's table and callout styles scaled down.
- Type sizes: body text no smaller than 7.5 pt, table and code text no smaller than 7 pt. When
  the text does not fit, cut words; do not shrink type below these floors.
- Assets: only files already under `docs/partner/assets/`. No new font, image or raster file
  (a raster image would make the PDF's bytes depend on the checkout path). No network access
  at build time.
- No date beyond the month-only `date:` line, and no `date-meta`, so the PDF stays
  byte-reproducible (see the comment at the top of the guide's `metadata.yaml`).

## 5. Text rules

- The guide at this branch, `docs/partner/mno-node-guide/mno-node-guide.md` (version 1.9), is
  the source of truth. A page states nothing the guide does not state, in the guide's terms.
  Line numbers below are for that file.
- One `# ` title, then `## ` sections only (pandoc shifts them up one level). No prose between
  the title and the first section.
- Links are absolute `https://` URLs. No repo-relative link, no in-document `#anchor` link.
- The only contact is `devs@telcoin.org`.
- British spelling, plain sentences, no em dashes, no marketing words. Writers load the
  `human-writing` skill before writing prose.
- Tables and short lists over paragraphs. Code spans for ports, flags, file names, tags, chain
  IDs in hex, URLs that are meant to be typed.
- Never printed, because they move with each release: the current node version, the scripts
  version, which node release starts signed releases, the oldest supported node release. Do
  not say or imply that every testnet node release is signed.

## 6. Decisions the orchestrator has already taken

- D1. Disk figures follow the guide: at least 2 TB of TLC NVMe (10,000 write IOPS, 300 MB/s),
  4 TB recommended. They match the upstream hardware page at tag `v0.17.0-adiri`. Upstream
  `main` raised them in #1834 (unreleased). A page does not print the `main` figures; the
  verifier records the difference as drift, not as a finding against the page.
- D2. Latency rule. Testnet page: the guide's wording, "a p95 round-trip time well below
  1 second to at least 7 of the 10 committee members". Mainnet page: no committee size, since
  the mainnet committee is not published: "a p95 round-trip time well below 1 second to a
  quorum of the committee". The verifier checks that against the upstream page
  (`docs/src/getting-started/hardware-requirements.md`, the Validator CPU and Networking
  sections) and settles the final wording.
- D3. Mainnet stake: no figure. `prepare-stake.sh` reads the amount on chain.
- D4. Both pages carry the guide's instruction to email `devs@telcoin.org` with the planned
  hardware before buying anything for a validator.
- D5. `metadata.yaml` keys: `subtitle`, `badge`, `version: "1.0"`, `date: November 2026`,
  `author: Telcoin Association`, `description`, `contact: devs@telcoin.org`,
  `repo-url: https://github.com/Telcoin-Association/tn-node-deployment`, `lang: en-GB`,
  `toc-depth: 0`. No `title:`. A header comment like the guide's.

## 7. Facts for the testnet page

| Block | Facts | Guide lines |
|---|---|---|
| Network | EVM-compatible layer 1; Narwhal and Bullshark consensus; reth execution, so Ethereum-style JSON-RPC. Chain ID 2017 (`0x7e1`). Public RPC `https://rpc.adiri.tel`, JSON-RPC over HTTPS only (no WebSocket). Explorer `https://telscan.io`. Status page `https://status.adiri.telcoin.network/`. Six-hour epochs. Node release tags `vX.Y.Z-adiri`; a branch, a commit id or `latest` is refused. Docker image package `ghcr.io/telcoin-association/tn-testnet`, or the older repository on `us-docker.pkg.dev`, which today's default still uses | 5-8, 57, 207, 230, 269, 272, 312, 830, 997 |
| Hardware | Three role tiers, minimum and recommended (physical cores; cloud vCPUs are usually hyperthreads). Storage for every role. Validators: 200 Mbps symmetric minimum, 1 Gbps recommended, and the latency rule (D2). ECC RAM for validators. Swap off, time sync, data directory on ext4 or xfs. Email before buying validator hardware (D4) | 98-128 |
| Operating system and host | Ubuntu 24.04 LTS. On testnet Debian 12 and Ubuntu 22.04 are accepted (systemd 247 or newer; below 250 the passphrase stays in a root-only file). Signed releases ship x86_64 Linux tarballs; otherwise build from source or use Docker (no testnet release has a tarball until the first signed one). A TPM 2.0 or vTPM is optional on testnet. Setup stops until the CVE-2026-31431 kernel mitigation is in place. macOS is not supported | 138-165, 317, 335 |
| Ports | 49590/UDP and 49594/UDP inbound from everywhere on every node. 443/TCP and 80/TCP only when Caddy serves public RPC or the dashboard. 8545, 8546 and 9101 loopback only. SSH from your admin addresses | 169-187 |
| Install | The installer one-liner and `sudo bash ~/telcoin-node-scripts/setup-node.sh`. Install methods: build from source, signed release, Docker, or a binary you supply. The scripts come from a signed release tag and are checked with `gpgv` before anything installs. Nothing about node release signatures on the testnet page: `v0.17.0-adiri` is unsigned and passes by a one-tag exception in `lib/common.sh`, so no testnet node release is signed yet | 255, 267-268, 280, 310-313 |
| Roles and validating | Anyone can run a node; no approval is needed to install one, follow consensus and serve JSON-RPC. Validating is on chain: only GSMA-member mobile network operators the Telcoin Association has approved. Before staking, the node must be synced and advertise a publicly routable RPC URL (a prerequisite of the stake, not of approval). Four steps: approval (a ConsensusNFT minted to the execution address), stake (1,000,000 TEL on testnet today; `prepare-stake.sh` reads the current amount), activation, committee selection (earliest seat is epoch E+3 when `activate()` is mined in epoch E; 12 to 18 hours on six-hour epochs) | 12-20, 77-82, 1324-1331, 1494-1496 |
| Contact | `devs@telcoin.org`; the full guide PDF `https://github.com/Telcoin-Association/tn-node-deployment/blob/main/docs/partner/mno-node-guide/mno-node-guide.pdf`; the repository | 27, 46-50 |

## 8. Facts for the mainnet page

| Block | Facts | Guide lines |
|---|---|---|
| Status | Mainnet has not launched. The scripts refuse a mainnet install until the scripts release that launches it; `update-scripts.sh` brings that release | 211-228 |
| Network | Chain ID 487 (`0x1e7`). Public RPC `https://rpc.telcoin.network` is planned and set at launch; today it answers for the testnet, so check the chain ID. Explorer not launched yet. Six-hour epochs. Node release tags `vX.Y.Z`. Docker image package `ghcr.io/telcoin-association/tn-mainnet` | 208, 217, 233, 269, 272, 830 |
| Hardware | The same role tiers, storage and validator network figures as testnet (the guide's table is not split by network); latency rule in the D2 mainnet form; email first (D4) | 98-128 |
| Operating system and host | Ubuntu 24.04 LTS only (systemd 255 or newer). A TPM 2.0 or vTPM, or `--allow-no-tpm`. BLS passphrase of at least 16 bytes. Logs go to the systemd journal by default. CVE-2026-31431 mitigation required | 138-151, 162, 195, 336, 573 |
| Ports and exposure | The same P2P ports. RPC is never bound to a public address (mainnet refuses it). Enabling the firewall needs the SSH sources. `install-caddy.sh` refuses public RPC and the dashboard on a staked validator; serve public RPC from a separate node | 169-187, 415, 436, 866, 1199 |
| Stricter than testnet | Release tags only, with the signature mandatory, source builds included. A Docker image is named by its release tag and its digest comes from the signed release. `--passphrase-method stdin` is refused. The testnet add-ons are refused | 269, 273, 316, 338, 1014 |
| Validating | The same four steps. The stake amount is read on chain by `prepare-stake.sh`; no figure is printed | 77-82, 1324-1331 |
| Contact | `devs@telcoin.org`; the full guide PDF; the repository | 46-50 |

Every item on the mainnet page that is not decided yet is marked "set at launch". No invented
figure, date or endpoint.

## 8a. Changes after the testnet verification (2026-11-17)

Sections 7 and 8 above carry the corrected facts. What the testnet verifier changed, for the
record: ports 443 and 80 belong to Caddy (public RPC or the dashboard; port 80 is certificate
issuance and the redirect); the testnet Docker default still pulls from the older registry;
no testnet release is signed or has a tarball yet, so the page says nothing about node release
signatures and ties tarballs to signed releases; a validator must have a synced node that
advertises a publicly routable RPC URL before it stakes. The guide's lines 312 and 745 say
signed releases start with `v0.17.0-adiri`; `lib/common.sh` (`TN_UNSIGNED_RELEASE_TAG`) says
that tag is the last unsigned one. That is a guide defect, reported to the user, not fixed in
this round.

## 8b. Changes after the mainnet verification (2026-11-17)

The mainnet verifier found nothing wrong and four statements that said more than the guide
does. As committed, the page says: the public RPC URL "is planned and set at launch" (the URL
itself is not final); the explorer is "Not launched yet" (the guide's words, not "set at
launch"); "Source, release, Docker: signed `vX.Y.Z` release tags only" (a binary the operator
supplies is not held to release tags); "Mainnet keeps RPC on `127.0.0.1`; the firewall asks
for SSH sources" (mainnet refuses the `0.0.0.0` bind, not public RPC as such, and the
firewall accepts `--ssh-anywhere`); and `install-caddy.sh` "refuses public RPC and the
dashboard on a staked validator; it suggests a separate RPC node", which removes the
contradiction with the validating paragraph's "advertise a publicly routable RPC URL". D2 is
settled: "to a quorum of the committee" stands, because the upstream page calls its 7 of 10
the quorum. The oldest supported mainnet release is not on the page.

## 9. Hand-back and checkpoints

Each unit rewrites its checkpoint (a `status:` header and the list of completed sections) after
each section, and on start reads its own checkpoint and continues from the first unfinished
section. If Write is refused for a checkpoint or report, the unit returns the complete text in
its final answer and does not work around the refusal. A unit trending past about 150k tokens
checkpoints and hands back what it has. Final answers are summaries, not file dumps.
