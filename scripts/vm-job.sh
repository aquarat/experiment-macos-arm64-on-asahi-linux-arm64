#!/usr/bin/env bash
# Run one command in a throwaway macOS guest and discard the guest afterwards.
#
#   scripts/vm-job.sh <command...>          # runs in the guest via SSH; stdin is passed through
#
# Environment: GOLDEN (bundle dir), CPUS (4), RAM (12G), BOOT_TIMEOUT (90 s),
# JOB_TIMEOUT (3600 s), KEEP=1 to keep the guest's disk after the job,
# RUNNER_KEY (~/.ssh/vmapple_runner), BOOT_RETRIES (2: a guest that never
# reaches SSH is discarded and booted again from a fresh clone),
# KEEP_ON_BOOT_FAIL=1 to leave such a guest running for inspection,
# BALLOON=1 (+ BALLOON_GOVERNOR=0 to skip the governor; tunables in
# scripts/balloon-governor.py). Launcher settings (GFX, VK_DRIVER_FILES, AUDIO,
# TAP_IF, QEMU_BIN, ...) pass through vm-run.sh to scripts/launch-kvm.sh.
# Logs end up in artifacts/job-logs/<job>/.
#
# The guest is a reflink clone of the golden bundle (scripts/vm-run.sh), so a
# job never changes the golden image, and its memory is returned to the host
# when QEMU exits. Exit status: the command's status, or 124 for a job
# timeout, 125 for a guest that never reached SSH.
set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
key="${RUNNER_KEY:-$HOME/.ssh/vmapple_runner}"
boot_timeout="${BOOT_TIMEOUT:-90}"
job_timeout="${JOB_TIMEOUT:-3600}"
export CPUS="${CPUS:-4}" RAM="${RAM:-12G}"
# vmapple2 host kernels emulate the no-syndrome GIC store; no GDB hand-off needed.
export INJECT="${INJECT:-0}"

test $# -gt 0 || { echo "usage: $0 <command...>" >&2; exit 2; }

free_port() {
    python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'
}
export SSH_PORT="$(free_port)" GDB_PORT="$(free_port)"
name="job-$(date +%Y%m%d-%H%M%S)-$$"
run="$repo_root/artifacts/runs/$name"
ssh_opts=(-i "$key" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=5
          -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR
          -p "$SSH_PORT" aquarat@127.0.0.1)
log() { echo "[vm-job $name $(date +%T)] $*" >&2; }

qemu_alive() {
    local pid
    pid="$(cat "$run/launcher.pid" 2>/dev/null)" || return 1
    kill -0 "$pid" 2>/dev/null
}

booted=0
governor_pid=
cleanup() {
    # Finish cleaning up even if more INT/TERM arrive (a service stop signals
    # every process, then the orchestrator signals its group again).
    trap '' INT TERM
    if test -n "$governor_pid"; then
        kill "$governor_pid" 2>/dev/null; wait "$governor_pid" 2>/dev/null; governor_pid=
    fi
    # A guest that never reached SSH cannot be shut down over SSH; skip
    # straight to QMP quit instead of waiting out the SSH and power-off timeouts.
    if qemu_alive && test "$booted" = 1; then
        log "shutting guest down"
        timeout 20 ssh -n "${ssh_opts[@]}" 'sudo -n shutdown -h now' >/dev/null 2>&1
        for _ in $(seq 1 60); do qemu_alive || break; sleep 2; done
    fi
    if qemu_alive; then
        log "guest did not power off; QMP quit"
        "$repo_root/scripts/vm-run.sh" quit "$name" >/dev/null 2>&1
        for _ in $(seq 1 15); do qemu_alive || break; sleep 1; done
    fi
    if qemu_alive; then
        log "QEMU still running; killing launcher group"
        kill -TERM -- "-$(cat "$run/launcher.pid")" 2>/dev/null
        sleep 3
    fi
    if test "${KEEP:-0}" != 1; then
        mkdir -p "$repo_root/artifacts/job-logs"
        mv "$run/logs" "$repo_root/artifacts/job-logs/$name" 2>/dev/null
        cp "$run/env.txt" "$repo_root/artifacts/job-logs/$name/" 2>/dev/null
        rm -rf "$run"
    fi
}
trap cleanup EXIT
trap 'test -n "${job_pid:-}" && kill "$job_pid" 2>/dev/null; exit 130' INT TERM

boot() {
    local t0
    # start may wait for a macOS instance slot (licence limit, see vm-run.sh).
    "$repo_root/scripts/vm-run.sh" start "$name" >/dev/null || return 1
    t0=$(date +%s)
    log "booting (cpus=$CPUS ram=$RAM ssh=127.0.0.1:$SSH_PORT)"
    until timeout 10 ssh -n "${ssh_opts[@]}" true 2>/dev/null; do
        qemu_alive || { log "QEMU exited during boot"; return 1; }
        if (( $(date +%s) - t0 > boot_timeout )); then
            log "no SSH after ${boot_timeout}s"; return 1
        fi
        sleep 2
    done
    booted=1
}

t0=$(date +%s)
attempt=0
until boot; do
    if test "${KEEP_ON_BOOT_FAIL:-0}" = 1; then
        log "leaving $name running for inspection"
        trap - EXIT; exit 125
    fi
    cleanup
    booted=0
    attempt=$((attempt + 1))
    (( attempt <= ${BOOT_RETRIES:-2} )) || exit 125
    name="$name-r$attempt"; run="$repo_root/artifacts/runs/$name"
    log "retrying boot ($attempt) from a fresh clone"
done
t1=$(date +%s)
log "guest ready after $((t1 - t0))s; running job"
# BALLOON=1: size the guest's balloon to its needs while the job runs
# (BALLOON_GOVERNOR=0 to drive it by hand; tunables: balloon-governor.py).
if test "${BALLOON:-0}" = 1 && test "${BALLOON_GOVERNOR:-1}" = 1; then
    "$repo_root/scripts/balloon-governor.py" \
        --qmp "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/vmapple/$name.balloon.qmp" \
        --ssh-port "$SSH_PORT" --key "$key" > "$run/logs/balloon-governor.log" 2>&1 < /dev/null &
    governor_pid=$!
fi
# Background + wait so INT/TERM interrupt a long-running job immediately
# (bash defers traps until a foreground command returns); <&0 keeps stdin.
timeout "$job_timeout" ssh "${ssh_opts[@]}" "$@" <&0 &
job_pid=$!
wait "$job_pid"
status=$?
log "job exit $status after $(( $(date +%s) - t1 ))s"
exit "$status"
