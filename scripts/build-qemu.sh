#!/usr/bin/env bash
# Build qemu-system-aarch64 (vmapple + KVM + Reims GPU) from the aquarat
# forks; no patch files are applied.
#
#   scripts/build-qemu.sh [OUTDIR]          default OUTDIR: build/qemu-fleet
#
# Environment: REIMS_URL (default https://github.com/aquarat/reims-vgpu.git),
# REIMS_REF (default master), QEMU_URL (override the vendor/qemu source,
# e.g. a local repository with unpushed commits). The QEMU source is Reims' vendor/qemu submodule,
# i.e. aquarat/qemu-reims-vgpu at the commit Reims pins. An existing OUTDIR is
# updated in place (fetch, checkout, incremental build).
# Needs: git cargo ninja meson gcc, and the -devel packages listed in
# docs/NOTES.md (glib2 pixman gtk3 vulkan-loader libslirp libfdt gnutls nettle ...).
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="${1:-$repo_root/build/qemu-fleet}"
url="${REIMS_URL:-https://github.com/aquarat/reims-vgpu.git}"
ref="${REIMS_REF:-master}"
die() { echo "error: $*" >&2; exit 1; }
for c in git cargo ninja meson cc; do command -v "$c" >/dev/null || die "missing $c"; done

# Fetch the ref in both cases: `checkout --detach <branch>` on a fresh clone
# fails for any branch but the default (git tries to create a tracking branch).
test -d "$out/.git" || git clone -q "$url" "$out"
git -C "$out" fetch -q "$url" "$ref"
git -C "$out" checkout -q --detach FETCH_HEAD
if test -n "${QEMU_URL:-}"; then
    # Build unpushed QEMU commits (e.g. from scripts/sync-upstream.sh).
    git -C "$out" submodule init -q vendor/qemu
    git -C "$out" config submodule.vendor/qemu.url "$QEMU_URL"
else
    git -C "$out" submodule sync -q vendor/qemu
fi
git -C "$out" submodule update -q --init vendor/qemu

q="$out/vendor/qemu"
(
    cd "$q"
    if ! test -f build/build.ninja; then
        ./configure --target-list=aarch64-softmmu --enable-kvm --enable-gnutls \
            --enable-gtk --disable-docs --disable-tools -Dreims_vgpu_backend=vulkan \
            > configure.log 2>&1 || { tail -20 configure.log; die "configure failed"; }
    fi
    ninja -C build qemu-system-aarch64 pc-bios/keymaps/en-us > build.log 2>&1 ||
        { grep -E "error|FAILED" build.log | head -20; die "build failed (see $q/build.log)"; }
)
bin="$q/build/qemu-system-aarch64"
{
    echo "reims    $url $(git -C "$out" rev-parse HEAD)"
    echo "qemu     $(git -C "$q" remote get-url origin) $(git -C "$q" rev-parse HEAD)"
    echo "binary   $(sha256sum "$bin" | cut -d' ' -f1)"
    echo "built    $(date -Is) on $(hostname -s)"
} | tee "$out/BUILD-MANIFEST"
echo "QEMU_BIN=$bin"
