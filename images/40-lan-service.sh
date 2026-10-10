#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Layer 40: a DHCP network service "LAN" on en1, for the optional second NIC on
# a host tap/bridge (launch-kvm.sh TAP_IF/TAP_MAC).                (Tahoe v6)
# Runs INSIDE the guest. en1 exists only if the bake guest has the tap NIC:
#
#   sudo scripts/host-net-setup.sh test-up        # or: taps <bridge> 1
#   TAP_IF=vmtap1 TAP_MAC=52:54:00:76:62:01 scripts/bake-golden.sh \
#       tahoe-26.4-25E246-v4 tahoe-26.4-25E246-v6 \
#       "network service LAN (DHCP) on en1 for an optional bridged tap NIC" "bash -s" < images/40-lan-service.sh
#
# Without the service macOS never runs DHCP on en1. The default route stays on
# en0 (user-mode NAT, the management path). Idempotent.
# The body is a function run with stdin from /dev/null: bash -s reads this
# script from stdin incrementally, so any command reading stdin would swallow
# the rest of it and the bake would "succeed" with half a layer.
main() {
    set -euo pipefail

    SERVICE="${SERVICE:-LAN}"
    IFACE="${IFACE:-en1}"

    networksetup -listallhardwareports | grep -q "^Device: $IFACE\$" ||
        { echo "no $IFACE: bake with TAP_IF/TAP_MAC set (second NIC)" >&2; exit 1; }
    if ! networksetup -listallnetworkservices | grep -qx "$SERVICE"; then
        sudo -n networksetup -createnetworkservice "$SERVICE" "$IFACE"
    fi
    sudo -n networksetup -setdhcp "$SERVICE"
    networksetup -listallnetworkservices
    sleep 8
    echo "$IFACE address: $(ipconfig getifaddr "$IFACE" || echo none yet)"
    echo "layer 40 complete"
}
main "$@" < /dev/null
