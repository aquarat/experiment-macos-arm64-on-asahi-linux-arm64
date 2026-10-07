#!/usr/bin/env bash
# Step 05 (macOS 26): create the guest account without a GUI, from a KVM
# single-user boot driven over the serial console, and promote the result.
# Runs on the Linux host:
#
#   GUEST_PASSWORD=… images/host/create-account.sh <pristine-bundle> <dst-bundle> <authorized_keys>
#
# Why: a fresh macOS 26 restore has keystore-encrypted System and Data volumes,
# so the Data volume cannot be pre-seeded offline from macOS
# (scripts/macos-preseed-guest.sh only works for unencrypted guests), and
# `dscl -f … localonly` fails in single-user mode (eDSUnknownNodeName).
#
# Environment: GUEST_USER (default aquarat, the account the other scripts in
# scripts/ log in as), GUEST_PASSWORD (required; typed over the serial console
# and scrubbed from the console log; no single quotes), CPUS (4), RAM (12G),
# PROMPT_TIMEOUT (240 s). <authorized_keys> must contain the runner key that
# scripts/bake-golden.sh and scripts/vm-job.sh use (RUNNER_KEY, default
# ~/.ssh/vmapple_runner) plus any operator keys.
#
# Needs a host where scripts/vm-run.sh works and gdb is installed: the
# single-user boot-args are injected through the GDB hand-off (INJECT=1).
set -euo pipefail

src="${1:?usage: $0 <pristine-bundle> <dst-bundle> <authorized_keys>}"
dst="${2:?dst bundle}"; keys="${3:?authorized_keys file}"
user="${GUEST_USER:-aquarat}"
pw="${GUEST_PASSWORD:?set GUEST_PASSWORD}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
die() { echo "error: $*" >&2; exit 1; }

test -d "$src/guest" || die "no $src/guest"
test ! -e "$dst" || die "$dst exists"
test -s "$keys" || die "no keys in $keys"
[[ "$user" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "bad GUEST_USER"
case "$pw" in *"'"*|*$'\n'*) die "GUEST_PASSWORD must not contain ' or newlines" ;; esac
! grep -q "'" "$keys" || die "authorized_keys must not contain single quotes"
command -v gdb >/dev/null || die "gdb is required (boot-args injection)"

free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'; }
name="account-$(basename "$dst")-$$"
run="$repo_root/artifacts/runs/$name"
sock_dir="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/vmapple"
sock="$sock_dir/$name.ser"
console_log="$run/logs/serial-console.log"
shell_py="$repo_root/scripts/serial-shell.py"
mkdir -p "$sock_dir"

GOLDEN="$src" INJECT=1 GDB_PORT="$(free_port)" SSH_PORT="$(free_port)" \
CPUS="${CPUS:-4}" RAM="${RAM:-12G}" \
XNU_BOOT_ARGS="-s -v serial=11 debug=0x14c" SERIAL="chardev:ser0" \
QEMU_EXTRA_ARGS="-chardev socket,id=ser0,path=$sock,server=on,wait=off,logfile=$console_log" \
    "$repo_root/scripts/vm-run.sh" start "$name"
pid="$(cat "$run/launcher.pid")"

# The password is typed on the console, so the console log echoes it: overwrite
# it in place with as many X (same length, so QEMU's write offset stays valid).
scrub_log() {
    test -f "$console_log" || return 0
    python3 -I - "$console_log" "$pw" <<'PY'
import sys
path, secret = sys.argv[1], sys.argv[2].encode()
with open(path, "r+b") as f:
    data = f.read()
    if secret in data:
        f.seek(0); f.write(data.replace(secret, b"X" * len(secret)))
PY
}
done_ok=0
on_exit() {
    scrub_log
    test "$done_ok" = 1 && return
    echo "failed; the guest may still be running for inspection: $run" >&2
    echo "  stop it: scripts/vm-run.sh quit $name; then rm -rf $run" >&2
}
trap on_exit EXIT

for _ in $(seq 1 60); do test -S "$sock" && break; sleep 1; done
test -S "$sock" || die "serial socket $sock did not appear"
echo "waiting for the single-user shell (1-3 min)"
"$shell_py" "$sock" wait '(root#|sh-[0-9.]+#|# $)' "${PROMPT_TIMEOUT:-240}" > /dev/null ||
    die "no single-user prompt; see $console_log"

# Run one console command; fail unless it printed exit status 0.
con() {
    local out rc
    out="$(timeout $(( ${2:-60} + 20 )) "$shell_py" "$sock" run "$1" "${2:-60}" 2>&1)" ||
        die "no completion marker for: ${1:0:60}…"
    rc="$(grep -aoE '__DONE_[0-9]+__[0-9]+' <<<"$out" | tail -1 | sed 's/.*__//')"
    grep -av -E 'triggered unnest|failed lookup|^\s*$|__DONE_' <<<"$out" | tail -5 || true
    test "$rc" = 0 || die "exit $rc: ${1:0:60}…"
}

R=/System/Library/Filesystems/apfs.fs/Contents/Resources
P=/private/var/db/com.apple.xpc.launchd/disabled.plist
# Unlock and mount the (keystore-encrypted) Data volume.
con "$R/apfs_boot_util 1; $R/apfs_boot_util 2; test -d /private/var/db/dslocal/nodes/Default" 120
# Directory services: start opendirectoryd, then use the local node.
con "launchctl bootstrap system /System/Library/LaunchDaemons/com.apple.opendirectoryd.plist; sleep 3; launchctl list | grep -q opendirectoryd" 60
con "dscl . -create /Users/$user && dscl . -create /Users/$user UniqueID 501 && dscl . -create /Users/$user PrimaryGroupID 20 && dscl . -create /Users/$user UserShell /bin/zsh && dscl . -create /Users/$user RealName $user && dscl . -create /Users/$user NFSHomeDirectory /Users/$user && dseditgroup -o edit -a $user -t user admin && dscl . -read /Users/$user UniqueID PrimaryGroupID" 90
# Password: not echoed here; scrub_log removes it from the console log.
timeout 80 "$shell_py" "$sock" run "dscl . -passwd /Users/$user '$pw'" 60 > /dev/null 2>&1 ||
    die "setting the password did not complete"
scrub_log
con "dscl . -read /Users/$user AuthenticationAuthority > /dev/null" 30
# Home, SSH keys (one printf argument per key line).
key_args="$(grep -v -E '^\s*(#|$)' "$keys" | sed "s/.*/'&'/" | tr '\n' ' ')"
con "mkdir -p /Users/$user/.ssh && printf '%s\n' $key_args > /Users/$user/.ssh/authorized_keys && chmod 700 /Users/$user/.ssh && chmod 600 /Users/$user/.ssh/authorized_keys && chown -R 501:20 /Users/$user" 30
# Skip Setup Assistant, passwordless sudo, image record.
con "touch /private/var/db/.AppleSetupDone && echo '$user ALL=(ALL) NOPASSWD: ALL' > /private/etc/sudoers.d/$user && chmod 440 /private/etc/sudoers.d/$user && echo 'baked $(basename "$dst") under KVM single-user: account $user, sshd, $(grep -c -v -E '^\s*(#|$)' "$keys") authorized key(s)' > /private/etc/vmapple-image-version" 30
# Enable sshd (Remote Login) in launchd's override database.
con "/usr/libexec/PlistBuddy -c 'Delete :com.openssh.sshd' $P 2>/dev/null; /usr/libexec/PlistBuddy -c 'Add :com.openssh.sshd bool false' $P && /usr/libexec/PlistBuddy -c 'Print :com.openssh.sshd' $P" 30
con "sync" 30
# QEMU runs with -no-reboot, so `reboot` ends the VM.
timeout 20 "$shell_py" "$sock" run "sync; reboot" 10 > /dev/null 2>&1 || true
for _ in $(seq 1 60); do kill -0 "$pid" 2>/dev/null || break; sleep 2; done
kill -0 "$pid" 2>/dev/null && die "QEMU did not exit after reboot"
scrub_log

mkdir -p "$dst/guest"
for f in disk.img aux.img.trimmed vm.json; do cp --reflink=always "$run/$f" "$dst/guest/$f"; done
cp -r "$src/extras" "$dst/" 2>/dev/null || true
{ cat "$src/README.txt" 2>/dev/null || true
  echo "$(date -I) from $(basename "$src") via $name: account $user (admin, NOPASSWD sudo) created in KVM single-user mode; sshd enabled; authorized keys; AppleSetupDone"
} > "$dst/README.txt"
(cd "$dst" && sha256sum guest/* > MANIFEST.sha256)
chmod a-w "$dst"/guest/*
done_ok=1
rm -rf "$run"
echo "account bundle: $dst"
echo "next: scripts/bake-golden.sh $dst <v1> \"headless settings, CLT …\" \"bash -s\" < images/10-headless-clt.sh"
