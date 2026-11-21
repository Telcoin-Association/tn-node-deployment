# Mainnet node requirements

<div class="wide">

## Status

> [!WARNING]
> Mainnet has not launched: the scripts refuse it until `update-scripts.sh` brings the scripts release that launches it.

## Hardware per role

| Role | Minimum | Recommended |
|---|---|---|
| Observer, follower | 2 cores (4 vCPU), 8 GB RAM | 4 cores (8 vCPU), 16 GB RAM |
| Observer, public RPC | 4 cores (8 vCPU), 16 GB RAM | 8 cores (16 vCPU), 32 GB RAM |
| Validator | 8 cores (16 vCPU), 32 GB ECC RAM | 16 cores (32 vCPU), 64 GB ECC RAM |
| Storage, validator | 2 TB TLC NVMe (20,000 write IOPS, 300 MB/s) | 4 TB |
| Storage, observer | 2 TB TLC NVMe (10,000 write IOPS, 300 MB/s) | 4 TB |
| Validator bandwidth | 200 Mbps symmetric | 1 Gbps |

- Prioritise single-core performance: EVM execution is single-threaded, so a high clock speed matters more than extra cores.
- A validator also needs a p95 round-trip time well below 1 second to a quorum of the committee.
- Every node: swap off, time sync on, ext4 or xfs; none checked.

> [!IMPORTANT]
> Email devs@telcoin.org with your planned hardware before you buy anything for a validator.

</div>

<div class="columns">

## Network

| | |
|---|---|
| Chain ID | 731 (`0x2db`) |
| Public RPC | `https://rpc.telcoin.network` is planned and set at launch; today it serves the testnet |
| Explorer | Not launched yet |
| Epochs | Six hours |

## Operating system and host

- Ubuntu 26.04 LTS (recommended) or 24.04 LTS (systemd 255 or newer).
- Release tarballs are x86_64 Linux; on another architecture, build from source or use Docker. macOS is not supported.
- A BLS passphrase of at least 16 bytes, and a TPM 2.0 or vTPM unless you pass `--allow-no-tpm`.
- Logs go to the systemd journal by default.
- Setup stops until the CVE-2026-31431 kernel mitigation (<https://copy.fail>) is in place.

## Ports

| Port | Open to | Purpose |
|---|---|---|
| `49590`, `49594` UDP | Everywhere | P2P (QUIC), every node |
| `443`, `80` TCP | Everywhere | Caddy: RPC, dashboard |
| `8545`, `8546` TCP | Loopback only | JSON-RPC |
| `9101` TCP | Loopback only | Metrics |
| `22` TCP | Your admin IPs | SSH (or your SSH port) |

Open the UDP ports on every node, in every layer that filters traffic (`ufw`, cloud firewall, NAT).
Open `443` and `80` only for public RPC or the dashboard.
The firewall asks for SSH sources.

<div class="col-break"></div>

## Install

Run the installer without `sudo`, then run setup:

```bash
curl --proto '=https' --tlsv1.2 -fsSL \
  https://install.telcoin.network | bash
sudo bash ~/telcoin-node-scripts/setup-node.sh
```

Setup's `2) Mainnet` choice is refused until launch.

- Source, release, Docker: signed `vX.Y.Z` release tags only.
- Docker: `ghcr.io/telcoin-association/tn-mainnet`, by release tag; the signed release gives the digest.
- Testnet add-ons are refused, and so is a server that has one.
- `install-caddy.sh` refuses public RPC and the dashboard on a staked validator; it suggests a separate RPC node.

## Roles and validating

Anyone can run a node.
Validating is an on-chain step, only for GSMA-member mobile network operators the Telcoin Association has approved.
It takes four steps; before you stake, sync the node and advertise a publicly routable RPC URL:

1. Approval: a ConsensusNFT minted to your execution address.
2. Stake: `prepare-stake.sh` reads the amount on chain.
3. Activation.
4. Committee selection: if `activate()` is mined in epoch E, the earliest seat is epoch E+3.

## Contact

Email devs@telcoin.org about running a node, validator onboarding, approval or hardware.
The full operator guide is at [run.telcoin.network/guide](https://run.telcoin.network/guide).

</div>
