# Checkpoint: unit M (mainnet node requirements one-pager)

status: DONE (M1-M4 complete; hand-back sent)

## Completed sections

- M1 Copies and metadata
  - `cp` template.html and theme.css from docs/partner/testnet-node-requirements/
  - `cmp` template.html pair: silent, exit 0; `cmp` theme.css pair: silent, exit 0
  - metadata.yaml written: badge "Mainnet · not launched", subtitle same as testnet page,
    keys per spec D5, header comment adapted
- M2 Content: docs/partner/mainnet-node-requirements/mainnet-node-requirements.md
  - Status (wide, WARNING callout, one line): guide 211-228 (216, 220-227)
  - Hardware per role (wide): guide 99-100 cores, 102-108 table, 109 QLC, 113 bandwidth,
    114 latency in spec D2 mainnet form, 116-117 email (D4), 119-126 swap/time/fs
  - Network: 208 (chain ID, RPC planned/set at launch, explorer not launched),
    233 (RPC answers for the testnet today), 830 (six-hour epochs)
  - Operating system and host: 138-139 + 143-148 (Ubuntu 24.04 only, systemd 255),
    317 x86_64, 153 macOS, 195 passphrase 16 bytes, 150-151 + 336 TPM / --allow-no-tpm,
    162-164 CVE
  - Ports: 169-187 (table, UDP everywhere), 173-174 (443/80 = Caddy), 866 (mainnet refuses
    a public RPC bind)
  - Install: 255 installer + setup, 223 `2) Mainnet` refused, 269 + 316 + 268 signed
    release tags only incl. source builds, 227 + 270 oldest release set at launch,
    217 + 272-273 Docker image by release tag, digest from the signed release
  - Roles and validating: 12-15, 1328-1329 (synced node, publicly routable RPC URL in
    node-info.yaml), 1199-1200 (install-caddy.sh refuses public RPC on a staked validator,
    separate RPC node), 77-82 steps, 1330 + spec D3 (stake read on chain, no figure),
    1494-1495 E+3
  - Contact: 46-50; orchestrator's exact guide-link sentence
  - "set at launch" items: public RPC (Network table), explorer (Network table),
    oldest mainnet node release the scripts accept (Install)
- M3 Fit and polish
  - Seven fit passes. Orchestrator addendum (4 changes) applied: validator prerequisite
    sentence before the steps (1329 + 1199); 443/80 purpose "Caddy: RPC, dashboard" and
    "Open 443 and 80 only if you serve public RPC or the dashboard."; contact sentence with
    the guide as link text; no "Signed node releases are checked..." sentence, x86_64 line
    as guide 317
  - Dropped for space (spec facts): Chain row (sec. 7 only), "so check the chain ID",
    logs to journal (573), firewall SSH sources (415/436), --passphrase-method stdin refused
    (338), testnet add-ons refused (1014), install methods list, gpgv scripts line,
    "without approval" (12-13)
  - Unused height above the footer: left 5.3 mm, right 5.2 mm (pdftotext -bbox)

- M4 Checks (all in tn-pdf-tools, absolute repo mount)
  a. build twice: "PDF unchanged: ... (1 pages)" both times, exit 0
  b. cmp template.html pair exit 0, cmp theme.css pair exit 0, both silent
  c. pdftotext -layout: devs@telcoin.org x3; -i greps legacy / 1,000,000 / 7 of the 10 /
     12 to 18 / v0\. all 0 (PDF text and Markdown)
  d. pdffonts: Geist Semi-Bold, Geist, Geist Mono, Geist Medium, Geist Bold, all emb yes;
     pdfinfo: Pages 1, A4 595.276 x 841.89, no CreationDate
  e. 0 "weasyprint:" lines in both build logs; build/weasyprint.log empty
  f. "set at launch": Public RPC row, Explorer row, oldest release (Install)
  g. git status: new = docs/partner/mainnet-node-requirements/ + tasks/ckpt-onepager-M.md;
     everything else is other units' files
  h. build/page-1.png at 110 dpi (gitignored)
- Guide vs brief: explorer is "Not launched yet" in guide 208; "set at launch" is the
  brief's wording. Guide 1329 + 1199 are not linked in the guide; "served by a separate RPC
  node" is the orchestrator's pairing.
