#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${QEMU_27ON86_GDB_PORT:?set QEMU_27ON86_GDB_PORT}"
: "${QEMU_27ON86_XNU_BOOT_ARGS:?set QEMU_27ON86_XNU_BOOT_ARGS}"
: "${QEMU_27ON86_QMP_SOCKET:?set QEMU_27ON86_QMP_SOCKET}"
export VMAPPLE_INJECT_SCRIPT_DIR="$script_dir"
exec "${GDB_BIN:-gdb}" -nx -q -batch -x "$script_dir/inject-xnu-kvm.gdb"

