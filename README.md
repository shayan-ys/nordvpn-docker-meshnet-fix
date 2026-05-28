# nordvpn-docker-meshnet-fix

> iptables + nftables ACCEPT rules + a systemd timer that keep Docker bridge
> containers reachable from NordVPN Meshnet peers, even though `nordvpnd`
> installs packet-killing rules that block them by default. Handles both
> the legacy iptables-only NordVPN client and the current one that uses an
> `inet nordvpn` nftables table.

## The problem

NordVPN's Linux daemon installs two layers of rules that drop traffic
between Docker bridge networks (e.g. `172.18.0.0/16`) and Meshnet peers
(`100.64.0.0/10`):

**1. Legacy iptables FORWARD chain** — three rules at position 1:

```
ACCEPT  0.0.0.0/0      -> 100.64.0.0/10  ctstate RELATED,ESTABLISHED  /* nordvpn-exitnode-permanent */
DROP    0.0.0.0/0      -> 100.64.0.0/10                               /* nordvpn-exitnode-permanent */
DROP    100.64.0.0/10  -> 0.0.0.0/0                                   /* nordvpn-exitnode-permanent */
```

The container's outbound SYN to `100.64.x.y` is dropped; even if bypassed,
the peer's SYN+ACK is dropped on return because Docker MASQUERADE has
rewritten the destination back to the bridge IP while the source still
falls in `100.64.0.0/10`.

**2. Current nftables `inet nordvpn` table** — a `forward` chain whose
sub-chain `internet_to_mesh_peer` ends in an unconditional `drop`:

```
chain internet_to_mesh_peer {
    ip daddr != @allow_peer_traffic_routing drop
    ip saddr @lan_ranges ip daddr != @peer_local_network_access drop
    oifname "nordlynx" ct state established,related accept
    drop                            # ← kills new SYNs from non-meshnet sources
}
```

NEW SYNs from a Docker container (saddr in 172.x) destined to an
allowlisted Meshnet peer fall off the bottom of this chain and get
dropped. Per-table verdicts at the same netfilter hook do **not**
short-circuit other tables — so an iptables ACCEPT for the same packet is
ignored once the nft table reaches `drop`. Both backends need their own
rule.

The host itself is fine in both cases — host traffic goes via the OUTPUT
chain, not FORWARD. Only Docker containers break.

## The fix

**iptables** — two ACCEPT rules at FORWARD position 1, before NordVPN's DROPs:

```bash
sudo iptables -I FORWARD 1 -s 172.18.0.0/16 -d 100.64.0.0/10 -j ACCEPT
sudo iptables -I FORWARD 1 -s 100.64.0.0/10 -d 172.18.0.0/16 \
  -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
```

**nftables** — one ACCEPT at the top of NordVPN's own forward chain,
before its jumps into the drop-terminated sub-chains:

```bash
sudo nft insert rule inet nordvpn forward \
  ip saddr 172.18.0.0/16 ip daddr 100.64.0.0/10 accept \
  comment "docker-meshnet-fix"
```

A single egress rule is sufficient on the nft side because return traffic
already passes — `mesh_peer_to_internet` has `ip daddr != 100.64.0.0/10
accept` for allowlisted peers, and Docker bridge IPs aren't in the
Meshnet range.

`nordvpnd` re-asserts both backends every time Meshnet starts or peer
settings change, so a 5-minute systemd timer keeps the ACCEPTs at the
top. **Existence checks (`iptables -C`, or scanning for the same nft
rule)** are insufficient — order matters in both backends. The script
deletes-then-reinserts iptables rules at position 1, and uses a marker
comment (`docker-meshnet-fix`) to find+remove the nft rule before
re-inserting at the top of the chain.

## Install

Requires `iptables`, `systemd`, and root. `nft` is optional — if absent,
or if the `inet nordvpn` table isn't present (older NordVPN or Meshnet
off), the script skips the nft branch silently.

```bash
git clone https://github.com/shayan-ys/nordvpn-docker-meshnet-fix.git
cd nordvpn-docker-meshnet-fix
sudo ./install.sh
```

`install.sh`:
- copies the script to `/usr/local/bin/nordvpn-docker-meshnet-fix.sh`
- copies the unit + timer to `/etc/systemd/system/`
- seeds `/etc/default/nordvpn-docker-meshnet-fix` with defaults (only if absent)
- enables and starts the timer

Override the defaults by editing `/etc/default/nordvpn-docker-meshnet-fix`:

```bash
DOCKER_SUBNET=172.18.0.0/16
MESHNET_SUBNET=100.64.0.0/10
```

Find your bridge subnet with `docker network inspect bridge | jq -r '.[0].IPAM.Config[0].Subnet'`.

## Verify

```bash
sudo systemctl status nordvpn-docker-meshnet-fix.timer
sudo iptables -L FORWARD -n --line-numbers | head -5
sudo nft -a list chain inet nordvpn forward 2>/dev/null | head -10
```

Lines 1 and 2 of the iptables FORWARD chain should be the ACCEPTs above.
The first rule in the nft `inet nordvpn forward` chain should be the
ACCEPT carrying the `docker-meshnet-fix` comment (skipped silently if
the table doesn't exist). From inside any Docker container with the
bridge network: `curl http://<peer>.nord:<port>` should now succeed.

## Uninstall

```bash
sudo ./uninstall.sh         # removes script + units, keeps /etc/default
sudo ./uninstall.sh --purge # also removes /etc/default config
```

iptables and nft rules are not touched on uninstall — they will expire
next time `nordvpnd` reasserts its own rules.

## What does NOT solve this

- `nordvpn set firewall off` — affects different rules; **and bounces the
  daemon, dropping your Meshnet tunnel mid-session** (recover via LAN/console).
- `nordvpn meshnet peer routing deny` / `peer local deny` — peer-specific
  transient rules only.
- `nordvpn set meshnet off` — kills Meshnet entirely.

## Why this exists

There is no canonical fix in the
[NordVPN Linux issue tracker](https://github.com/NordSecurity/nordvpn-linux/issues)
or on r/selfhosted; the prevailing answers are "switch to Tailscale" or
hand-rolled `iptables` invocations that don't survive `nordvpnd` reload.
This script + timer is small enough to read in one sitting and survives
peer changes, daemon restarts, and reboots.

The blocking rules are added by `enableFiltering()` in
[`daemon/firewall/forwarder/fw.go`](https://github.com/NordSecurity/nordvpn-linux/blob/main/daemon/firewall/forwarder/fw.go).

## Tests

- `bats tests/unit/` — unit tests with a mocked `iptables` binary
- `tests/integration/run.sh` — privileged Docker container that simulates
  the FORWARD-DROP race and asserts rule ordering

CI (GitHub Actions) runs all three on every push.

## License

MIT — see [LICENSE](LICENSE).
