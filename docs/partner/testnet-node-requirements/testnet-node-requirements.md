# Adiri testnet node requirements

<div class="wide">

## Hardware per role

| Role | Minimum | Recommended |
|---|---|---|
| Observer, follower | 2 cores, 8 GB RAM | 4 cores, 16 GB RAM |
| Observer, public RPC | 4 cores, 16 GB RAM | 8 cores, 32 GB RAM |
| Validator | 8 cores, 32 GB ECC RAM | 16 cores, 64 GB ECC RAM |
| Storage, every role | 2 TB TLC NVMe (10,000 write IOPS, 300 MB/s) | 4 TB |
| Validator bandwidth | 200 Mbps symmetric | 1 Gbps |

- CPU counts are physical cores; cloud vCPUs are usually hyperthreads, so an 8 vCPU instance has about 4.
- A validator also needs a p95 round-trip time well below 1 second to at least 7 of the 10 committee members.
- Avoid QLC drives: they wear out under continuous chain writes.
- Every node: swap off, time sync on, data directory on ext4 or xfs; the scripts check none of these.

> [!IMPORTANT]
> Email devs@telcoin.org with your planned hardware before you buy anything for a validator.

</div>

<div class="columns">

## Network

| | |
|---|---|
| Chain | EVM-compatible layer 1; Narwhal and Bullshark consensus; reth execution, so Ethereum-style JSON-RPC |
| Chain ID | 2017 (`0x7e1`) |
| Public RPC | `https://rpc.adiri.tel` (no WebSocket) |
| Explorer | `https://telscan.io` |
| Status page | `https://status.adiri.telcoin.network/` |
| Epochs | Six hours |

## Operating system and host

- Ubuntu 26.04 LTS (recommended) or 24.04 LTS. macOS is not supported.
  Debian 12 and Ubuntu 22.04 also install on testnet (systemd 247 or newer); below systemd 250 the BLS passphrase stays in a root-only file.
- Signed releases ship x86_64 Linux tarballs; otherwise build from source or use Docker.
- A TPM 2.0 or vTPM is optional on testnet.
- Setup stops until the CVE-2026-31431 kernel mitigation (<https://copy.fail>) is in place.

## Ports

| Port | Open to | Purpose |
|---|---|---|
| `49590`, `49594` UDP | Everywhere | P2P (QUIC), every node |
| `443`, `80` TCP | Everywhere | Caddy: RPC, dashboard |
| `8545`, `8546` TCP | Loopback only | JSON-RPC |
| `9101` TCP | Loopback only | Metrics |
| `22` TCP | Your admin IPs | SSH (or your SSH port) |

Open the UDP ports on every node, even one that may never validate, in every layer that filters traffic: `ufw`, the cloud firewall, NAT port forwards.
Open `443` and `80` only if you serve public RPC or the dashboard.

<div class="col-break"></div>

## Install

Run the installer without `sudo`, then run setup:

```bash
curl --proto '=https' --tlsv1.2 -fsSL \
  https://install.telcoin.network | bash
sudo bash ~/telcoin-node-scripts/setup-node.sh
```

- Install methods: build from source, signed release, Docker, or a binary you supply.
- The node runs release tags only, `vX.Y.Z-adiri`; a branch, a commit id or `latest` is refused.
- Docker image: `ghcr.io/telcoin-association/tn-testnet`, or the older repository on `us-docker.pkg.dev`.
- The scripts come from a signed release tag and are checked with `gpgv` before anything installs.

## Roles and validating

Anyone can run a node: no approval is needed to install one, follow consensus and serve JSON-RPC.
Validating is a separate, on-chain step, only for GSMA-member mobile network operators the Telcoin Association has approved.
It takes four steps; before you stake, the node must be synced and advertise a publicly routable RPC URL:

1. Approval: a ConsensusNFT minted to your execution address.
2. Stake: 1,000,000 TEL on testnet today; `prepare-stake.sh` reads the current amount.
3. Activation.
4. Committee selection: if `activate()` is mined in epoch E, the earliest seat is epoch E+3, 12 to 18 hours later.

## Contact

Email devs@telcoin.org about running a node, validator onboarding, approval or hardware.
The full operator guide is at [run.telcoin.network/guide](https://run.telcoin.network/guide).

</div>
