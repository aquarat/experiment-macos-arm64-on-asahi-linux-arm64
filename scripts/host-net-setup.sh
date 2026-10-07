#!/usr/bin/env bash
# Host networking for guests that need their own address (run with sudo).
#
#   sudo scripts/host-net-setup.sh taps <bridge> <slots>   # persistent vmtap1..N on <bridge>
#   sudo scripts/host-net-setup.sh test-up                 # isolated br-vmtest + DHCP (runtime only)
#   sudo scripts/host-net-setup.sh test-down
#
# Each runner slot N then boots with TAP_IF=vmtapN TAP_MAC=52:54:00:76:62:0N
# (a stable MAC, so the LAN's DHCP server can reserve a stable address).
#
# Bridging the host's LAN Ethernet is deliberately not automated, because it
# moves the host's own address and can drop the SSH session doing it. On a
# NetworkManager host with Ethernet <eth>, from a local console:
#   nmcli con add type bridge ifname br0 con-name br0 bridge.stp no ipv4.method auto
#   nmcli con add type bridge-slave ifname <eth> master br0 con-name br0-port
#   nmcli con down "<current eth connection>"; nmcli con up br0
# Wi-Fi client interfaces cannot be bridged; use user-mode NAT there.
set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }
test "$(id -u)" = 0 || die "run with sudo"
owner="${SUDO_UID:?run via sudo so the taps belong to the invoking user}"

case "${1:-}" in
taps)
    bridge="${2:?bridge}"; slots="${3:?slots}"
    test -d "/sys/class/net/$bridge/bridge" || die "$bridge is not a bridge"
    for n in $(seq 1 "$slots"); do
        nmcli -t -f NAME con show | grep -qx "vmtap$n" ||
            nmcli con add type tun ifname "vmtap$n" con-name "vmtap$n" \
                tun.mode tap tun.owner "$owner" \
                controller "$bridge" port-type bridge autoconnect yes >/dev/null
        nmcli con up "vmtap$n" >/dev/null
        echo "vmtap$n on $bridge (owner uid $owner)"
    done
    ;;
test-up)
    ip link show br-vmtest >/dev/null 2>&1 || ip link add br-vmtest type bridge
    ip addr replace 198.51.100.1/24 dev br-vmtest
    ip link set br-vmtest up
    ip link show vmtap1 >/dev/null 2>&1 || ip tuntap add vmtap1 mode tap user "$owner"
    ip link set vmtap1 master br-vmtest up
    firewall-cmd --zone=trusted --add-interface=br-vmtest >/dev/null 2>&1 || true
    dnsmasq --interface=br-vmtest --bind-interfaces --except-interface=lo --port=0 \
        --dhcp-range=198.51.100.50,198.51.100.99,1h --dhcp-leasefile=/run/br-vmtest.leases \
        --pid-file=/run/br-vmtest-dnsmasq.pid --log-dhcp --log-facility=/run/br-vmtest-dnsmasq.log
    echo "br-vmtest 198.51.100.1/24 with DHCP .50-.99; vmtap1 attached"
    ;;
test-down)
    test -f /run/br-vmtest-dnsmasq.pid && kill "$(cat /run/br-vmtest-dnsmasq.pid)" 2>/dev/null || true
    firewall-cmd --zone=trusted --remove-interface=br-vmtest >/dev/null 2>&1 || true
    ip link del vmtap1 2>/dev/null || true
    ip link del br-vmtest 2>/dev/null || true
    rm -f /run/br-vmtest.leases /run/br-vmtest-dnsmasq.pid
    echo "test bridge removed"
    ;;
*) die "usage: $0 taps <bridge> <slots> | test-up | test-down" ;;
esac
