#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Layer 55: the iOS simulator platform matching the installed Xcode
# (Xcode 26.4.1 -> iOS 26.4.1, 23E254a; an 8.46 GB MobileAsset).     (Tahoe v10)
# Runs INSIDE the guest on top of layer 50 (Xcode, scripts/bake-xcode.sh):
#
#   GFX=none scripts/bake-golden.sh tahoe-26.4-25E246-v9 tahoe-26.4-25E246-v10 \
#       "v9 + iOS 26.4.1 simulator platform (xcodebuild -downloadPlatform iOS)" \
#       "bash -s" < images/55-ios-simulator.sh
#
# Bake on a host with WIRED Ethernet: slirp passes the host's full speed there
# (~25 MB/s, ~6 min) but crawled at ~330 KiB/s on a Wi-Fi host. Idempotent.
# The body is a function run with stdin from /dev/null: bash -s reads this
# script from stdin incrementally, so any command reading stdin would swallow
# the rest of it and the bake would "succeed" with half a layer.
main() {
    set -euo pipefail

    xcodebuild -version
    # CoreSimulatorService needs ~30 s to come up the first time; until then
    # -downloadPlatform fails with "Unable to connect to simulator".
    xcrun simctl list runtimes >/dev/null 2>&1 || true
    if ! xcrun simctl list runtimes | grep -q '^iOS '; then
        log="$(mktemp)"; trap 'rm -f "$log"' EXIT
        for try in 1 2 3; do
            if xcodebuild -downloadPlatform iOS > "$log" 2>&1; then ok=1; else ok=0; fi
            # Drop the per-percent progress lines.
            tr '\r' '\n' < "$log" | grep -v -E '^Downloading .*%|^$' | tail -5 || true
            test "$ok" = 1 && break
            test "$try" = 3 && { echo "downloadPlatform failed 3 times" >&2; exit 1; }
            sleep 30
        done
    fi
    xcrun simctl list runtimes
    rt="$(xcrun simctl list runtimes | grep -o 'iOS [0-9.]* ([^)]*)' | head -1)"
    test -n "$rt" || { echo "no iOS runtime listed" >&2; exit 1; }
    echo "+ iOS simulator platform $rt" | sudo -n tee -a /etc/vmapple-image-version
    echo "layer 55 complete"
}
main "$@" < /dev/null
