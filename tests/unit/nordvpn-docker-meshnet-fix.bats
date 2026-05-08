#!/usr/bin/env bats

load test_helper

setup() {
  setup_iptables_mock
}

@test "uses default subnets when no env or conf is set" {
  run run_script
  [ "$status" -eq 0 ]
  grep -q -- '-s 172.18.0.0/16 -d 100.64.0.0/10 -j ACCEPT' "$IPTABLES_LOG"
  grep -q -- '-s 100.64.0.0/10 -d 172.18.0.0/16' "$IPTABLES_LOG"
  grep -q -- '--ctstate RELATED,ESTABLISHED' "$IPTABLES_LOG"
}

@test "honors DOCKER_SUBNET env override" {
  DOCKER_SUBNET=10.20.0.0/16 run run_script
  [ "$status" -eq 0 ]
  grep -q -- '-s 10.20.0.0/16 -d 100.64.0.0/10 -j ACCEPT' "$IPTABLES_LOG"
  ! grep -q -- '-s 172.18.0.0/16' "$IPTABLES_LOG"
}

@test "honors MESHNET_SUBNET env override" {
  MESHNET_SUBNET=100.65.0.0/16 run run_script
  [ "$status" -eq 0 ]
  grep -q -- '-d 100.65.0.0/16 -j ACCEPT' "$IPTABLES_LOG"
}

@test "always inserts at FORWARD position 1" {
  run run_script
  [ "$status" -eq 0 ]
  # Both -I commands must include "FORWARD 1"
  insert_count=$(grep -c -- '-I FORWARD 1' "$IPTABLES_LOG")
  [ "$insert_count" -eq 2 ]
}

@test "deletes before inserting (egress rule)" {
  run run_script
  [ "$status" -eq 0 ]
  # First operation per direction must be -D, second must be -I
  egress_first=$(grep -E -- '-(D|I) FORWARD.* -s 172.18.0.0/16 -d 100.64.0.0/10' "$IPTABLES_LOG" | head -1)
  [[ "$egress_first" == *"-D FORWARD"* ]]
}

@test "exits non-zero when iptables is missing" {
  # PATH=/nonexistent guarantees `command -v iptables` finds nothing on any host
  # (Ubuntu has /usr/sbin/iptables in default PATH, so just dropping the mock
  # bin dir from PATH isn't enough). Use absolute /bin/bash to bypass PATH.
  run /bin/bash -c 'PATH=/nonexistent exec /bin/bash "$1"' _ \
    "$BATS_TEST_DIRNAME/../../nordvpn-docker-meshnet-fix.sh"
  [ "$status" -eq 2 ]
  [[ "$output" == *"iptables not found"* ]]
}

@test "reads /etc/default conf if path is overridden via CONF env" {
  # The script hardcodes CONF=/etc/default/...; for this test we wrap.
  # Skip if the script doesn't expose CONF override — current implementation does not.
  skip "CONF override not exposed; documenting expected behavior only"
}
