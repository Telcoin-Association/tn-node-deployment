# Shared facts: scripts-v2.2.0 round (2026-11-24)

Every agent of this round reads this file first. It is the one story every changed file tells.
Do not restate a fact differently from here; if the code or a file you read contradicts a fact
below, stop and report it instead of picking one.

## What changes in this pull request

1. A third release key ships: `lib/release-keys/sstanfield.asc`.
2. The testnet worker-gateway pin is set; the mainnet pin stays empty.
3. `update-scripts.sh` names the installer when a release was signed by no installed key, or by
   an expired or revoked one.
4. The docs say all of that, and say what a host on `scripts-v2.1.0` must do.

No version constant moves. `update-scripts.sh` and `lib/gateway.sh` stay 2.2.0 (`SCRIPT_VERSION`,
`GATEWAY_VERSION`), because `scripts-v2.2.0` is not released yet and both already carry the
bump of this cycle. `MANIFEST`, `MANIFEST.asc`, `RELEASE` and the `TN_SCRIPTS_TAG` line of
`install.sh` are not touched: the release tool writes them. `*.sha256` sidecars are not touched
by any agent: the orchestrator regenerates them in the final `chore(release)` commit.

## Release keys

Three keys, all ed25519 primary keys that sign, each on its holder's YubiKey:

| handle | primary key fingerprint | expires | added |
|---|---|---|---|
| grantkee | `95A38484E1CBD31D773F6AF928FD56AD2F9FAE47` | 2028-11-16 | 2026-11-17 |
| MavenRain | `32F886ADE9C3A88218E4B67CA0A69159FC76DBFD` | 2028-11-10 | 2026-11-17 |
| sstanfield | `9D72ECBEE3AA983FA8671DA511423DE08DDE052C` | 2028-11-19 | 2026-11-24 |

- The submodule `vendor/tn-release-signing` moves from `813fcf4` to
  `172be748508160d3aba03f2378d0c0a76a5a7e31` (`172be74`), tn-release-signing's main. The move
  brings in `keys/sstanfield.asc` and its `KEYS.md` row, nothing else.
- Any one of the three may sign a script release, a node release or a `tn-p2p-allow-sync`
  release. `TN_SIG_THRESHOLD` stays 1.
- C locale name order of the key files: `MavenRain.asc`, `grantkee.asc`, `sstanfield.asc`
  (upper case sorts first). `install.sh` embeds them in that order.
- The earliest expiry is 2028-11-10 (MavenRain), the latest 2028-11-19 (sstanfield).
- With three YubiKey-held keys, losing one key no longer strands hosts: a release signed by
  either remaining key verifies against the installed set.
- grantkee's RSA-2048 key `4E36D35A4AB61B589861D01AC7173F2377CA7573` was the only key of
  `scripts-v2.1.0`. It was removed from tn-release-signing and signs nothing any more.

## Node release v0.18.0-adiri

- Published on GitHub on 2026-11-24, signed by grantkee's ed25519 key
  (`95A38484E1CBD31D773F6AF928FD56AD2F9FAE47`). It is the first signed release on the testnet
  channel. `v0.16.0-adiri` and `v0.17.0-adiri` have no signed release.
- Text that says signed releases "are planned to start with `v0.17.0-adiri`", or that no testnet
  release is published on GitHub yet, is out of date. The fallbacks for a time without a signed
  release still exist in the code (they run when the Releases API cannot be read, and for a tag
  that has no signed release); describe them as fallbacks, not as today's normal path.
- The node image needs no pin: setup and update resolve it from the signed release at run time.
  The `v0.16.0-adiri` offline fallback image stays. `TESTNET_CHAIN_CONFIGS_TAG` stays
  `v0.16.0-adiri` by design (see AGENTS.md "Chain configs").

## Worker gateway pin

- `lib/gateway.sh`, one line under its `# network-gated:` marker:
  `GW_TESTNET_IMAGE_PIN="ghcr.io/telcoin-association/tn-worker-gateway@sha256:efed742a8a32db4f71b397d17ac448bcd98dcc0d14083197c1f7cecbc72bcffb" GW_TESTNET_PIN_RELEASE="v0.18.0-adiri"`
- It is the `IMAGE_DIGEST-worker-gateway` line of the signed `v0.18.0-adiri` release.
- The mainnet pin stays empty: `GW_MAINNET_IMAGE_PIN="" GW_MAINNET_PIN_RELEASE=""`. Mainnet still
  refuses the enable with `this scripts release pins no worker-gateway image for mainnet yet`.
- So from `scripts-v2.2.0` the gateway runs on testnet and on devnets. On testnet
  `setup-gateway.sh --enable ... --network testnet` takes the pinned image; an `--image` other
  than the pin is refused there, as before.
- The pinned image was probed on 2026-11-24 (`linux/amd64`): its `--help` lists every flag of
  `GW_REQUIRED_FLAGS`.

## Hosts on scripts-v2.1.0

A host on `scripts-v2.1.0` cannot take `scripts-v2.2.0` with `update-scripts.sh`. Its updater
verifies a release against the keys the host already has, which is the RSA key alone, and no
release is signed by that key any more. The 2.1.0 updater prints this and exits 1 (measured on
2026-11-24 with the real `scripts-v2.1.0` tree and gpgv 2.4.8 on Ubuntu 26.04, against a release
signed by a key the tree does not hold):

```
a signature by key 28FD56AD2F9FAE47, which is not a release key, was not checked
    gpgv: Signature made <date>
    gpgv:                using EDDSA key 95A38484E1CBD31D773F6AF928FD56AD2F9FAE47
    gpgv: Can't check signature: No public key
  [ERROR] The release manifest is not signed by a Telcoin release key (no release key in lib/release-keys made a good signature); nothing was changed.
```

So there are five lines, not two: the warning, three indented `gpgv:` lines, and the error.
`28FD56AD2F9FAE47` is the long key id of grantkee's ed25519 key; the warning has no prefix and
the last line carries the script's `[ERROR]` tag. Key a troubleshooting row on the `[ERROR]` line
(with its reason `no release key in lib/release-keys made a good signature`), and name the
warning line as what comes before it. Never write that the updater prints "two lines" or
"exactly" these lines: the `gpgv:` lines sit between them and their wording belongs to gpgv. It
names no remedy. Nothing on the host changes
and the node keeps running. The same refusal meets every later release.

The remedy is one command, run once as the user who owns `~/telcoin-node-scripts`:

```
curl --proto '=https' --tlsv1.2 -fsSL https://install.telcoin.network | bash -s -- --yes
```

It verifies the release with the keys embedded in the installer, replaces only
`~/telcoin-node-scripts`, and puts the old tree back if anything fails. It does not touch the
node, its data or its keys. Afterwards `bash ~/telcoin-node-scripts/update-scripts.sh --check`
reports `scripts-v2.2.0`; where the Node Manager UI runs, `sudo bash ui/install-ui.sh --update`
brings its copy of the scripts up to date.

Who is affected: hosts installed or updated through the signed flow since 2026-11-10, and any
older host that carries the RSA `lib/release-keys/grantkee.asc`. A host on update-scripts 1.1.72
or older with no key file takes 2.2.0 through the one-time key bootstrap, as documented.

AWS one-click stacks launched before `scripts-v2.2.0` installed `scripts-v2.1.0`: their daily
update association fails at `update-scripts.sh` until the operator runs the installer once in a
Session Manager shell. That shell runs as `ssm-user`, and the stack keeps the scripts in
`/home/ubuntu/telcoin-node-scripts`, owned by `ubuntu`, so there the command is the form the
stack's own user data runs:

```
sudo -u ubuntu -H bash -c "set -o pipefail; curl --proto '=https' --tlsv1.2 -fsSL https://install.telcoin.network | bash -s -- --yes"
```

The plain one-liner in a Session Manager shell would install a second tree in `ssm-user`'s home
and leave the stack's scripts on 2.1.0.

`bash update-scripts.sh` on such a host is never the remedy for anything in 2.2.0. A doc that
tells a 2.1.0 operator to run `update-scripts.sh` to get 2.2.0 is wrong and gets the installer
one-liner instead.

## The updater's hint (2.2.0 and later)

Narrowed in the review round (2026-11-24): a revoked key and the first-run key bootstrap get no
hint. An earlier version of this section listed `REVKEYSIG`; that was wrong.

From `scripts-v2.2.0`, when `update-scripts.sh` refuses a release with `The release manifest is
not signed by a Telcoin release key (<reason>); nothing was changed.` and the reason is that no
installed key made a good signature (`NOSIG`), or the signing key has expired (`EXPKEYSIG`), it
prints `reinstall_hint` after the error:

```
  ->  Re-install the scripts with the verified installer, then run the updater again:
  ->    curl --proto '=https' --tlsv1.2 -fsSL https://install.telcoin.network | bash
```

(`print_info` writes the `->` prefix; there is no `[INFO]` tag.)

The rule: the hint prints only where re-installing can help, which is where the installer's
embedded keys can differ from the keys the host verified with. A host that skipped a release
which changed the key set holds none of the new keys (`NOSIG`); a host whose copy of a key has
passed its expiry holds the old copy (`EXPKEYSIG`), and the installer carries the renewed one.

It prints no hint:

- for a signature by a revoked key (`REVKEYSIG`). A host holds a revoked copy of a key only
  because a signed release shipped it, so a later release signed by that key is a mistake or a
  compromised key in use. The installer verifies the same release with the same key and refuses
  it too;
- for a signature that does not match the manifest (`BADSIG`: a changed file, not a key
  problem), for an expired signature (`EXPSIG`) or when gpgv reports an error for a signature
  (`ERRSIG`);
- on the first signed run of a host that has no key file yet (the one-time key bootstrap): there
  the keys are the ones the release itself lists, and the installer embeds the same files.

It never prints the hint twice in one run. The hint cannot help a 2.1.0 host, whose updater
predates it; it makes the next key change explain itself.

## Other facts the docs need

- `click` 8.5.1 in `ui/requirements.txt` (Dependabot, pull request #63) is on main and is
  recorded in no changelog yet.
- The AWS one-click stack (`aws/node.yaml`, pull request #71) is new since `scripts-v2.1.0`.
  Publishing the template to S3 (`publish-aws-templates.yml`) is not wired yet: the
  `aws-templates` environment and its variables do not exist, so that workflow's upload job
  fails on the tag without touching the installer. The steps are in followup.md.
- Follow-up, not in this release: a check in `tools/release-scripts.sh` that a release verifies
  against the previous release's key set unless overridden, so a key change that strands hosts
  cannot pass unnoticed.
- Closed by this release: "the first telcoin-network release must be signed with a
  tn-release-signing key" (`v0.18.0-adiri` is), and "telcoin-network main still lists the RSA
  key" (it no longer does).

## Writing rules for every agent

- Plain, direct prose. Short sentences. Say what a thing does. No em dashes; use a colon, a
  comma or two sentences. No filler ("in order to", "it is important to note"), no "crucial",
  "robust", "seamless", "comprehensive", "leverage", "ensure that".
- Match the file you edit: its line width, its wrapping (some files wrap at 100 columns, some
  keep one sentence per line), its table style, its tense. Change the lines you must; do not
  reflow or reword neighbours.
- No version numbers for things that are not versions. Do not invent a figure, a date or a
  command: take each from this file or from the code.
- No Claude or AI attribution anywhere.
- The partner guide and one-pagers may not contain the word "legacy", `--observer`,
  `migrate-node-naming`, `setup-observer.sh`, `setup-validator.sh`, a repo-relative link or any
  contact other than `devs@telcoin.org`.

## Checkpoint rule for every agent

Your prompt names a checkpoint file. On start, read it and continue from the first unfinished
section. Rewrite it after each section with a `status:` header (`in-progress` or `done`) and the
list of completed sections with one line each on what changed (file and line). If a write is
refused, do not work around it: return the full text in your final answer. Return a summary,
never file dumps. Do not commit, push, run `gen-checksums.sh` or touch files outside your list.
