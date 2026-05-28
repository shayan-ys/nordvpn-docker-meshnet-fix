#!/bin/bash
# nordvpn-docker-meshnet-fix
# Keep Docker-bridge <-> NordVPN-Meshnet ACCEPT rules above nordvpnd's
# packet-killing rules. Handles both backends NordVPN uses:
#
# 1. Legacy iptables: nordvpnd's `nordvpn-exitnode-permanent` chain installs
#    DROP rules at FORWARD position 1 whenever Meshnet (re)starts or peer
#    settings change. Existence-check logic (`iptables -C`) is insufficient
#    because rule ORDER matters — rules below the DROPs do nothing. We
#    delete-then-reinsert at position 1 every run.
#
# 2. Current nftables: nordvpnd (>= 3.x) installs an `inet nordvpn` table
#    whose `forward` chain dispatches to sub-chains `mesh_peer_to_internet`
#    and `internet_to_mesh_peer`. Both end in unconditional `drop`. The
#    drops kill NEW SYNs from Docker bridges to Meshnet peers — and the
#    iptables ACCEPTs above do NOT preempt them, because per-table verdicts
#    don't short-circuit other tables at the same hook. We must insert an
#    accept at the top of `inet nordvpn`'s own `forward` chain.
#
# Config (override via /etc/default/nordvpn-docker-meshnet-fix or env):
#   DOCKER_SUBNET   default 172.18.0.0/16
#   MESHNET_SUBNET  default 100.64.0.0/10

set -euo pipefail

CONF=/etc/default/nordvpn-docker-meshnet-fix
# shellcheck source=/dev/null
[[ -r "$CONF" ]] && . "$CONF"

DOCKER_SUBNET="${DOCKER_SUBNET:-172.18.0.0/16}"
MESHNET_SUBNET="${MESHNET_SUBNET:-100.64.0.0/10}"

if ! command -v iptables >/dev/null 2>&1; then
  echo "nordvpn-docker-meshnet-fix: iptables not found in PATH" >&2
  exit 2
fi

# --- iptables backend (legacy) -----------------------------------------------

# Egress: Docker -> Meshnet
iptables -D FORWARD -s "$DOCKER_SUBNET" -d "$MESHNET_SUBNET" -j ACCEPT 2>/dev/null || true
iptables -I FORWARD 1 -s "$DOCKER_SUBNET" -d "$MESHNET_SUBNET" -j ACCEPT

# Return: Meshnet -> Docker (established connections only)
iptables -D FORWARD -s "$MESHNET_SUBNET" -d "$DOCKER_SUBNET" \
  -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
iptables -I FORWARD 1 -s "$MESHNET_SUBNET" -d "$DOCKER_SUBNET" \
  -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

# --- nftables backend (current `inet nordvpn` table) -------------------------
#
# Skip silently if `nft` isn't installed, or if the `inet nordvpn` table
# isn't present (older NordVPN, or Meshnet currently off). The iptables
# rules above are still useful on those hosts.

NFT_MARK="docker-meshnet-fix"

if command -v nft >/dev/null 2>&1 && nft list table inet nordvpn >/dev/null 2>&1; then
  # Remove any prior rules carrying our marker (idempotent re-runs).
  # We tag our rule with a comment so we can find+remove without colliding
  # with nordvpn's own rules in the same chain.
  while read -r handle; do
    [[ -n "$handle" ]] || continue
    nft delete rule inet nordvpn forward handle "$handle" 2>/dev/null || true
  done < <(
    nft -a list chain inet nordvpn forward 2>/dev/null \
      | awk -v m="$NFT_MARK" '
          index($0, "comment \"" m "\"") > 0 {
            for (i = 1; i <= NF; i++) if ($i == "handle") print $(i+1)
          }'
  )

  # Insert at the top of the forward chain so we run before nordvpn's
  # jumps into `internet_to_mesh_peer` (whose terminal `drop` kills the
  # container's NEW SYNs). Return traffic from the peer goes through
  # `mesh_peer_to_internet` which already accepts non-meshnet destinations
  # for allowlisted peers, so a single egress rule is sufficient.
  nft insert rule inet nordvpn forward \
    ip saddr "$DOCKER_SUBNET" ip daddr "$MESHNET_SUBNET" \
    accept comment "$NFT_MARK"
fi
