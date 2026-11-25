# Operator note: scripts-v2.2.0

Draft for the operator channels.
Post it once the `scripts-v2.2.0` tag is out and `https://install.telcoin.network` serves it.
Everything below the line is the note.

---

**scripts-v2.2.0 is out. Hosts on scripts-v2.1.0: run the installer once.**

`scripts-v2.2.0` is the script release for telcoin-network `v0.18.0-adiri`.
If your host is on `scripts-v2.1.0`, `update-scripts.sh` cannot take it there.
Run the installer once instead, as the user who owns `~/telcoin-node-scripts` (not root):

```
curl --proto '=https' --tlsv1.2 -fsSL https://install.telcoin.network | bash -s -- --yes
```

It checks the release's signature with the keys built into the installer, replaces only `~/telcoin-node-scripts`, and puts the old directory back if anything fails.
Files you changed or added in that directory are not kept.
It does not touch the node, its data or its keys.
The node keeps running.

**Why the updater refuses**

Script releases are now signed with new keys, held on hardware tokens by three maintainers.
`scripts-v2.1.0` trusts only the earlier key, which is retired, so its updater stops with:

```
a signature by key 28FD56AD2F9FAE47, which is not a release key, was not checked
    gpgv: Signature made <date>
    gpgv:                using EDDSA key 95A38484E1CBD31D773F6AF928FD56AD2F9FAE47
    gpgv: Can't check signature: No public key
  [ERROR] The release manifest is not signed by a Telcoin release key (no release key in lib/release-keys made a good signature); nothing was changed.
```

Nothing on the host changed.
The installer carries the new keys, and from 2.2.0 on `update-scripts.sh` updates the scripts as before.

**Who needs this**

- Hosts that installed or updated the scripts since 10 November 2026.
- Any host whose `update-scripts.sh` stops with the `[ERROR]` line above.
- AWS one-click stacks launched before this release. Their daily update fails until you run
  this once in a Session Manager shell. Do not use the plain command above there: the shell is
  `ssm-user`, and the stack's scripts belong to `ubuntu`, in `/home/ubuntu/telcoin-node-scripts`.

  ```
  sudo -u ubuntu -H bash -c "set -o pipefail; curl --proto '=https' --tlsv1.2 -fsSL https://install.telcoin.network | bash -s -- --yes"
  ```

Not sure which release a host is on?
`grep '^release=' ~/telcoin-node-scripts/MANIFEST` names it (`/home/ubuntu/telcoin-node-scripts/MANIFEST` on an AWS stack).
A host with no `MANIFEST` there is on older scripts and updates with `update-scripts.sh` as before.

**Afterwards**

```
bash ~/telcoin-node-scripts/update-scripts.sh --check
sudo bash ~/telcoin-node-scripts/ui/install-ui.sh --update
sudo bash ~/telcoin-node-scripts/check-node.sh
```

The first reports `scripts-v2.2.0`.
The second is only for hosts that run the Node Manager UI, which keeps its own copy of the scripts.
On an AWS stack the scripts are in `/home/ubuntu/telcoin-node-scripts`: write that path in place of `~/telcoin-node-scripts`, and run the first command as `ubuntu` (`sudo -u ubuntu -H bash /home/ubuntu/telcoin-node-scripts/update-scripts.sh --check`).

**Updating the node to v0.18.0-adiri**

`v0.18.0-adiri` is the first signed release on the testnet channel.
The update is one way: on its first start the node moves its execution database from MDBX to tn-lmdb, and no earlier release opens the data directory afterwards.
`update-node.sh` warns, asks about a snapshot and never rolls back on its own.
Read section 4.2 of OPERATOR.md before you run it, and check the free space on the data directory's filesystem first.

**Also in this release**

- New testnet installs work again. Fresh installs have stopped at step 4 of 8 since 14 November;
  setup now reads the chain configs from a pinned tag.
- `setup-gateway.sh` runs telcoin-network's worker gateway, on testnet with the image
  `v0.18.0-adiri` signs.
- `firewall-setup.sh` no longer deletes a rule when you re-enter its source in another spelling.
- Ubuntu 26.04 LTS is the recommended OS; 24.04 stays supported.

The full release note:
https://github.com/Telcoin-Association/tn-node-deployment/blob/main/CHANGELOG/scripts-v2.2.0.md

Questions: support@telcoin.org
