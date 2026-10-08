#!/usr/bin/env bash
# Boot a golden repeatedly and record, per boot, the time to SSH and whether
# AppleVirtIOSound registered (macOS 26 guests with AUDIO=virtio).
#
#   GOLDEN=~/vm-artifacts/<bundle> scripts/debug/boot-reliability.sh <label> <count>
#
# Results go to artifacts/reliability/<label>/runs.log, one line per boot:
#   <n> <run> ssh=<s>s sndok|SNDFAIL|snd?   or   <n> <run> STALL
# A boot that never answers SSH is kept for BOOT_TIMEOUT seconds, its QEMU log
# and virtio queue state (scripts/debug/vqstate.py) are saved, then it is quit.
# Environment: GOLDEN, QEMU_BIN, CPUS (8), RAM (12G), GFX (none), AUDIO
# (virtio), BOOT_TIMEOUT (90), RUNNER_KEY (~/.ssh/vmapple_runner),
# QEMU_EXTRA_ARGS (e.g. "-trace virtio_snd_* -d guest_errors").
# Touch <outdir>/STOP to end the loop after the current boot.
# vm-run.sh waits for a free macOS instance slot before each boot.
set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
label="${1:?usage: $0 <label> <count>}"
count="${2:?usage: $0 <label> <count>}"
[[ "$label" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "bad label" >&2; exit 2; }
export GOLDEN="${GOLDEN:?set GOLDEN}"
export CPUS="${CPUS:-8}" RAM="${RAM:-12G}" GFX="${GFX:-none}" AUDIO="${AUDIO:-virtio}" INJECT=0
boot_timeout="${BOOT_TIMEOUT:-90}"
key="${RUNNER_KEY:-$HOME/.ssh/vmapple_runner}"
out="$repo_root/artifacts/reliability/$label"
mkdir -p "$out"
cd "$repo_root"

sshq() {
    local port=$1; shift
    timeout 20 ssh -n -i "$key" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=5 \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        -p "$port" aquarat@127.0.0.1 "$@"
}
free_port() {
    python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'
}
qemu_of() {
    local q
    for q in $(pgrep -x qemu-system-aar); do
        tr '\0' ' ' < "/proc/$q/cmdline" 2>/dev/null | grep -q "runs/$1/" && echo "$q"
    done
}
stop_vm() {
    local p
    scripts/vm-run.sh quit "$1" >/dev/null 2>&1
    for _ in $(seq 1 20); do test -z "$(qemu_of "$1")" && return; sleep 1; done
    p=$(qemu_of "$1"); test -n "$p" && kill -9 $p
}

for i in $(seq 1 "$count"); do
    test -e "$out/STOP" && { echo "stopped" >> "$out/runs.log"; break; }
    name="rel-$label-$i-$(date +%H%M%S)"
    port=$(free_port)
    export SSH_PORT=$port
    scripts/vm-run.sh start "$name" >/dev/null || { echo "$i start-failed" >> "$out/runs.log"; continue; }
    run="artifacts/runs/$name"
    t0=$(date +%s.%N); st=; seen=0
    while :; do
        if sshq "$port" true 2>/dev/null; then
            st=$(python3 -c "print(round($(date +%s.%N)-$t0,1))"); break
        fi
        if test -n "$(qemu_of "$name")"; then
            seen=1
        elif (( seen )) || (( $(date +%s) - ${t0%.*} > 30 )); then
            break       # QEMU exited (or never started)
        fi
        (( $(date +%s) - ${t0%.*} > boot_timeout )) && break
        sleep 1
    done
    if test -n "$st"; then
        snd=$(sshq "$port" 'ioreg -rc AppleVirtIOSound -d1 -w0 | head -1' 2>&1)
        case "$snd" in
            *'!registered'*) a=SNDFAIL ;;
            *registered*) a=sndok ;;
            *) a="snd?" ;;
        esac
        echo "$i $name ssh=${st}s $a" >> "$out/runs.log"
        if test "$a" != sndok; then
            mkdir -p "$out/$name"
            python3 scripts/debug/vqstate.py "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/vmapple/$name.qmp" \
                > "$out/$name/vqstate.txt" 2>&1
            cp "$run/logs/launcher.log" "$out/$name/" 2>/dev/null
        fi
    else
        echo "$i $name STALL" >> "$out/runs.log"
        mkdir -p "$out/$name"
        python3 scripts/debug/vqstate.py "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/vmapple/$name.qmp" \
            > "$out/$name/vqstate.txt" 2>&1
        cp -r "$run/logs" "$out/$name/" 2>/dev/null
    fi
    stop_vm "$name"
    rm -rf "$run"
done
echo DONE >> "$out/runs.log"
awk '/ rel-/{n++} / STALL/{s++} /SNDFAIL/{f++} END{printf "boots %d, no SSH %d, sound !registered %d\n", n, s, f}' \
    "$out/runs.log"
