#!/usr/bin/env bash
# Hand a running guest's unused memory back to the host: inflate the balloon
# step by step down to a floor, then deflate to the full size again.
#
#   scripts/balloon-squeeze.sh <vm-name> [floor e.g. 4G]
#
# Needs the guest started with BALLOON=1 (virtio-balloon with macos-units,
# aquarat/qemu-reims-vgpu QEMU) and no governor driving it (vm-job.sh:
# BALLOON_GOVERNOR=0); see docs/NOTES.md "Memory balloon (macOS guests)".
# Steps of BALLOON_STEP (default 256M), each confirmed via query-balloon.
# Pages the balloon took are discarded on the host (RSS drops); after the
# deflate the guest has its full RAM again, re-backed only when touched.
# Prints the host RSS before and after (QEMU Rss under-counts memfd RAM).
set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
name="${1:?usage: $0 <vm-name> [floor]}"
to_bytes() { numfmt --from=iec "${1%B}"; }
floor="$(to_bytes "${2:-4G}")"
step="$(to_bytes "${BALLOON_STEP:-256M}")"
step_timeout="${BALLOON_STEP_TIMEOUT:-20}"

qmp() { "$repo_root/scripts/vm-run.sh" qmp "$name" "$1" | tail -1; }
actual() { qmp '{"execute":"query-balloon"}' | python3 -c 'import json,sys; print(json.load(sys.stdin)["return"]["actual"])'; }
pid() { pgrep -f "qemu-system-aarch64.*artifacts/runs/$name/" | head -1; }
rss() { local p; p="$(pid)"; test -n "$p" && awk '/^Rss:/{printf "%.2f GB", $2/1048576}' "/proc/$p/smaps_rollup"; }

full="$(actual)" || { echo "no balloon on $name" >&2; exit 1; }
echo "[squeeze $name] start: guest $((full >> 20)) MiB, host RSS $(rss)"
target="$full"
while (( target - step >= floor )); do
    target=$((target - step))
    qmp "{\"execute\":\"balloon\",\"arguments\":{\"value\":$target}}" >/dev/null
    t0=$(date +%s)
    until (( $(actual) <= target )); do
        if (( $(date +%s) - t0 > step_timeout )); then
            echo "[squeeze $name] no progress at $((target >> 20)) MiB; stopping there"
            break 2
        fi
        sleep 1
    done
done
reached="$(actual)"
qmp "{\"execute\":\"balloon\",\"arguments\":{\"value\":$full}}" >/dev/null
echo "[squeeze $name] inflated to $((reached >> 20)) MiB, deflated to $((full >> 20)) MiB; host RSS $(rss)"
