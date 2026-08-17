#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ipsw="${IPSW:-${1:-}}"
guest_dir="${GUEST_DIR:-$repo_root/artifacts/guest}"
disk_size="${DISK_SIZE:-64g}"
cpus="${CPUS:-4}"
ram="${RAM:-8g}"
guest_mac="${GUEST_MAC:-52:54:00:76:61:70}"
known_name="UniversalMac_13.6_22G120_Restore.ipsw"
known_sha1="a1675f2c8412122a5e796981571b0269a966708e"

die() { echo "error: $*" >&2; exit 1; }

test "$(uname -s)" = Darwin || die "run this script from native macOS"
command -v macosvm >/dev/null 2>&1 || die "macosvm is required (brew install macosvm)"
test -n "$ipsw" || die "usage: $0 /path/to/UniversalMac_Restore.ipsw"
test -f "$ipsw" || die "IPSW not found: $ipsw"
test ! -e "$guest_dir/disk.img" || die "refusing to overwrite $guest_dir/disk.img"

if test "$(basename "$ipsw")" = "$known_name"; then
    actual_sha1="$(shasum -a 1 "$ipsw" | awk '{print $1}')"
    test "$actual_sha1" = "$known_sha1" ||
        die "IPSW SHA-1 mismatch: expected $known_sha1, got $actual_sha1"
fi

cat <<EOF
This will restore the supplied $(du -h "$ipsw" | awk '{print $1}') IPSW and
create a $disk_size sparse VM disk under:
  $guest_dir

The restore writes disk.img, aux.img, and vm.json. Continue? [y/N]
EOF
read -r answer
case "$answer" in
    y|Y|yes|YES) ;;
    *) echo "cancelled"; exit 0 ;;
esac

mkdir -p "$guest_dir"
macosvm \
    --disk "$guest_dir/disk.img,size=$disk_size" \
    --aux "$guest_dir/aux.img" \
    --restore "$ipsw" \
    --net nat \
    --mac "$guest_mac" \
    -c "$cpus" \
    -r "$ram" \
    "$guest_dir/vm.json"

test -f "$guest_dir/vm.json" || die "macosvm did not produce vm.json"
dd if="$guest_dir/aux.img" of="$guest_dir/aux.img.trimmed" \
    bs=$((0x4000)) skip=1 status=none

echo "provisioned VMApple bundle: $guest_dir"
echo "copy this artifacts/guest directory back to the Asahi checkout"
