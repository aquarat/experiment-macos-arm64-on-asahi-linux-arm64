#!/usr/bin/env bash
# Build a private copy of Mesa's Asahi Vulkan driver (Honeykrisp) with the
# patches in patches/mesa/, for QEMU's Reims GPU to render on the real GPU.
# The system Mesa is not touched; guests use it through VK_DRIVER_FILES.
#
#   scripts/build-mesa-honeykrisp.sh [PREFIX]     default PREFIX: ~/opt/mesa-honeykrisp
#
# Builds the Mesa release that matches the host's mesa-vulkan-drivers package
# (MESA_REF overrides, e.g. mesa-26.1.8), so the kernel UAPI and system
# libraries line up. Rerun after Fedora updates Mesa.
# Prints the VK_DRIVER_FILES value to use (PREFIX/share/vulkan/icd.d/...).
# Needs Mesa's build dependencies: sudo dnf builddep mesa
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
prefix="${1:-$HOME/opt/mesa-honeykrisp}"
src="${MESA_SRC:-$HOME/src/mesa-honeykrisp}"
die() { echo "error: $*" >&2; exit 1; }

ref="${MESA_REF:-}"
if test -z "$ref"; then
    v="$(rpm -q --qf '%{VERSION}' mesa-vulkan-drivers 2>/dev/null)" || die "set MESA_REF"
    ref="mesa-$v"
fi

if test -d "$src/.git"; then
    git -C "$src" fetch -q --depth 1 origin tag "$ref"
    git -C "$src" checkout -q -f "$ref"
    git -C "$src" clean -q -fdx -e build
else
    git -c advice.detachedHead=false clone -q --depth 1 --branch "$ref" https://gitlab.freedesktop.org/mesa/mesa.git "$src"
fi
for p in "$repo_root"/patches/mesa/*.patch; do
    git -C "$src" apply --index "$p" || die "patch does not apply: $(basename "$p")"
done

cd "$src"
if ! test -f build/build.ninja; then
    meson setup build --prefix="$prefix" --buildtype=release -Db_ndebug=true \
        -Dvulkan-drivers=asahi -Dgallium-drivers= -Dplatforms= -Dglx=disabled \
        -Degl=disabled -Dgbm=disabled -Dopengl=false -Dgles1=disabled \
        -Dgles2=disabled -Dllvm=enabled -Dvideo-codecs= -Dtools= \
        > meson-setup.log 2>&1 || { tail -30 meson-setup.log; die "meson setup failed"; }
else
    meson configure build --prefix="$prefix" >/dev/null
fi
ninja -C build > build.log 2>&1 || { grep -E "error|FAILED" build.log | head -20; die "build failed (see $src/build.log)"; }
ninja -C build install > install.log 2>&1 || { tail -20 install.log; die "install failed"; }

icd="$(ls "$prefix"/share/vulkan/icd.d/asahi_icd.*.json)"
{
    echo "mesa     $ref ($(git -C "$src" rev-parse --short HEAD))"
    echo "patches  $(cd "$repo_root/patches/mesa" && ls *.patch | tr '\n' ' ')"
    echo "built    $(date -Is) on $(hostname -s)"
} | tee "$prefix/BUILD-MANIFEST"
echo "VK_DRIVER_FILES=$icd"
