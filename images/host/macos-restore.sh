#!/usr/bin/env bash
# Step 00: restore a pristine guest bundle with Virtualization.framework.
# Runs on NATIVE macOS (Apple Silicon), from a checkout of this repository:
#
#   images/host/macos-restore.sh tahoe|ventura [WORKDIR]      default WORKDIR: ~/vmwork
#
# 1. builds s-u/macosvm at a pinned commit with patches/macosvm-hwmodel-override.patch
#    (needs the Command Line Tools: xcode-select --install);
# 2. downloads the pinned UniversalMac IPSW from Apple's CDN (resumable) and
#    checks its SHA-1;
# 3. runs scripts/provision-on-macos.sh (macosvm --restore) into
#    WORKDIR/<bundle>/guest, forcing the version-1 hardware model for Tahoe;
# 4. copies this Mac's AVPBooter into WORKDIR/<bundle>/extras and records the
#    host macOS version and the macosvm commit there.
#
# The result is a never-booted bundle (guest/disk.img, aux.img,
# aux.img.trimmed, vm.json). Copy it to the Linux host afterwards (see
# docs/IMAGES.md); vm.json holds the VM's identity, so keep it private.
set -euo pipefail

target="${1:?usage: $0 tahoe|ventura [WORKDIR]}"
work="${2:-$HOME/vmwork}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

MACOSVM_REPO="${MACOSVM_REPO:-https://github.com/s-u/macosvm.git}"
MACOSVM_COMMIT="${MACOSVM_COMMIT:-c21fd7414bab38b0a2474b351b90378bdef98325}"

# Ventura's VZMacHardwareModel descriptor, which Tahoe must be restored with:
# binary plist {DataRepresentationVersion 1, PlatformVersion 2,
# MinimumSupportedOS [13,0,0]}. Generic (identical in every VZ macOS VM of
# this platform), not a machine identity. Tahoe's own default descriptor
# (DataRepresentationVersion 2) fails with
# "VZErrorDomain -9 … Failed to get current host key".
HWMODEL_V1_B64="YnBsaXN0MDDTAQIDBAUGXxAZRGF0YVJlcHJlc2VudGF0aW9uVmVyc2lvbl8QD1BsYXRmb3JtVmVyc2lvbl8QEk1pbmltdW1TdXBwb3J0ZWRPUxABEAKjBwgIEA0QAAgPKz1SVFZaXAAAAAAAAAEBAAAAAAAAAAkAAAAAAAAAAAAAAAAAAABe"

case "$target" in
tahoe)
    IPSW_NAME=UniversalMac_26.4_25E246_Restore.ipsw
    IPSW_URL=https://updates.cdn-apple.com/2026WinterFCS/fullrestores/122-00766/062A6121-2ABE-45D7-BCB1-72B666B6D2C2/UniversalMac_26.4_25E246_Restore.ipsw
    IPSW_SHA1=177baf85518c6e9cebf83990e11e59259b5c97dd
    BUNDLE=tahoe-26.4-25E246-restore
    DISK_SIZE=160g CPUS=8 RAM=16g GUEST_MAC=52:54:00:76:61:71
    hwmodel="$HWMODEL_V1_B64"
    ;;
ventura)
    IPSW_NAME=UniversalMac_13.6_22G120_Restore.ipsw
    IPSW_URL=https://updates.cdn-apple.com/2023FallFCS/fullrestores/042-55833/C0830847-A2F8-458F-B680-967991820931/UniversalMac_13.6_22G120_Restore.ipsw
    IPSW_SHA1=a1675f2c8412122a5e796981571b0269a966708e
    BUNDLE=ventura-13.6-22G120-restore
    DISK_SIZE=64g CPUS=4 RAM=8g GUEST_MAC=52:54:00:76:61:70
    hwmodel=""          # Ventura's default descriptor is already version 1
    ;;
*) echo "usage: $0 tahoe|ventura [WORKDIR]" >&2; exit 2 ;;
esac

die() { echo "error: $*" >&2; exit 1; }
test "$(uname -s)" = Darwin || die "run this on native macOS"
test "$(uname -m)" = arm64 || die "needs Apple Silicon"
mkdir -p "$work/src" "$work/ipsw"

# 1. macosvm with the hardware-model override.
mv_src="$work/src/macosvm"
mv_bin="$mv_src/macosvm/macosvm"
if ! test -x "$mv_bin"; then
    test -d "$mv_src/.git" || git clone -q "$MACOSVM_REPO" "$mv_src"
    git -C "$mv_src" checkout -q "$MACOSVM_COMMIT"
    git -C "$mv_src" apply "$repo_root/patches/macosvm-hwmodel-override.patch"
    # The Makefile ad-hoc signs with com.apple.security.virtualization; enough.
    make -C "$mv_src"
fi
test -x "$mv_bin" || die "macosvm build failed"

# 2. IPSW (12 GB Ventura, ~18 GB Tahoe), resumable.
ipsw="$work/ipsw/$IPSW_NAME"
if test "$(shasum -a 1 "$ipsw" 2>/dev/null | cut -d' ' -f1)" != "$IPSW_SHA1"; then
    curl --fail --location --continue-at - --output "$ipsw" "$IPSW_URL"
    sum="$(shasum -a 1 "$ipsw" | cut -d' ' -f1)"
    test "$sum" = "$IPSW_SHA1" || die "IPSW SHA-1 $sum, expected $IPSW_SHA1"
fi

# 3. Restore (provision-on-macos.sh asks for confirmation; answer it).
bundle="$work/$BUNDLE"
test ! -e "$bundle/guest/disk.img" || die "$bundle/guest/disk.img exists"
echo y | PATH="$(dirname "$mv_bin"):$PATH" MACOSVM_HWMODEL_B64="$hwmodel" \
    GUEST_DIR="$bundle/guest" DISK_SIZE="$DISK_SIZE" CPUS="$CPUS" RAM="$RAM" GUEST_MAC="$GUEST_MAC" \
    "$repo_root/scripts/provision-on-macos.sh" "$ipsw"

# 4. Firmware and provenance next to the guest.
mkdir -p "$bundle/extras"
booter=/System/Library/Frameworks/Virtualization.framework/Resources/AVPBooter.vmapple2.bin
ver="$(strings "$booter" | grep -m1 -o 'mBoot-[0-9.]*' || echo unknown)"
cp "$booter" "$bundle/extras/AVPBooter.vmapple2.$ver.bin"
sw_vers > "$bundle/extras/host-sw_vers.txt"
git -C "$mv_src" rev-parse HEAD > "$bundle/extras/macosvm-commit.txt"
(cd "$bundle" && shasum -a 256 guest/* extras/* > MANIFEST.sha256)
echo "$(date -u +%F) restored $IPSW_NAME (SHA-1 $IPSW_SHA1) with macosvm ${MACOSVM_COMMIT:0:7}${hwmodel:+, hardware model v1 forced}, disk $DISK_SIZE" \
    > "$bundle/README.txt"
echo "pristine bundle: $bundle (AVPBooter $ver)"
cat "$bundle/MANIFEST.sha256"
