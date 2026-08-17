#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
qemu="${QEMU_BIN:-$repo_root/build/experiment-macOS-arm64-on-linux-x86/build/qemu-system-aarch64}"
booter="${AVPBOOTER:-$HOME/Downloads/AVPBooter.vmapple2.bin}"
state_dir="${DFU_STATE_DIR:-$repo_root/artifacts/dfu}"
usb_socket="${USB_SOCKET:-$state_dir/vmapple-usb.sock}"
no_reboot="${NO_REBOOT:-on}"

die() { echo "error: $*" >&2; exit 1; }

"$repo_root/scripts/check-host.sh" >/dev/null
test -x "$qemu" || die "patched QEMU not found: $qemu"
test -f "$booter" || die "AVPBooter not found: $booter"
test ! -e "$usb_socket" || die "remove stale socket first: $usb_socket"
case "$no_reboot" in
    on) reboot_args=(-no-reboot) ;;
    off) reboot_args=() ;;
    *) die "NO_REBOOT must be 'on' or 'off'" ;;
esac

mkdir -p "$state_dir"
for disk in aux root; do
    if test ! -f "$state_dir/$disk.raw"; then
        truncate -s 16K "$state_dir/$disk.raw"
    fi
done

echo "starting AVPBooter DFU mode with KVM"
echo "USB transport: $usb_socket"

trace_args=()
if test -n "${QEMU_TRACE_FILE:-}"; then
    trace_parent="$(dirname "$QEMU_TRACE_FILE")"
    test -d "$trace_parent" || die "trace directory not found: $trace_parent"
    trace_args=(-trace "enable=bdif_usb*,file=$QEMU_TRACE_FILE")
    echo "BDIF trace: $QEMU_TRACE_FILE"
fi

exec "$qemu" \
    -machine "vmapple,uuid=1,accel=kvm,run-installer=on" \
    -cpu host \
    -smp "${CPUS:-4}" \
    -m "${RAM:-4G}" \
    -bios "$booter" \
    -drive "file=$state_dir/aux.raw,if=pflash,format=raw" \
    -drive "file=$state_dir/root.raw,if=pflash,format=raw" \
    -drive "file=$state_dir/aux.raw,if=none,id=aux,format=raw" \
    -drive "file=$state_dir/root.raw,if=none,id=root,format=raw" \
    -device vmapple-virtio-blk-pci,variant=aux,drive=aux \
    -device vmapple-virtio-blk-pci,variant=root,drive=root \
    -chardev "socket,id=vusb,path=$usb_socket,server=on,wait=off" \
    -global vmapple-bdif.usbdev=vusb \
    "${trace_args[@]}" \
    -display none \
    -serial mon:stdio \
    "${reboot_args[@]}"
