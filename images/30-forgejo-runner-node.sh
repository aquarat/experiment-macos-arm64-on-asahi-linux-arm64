#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Layer 30: forgejo-runner (darwin-arm64 build) in ~/forgejo-runner and
# Node.js LTS in ~/node, on PATH via ~/.zshenv.                    (Tahoe v4)
# Runs INSIDE the guest as the guest user. forgejo-runner has no macOS release:
# build it on the host first and serve it to the guest over slirp (the host's
# 127.0.0.1 is 10.0.2.2 inside the guest):
#
#   images/host/build-forgejo-runner-darwin.sh            # -> build/forgejo-runner/
#   python3 -m http.server -b 127.0.0.1 8000 -d build/forgejo-runner &
#   scripts/bake-golden.sh tahoe-26.4-25E246-v2 tahoe-26.4-25E246-v4 \
#       "forgejo-runner v13.2.0 (darwin-arm64 build) in ~/forgejo-runner, Node v24.21.0 in ~/node on PATH via ~/.zshenv" \
#       "env FORGEJO_RUNNER_SHA256=<sha256 printed by the build> bash -s" < images/30-forgejo-runner-node.sh
#   kill %1
#
# Node is what JavaScript actions (actions/checkout, …) need in host mode.
# Idempotent.
# The body is a function run with stdin from /dev/null: bash -s reads this
# script from stdin incrementally, so any command reading stdin would swallow
# the rest of it and the bake would "succeed" with half a layer.
main() {
    set -euo pipefail

    FORGEJO_RUNNER_VERSION="${FORGEJO_RUNNER_VERSION:-13.2.0}"
    FORGEJO_RUNNER_URL="${FORGEJO_RUNNER_URL:-http://10.0.2.2:8000/forgejo-runner-$FORGEJO_RUNNER_VERSION-darwin-arm64}"
    # Reference build (go1.26.8); a build with another Go release differs.
    FORGEJO_RUNNER_SHA256="${FORGEJO_RUNNER_SHA256:-64cbd7b93d672c0b709a9bacea6303c9d5805d145f2e20b121594536725d2b44}"
    NODE_VERSION="${NODE_VERSION:-v24.21.0}"
    # Empty: verify against nodejs.org's SHASUMS256.txt for that release.
    NODE_SHA256="${NODE_SHA256:-}"

    tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

    # forgejo-runner
    fr="$HOME/forgejo-runner/forgejo-runner"
    if ! test -x "$fr" || test "$(shasum -a 256 "$fr" | cut -d' ' -f1)" != "$FORGEJO_RUNNER_SHA256"; then
        curl -fsSL -o "$tmp/forgejo-runner" "$FORGEJO_RUNNER_URL"
        echo "$FORGEJO_RUNNER_SHA256  $tmp/forgejo-runner" | shasum -a 256 -c
        mkdir -p "$HOME/forgejo-runner"
        install -m 755 "$tmp/forgejo-runner" "$fr"
    fi

    # Node.js
    node_tar="node-$NODE_VERSION-darwin-arm64.tar.xz"
    if test "$(cat "$HOME/node/VERSION-vmapple" 2>/dev/null)" != "$NODE_VERSION"; then
        curl -fsSL -o "$tmp/$node_tar" "https://nodejs.org/dist/$NODE_VERSION/$node_tar"
        if test -z "$NODE_SHA256"; then
            curl -fsSL -o "$tmp/SHASUMS256.txt" "https://nodejs.org/dist/$NODE_VERSION/SHASUMS256.txt"
            NODE_SHA256="$(awk -v f="$node_tar" '$2 == f {print $1}' "$tmp/SHASUMS256.txt")"
            test -n "$NODE_SHA256" || { echo "$node_tar not in SHASUMS256.txt" >&2; exit 1; }
        fi
        echo "$NODE_SHA256  $tmp/$node_tar" | shasum -a 256 -c
        rm -rf "$HOME/node"; mkdir -p "$HOME/node"
        tar -xJf "$tmp/$node_tar" -C "$HOME/node" --strip-components 1
        echo "$NODE_VERSION" > "$HOME/node/VERSION-vmapple"
    fi
    # Non-interactive zsh (every SSH command, hence every runner) reads only ~/.zshenv.
    grep -q node/bin "$HOME/.zshenv" 2>/dev/null || echo 'export PATH=$HOME/node/bin:$PATH' >> "$HOME/.zshenv"

    "$fr" --version
    zsh -c '. ~/.zshenv; command -v node; node --version; npm --version'
    echo "layer 30 complete"
}
main "$@" < /dev/null
