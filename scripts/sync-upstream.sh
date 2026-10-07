#!/usr/bin/env bash
# Bring the aquarat forks up to date with their upstreams.
#
#   scripts/sync-upstream.sh merge [WORKDIR]   # fetch + merge into local masters, bump vendor/qemu
#   scripts/sync-upstream.sh build [WORKDIR]   # build the merged result (Asahi host)
#   scripts/sync-upstream.sh push  [WORKDIR]   # push both masters (needs GitHub credentials)
#
# WORKDIR (default ~/Projects/fork-sync) holds full clones:
#   qemu-reims-vgpu  origin aquarat, upstream qemu-project, steelbrain (vmapple branch)
#   reims-vgpu       origin aquarat, upstream steelbrain-bot
# merge stops on the first conflict and leaves it for resolution (finish
# with `git commit`, then rerun merge). Test between build and push, e.g. the
# Ventura/Tahoe loops with QEMU_BIN pointing at the new binary.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cmd="${1:?usage: $0 merge|build|push [WORKDIR]}"
wd="${2:-$HOME/Projects/fork-sync}"
q="$wd/qemu-reims-vgpu"; r="$wd/reims-vgpu"
# Merge commits use your git identity (user.name/user.email, or GIT_AUTHOR_*).
G=(git)

clone() {  # dir origin [name url]...
    local dir="$1" origin="$2"; shift 2
    test -d "$dir/.git" || git clone -q "$origin" "$dir"
    while test $# -gt 0; do
        git -C "$dir" remote get-url "$1" >/dev/null 2>&1 || git -C "$dir" remote add "$1" "$2"
        shift 2
    done
}

case "$cmd" in
merge)
    mkdir -p "$wd"
    clone "$q" https://github.com/aquarat/qemu-reims-vgpu.git \
        upstream https://gitlab.com/qemu-project/qemu.git \
        steelbrain https://github.com/steelbrain/qemu-reims-vgpu.git
    clone "$r" https://github.com/aquarat/reims-vgpu.git \
        upstream https://github.com/steelbrain-bot/reims-vgpu.git
    git -C "$q" fetch -q origin master
    git -C "$q" fetch -q upstream master
    git -C "$q" fetch -q steelbrain host-reims-vgpu-vmapple
    git -C "$q" checkout -q -B master origin/master
    "${G[@]}" -C "$q" merge --no-edit steelbrain/host-reims-vgpu-vmapple
    "${G[@]}" -C "$q" merge --no-edit upstream/master
    git -C "$r" fetch -q origin master
    git -C "$r" fetch -q upstream master
    git -C "$r" checkout -q -B master origin/master
    "${G[@]}" -C "$r" merge --no-edit upstream/master
    # Keep our submodule URL/branch whatever upstream's .gitmodules says.
    git -C "$r" config -f .gitmodules submodule.vendor/qemu.url https://github.com/aquarat/qemu-reims-vgpu.git
    git -C "$r" config -f .gitmodules submodule.vendor/qemu.branch master
    git -C "$r" update-index --cacheinfo "160000,$(git -C "$q" rev-parse master),vendor/qemu"
    git -C "$r" add .gitmodules
    git -C "$r" diff --cached --quiet ||
        "${G[@]}" -C "$r" commit -q -m "vendor/qemu: bump to $(git -C "$q" rev-parse --short master) (upstream sync)"
    echo "qemu  master $(git -C "$q" log --oneline -1 master)"
    echo "reims master $(git -C "$r" log --oneline -1 master)"
    ;;
build)
    REIMS_URL="$r" REIMS_REF=master QEMU_URL="$q" \
        "$repo_root/scripts/build-qemu.sh" "$wd/build"
    ;;
push)
    git -C "$q" push origin master
    git -C "$r" push origin master
    ;;
*) echo "usage: $0 merge|build|push [WORKDIR]" >&2; exit 2 ;;
esac
