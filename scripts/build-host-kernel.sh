#!/usr/bin/env bash
# Build a Fedora Asahi kernel-16k with the macOS-guest KVM patches, from a
# base kernel SRPM, in a private rpmbuild topdir (the user's ~/rpmbuild is
# never touched).
#
#   scripts/build-host-kernel.sh <base.src.rpm> <buildid> [extra-test-patch...]
#
#   e.g. a host that carries its own out-of-tree patch series (applied first):
#     scripts/build-host-kernel.sh /path/to/kernel-7.1.13-401.asahi.fc44.src.rpm \
#         vmapple2 /path/to/extra-series.patch
#   a machine on the stock Asahi kernel needs no extra patch:
#     scripts/build-host-kernel.sh kernel-7.1.13-402.asahi.fc44.src.rpm vmapple2
#
# The base SRPM must be the one matching the kernel you run (dnf download
# --source kernel-16k-core-$(uname -r | sed 's/+16k//') or the @asahi copr).
# Output: <topdir>/RPMS/aarch64/*.vmapple*.rpm; install with
# scripts/fedora-test-kernel.sh install <dir> <version-release.arch>.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
srpm="$1"; buildid="$2"; shift 2
topdir="${TOPDIR:-$HOME/Projects/vmapple-kernel/rpmbuild-$buildid}"
kvm_patches=(
    "$repo_root/patches/linux-7.1.13-vmapple-pac-vmkey.patch"
    "$repo_root/patches/linux-7.1.13-kvm-nisv-ldst.patch"
)
die() { echo "error: $*" >&2; exit 1; }
test -f "$srpm" || die "no such SRPM: $srpm"
[[ "$buildid" =~ ^[a-z0-9]+$ ]] || die "buildid must be lowercase alphanumeric"
test ! -e "$topdir" || die "$topdir exists"
for p in "$@" "${kvm_patches[@]}"; do test -f "$p" || die "missing patch $p"; done

mkdir -p "$topdir"/{SPECS,SOURCES,BUILD,RPMS,SRPMS}
rpm --define "_topdir $topdir" -i "$srpm"
# Fedora's spec applies SOURCES/linux-kernel-test.patch last (Patch999999).
cat "$@" "${kvm_patches[@]}" > "$topdir/SOURCES/linux-kernel-test.patch"
{
    echo "base_srpm $(sha256sum "$srpm")"
    sha256sum "$@" "${kvm_patches[@]}" "$topdir/SOURCES/linux-kernel-test.patch"
} > "$topdir/INPUTS.sha256"

flags=(--target aarch64 --define "buildid .$buildid" --without up --without debug
       --without debuginfo --without perf --without tools --without libperf
       --without ynl --without selftests --without doc --without bpftool --without efiuki)
echo "prep (patch check) ..."
rpmbuild --define "_topdir $topdir" -bp "${flags[@]}" "$topdir/SPECS/kernel.spec" \
    > "$topdir/prep.log" 2>&1 || die "prep failed; see $topdir/prep.log"
rm -rf "$topdir/BUILD"/*
echo "build ..."
rpmbuild --define "_topdir $topdir" -bb "${flags[@]}" "$topdir/SPECS/kernel.spec" \
    > "$topdir/build.log" 2>&1 || die "build failed; see $topdir/build.log"
ls "$topdir/RPMS/aarch64/" | grep "\.$buildid\."
