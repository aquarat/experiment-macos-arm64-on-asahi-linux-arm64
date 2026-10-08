#!/usr/bin/env bash
# One VM experiment per invocation, from a read-only golden bundle.
#
#   GOLDEN=~/vm-artifacts/<bundle> scripts/vm-run.sh start <name>   [env passed to launch-gui-kvm.sh]
#   scripts/vm-run.sh status <name>
#   scripts/vm-run.sh qmp <name> '<json command>'
#   scripts/vm-run.sh screenshot <name>     # writes artifacts/runs/<name>/screen-<time>.png
#   scripts/vm-run.sh quit <name>
#
# start reflink-clones disk.img and aux.img.trimmed (btrfs: instant, no space
# until the guest writes), so the golden bundle is never opened read-write.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
runs="$repo_root/artifacts/runs"
golden="${GOLDEN:-$HOME/vm-artifacts/ventura-13.6-22G120-v2}"
booter="${AVPBOOTER:-$repo_root/artifacts/firmware/AVPBooter.vmapple2.mBoot-18000.101.7.bin}"
sock_dir="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/vmapple"
# Mesa's AGX compiler asserts on Reims FP16 shaders (see docs/NOTES.md); llvmpipe is the
# known-good renderer until Honeykrisp is qualified.
export VK_DRIVER_FILES="${VK_DRIVER_FILES:-/usr/share/vulkan/icd.d/lvp_icd.aarch64.json}"

die() { echo "error: $*" >&2; exit 1; }
name="${2:-}"; test -n "$name" || die "usage: $0 start|status|qmp|screenshot|quit <name>"
[[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || die "bad run name"
run="$runs/$name"
qmp="$sock_dir/$name.qmp"

qmp_call() {
    printf '%s\n' '{"execute":"qmp_capabilities"}' "$1" |
        socat -t"${QMP_WAIT:-3}" - "UNIX-CONNECT:$qmp" | tail -n +3
}

case "$1" in
start)
    if test "${RESUME:-0}" = 1; then
        # Boot an existing run's disk again (e.g. after a single-user bake).
        test -f "$run/disk.img" || die "$run has no disk to resume"
        mv "$run/logs" "$run/logs.$(date +%H%M%S)" 2>/dev/null || true
    else
        test ! -e "$run" || die "$run exists"
    fi
    mkdir -p "$run/logs" "$sock_dir"
    if test "${RESUME:-0}" != 1; then
        for f in disk.img aux.img.trimmed vm.json; do
            cp --reflink=always "$golden/guest/$f" "$run/$f"
            chmod u+w "$run/$f"
        done
    fi
    env | grep -E '^(CPUS|RAM|NET_DEVICE_OPTS|TAP_IF|TAP_MAC|INJECT|KVM_MMIO_PATCH|VMAPPLE_HANDOFF_PC|GFX|CONSOLE|XNU_BOOT_ARGS|CSR_CONFIG|QEMU_EXTRA_ARGS|REIMS_[A-Z_]+|VK_[A-Z_]+|MESA_[A-Z_]+|SSH_PORT|SSH_BIND|MEMFD|BALLOON[A-Z_]*|AUDIO[A-Z_]*)=' \
        > "$run/env.txt" || true
    echo "golden=$golden booter=$booter" >> "$run/env.txt"
    (
        cd "$repo_root"
        GUEST_DIR="$run" AVPBOOTER="$booter" LOG_DIR="$run/logs" QMP_SOCKET="$qmp" \
            REIMS_VGPU_WINDOW="${REIMS_VGPU_WINDOW:-0}" CONSOLE="${CONSOLE:-none}" \
            setsid nohup scripts/launch-gui-kvm.sh > "$run/logs/launcher.log" 2>&1 < /dev/null &
        echo $! > "$run/launcher.pid"
    )
    echo "started $name: $run"
    ;;
status)
    qmp_call '{"execute":"query-status"}'
    qmp_call '{"execute":"human-monitor-command","arguments":{"command-line":"info registers"}}' |
        grep -o 'PC=[0-9a-f]*' || true
    ;;
qmp) qmp_call "${3:?json}" ;;
screenshot)
    t="$(date +%H%M%S)"
    qmp_call "{\"execute\":\"screendump\",\"arguments\":{\"filename\":\"$run/screen-$t.ppm\"}}" >/dev/null
    magick "$run/screen-$t.ppm" -resize 50% "$run/screen-$t.png" && rm -f "$run/screen-$t.ppm"
    echo "$run/screen-$t.png"
    ;;
quit) qmp_call '{"execute":"quit"}' || true ;;
*) die "unknown command $1" ;;
esac
