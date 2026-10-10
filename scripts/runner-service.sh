#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Entry point for the runner systemd units: load this host's profile, then
# run one of the ephemeral runner orchestrators with its VM_SLOTS.
#
#   scripts/runner-service.sh forgejo|gha
#
# The host profile is hosts/$(hostname -s).env (or HOST_PROFILE). Credentials
# come from the unit's EnvironmentFile, never from this repository.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
profile="${HOST_PROFILE:-$repo_root/hosts/$(hostname -s).env}"
test -f "$profile" || { echo "no host profile $profile" >&2; exit 1; }
set -a; . "$profile"; set +a
# Discard run directories (guest disk clones) left by a crash or power loss.
for d in "$repo_root"/artifacts/runs/job-*/; do
    test -d "$d" || continue
    pgrep -f -- "${d%/}/" >/dev/null || rm -rf -- "$d"
done
case "${1:-}" in
forgejo) exec "$repo_root/scripts/forgejo-ephemeral-runner.sh" "${VM_SLOTS:-1}" ;;
gha)     exec "$repo_root/scripts/gha-ephemeral-runner.sh" "${VM_SLOTS:-1}" ;;
*) echo "usage: $0 forgejo|gha" >&2; exit 2 ;;
esac
