#!/usr/bin/env bash
# Check the host: AArch64, /dev/kvm access, and a QEMU with the vmapple
# machine (QEMU_BIN, else build/qemu-fleet from scripts/build-qemu.sh).
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fleet_qemu="$repo_root/build/qemu-fleet/vendor/qemu/build/qemu-system-aarch64"
gui_qemu="$repo_root/build/reims-linux-product/vendor/qemu/build/qemu-system-aarch64"
development_gui_qemu="$repo_root/build/reims-linux/vendor/qemu/build/qemu-system-aarch64"
headless_qemu="$repo_root/build/experiment-macOS-arm64-on-linux-x86/build/qemu-system-aarch64"
if test -n "${QEMU_BIN:-}"; then
    qemu="$QEMU_BIN"
elif test -x "$fleet_qemu"; then
    qemu="$fleet_qemu"
elif test -x "$gui_qemu"; then
    qemu="$gui_qemu"
elif test -x "$development_gui_qemu"; then
    qemu="$development_gui_qemu"
else
    qemu="$headless_qemu"
fi

test "$(uname -m)" = aarch64 || {
    echo "error: this flow requires an AArch64 host" >&2
    exit 1
}
test -r /dev/kvm && test -w /dev/kvm || {
    echo "error: current user cannot access /dev/kvm" >&2
    exit 1
}
test -x "$qemu" || {
    echo "error: patched QEMU not found at $qemu" >&2
    exit 1
}
"$qemu" -machine help | grep -q '^vmapple '

printf 'architecture: %s\n' "$(uname -m)"
printf 'kernel: %s\n' "$(uname -r)"
printf 'KVM: accessible\n'
printf 'QEMU: %s\n' "$qemu"
printf 'VMApple KVM host check: PASS\n'
