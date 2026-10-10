#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Cross-compile forgejo-runner for darwin/arm64 (Forgejo publishes no macOS
# build). Runs on the Linux (or macOS) host, not in the guest; layer
# images/30-forgejo-runner-node.sh then installs the result.
#
#   images/host/build-forgejo-runner-darwin.sh [OUTDIR]     default OUTDIR: build/forgejo-runner
#
# Needs git and Go (Fedora: dnf install golang). The reference binary was built
# with go1.26.8; another Go release produces a different (equally valid)
# binary, so the SHA-256 check below is a warning, not an error.
set -euo pipefail

FORGEJO_RUNNER_VERSION="${FORGEJO_RUNNER_VERSION:-v13.2.0}"
FORGEJO_RUNNER_COMMIT_PREFIX="${FORGEJO_RUNNER_COMMIT_PREFIX:-df6b843f}"   # tag v13.2.0
FORGEJO_RUNNER_REPO="${FORGEJO_RUNNER_REPO:-https://code.forgejo.org/forgejo/runner.git}"
REFERENCE_GO="go1.26.8"
REFERENCE_SHA256="64cbd7b93d672c0b709a9bacea6303c9d5805d145f2e20b121594536725d2b44"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
out="${1:-$repo_root/build/forgejo-runner}"
die() { echo "error: $*" >&2; exit 1; }
for c in git go sha256sum; do command -v "$c" >/dev/null || die "missing $c"; done

src="$out/src-$FORGEJO_RUNNER_VERSION"
mkdir -p "$out"
test -d "$src/.git" ||
    git clone -q --depth 1 --branch "$FORGEJO_RUNNER_VERSION" "$FORGEJO_RUNNER_REPO" "$src"
commit="$(git -C "$src" rev-parse HEAD)"
case "$commit" in
    "$FORGEJO_RUNNER_COMMIT_PREFIX"*) ;;
    *) die "tag $FORGEJO_RUNNER_VERSION is $commit, expected $FORGEJO_RUNNER_COMMIT_PREFIX…" ;;
esac

major="${FORGEJO_RUNNER_VERSION%%.*}"            # v13 -> module path .../runner/v13
bin="$out/forgejo-runner-${FORGEJO_RUNNER_VERSION#v}-darwin-arm64"
(
    cd "$src"
    GOOS=darwin GOARCH=arm64 CGO_ENABLED=0 go build -trimpath \
        -ldflags "-s -w -X code.forgejo.org/forgejo/runner/$major/internal/pkg/ver.version=$FORGEJO_RUNNER_VERSION" \
        -o "$bin" .
)
sum="$(sha256sum "$bin" | cut -d' ' -f1)"
echo "$sum  $(basename "$bin")" > "$bin.sha256"
go_version="$(go env GOVERSION)"
echo "built  $bin"
echo "go     $go_version"
echo "sha256 $sum"
if test "$sum" != "$REFERENCE_SHA256"; then
    echo "note: differs from the reference build ($REFERENCE_GO: $REFERENCE_SHA256);" >&2
    test "$go_version" = "$REFERENCE_GO" &&
        echo "warning: same Go release as the reference, yet a different binary" >&2
    echo "pass FORGEJO_RUNNER_SHA256=$sum to images/30-forgejo-runner-node.sh" >&2
fi
