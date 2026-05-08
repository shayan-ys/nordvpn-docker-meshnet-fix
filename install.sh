#!/bin/bash
# install.sh — copy the script + units into place and enable the timer.
# Idempotent: safe to re-run.

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "install.sh: must run as root (use sudo)" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

install -m 0755 "$SCRIPT_DIR/nordvpn-docker-meshnet-fix.sh" \
  /usr/local/bin/nordvpn-docker-meshnet-fix.sh

install -m 0644 "$SCRIPT_DIR/nordvpn-docker-meshnet-fix.service" \
  /etc/systemd/system/nordvpn-docker-meshnet-fix.service
install -m 0644 "$SCRIPT_DIR/nordvpn-docker-meshnet-fix.timer" \
  /etc/systemd/system/nordvpn-docker-meshnet-fix.timer

if [[ ! -f /etc/default/nordvpn-docker-meshnet-fix ]]; then
  install -m 0644 "$SCRIPT_DIR/nordvpn-docker-meshnet-fix.env.example" \
    /etc/default/nordvpn-docker-meshnet-fix
  echo "Wrote default config to /etc/default/nordvpn-docker-meshnet-fix"
else
  echo "Keeping existing /etc/default/nordvpn-docker-meshnet-fix"
fi

systemctl daemon-reload
systemctl enable --now nordvpn-docker-meshnet-fix.timer

echo
echo "Installed. Verify with:"
echo "  sudo systemctl status nordvpn-docker-meshnet-fix.timer"
echo "  sudo iptables -L FORWARD -n --line-numbers | head -10"
