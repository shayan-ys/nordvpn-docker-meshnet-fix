#!/bin/bash
# uninstall.sh — disable the timer and remove installed files.
# Does NOT remove iptables rules (they expire on next nordvpnd state change).

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "uninstall.sh: must run as root (use sudo)" >&2
  exit 1
fi

systemctl disable --now nordvpn-docker-meshnet-fix.timer 2>/dev/null || true
systemctl disable --now nordvpn-docker-meshnet-fix.service 2>/dev/null || true

rm -f /etc/systemd/system/nordvpn-docker-meshnet-fix.service
rm -f /etc/systemd/system/nordvpn-docker-meshnet-fix.timer
rm -f /usr/local/bin/nordvpn-docker-meshnet-fix.sh

# Keep /etc/default/nordvpn-docker-meshnet-fix unless --purge
if [[ "${1:-}" == "--purge" ]]; then
  rm -f /etc/default/nordvpn-docker-meshnet-fix
  echo "Purged /etc/default/nordvpn-docker-meshnet-fix"
fi

systemctl daemon-reload
echo "Uninstalled. iptables FORWARD rules untouched; they will expire on next nordvpnd refresh."
