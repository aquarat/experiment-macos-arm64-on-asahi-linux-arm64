#!/usr/bin/env bash
# Layer 45: boot once under a QEMU with the avp,rtc clock so the image's NVRAM
# (in AUX) gets com.apple.System.rtc-offset.                         (Tahoe v7)
# Runs INSIDE the guest; the change is made by macOS itself at boot/shutdown:
#
#   scripts/bake-golden.sh tahoe-26.4-25E246-v6 tahoe-26.4-25E246-v7 \
#       "baked under QEMU with avp,rtc: NVRAM rtc-offset present, so timed trusts the RTC" \
#       "bash -s" < images/45-avp-rtc.sh
#
# Needed only for images whose earlier layers were baked under a PL031-only
# QEMU. With scripts/build-qemu.sh's QEMU (avp,rtc on by default) every bake
# already runs under avp,rtc, so on a from-scratch chain this layer is a
# harmless check. Fails if the QEMU lacks avp,rtc.
# The body is a function run with stdin from /dev/null: bash -s reads this
# script from stdin incrementally, so any command reading stdin would swallow
# the rest of it and the bake would "succeed" with half a layer.
main() {
    set -euo pipefail

    sleep 25      # let timed settle and write the offset
    # Only AppleVirtualPlatformRTC registers this sysctl; absent = no avp,rtc device.
    off="$(sysctl -n kern.monotoniclock_offset_usecs)"
    echo "kern.monotoniclock_offset_usecs: $off"
    echo "NVRAM rtc entries: $(nvram -p 2>/dev/null | grep -i -c rtc || true)"
    echo "layer 45 complete"
}
main "$@" < /dev/null
