# Debugging overlay SSH to a node

A runbook for when `tn_ssh <node>` won't connect — most often a banner-exchange timeout.
That symptom is almost always **transport** (the tunnel isn't converged, or the node's
active firewall is dropping the inbound SYN), not keys — a missing key gives
`Permission denied (publickey)`, not a timeout.

Work top-down: confirm your own side, then the hub, then the node. The first place a check
fails localizes the fault. The one-shot triage on the node (`setup-vpn.sh --status`) covers
most of section 3 in a single command — start there if you can reach the node at all.

Overlay landmarks: the hub is `10.100.0.1`; maintainers are `10.100.9.0/24`; external nodes
are `10.100.20.0/24`. `tn_ssh` jumps maintainer → hub (`tnadmin@10.100.0.1`) → node.

---

## 1. On the maintainer laptop

```bash
# Your tunnel is up — expect a recent handshake + nonzero transfer.
sudo wg show

# The hub answers over the overlay (proves the tunnel carries traffic, not just that it's up).
ping -c3 10.100.0.1

# The name resolves to an overlay IP (reads registry.csv col name → col IP).
source common/wgvpn/lib/wg-ssh-lib.sh
tn_overlay_ip <node>            # e.g. validator-6-adiri -> 10.100.20.7

# The hub hop ALONE works (isolates "can I reach the jump?" from "can the jump reach the node?").
ssh -v -i ~/.config/tnvpn/id_ed25519 -o IdentitiesOnly=yes tnadmin@10.100.0.1 true

# The full path, verbose. TN_SSH_OPTS adds -v to the outer hop without dropping the pinned key.
TN_SSH_OPTS="-v -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15" tn_ssh <node> hostname
```

If your own `wg show` has no recent handshake, fix that first (`sudo wg-quick down tn-wg0 && sudo wg-quick up tn-wg0`) — nothing downstream can work through a dead tunnel. If `tn_overlay_ip` can't resolve the name, you're not looking at a transport problem at all — see the table below.

## 2. On the hub

```bash
# Is the node a peer, with a RECENT handshake and nonzero rx/tx?
sudo wg show wg0

# Does the node's live pubkey match its registry row? (a mismatch = the hub black-holes
# return traffic, so the node's SYN is forwarded but the reply never lands)
grep <node> common/wgvpn/peers/registry.csv      # compare col 4 to the peer in `wg show wg0`

# Forwarding is on, and the FORWARD chain admits the maintainer band.
sysctl net.ipv4.ip_forward                        # expect: net.ipv4.ip_forward = 1
sudo nft list ruleset | sed -n '/chain forward/,/}/p'   # expect accepts for 10.100.9.0/24
```

The hub forwards the whole maintainer band (`10.100.9.0/24` as src and dst) and allows
overlay→:22 to itself. If the node peer is missing here, enrolment didn't complete —
re-run `add-node.sh <name> <ip> <pubkey>` from `adiri-genesis`.

## 3. On the node (via the operator, IAP break-glass, or console)

```bash
sudo bash setup-vpn.sh --status      # one-shot: tunnel, reboot-persistence, keys, sshd, firewall

# Or check each piece directly:
sudo wg show wg0                                   # handshake with the hub? nonzero transfer?
sudo ss -tlnp 'sport = :22'                        # is sshd actually listening on :22?
sudo ufw status                                    # ACTIVE? is there an ALLOW from 10.100.0.0/16?
sudo wc -l ~tnadmin/.ssh/authorized_keys.tnvpn     # maintainer keys present (one per line)?
sudo sshd -t                                       # sshd config valid (a bad drop-in blocks reload)?
sudo journalctl -u ssh -n50 --no-pager             # what does sshd say when you connect?
```

`--status` prints the exact fix command under any failing check, so prefer it. The manual
commands are for when you want to see the raw state or `--status` itself can't run.

---

## Symptom → cause → fix

| Symptom (maintainer side) | Most likely cause | Fix |
|---|---|---|
| **Connection timed out during banner exchange** | Node `wg0` not handshaking with the hub (tunnel not converged, or registry pubkey ≠ node's actual key) — Cause 1 | On the node: `sudo bash setup-vpn.sh --status`; `sudo wg-quick up wg0`; if pubkey drifted, re-send `sudo wg show wg0` pubkey to the Association |
| **Banner timeout, but the tunnel is up** | Operator's ACTIVE ufw has no overlay→:22 allow rule (ufw enabled/tightened after enrol) — Cause 2 | On the node: `sudo bash setup-vpn.sh --apply-firewall` (then `--status` to confirm) |
| **Worked before, dead after a node reboot** | `wg-quick@wg0` was never enabled, so the tunnel didn't come back — Cause 3 | On the node: `sudo systemctl enable wg-quick@wg0` (`--status` check 2 catches this) |
| **`Permission denied (publickey)`** | Maintainer key not on the node (not a transport problem) | Operator: `git pull && sudo bash setup-vpn.sh --sync-keys`. Admin (overlay up): `SYNC_ALL_NODES=1 ./common/wgvpn/sync-access.sh` |
| **`tn_overlay_ip: cannot resolve` / ssh `UNKNOWN port 65535`** | Name not in `registry.csv` (or misspelled) — resolution returned nothing | Confirm the row exists and the name matches; `tn_overlay_ip <node>` must print an IP. Add via `add-node.sh` if missing |
| **Host key verification failed** | Node was rebuilt; its host key changed (accept-new pinned the old one) | Clear the stale `known_hosts` line for the node's overlay IP, then retry |

The three banner-timeout rows map one-to-one to checks 1, 5, and 2 of `setup-vpn.sh --status`
— running it on the node tells you which one you're in without guessing.
