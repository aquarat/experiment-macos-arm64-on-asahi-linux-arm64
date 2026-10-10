#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Layer 62: pre-warm the iOS simulator so CI jobs don't pay for first use.
# Runs INSIDE the guest on top of layer 60 (any GFX; GFX=none is fine):
#
#   GFX=none scripts/bake-golden.sh <src> <dst> "simulator warm (images/62-simulator-warm.sh)" \
#       "bash -s" < images/62-simulator-warm.sh
#
# Without this, every fresh clone of the image spends (8G/4 CPU guest):
# - ~130 s building the simulator runtime's dyld shared cache (CoreSimulator
#   does it on first use; it lives in /Library/Developer/CoreSimulator/Caches);
# - ~105 s extra on each device's first boot (data migration, first-launch
#   setup); later boots of the same device take ~20 s.
# Both are written to the image here. Warmed devices: SIM_WARM_DEVICES, a
# comma-separated list of existing device names (default: the newest
# "iPhone <N>" and "iPhone <N> Pro"); jobs should use one of them (by name)
# rather than `simctl create` a new one. Each warmed device is ~650 MB.
# The body is a function run with stdin from /dev/null (see docs/IMAGES.md).
main() {
    set -euo pipefail

    xcrun simctl list runtimes >/dev/null 2>&1 || true   # start CoreSimulatorService
    xcrun simctl runtime dyld_shared_cache update --all

    local names
    names="${SIM_WARM_DEVICES:-$(xcrun simctl list devices available -j | /usr/bin/python3 -c '
import json, re, sys
names = {d["name"] for devs in json.load(sys.stdin)["devices"].values() for d in devs}
for pat in (r"iPhone (\d+)", r"iPhone (\d+) Pro"):
    m = sorted((int(re.fullmatch(pat, n).group(1)), n) for n in names if re.fullmatch(pat, n))
    if m: print(m[-1][1])
' | paste -sd, -)}"
    test -n "$names" || { echo "no simulator devices to warm" >&2; exit 1; }

    local name udid s secs
    local IFS=,
    for name in $names; do
        udid="$(xcrun simctl list devices available -j | /usr/bin/python3 -c '
import json, sys
print(next(d["udid"] for devs in json.load(sys.stdin)["devices"].values() for d in devs if d["name"] == sys.argv[1]))
' "$name")"
        s=$(date +%s)
        xcrun simctl bootstatus "$udid" -b >/dev/null
        echo "$name ($udid): first boot $(( $(date +%s) - s )) s"
        sleep 60   # let post-boot first-launch work finish
        xcrun simctl shutdown "$udid"
        s=$(date +%s)
        xcrun simctl bootstatus "$udid" -b >/dev/null
        secs=$(( $(date +%s) - s ))
        xcrun simctl shutdown "$udid"
        echo "$name: warm boot $secs s"
    done
    du -sh /Library/Developer/CoreSimulator/Caches/dyld

    echo "+ simulator warm (images/62-simulator-warm.sh): dyld cache, devices: $names" |
        sudo -n tee -a /etc/vmapple-image-version >/dev/null
    echo "layer 62-simulator-warm complete"
}
main "$@" < /dev/null
