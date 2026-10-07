#!/usr/bin/env bash
# Layer 20: GitHub Actions runner in ~/actions-runner.             (Tahoe v2)
# Runs INSIDE the guest as the guest user, via:
#
#   scripts/bake-golden.sh tahoe-26.4-25E246-v1 tahoe-26.4-25E246-v2 \
#       "actions-runner 2.338.0 in ~/actions-runner" "bash -s" < images/20-actions-runner.sh
#
# Only unpacked; scripts/gha-ephemeral-runner.sh configures a JIT runner per
# job. ~2.5 min including boot and shutdown. Idempotent.
# The body is a function run with stdin from /dev/null: bash -s reads this
# script from stdin incrementally, so any command reading stdin would swallow
# the rest of it and the bake would "succeed" with half a layer.
main() {
    set -euo pipefail

    RUNNER_VERSION="${RUNNER_VERSION:-2.338.0}"
    # Published on the release page (github.com/actions/runner/releases/tag/v2.338.0).
    RUNNER_SHA256="${RUNNER_SHA256:-df4cebda25c86a886ed204e49fee63f5c2e7cec5f447b5c98440a826bbdf9df2}"
    url="https://github.com/actions/runner/releases/download/v$RUNNER_VERSION/actions-runner-osx-arm64-$RUNNER_VERSION.tar.gz"

    dir="$HOME/actions-runner"
    if test "$(cd "$dir" 2>/dev/null && ./config.sh --version 2>/dev/null)" = "$RUNNER_VERSION"; then
        echo "actions-runner $RUNNER_VERSION already present"; echo "layer 20 complete"; return 0
    fi
    tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
    curl -fsSL -o "$tmp/runner.tgz" "$url"
    echo "$RUNNER_SHA256  $tmp/runner.tgz" | shasum -a 256 -c
    rm -rf "$dir"; mkdir -p "$dir"
    tar -xzf "$tmp/runner.tgz" -C "$dir"
    cd "$dir" && ./config.sh --version
    echo "layer 20 complete"
}
main "$@" < /dev/null
