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

# Mock nft: append argv to $NFT_LOG. Stateful enough to simulate the
# `nft list table inet nordvpn` existence probe and the
# `nft -a list chain inet nordvpn forward` listing used to find handles.
#
# Modes (set via env before calling):
#   NFT_MODE=absent   -> nft binary is not on PATH (skip nft branch)
#   NFT_MODE=no_table -> nft is present but `list table inet nordvpn` fails
#   NFT_MODE=clean    -> nft is present, table exists, no prior marked rules
#   NFT_MODE=stale    -> nft is present, table exists, one prior marked rule
#                        at handle 99 (script should delete it before re-adding)
setup_nft_mock() {
  export NFT_LOG="$BATS_TEST_TMPDIR/nft.log"
  : > "$NFT_LOG"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  mkdir -p "$BATS_TEST_TMPDIR/bin"

  local mode="${NFT_MODE:-clean}"

  if [[ "$mode" == "absent" ]]; then
    # Don't create the nft mock — `command -v nft` will return false.
    return 0
  fi

  cat > "$BATS_TEST_TMPDIR/bin/nft" <<MOCK
#!/bin/bash
echo "nft \$*" >> "$NFT_LOG"
mode="$mode"

# \`nft list table inet nordvpn\`
if [[ "\$1" == "list" && "\$2" == "table" && "\$3" == "inet" && "\$4" == "nordvpn" ]]; then
  [[ "\$mode" == "no_table" ]] && exit 1
  exit 0
fi

# \`nft -a list chain inet nordvpn forward\`
if [[ "\$1" == "-a" && "\$2" == "list" && "\$3" == "chain" && "\$4" == "inet" \\
      && "\$5" == "nordvpn" && "\$6" == "forward" ]]; then
  echo 'table inet nordvpn {'
  echo '    chain forward {'
  echo '        type filter hook forward priority filter; policy accept;'
  if [[ "\$mode" == "stale" ]]; then
    echo '        ip saddr 172.18.0.0/16 ip daddr 100.64.0.0/10 accept comment "docker-meshnet-fix" # handle 99'
  fi
  echo '        ip saddr 100.64.0.0/10 jump mesh_peer_to_internet # handle 28'
  echo '        ip daddr 100.64.0.0/10 jump internet_to_mesh_peer # handle 34'
  echo '    }'
  echo '}'
  exit 0
fi

exit 0
MOCK
  chmod +x "$BATS_TEST_TMPDIR/bin/nft"
}

run_script() {
  bash "$BATS_TEST_DIRNAME/../../nordvpn-docker-meshnet-fix.sh"
}
