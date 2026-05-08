# Mock iptables: append every invocation's argv (one per line) to $IPTABLES_LOG.
# `iptables -D` returns 1 on first call (rule absent) so the script's || true
# fallback path is exercised; subsequent -D calls return 0.
setup_iptables_mock() {
  export IPTABLES_LOG="$BATS_TEST_TMPDIR/iptables.log"
  : > "$IPTABLES_LOG"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/iptables" <<'MOCK'
#!/bin/bash
echo "iptables $*" >> "$IPTABLES_LOG"
# Make -D fail on first call only, to mimic "rule not present yet"
if [[ "$1" == "-D" ]]; then
  marker="$BATS_TEST_TMPDIR/.delete_seen_$2_$3"
  if [[ ! -f "$marker" ]]; then
    : > "$marker"
    exit 1
  fi
fi
exit 0
MOCK
  chmod +x "$BATS_TEST_TMPDIR/bin/iptables"
}

run_script() {
  bash "$BATS_TEST_DIRNAME/../../nordvpn-docker-meshnet-fix.sh"
}
