#!/bin/bash
# Ensure Docker bridge (172.18.0.0/16) can reach NordVPN Meshnet (100.64.0.0/10)
# nordvpn-exitnode-permanent rules block this; delete-then-reinsert at position 1
# so ACCEPTs always precede nordvpnd DROP rules.
# (iptables -C only checks rule existence, not position, so check+insert logic
# leaves rules stranded below DROPs after nordvpnd refreshes.)

# Egress: Docker -> Meshnet
iptables -D FORWARD -s 172.18.0.0/16 -d 100.64.0.0/10 -j ACCEPT 2>/dev/null
iptables -I FORWARD 1 -s 172.18.0.0/16 -d 100.64.0.0/10 -j ACCEPT

# Return: Meshnet -> Docker (established connections)
iptables -D FORWARD -s 100.64.0.0/10 -d 172.18.0.0/16 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null
iptables -I FORWARD 1 -s 100.64.0.0/10 -d 172.18.0.0/16 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
