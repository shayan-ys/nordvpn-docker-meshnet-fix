#!/bin/bash
# Integration test: spin up a privileged container, simulate nordvpnd's
# FORWARD-DROP rules, run the fix script, assert the ACCEPT rules end up
# at position 1 (above the DROPs).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IMAGE_TAG="nordvpn-docker-meshnet-fix-test:latest"

docker build -q -t "$IMAGE_TAG" "$REPO_ROOT/tests/integration/" >/dev/null

docker run --rm --privileged \
  -v "$REPO_ROOT:/repo:ro" \
  "$IMAGE_TAG" bash -euxc '
    # Simulate nordvpnd: install the two permanent DROPs at position 1.
    iptables -I FORWARD 1 -s 0.0.0.0/0 -d 100.64.0.0/10 -j DROP \
      -m comment --comment "nordvpn-exitnode-permanent"
    iptables -I FORWARD 1 -s 100.64.0.0/10 -d 0.0.0.0/0 -j DROP \
      -m comment --comment "nordvpn-exitnode-permanent"

    # Sanity: DROPs are at top.
    iptables -L FORWARD -n --line-numbers | head -5

    # Run the fix.
    bash /repo/nordvpn-docker-meshnet-fix.sh

    # Assert: rule 1 and rule 2 are our ACCEPTs.
    rules=$(iptables -L FORWARD -n --line-numbers)
    echo "$rules"
    line1=$(echo "$rules" | awk "\$1==\"1\"")
    line2=$(echo "$rules" | awk "\$1==\"2\"")
    echo "$line1" | grep -q ACCEPT
    echo "$line2" | grep -q ACCEPT
    echo "$line1" | grep -qE "100.64.0.0/10|172.18.0.0/16"
    echo "$line2" | grep -qE "100.64.0.0/10|172.18.0.0/16"

    # Re-run: must remain at position 1 (delete-then-reinsert behavior).
    bash /repo/nordvpn-docker-meshnet-fix.sh
    iptables -L FORWARD -n --line-numbers | awk "\$1==\"1\"" | grep -q ACCEPT
    iptables -L FORWARD -n --line-numbers | awk "\$1==\"2\"" | grep -q ACCEPT

    echo "INTEGRATION TEST PASSED"
  '
