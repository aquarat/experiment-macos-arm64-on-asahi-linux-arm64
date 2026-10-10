#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Serve GitHub Actions jobs with one throwaway macOS guest per job.
#
#   GH_TOKEN=<token> GH_SCOPE=repos/<owner>/<repo> scripts/gha-ephemeral-runner.sh [slots]
#   GH_SCOPE=orgs/<org> also works (token needs org self-hosted runner admin).
#
# Each slot loops: ask GitHub for a just-in-time runner configuration, boot a
# guest from GOLDEN with scripts/vm-job.sh, run the baked-in actions-runner
# with that configuration (it takes exactly one job, then exits), discard the
# guest. The JIT configuration travels over SSH stdin, never on a command line.
#
# Environment: GOLDEN (needs ~/actions-runner in the image), CPUS, RAM,
# RUNNER_LABELS (default macOS,ARM64,vmapple), RUNNER_GROUP_ID (default 1),
# JOB_TIMEOUT (default 10800 s).
set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${GH_TOKEN:?set GH_TOKEN}" "${GH_SCOPE:?set GH_SCOPE (repos/OWNER/REPO or orgs/ORG)}"
slots="${1:-1}"
labels="${RUNNER_LABELS:-macOS,ARM64,vmapple}"
export JOB_TIMEOUT="${JOB_TIMEOUT:-10800}"
export GOLDEN="${GOLDEN:-$HOME/vm-artifacts/tahoe-26.4-25E246-v7}" CPUS="${CPUS:-8}" RAM="${RAM:-16G}"

jit_config() {
    local name="$1"
    python3 - "$name" "$labels" "${RUNNER_GROUP_ID:-1}" <<'EOF' |
import json, sys
name, labels, group = sys.argv[1], sys.argv[2], int(sys.argv[3])
print(json.dumps({"name": name, "runner_group_id": group,
                  "labels": [l for l in labels.split(",") if l], "work_folder": "_work"}))
EOF
    curl -sSf -X POST \
        -H "Authorization: Bearer $GH_TOKEN" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "https://api.github.com/$GH_SCOPE/actions/runners/generate-jitconfig" -d @- |
        python3 -c 'import json,sys; print(json.load(sys.stdin)["encoded_jit_config"])'
}

slot() {
    local n="$1" name jit
    # Slot N gets its own LAN tap and a stable MAC when NET_TAP_PREFIX is set.
    if test -n "${NET_TAP_PREFIX:-}"; then
        export TAP_IF="${NET_TAP_PREFIX}$n" TAP_MAC="$(printf '52:54:00:76:62:%02x' "$n")"
    fi
    while true; do
        name="vmapple-$(hostname -s)-$n-$(date +%Y%m%d%H%M%S)"
        if ! jit="$(jit_config "$name")"; then
            echo "[slot $n] could not get a JIT config; retrying in 60 s" >&2
            sleep 60; continue
        fi
        echo "[slot $n] $name waiting for a job" >&2
        printf '%s\n' "$jit" | "$repo_root/scripts/vm-job.sh" \
            'read -r jit; cd ~/actions-runner && exec ./run.sh --jitconfig "$jit"'
        echo "[slot $n] $name finished with status $?" >&2
    done
}

# Stopping the orchestrator stops every slot; each vm-job then shuts its guest down.
trap 'trap - INT TERM; kill -TERM 0 2>/dev/null; wait; exit 130' INT TERM
for n in $(seq 1 "$slots"); do slot "$n" & done
wait
