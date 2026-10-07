#!/bin/bash
# Pre-seed a freshly restored (never booted) macOS guest disk so it boots
# straight to a usable SSH account without Setup Assistant.
# Run on the macOS host as root, with the VM stopped:
#
#   sudo scripts/macos-preseed-guest.sh <disk.img> <user> <password> <authorized_keys file>
#
# Writes only into the guest's Data volume: a local admin user (dslocal via
# `dscl -f`), its home and ~/.ssh/authorized_keys, /var/db/.AppleSetupDone,
# sshd enabled in launchd's disabled.plist, and a NOPASSWD sudoers drop-in.
set -euo pipefail

img="$1"; user="$2"; password="$3"; keys="$4"
test "$(id -u)" = 0 || { echo "run as root" >&2; exit 1; }
test -f "$img" && test -f "$keys"

attach="$(hdiutil attach -imagekey diskimage-class=CRawDiskImage -owners on "$img")"
echo "$attach"
dev="$(awk 'NR==1{print $1}' <<<"$attach")"
trap 'hdiutil detach "$dev" -force >/dev/null 2>&1 || true' EXIT

# A fresh restore's Data volume is not auto-mounted: mount each APFS volume
# from this attach, then pick the one holding private/var/db.
data=""
for d in $(awk '/41504653-0000-11AA-AA11-0030654/ {print $1}' <<<"$attach"); do
    m="$(diskutil info "$d" | sed -n 's/^ *Mount Point: *//p')"
    if test -z "$m"; then
        diskutil mount "$d" >/dev/null 2>&1 || continue
        m="$(diskutil info "$d" | sed -n 's/^ *Mount Point: *//p')"
    fi
    if test -n "$m" && test -d "$m/private/var/db"; then data="$m"; fi
done
test -n "$data" || { echo "no Data volume mounted" >&2; exit 1; }
echo "data volume: $data"

node="$data/private/var/db/dslocal/nodes/Default"
test -d "$node" || { echo "no dslocal node at $node" >&2; ls "$data/private/var/db" >&2; exit 1; }
u="/Local/Target/Users/$user"
dscl -f "$node" localonly -create "$u"
dscl -f "$node" localonly -create "$u" UniqueID 501
dscl -f "$node" localonly -create "$u" PrimaryGroupID 20
dscl -f "$node" localonly -create "$u" UserShell /bin/zsh
dscl -f "$node" localonly -create "$u" RealName "$user"
dscl -f "$node" localonly -create "$u" NFSHomeDirectory "/Users/$user"
dscl -f "$node" localonly -passwd "$u" "$password"
dscl -f "$node" localonly -append /Local/Target/Groups/admin GroupMembership "$user"
dscl -f "$node" localonly -read "$u" UniqueID PrimaryGroupID NFSHomeDirectory

home="$data/Users/$user"
mkdir -p "$home/.ssh"
install -m 600 "$keys" "$home/.ssh/authorized_keys"
chmod 700 "$home/.ssh"
chown -R 501:20 "$home"

touch "$data/private/var/db/.AppleSetupDone"
defaults write "$data/private/var/db/com.apple.xpc.launchd/disabled.plist" com.openssh.sshd -bool false
mkdir -p "$data/private/etc/sudoers.d"
echo "$user ALL=(ALL) NOPASSWD: ALL" > "$data/private/etc/sudoers.d/$user"
chmod 440 "$data/private/etc/sudoers.d/$user"
echo "preseed done for $user on $data"
