#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
gui_qemu="$repo_root/build/reims-linux-product/vendor/qemu/build/qemu-system-aarch64"
development_gui_qemu="$repo_root/build/reims-linux/vendor/qemu/build/qemu-system-aarch64"
headless_qemu="$repo_root/build/experiment-macOS-arm64-on-linux-x86/build/qemu-system-aarch64"
if test -n "${QEMU_BIN:-}"; then
    qemu="$QEMU_BIN"
elif test -x "$gui_qemu"; then
    qemu="$gui_qemu"
elif test -x "$development_gui_qemu"; then
    qemu="$development_gui_qemu"
else
    qemu="$headless_qemu"
fi
guest_dir="${GUEST_DIR:-$repo_root/artifacts/guest}"
booter="${AVPBOOTER:-$HOME/Downloads/AVPBooter.vmapple2.bin}"
ram="${RAM:-8G}"
cpus="${CPUS:-8}"
cpu_model="${CPU_MODEL:-host}"
ssh_port="${SSH_PORT:-2222}"
guest_mac="${GUEST_MAC:-52:54:00:76:61:70}"
log_dir="${LOG_DIR:-$repo_root/logs}"
serial="${SERIAL:-}"
qmp_socket_override="${QMP_SOCKET:-}"
gdb_port="${GDB_PORT:-}"
pause_at_start="${PAUSE_AT_START:-off}"
console="${CONSOLE:-reims}"

# The patched KVM QEMU forwards Apple's private VMApple PAuth HVC range and
# implements it in userspace. Keep the opt-in explicit in QEMU itself while
# making this repository's dedicated launcher select the required contract.
export QEMU_VMAPPLE_KVM_HVC="${QEMU_VMAPPLE_KVM_HVC:-1}"

die() { echo "error: $*" >&2; exit 1; }

"$repo_root/scripts/check-host.sh" >/dev/null
test -f "$booter" || die "AVPBooter not found: $booter"
test -f "$guest_dir/aux.img.trimmed" || die "missing $guest_dir/aux.img.trimmed"
test -f "$guest_dir/disk.img" || die "missing $guest_dir/disk.img"
test -f "$guest_dir/vm.json" || die "missing $guest_dir/vm.json"

ecid="$("$repo_root/scripts/extract-ecid.py" "$guest_dir/vm.json")"
mkdir -p "$log_dir"
stamp="$(date +%Y%m%d-%H%M%S)"
serial_log="$log_dir/serial-$stamp.log"
qmp_socket="${qmp_socket_override:-$log_dir/qmp-$stamp.sock}"
if test -z "$serial"; then
    serial="file:$serial_log"
fi
machine="vmapple,uuid=$ecid,accel=kvm"
display_args=(-display none)
debug_args=()
if test -n "$gdb_port"; then
    [[ "$gdb_port" =~ ^[0-9]+$ ]] || die "GDB_PORT must be numeric"
    debug_args+=(-gdb "tcp::$gdb_port")
fi
if test "$pause_at_start" = on; then
    debug_args+=(-S)
elif test "$pause_at_start" != off; then
    die "PAUSE_AT_START must be on or off"
fi
device_help="$({ "$qemu" -device reims-vgpu-mmio,help 2>&1 || true; })"
if grep -q '^reims-vgpu-mmio options:' <<<"$device_help"; then
    machine+=",gfx-device=reims-vgpu-mmio"
    if test -z "${WAYLAND_DISPLAY:-}" && \
            test -S "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/wayland-0"; then
        export WAYLAND_DISPLAY=wayland-0
    fi
    case "$console" in
        reims|none) ;;
        gtk)
            display_args=(-display gtk,zoom-to-fit=on)
            export GDK_BACKEND=wayland
            ;;
        *) die "CONSOLE must be reims, none, or gtk" ;;
    esac
fi

echo "launching VMApple with KVM (guest ECID loaded from vm.json)"
echo "QEMU: $qemu"
echo "serial: $serial_log"
echo "SSH after guest setup: localhost:$ssh_port"

exec "$qemu" \
    -machine "$machine" \
    -cpu "$cpu_model" \
    -smp "$cpus" \
    -m "$ram" \
    -bios "$booter" \
    -drive "if=pflash,format=raw,file.filename=$guest_dir/aux.img.trimmed,file.locking=off" \
    -drive "if=pflash,format=raw,file.filename=$guest_dir/disk.img,file.locking=off" \
    -drive "if=none,format=raw,file.filename=$guest_dir/aux.img.trimmed,file.locking=off,id=aux" \
    -device vmapple-virtio-blk-pci,variant=aux,drive=aux,share-rw=on \
    -drive "if=none,format=raw,file.filename=$guest_dir/disk.img,file.locking=off,id=root" \
    -device vmapple-virtio-blk-pci,variant=root,drive=root,share-rw=on \
    -netdev "user,id=net0,ipv6=off,hostfwd=tcp::$ssh_port-:22" \
    -device "virtio-net-pci,netdev=net0,mac=$guest_mac" \
    -qmp "unix:$qmp_socket,server=on,wait=off" \
    "${debug_args[@]}" \
    "${display_args[@]}" \
    -serial "$serial" \
    -no-reboot
