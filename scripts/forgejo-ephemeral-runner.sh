#!/usr/bin/env bash
# Serve Forgejo Actions jobs with one throwaway macOS guest per job.
#
#   FORGEJO_URL=https://forgejo.example FORGEJO_TOKEN=<token> FORGEJO_SCOPE=<scope> \
#       scripts/forgejo-ephemeral-runner.sh [slots]
#   FORGEJO_URL=https://forgejo.example FORGEJO_REGISTRATION_TOKEN=<token> \
#       scripts/forgejo-ephemeral-runner.sh [slots]
#
# API mode (FORGEJO_TOKEN): FORGEJO_SCOPE is admin (instance-wide),
# orgs/<org>, repos/<owner>/<repo> or user, and the token needs the matching
# admin/write permission. Each slot registers an *ephemeral* runner through
# the Forgejo API (POST <scope>/actions/runners), boots a guest from GOLDEN
# with scripts/vm-job.sh, and runs `forgejo-runner one-job --wait` there. The
# runner token travels over SSH stdin into a mode-600 file.
#
# Registration-token mode (FORGEJO_REGISTRATION_TOKEN, the token from the
# Actions runner settings page): the guest itself runs `forgejo-runner
# register --ephemeral` and then `one-job --wait`. The registration token
# travels over SSH stdin, is used once and is never written to disk; a
# workflow can still read the guest's .runner file (this one runner's
# credential). A slot stops if registration fails, so a misconfiguration does
# not pile up runners.
#
# Either way the runner takes exactly one job, Forgejo (>= 15) deletes it
# afterwards, and the guest is discarded.
#
# Environment: GOLDEN (needs ~/forgejo-runner and ~/node; default Tahoe v7),
# CPUS, RAM, RUNNER_LABELS (default macos-26-arm64:host,macos:host),
# FORGEJO_RUNNER_URL (instance URL as seen from the guest; default
# FORGEJO_URL; a Forgejo on the VM host itself is http://10.0.2.2:<port>),
# JOB_TIMEOUT (default 10800 s), FORGEJO_CACHE_SERVER + FORGEJO_CACHE_SECRET
# (a persistent `forgejo-runner cache-server` as seen from the guest, e.g.
# http://10.0.2.2:4100/ for one on the VM host; systemd/vmapple-runner-cache.service),
# so actions/cache survives the throwaway guests.
set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Also accept the names of a runner-registration.env as Forgejo admins hand it out.
FORGEJO_URL="${FORGEJO_URL:-${FORGEJO_INSTANCE_URL:-}}"
FORGEJO_REGISTRATION_TOKEN="${FORGEJO_REGISTRATION_TOKEN:-${FORGEJO_RUNNER_REGISTRATION_TOKEN:-}}"
: "${FORGEJO_URL:?set FORGEJO_URL}"
if test -z "${FORGEJO_REGISTRATION_TOKEN:-}"; then
    : "${FORGEJO_TOKEN:?set FORGEJO_TOKEN (API mode) or FORGEJO_REGISTRATION_TOKEN}"
    : "${FORGEJO_SCOPE:?set FORGEJO_SCOPE (admin, orgs/ORG, repos/OWNER/REPO or user)}"
fi
slots="${1:-1}"
labels="${RUNNER_LABELS:-macos-26-arm64:host,macos:host}"
runner_url="${FORGEJO_RUNNER_URL:-$FORGEJO_URL}"
api="${FORGEJO_URL%/}/api/v1/${FORGEJO_SCOPE:-}/actions/runners"
export JOB_TIMEOUT="${JOB_TIMEOUT:-10800}"
cache_server="${FORGEJO_CACHE_SERVER:-}"
cache_secret="${FORGEJO_CACHE_SECRET:-}"
if test -n "$cache_server" && test -z "$cache_secret"; then
    echo "FORGEJO_CACHE_SERVER needs FORGEJO_CACHE_SECRET" >&2; exit 2
fi
# Guest-side snippet: read the cache secret (second stdin line) and, if set,
# write the runner config (with a cache section pointing the job's cache
# proxy at the shared server). Always passed with -c: zsh would not split a $cfg.
guest_cfg="read -r cs; umask 077; { printf 'log:\\n  level: info\\n'; if test -n \"\$cs\"; then printf 'cache:\\n  enabled: true\\n  external_server: %s\\n  secret: %s\\n' $(printf %q "$cache_server") \"\$cs\"; fi; } > ~/.runner-config.yml; unset cs"
# Start CoreSimulatorService and let it load its device sets before taking a
# job: the first xcodebuild after boot otherwise fails with "Unable to find a
# device matching the provided destination specifier" while it is still
# loading (no-op on images without Xcode).
guest_warm="if command -v xcrun >/dev/null && xcrun -f simctl >/dev/null 2>&1; then for i in \$(seq 60); do xcrun simctl list devices available 2>/dev/null | grep -qE '[(](Shutdown|Booted)[)]' && break; sleep 2; done; fi"
export GOLDEN="${GOLDEN:-$HOME/vm-artifacts/tahoe-26.4-25E246-v7}" CPUS="${CPUS:-8}" RAM="${RAM:-16G}"

label_args=""
IFS=',' read -r -a label_list <<<"$labels"
for l in "${label_list[@]}"; do label_args+=" --label $(printf %q "$l")"; done

register() {
    local name="$1"
    curl -sSf -X POST -H "Authorization: token $FORGEJO_TOKEN" -H "Content-Type: application/json" \
        -d "{\"name\":\"$name\",\"description\":\"vmapple ephemeral macOS guest\",\"ephemeral\":true}" "$api"
}

slot() {
    local n="$1" name reply id uuid token
    # Slot N gets its own LAN tap and a stable MAC when NET_TAP_PREFIX is set.
    if test -n "${NET_TAP_PREFIX:-}"; then
        export TAP_IF="${NET_TAP_PREFIX}$n" TAP_MAC="$(printf '52:54:00:76:62:%02x' "$n")"
    fi
    while true; do
        name="vmapple-$(hostname -s)-$n-$(date +%Y%m%d%H%M%S)"
        if test -n "${FORGEJO_REGISTRATION_TOKEN:-}"; then
            echo "[slot $n] $name registering in a fresh guest" >&2
            printf '%s\n' "$FORGEJO_REGISTRATION_TOKEN" "$cache_secret" | "$repo_root/scripts/vm-job.sh" \
                "read -r t; $guest_cfg; $guest_warm; cd ~ && ~/forgejo-runner/forgejo-runner register --no-interactive --ephemeral --instance $(printf %q "$runner_url") --token \"\$t\" --name $name --labels $(printf %q "$labels") >&2 || exit 77; unset t; exec ~/forgejo-runner/forgejo-runner one-job --wait -c \$HOME/.runner-config.yml"
            st=$?
            echo "[slot $n] $name finished with status $st" >&2
            if test "$st" = 77; then
                echo "[slot $n] registration failed (token, URL, or Forgejo < 15); stopping this slot" >&2
                return 1
            fi
            test "$st" = 125 && sleep 30   # guest never booted (after retries)
            continue
        fi
        if ! reply="$(register "$name")"; then
            echo "[slot $n] runner registration failed; retrying in 60 s" >&2
            sleep 60; continue
        fi
        read -r id uuid token < <(python3 -c 'import json,sys; r=json.load(sys.stdin); print(r["id"], r["uuid"], r["token"])' <<<"$reply")
        echo "[slot $n] $name (id $id) waiting for a job" >&2
        printf '%s\n' "$token" "$cache_secret" | "$repo_root/scripts/vm-job.sh" \
            "read -r t; $guest_cfg; $guest_warm; umask 077; printf %s \"\$t\" > ~/.forgejo-runner-token; cd ~ && exec ~/forgejo-runner/forgejo-runner one-job --wait -c \$HOME/.runner-config.yml --url $(printf %q "$runner_url") --uuid $uuid --token-url file://\$HOME/.forgejo-runner-token$label_args"
        echo "[slot $n] $name finished with status $?" >&2
        # Ephemeral runners are removed by Forgejo after their job; remove a
        # registration left behind by a timeout or a guest that never booted.
        curl -s -o /dev/null -X DELETE -H "Authorization: token $FORGEJO_TOKEN" "$api/$id" || true
    done
}

# Stopping the orchestrator stops every slot; each vm-job then shuts its guest down.
trap 'trap - INT TERM; kill -TERM 0 2>/dev/null; wait; exit 130' INT TERM
for n in $(seq 1 "$slots"); do slot "$n" & done
wait
