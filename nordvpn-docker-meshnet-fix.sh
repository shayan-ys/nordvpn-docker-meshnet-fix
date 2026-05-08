#!/bin/bash
# nordvpn-docker-meshnet-fix
# Keep Docker-bridge -> NordVPN-Meshnet FORWARD rules above nordvpnd's DROPs.
#
# NordVPN's `nordvpn-exitnode-permanent` chain installs DROP rules at position 1
# of the FORWARD chain whenever Meshnet (re)starts or peer settings change.
# Existence-check logic (`iptables -C`) is insufficient because rule ORDER
# matters: rules below the DROPs do nothing. This script delete-then-reinserts
# at position 1 every run.
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

# Egress: Docker -> Meshnet
iptables -D FORWARD -s "$DOCKER_SUBNET" -d "$MESHNET_SUBNET" -j ACCEPT 2>/dev/null || true
iptables -I FORWARD 1 -s "$DOCKER_SUBNET" -d "$MESHNET_SUBNET" -j ACCEPT

# Return: Meshnet -> Docker (established connections only)
iptables -D FORWARD -s "$MESHNET_SUBNET" -d "$DOCKER_SUBNET" \
  -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
iptables -I FORWARD 1 -s "$MESHNET_SUBNET" -d "$DOCKER_SUBNET" \
  -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
