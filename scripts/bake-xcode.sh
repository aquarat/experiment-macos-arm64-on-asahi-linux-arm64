#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Derive a golden bundle with Xcode installed from a user-supplied .xip.
#
#   scripts/bake-xcode.sh <src-golden> <dst-golden> <Xcode_*.xip> [--ios-platform]
#
# Xcode downloads require an Apple ID, so the .xip must be fetched by the user
# (developer.apple.com/download/all). The guest needs ~3x the .xip size free.
# --ios-platform also runs `xcodebuild -downloadPlatform iOS` (simulator
# runtime). Simulators run without a GPU (GFX=none); apps that draw with Metal
# need the GPU on Honeykrisp for their UI tests (docs/NOTES.md, "Metal").
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
src="$1"; dst="$2"; xip="$3"; ios="${4:-}"
key="${RUNNER_KEY:-$HOME/.ssh/vmapple_runner}"
test -f "$xip" || { echo "no such .xip: $xip" >&2; exit 1; }
case "$(basename "$xip")" in Xcode*.xip) ;; *) echo "expected Xcode*.xip" >&2; exit 1 ;; esac

port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
name="xcode-$$"
GOLDEN="$src" SSH_PORT="$port" CPUS="${CPUS:-8}" RAM="${RAM:-16G}" INJECT="${INJECT:-0}" \
    "$repo_root/scripts/vm-run.sh" start "$name"
ssh_opts=(-i "$key" -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=no
          -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
for _ in $(seq 1 150); do
    timeout 10 ssh -n "${ssh_opts[@]}" -p "$port" aquarat@127.0.0.1 true 2>/dev/null && break
    sleep 2
done
echo "copying $(du -h "$xip" | cut -f1) into the guest"
scp "${ssh_opts[@]}" -P "$port" "$xip" aquarat@127.0.0.1:Xcode.xip
ssh -n "${ssh_opts[@]}" -p "$port" aquarat@127.0.0.1 "$(cat <<EOF
set -e
cd ~ && xip --expand Xcode.xip && rm Xcode.xip
app=\$(ls -d Xcode*.app | head -1)
sudo -n mv "\$app" /Applications/
sudo -n xcode-select -s "/Applications/\$app/Contents/Developer"
sudo -n xcodebuild -license accept
sudo -n xcodebuild -runFirstLaunch
xcodebuild -version
if test -n "$ios"; then
    # CoreSimulatorService takes ~30 s to start the first time; until then
    # -downloadPlatform fails with "Unable to connect to simulator".
    xcrun simctl list runtimes >/dev/null 2>&1 || true
    for try in 1 2 3; do
        xcodebuild -downloadPlatform iOS && break
        test \$try = 3 && exit 1
        sleep 30
    done
fi
xcrun simctl list runtimes || true
echo "+ \$(xcodebuild -version | tr '\n' ' ')" | sudo -n tee -a /etc/vmapple-image-version >/dev/null
sync
sudo -n shutdown -h now
EOF
)" || true
pid="$(cat "$repo_root/artifacts/runs/$name/launcher.pid")"
for _ in $(seq 1 120); do kill -0 "$pid" 2>/dev/null || break; sleep 2; done
kill -0 "$pid" 2>/dev/null && { echo "guest did not power off; not promoting" >&2; exit 1; }
run="$repo_root/artifacts/runs/$name"
mkdir -p "$dst/guest"
for f in disk.img aux.img.trimmed vm.json; do cp --reflink=always "$run/$f" "$dst/guest/$f"; done
cp -r "$src/extras" "$dst/" 2>/dev/null || true
{ cat "$src/README.txt" 2>/dev/null; echo "$(date -I) + Xcode from $(basename "$xip") (sha256 $(sha256sum "$xip" | cut -c1-16)…)"; } > "$dst/README.txt"
(cd "$dst" && sha256sum guest/* > MANIFEST.sha256)
chmod a-w "$dst"/guest/*
rm -rf "$run"
echo "golden: $dst"
