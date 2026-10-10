#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Guest-side installer for boot diagnostics with a DHCP kick (debug goldens only):
#   scripts/bake-golden.sh <src> <dst> "DEBUG: bootdiag2" "bash -s" < scripts/debug/bootdiag2-install.sh
# Logs clock, DHCP client and configd state to the console every 5 s for
# 3 minutes. If en0 has no IPv4 address after 45 s it runs `ipconfig set en0
# DHCP`, after 90 s it bounces en0. Output reaches the serial log when booted
# with the verbose injector (INJECT=1 KVM_MMIO_PATCH=0).
set -euo pipefail
sudo -n mkdir -p /usr/local/libexec
sudo -n tee /usr/local/libexec/vmapple-bootdiag2.sh >/dev/null <<'EOF'
#!/bin/sh
exec >/dev/console 2>&1
# run "$@" with a wall-clock limit (macOS has no timeout(1))
lim() { perl -e 'alarm shift; exec @ARGV' "$@"; }
i=0; kicked=0; bounced=0
while [ $i -lt 36 ]; do
  t=$((i*5))
  addr=$(ipconfig getifaddr en0 2>/dev/null)
  echo "BOOTDIAG2 t=$t date=$(date +%H:%M:%S) addr=[$addr] ifs=[$(ifconfig -l)]"
  if [ -z "$addr" ]; then
    echo "BOOTDIAG2 summary: $(lim 5 ipconfig getsummary en0 2>&1 | grep -E 'State|LinkStatusActive|IPv4|DHCP|Lease|Error' | tr -s ' \n' ' ' | cut -c1-400)"
    echo "BOOTDIAG2 nwi: $(lim 5 scutil --nwi 2>&1 | tr -s ' \n' ' ' | cut -c1-200) rc=$?"
    echo "BOOTDIAG2 procs: $(ps -axo pid,stat,etime,comm | grep -E 'configd|mDNSResponder|logd|timed|IPConfiguration' | grep -v grep | tr -s ' \n' ' ')"
    if [ $t -ge 45 ] && [ $kicked = 0 ]; then
      kicked=1; echo "BOOTDIAG2 KICK ipconfig set en0 DHCP: $(lim 10 ipconfig set en0 DHCP 2>&1; echo rc=$?)"
    elif [ $t -ge 90 ] && [ $bounced = 0 ]; then
      bounced=1; echo "BOOTDIAG2 BOUNCE en0: $(ifconfig en0 down 2>&1; sleep 1; ifconfig en0 up 2>&1; echo rc=$?)"
    fi
  elif [ $kicked = 1 ] || [ $bounced = 1 ]; then
    echo "BOOTDIAG2 RECOVERED t=$t addr=$addr kicked=$kicked bounced=$bounced"; kicked=2; bounced=2
  fi
  i=$((i+1)); sleep 5
done
EOF
sudo -n chmod 755 /usr/local/libexec/vmapple-bootdiag2.sh
sudo -n rm -f /Library/LaunchDaemons/org.vmapple.bootdiag.plist /usr/local/libexec/vmapple-bootdiag.sh
sudo -n tee /Library/LaunchDaemons/org.vmapple.bootdiag2.plist >/dev/null <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>org.vmapple.bootdiag2</string>
  <key>ProgramArguments</key><array><string>/usr/local/libexec/vmapple-bootdiag2.sh</string></array>
  <key>RunAtLoad</key><true/>
</dict></plist>
EOF
sudo -n chown root:wheel /Library/LaunchDaemons/org.vmapple.bootdiag2.plist
sudo -n chmod 644 /Library/LaunchDaemons/org.vmapple.bootdiag2.plist
plutil -lint /Library/LaunchDaemons/org.vmapple.bootdiag2.plist
