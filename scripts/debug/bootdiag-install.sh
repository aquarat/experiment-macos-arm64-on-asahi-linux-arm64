#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Guest-side installer for a boot-diagnostics LaunchDaemon (debug goldens only):
#   scripts/bake-golden.sh <src> <dst> "DEBUG: bootdiag" "bash -s" < scripts/debug/bootdiag-install.sh
# Output reaches the serial log when booted with the verbose injector
# (INJECT=1 KVM_MMIO_PATCH=0).
set -euo pipefail
sudo -n mkdir -p /usr/local/libexec
sudo -n tee /usr/local/libexec/vmapple-bootdiag.sh >/dev/null <<'EOF'
#!/bin/sh
# Boot diagnostics for the Tahoe no-network flake: print network/configd state
# to the console (serial when booted with serial=11) for the first 3 minutes.
exec >/dev/console 2>&1
i=0
while [ $i -lt 36 ]; do
  echo "BOOTDIAG t=$((i*5)) ifs=[$(ifconfig -l)] en0=[$(ifconfig en0 2>&1 | grep -E 'status|inet ' | tr '\n' ' ')]"
  echo "BOOTDIAG configd=[$(launchctl print system/com.apple.configd 2>/dev/null | grep -m1 'state =' | tr -d '\t')] sshd=[$(launchctl print system/com.openssh.sshd 2>/dev/null | grep -m1 'state =' | tr -d '\t')]"
  log show --last 6s --style compact --predicate 'process == "configd" OR senderImagePath CONTAINS[c] "IONetworking" OR senderImagePath CONTAINS[c] "AppleVirtIO"' 2>/dev/null | tail -6 | sed 's/^/BOOTDIAG log /'
  i=$((i+1)); sleep 5
done
EOF
sudo -n chmod 755 /usr/local/libexec/vmapple-bootdiag.sh
sudo -n tee /Library/LaunchDaemons/org.vmapple.bootdiag.plist >/dev/null <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>org.vmapple.bootdiag</string>
  <key>ProgramArguments</key><array><string>/usr/local/libexec/vmapple-bootdiag.sh</string></array>
  <key>RunAtLoad</key><true/>
</dict></plist>
EOF
sudo -n chown root:wheel /Library/LaunchDaemons/org.vmapple.bootdiag.plist
sudo -n chmod 644 /Library/LaunchDaemons/org.vmapple.bootdiag.plist
plutil -lint /Library/LaunchDaemons/org.vmapple.bootdiag.plist
