# Package DOCS-2: documentation of round 2 (tn-node-deployment)

Read `tasks/spec-r2-shared.md` first, then `tasks/spec-r2-SIG.md`, `tasks/spec-r2-IMG.md`,
`tasks/spec-r2-EPOCH.md` for what changed, then the implementers' checkpoints
`tasks/ckpt-r2-SIG.md`, `tasks/ckpt-r2-IMG.md`, `tasks/ckpt-r2-EPOCH.md` (their **Docs notes**
sections hold the facts and the stale lines) and the integrated code itself: every fact you
write is checked against the code on the integration tip, never copied from a checkpoint.
Worktree `~/coding/telcoin/tnd-r2-DOCS`, branch `r2/DOCS`, checkpoint `tasks/ckpt-r2-DOCS.md`.
You own: `README.md`, `OPERATOR.md`, `AGENTS.md`, `lib/release-keys/README`,
`CHANGELOG/scripts-v2.1.0.md`, `CHANGELOG/scripts-v2.0.0.md` (one note), `CHANGELOG.md` (if it
names the signing scheme), `followup.md`, `docs/testnet-addons.md`, the partner guide
`docs/partner/mno-node-guide/` (1.6 → 1.7, metadata, PDF rebuilt byte-identical twice through
`tools/build-partner-pdf.sh`; read the script header for the container it uses).

Facts and wording rules: plain prose, no em-dashes, no line-number references; operator-facing
documents say what to do; the changelog says what changed and why, grouped by package, and
calls `scripts-v2.1.0` the first signed script release (serial 1; `scripts-v2.0.0` was never
tagged: add that note to `CHANGELOG/scripts-v2.0.0.md` and leave its history as is).
`lib/release-keys/README` gains the sentence that the keys also sign script releases
(`MANIFEST.asc`). Private paths and the maintainer's workspace never appear.

## Sections

S1 **Integrity contract (SIG).** README (signed releases: `MANIFEST`, `MANIFEST.asc`,
`lib/release-keys/*.asc`, the gpgv policy, threshold, `gpgv` dependency, install.sh embedded
keys, bootstrap on a bare host; the hand-check block that OPERATOR §4.10 already uses for node
releases becomes the one block, used for both), OPERATOR (§4.1 install, §4.10 hand check, every
`ssh-keygen`/`allowed_signers`/`MANIFEST.sig` line), AGENTS ("Self-update and integrity
contract", CI note, the maintainer release steps with `tools/cut-release.sh prep`/`tag`, the
forwarded agent and the `--sig-from` fallback, CODEOWNERS paragraph), followup.md "Release
prep" section (rewrite: the first signed release is 2.1.0; the sidecar transition item stays;
#40 2-of-N stays with the threshold constant named), partner guide lines naming the SSH scheme.
Grep `allowed_signers|MANIFEST.sig|ssh-keygen|tn-node-scripts|release@telcoin.org` over your
files: zero hits left (CHANGELOG/scripts-v2.0.0.md history excepted, with the note).

S2 **Images (IMG).** Package names per network and the reason (channel = tag), the retired
single package, the storage floor by network, the image feature check (what runs, what it
refuses, when, `--json` behaviour), the raw-digest rule kept as defence in depth. README
(Docker images per network), OPERATOR, AGENTS (the images paragraph), partner guide (Docker
option), followup.md (the every-network example messages item stays unless IMG closed it).

S3 **Epoch (EPOCH).** OPERATOR, README and partner guide sentences naming the blind wait and
the mainnet epoch (constants, derived margins); EPOCH already edited AGENTS/CHANGELOG/followup.

S4 **Owners and Alloy.** AGENTS "Contributing" is already reworded (8db70e0); check README/
OPERATOR for a single-owner sentence. Alloy: `docs/testnet-addons.md` sync note already names
18f8485 (a2162b6); check the rest of that file and README for "pending merge".

S5 **CHANGELOG/scripts-v2.1.0.md.** New sections: signed releases (GPG, first signed release,
cut-release tool, CI), image packages, epoch constant, code owners, Alloy vendoring refresh,
#41 proposal pointer; the `min_updater` and serial facts.

S6 **Partner guide 1.7 + PDF.** Version bump in `metadata.yaml` and the guide, the changed
sentences, the PDF rebuilt twice with identical bytes (record both hashes in the checkpoint).

Hand back: commits on `r2/DOCS`, the grep results, the PDF hashes, open issues (facts you could
not verify in the code, with the file and the sentence).
