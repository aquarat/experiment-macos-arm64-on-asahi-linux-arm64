#!/usr/bin/env bash
# Prepare a Linux (Fedora Asahi) host to run macOS guests with the
# paravirtual GPU on the real GPU (Honeykrisp).
#
#   scripts/host-gpu-setup.sh            # as the user that runs the VMs (uses sudo)
#
# 1. Transparent huge pages for shared memory (persistent, /etc/tmpfiles.d):
#    with the GPU on, guest RAM is a shared memfd (Reims maps scattered guest
#    pages through it), and shmem THP defaults to "never" on Fedora, so guest
#    RAM would be backed by base pages only. "advise" lets QEMU's
#    MADV_HUGEPAGE on guest RAM take effect (PMD size and 2 MiB mTHP).
# 2. Builds the patched Mesa Asahi Vulkan driver into ~/opt/mesa-honeykrisp
#    (scripts/build-mesa-honeykrisp.sh) and prints the VK_DRIVER_FILES line
#    for hosts/<host>.env. Rerun after Fedora updates Mesa.
# 3. Checks access to the GPU render node.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
die() { echo "error: $*" >&2; exit 1; }

thp=/sys/kernel/mm/transparent_hugepage
conf=/etc/tmpfiles.d/vmapple-shmem-thp.conf
{
    echo "# macOS guests with the GPU: guest RAM is a shared memfd (see $(basename "$0"))"
    echo "w $thp/shmem_enabled - - - - advise"
    test -e "$thp/hugepages-2048kB/shmem_enabled" &&
        echo "w $thp/hugepages-2048kB/shmem_enabled - - - - advise"
} | sudo tee "$conf" >/dev/null
sudo systemd-tmpfiles --create "$conf"
echo "shmem THP: $(cat "$thp/shmem_enabled")"

for n in /dev/dri/renderD*; do
    test -r "$n" && test -w "$n" || die "no access to $n (add $(id -un) to group $(stat -c %G "$n"))"
done

"$repo_root/scripts/build-mesa-honeykrisp.sh" | tail -1
