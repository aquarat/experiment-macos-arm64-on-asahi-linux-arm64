#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
injector="${XNU_INJECTOR:-$repo_root/scripts/inject-xnu-kvm.sh}"
gdb_port="${GDB_PORT:-1234}"
log_dir="${LOG_DIR:-$repo_root/logs}"
qmp_socket="${QMP_SOCKET:-$log_dir/qmp-gui.sock}"
boot_args="${XNU_BOOT_ARGS:--v serial=11 debug=0x14c}"
qemu_pid=

die() { echo "error: $*" >&2; exit 1; }

command -v gdb >/dev/null 2>&1 || die "missing command: gdb"
test -x "$injector" || die "missing XNU injector: $injector"
[[ "$gdb_port" =~ ^[0-9]+$ ]] || die "GDB_PORT must be numeric"
mkdir -p "$log_dir"
test ! -e "$qmp_socket" || unlink "$qmp_socket"

stop_vm()
{
    if test -n "$qemu_pid" && kill -0 "$qemu_pid" 2>/dev/null; then
        kill -INT "$qemu_pid"
        wait "$qemu_pid" 2>/dev/null || true
    fi
}
trap stop_vm EXIT HUP INT TERM

PAUSE_AT_START=on GDB_PORT="$gdb_port" QMP_SOCKET="$qmp_socket" \
    LOG_DIR="$log_dir" "$repo_root/scripts/launch-kvm.sh" &
qemu_pid=$!

for _ in $(seq 1 300); do
    kill -0 "$qemu_pid" 2>/dev/null || die "QEMU exited before opening QMP"
    test -S "$qmp_socket" && break
    sleep 0.1
done
test -S "$qmp_socket" || die "QMP socket did not appear: $qmp_socket"

QEMU_27ON86_GDB_PORT="$gdb_port" \
QEMU_27ON86_XNU_BOOT_ARGS="$boot_args" \
QEMU_27ON86_CSR_CONFIG="${CSR_CONFIG:-0x2}" \
QEMU_27ON86_KVM_MMIO_PATCH=1 \
QEMU_27ON86_QMP_SOCKET="$qmp_socket" \
    "$injector"

set +e
wait "$qemu_pid"
vm_status=$?
set -e
qemu_pid=
exit "$vm_status"
