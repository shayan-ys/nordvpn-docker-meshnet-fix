# nordvpn-docker-meshnet-fix

> Two iptables ACCEPT rules + a systemd timer that keep Docker bridge
> containers reachable from NordVPN Meshnet peers, even though `nordvpnd`'s
> `nordvpn-exitnode-permanent` chain installs FORWARD-chain DROPs that block
> them by default.

## The problem

When NordVPN Meshnet is enabled on a Linux host, the daemon installs three
rules at the top of the `FORWARD` chain:

```
ACCEPT  0.0.0.0/0      -> 100.64.0.0/10  ctstate RELATED,ESTABLISHED  /* nordvpn-exitnode-permanent */
DROP    0.0.0.0/0      -> 100.64.0.0/10                               /* nordvpn-exitnode-permanent */
DROP    100.64.0.0/10  -> 0.0.0.0/0                                   /* nordvpn-exitnode-permanent */
```

Docker bridge networks (default `172.18.0.0/16`) match `0.0.0.0/0`, so:

- The container's outbound SYN to a Meshnet peer at `100.64.x.y` is dropped.
- Even if you bypass that, the peer's SYN+ACK is dropped on return because
  Docker MASQUERADE has rewritten the destination back to the bridge IP and
  the source still falls in `100.64.0.0/10`.

The host itself is fine — only Docker containers break.

## The fix

Two ACCEPT rules at FORWARD position 1, before NordVPN's DROPs:

```bash
sudo iptables -I FORWARD 1 -s 172.18.0.0/16 -d 100.64.0.0/10 -j ACCEPT
sudo iptables -I FORWARD 1 -s 100.64.0.0/10 -d 172.18.0.0/16 \
  -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
```

`nordvpnd` re-asserts its rules every time Meshnet starts or peer settings
change, so a 5-minute systemd timer keeps the ACCEPTs at the top.
**Existence checks (`iptables -C`) are insufficient** — order matters, so the
script always deletes-then-reinserts at position 1.

## Install

Requires `iptables`, `systemd`, and root.

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
```

Lines 1 and 2 should be the ACCEPTs above. From inside any Docker container
with the bridge network: `curl http://<peer>.nord:<port>` should now succeed.

## Uninstall

```bash
sudo ./uninstall.sh         # removes script + units, keeps /etc/default
sudo ./uninstall.sh --purge # also removes /etc/default config
```

iptables rules are not touched on uninstall — they will expire next time
`nordvpnd` reasserts its own rules.

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
