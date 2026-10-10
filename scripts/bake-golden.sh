#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Derive a new golden bundle by running a provisioning command in a guest
# booted from an existing one, then shutting it down cleanly.
#
#   scripts/bake-golden.sh <src-golden-dir> <dst-golden-dir> "<note>" <command...>
#
# The command runs over SSH as the image user (stdin passed through). On
# success the guest is shut down, its disk/AUX/vm.json are reflinked into
# <dst>/guest, made read-only, and a manifest and README note are written.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
src="$1"; dst="$2"; note="$3"; shift 3
key="${RUNNER_KEY:-$HOME/.ssh/vmapple_runner}"
export CPUS="${CPUS:-8}" RAM="${RAM:-16G}" INJECT="${INJECT:-0}"
test -d "$src/guest" || { echo "no $src/guest" >&2; exit 1; }
test ! -e "$dst" || { echo "$dst exists" >&2; exit 1; }

name="bake-$(basename "$dst")-$$"
run="$repo_root/artifacts/runs/$name"
port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
ssh_opts=(-i "$key" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=5
          -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR
          -p "$port" aquarat@127.0.0.1)

# Boot with retries: some macOS 26 boots stall before networking (see
# docs/NOTES.md, early-boot stall). A stalled guest is quit and a fresh clone booted.
booted=0
for attempt in 1 2 3; do
    GOLDEN="$src" SSH_PORT="$port" "$repo_root/scripts/vm-run.sh" start "$name"
    pid="$(cat "$run/launcher.pid")"
    t0=$(date +%s)
    while (( $(date +%s) - t0 < ${BOOT_TIMEOUT:-120} )); do
        if timeout 10 ssh -n "${ssh_opts[@]}" true 2>/dev/null; then booted=1; break; fi
        kill -0 "$pid" 2>/dev/null || break
        sleep 2
    done
    test "$booted" = 1 && break
    echo "boot attempt $attempt did not reach SSH; retrying from a fresh clone" >&2
    "$repo_root/scripts/vm-run.sh" quit "$name" >/dev/null 2>&1 || true
    for _ in $(seq 1 15); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
    kill -TERM -- "-$pid" 2>/dev/null || true
    rm -rf "$run"
done
test "$booted" = 1 || { echo "guest never reached SSH" >&2; exit 1; }
ssh "${ssh_opts[@]}" "$@"
ssh -n "${ssh_opts[@]}" "echo '+ $note' | sudo -n tee -a /etc/vmapple-image-version >/dev/null; sync; sudo -n shutdown -h now" || true
for _ in $(seq 1 90); do kill -0 "$pid" 2>/dev/null || break; sleep 2; done
kill -0 "$pid" 2>/dev/null && { echo "guest did not power off; not promoting" >&2; exit 1; }
grep -aq "ApplePSCI - system off" "$run"/logs/serial-*.log 2>/dev/null ||
    echo "warning: no PSCI system-off line in serial log (normal without -v boot-args)" >&2

mkdir -p "$dst/guest"
for f in disk.img aux.img.trimmed vm.json; do
    cp --reflink=always "$run/$f" "$dst/guest/$f"
done
cp -r "$src/extras" "$dst/" 2>/dev/null || true
{ cat "$src/README.txt" 2>/dev/null; echo "$(date -I) baked from $(basename "$src") via $name: $note"; } > "$dst/README.txt"
(cd "$dst" && sha256sum guest/* > MANIFEST.sha256)
chmod a-w "$dst"/guest/*
rm -rf "$run"
echo "golden: $dst"; cat "$dst/MANIFEST.sha256"
