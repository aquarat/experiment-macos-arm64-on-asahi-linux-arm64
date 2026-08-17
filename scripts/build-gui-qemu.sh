#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
reims_repo="${REIMS_VGPU_REPO:-$repo_root/../reims-vgpu}"
output_dir="${OUTPUT_DIR:-$repo_root/build/reims-linux-product}"
expected_reims="2844274c34baa1043d37995f5b1a9f1d265eae03"
expected_qemu="e17ddb98f71df5697daf2f830587f672a8f4f5a7"

die() { echo "error: $*" >&2; exit 1; }

for command in git cargo cc ninja; do
    command -v "$command" >/dev/null 2>&1 || die "missing command: $command"
done
test -d "$reims_repo/.git" || die "reims-vgpu checkout not found: $reims_repo"
test "$(git -C "$reims_repo" rev-parse HEAD)" = "$expected_reims" ||
    die "reims-vgpu must be at pinned commit $expected_reims"
test "$(git -C "$reims_repo/vendor/qemu" rev-parse HEAD)" = "$expected_qemu" ||
    die "QEMU submodule must be at pinned commit $expected_qemu"
test ! -e "$output_dir" || die "refusing to overwrite existing $output_dir"

cat <<EOF
This builds the experimental VMApple Vulkan/KVM QEMU under:
  $output_dir

The build copies source and may consume several GiB. Continue? [y/N]
EOF
if test "${CONFIRM:-0}" != 1; then
    read -r answer
    case "$answer" in
        y|Y|yes|YES) ;;
        *) echo "cancelled"; exit 0 ;;
    esac
fi

git clone --no-checkout "$reims_repo" "$output_dir"
git -C "$output_dir" checkout "$expected_reims"
git -C "$output_dir" submodule update --init vendor/qemu
git -C "$output_dir" apply "$repo_root/patches/reims-rust-linux-arm64.patch"
git -C "$output_dir/vendor/qemu" apply \
    "$repo_root/patches/reims-qemu-linux-arm64.patch"

(
    cd "$output_dir/vendor/qemu"
    ./configure \
        --target-list=aarch64-softmmu \
        --enable-kvm \
        --enable-gtk \
        --disable-docs \
        --disable-tools \
        -Dreims_vgpu_backend=vulkan \
        > configure-linux-aarch64.log 2>&1
    ninja -C build qemu-system-aarch64 > build-linux-aarch64.log 2>&1
)

qemu="$output_dir/vendor/qemu/build/qemu-system-aarch64"
test -x "$qemu" || die "build completed without $qemu"
"$qemu" -device reims-vgpu-mmio,help >/dev/null
echo "VMApple Vulkan/KVM QEMU built: $qemu"
