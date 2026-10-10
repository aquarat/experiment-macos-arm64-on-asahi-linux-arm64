#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Layer 65: headless settings for guests that run with the paravirtual GPU.
# Bake with the GPU on (the launcher's default GFX=reims, a working
# VK_DRIVER_FILES), never with GFX=none:
#
#   scripts/bake-golden.sh <src> <dst> "GPU headless (images/65-gpu-headless.sh)" "bash -s" < images/65-gpu-headless.sh
#
# - Display sleep after 1 minute. With display sleep off (layer 10's old
#   setting) WindowServer composites the invisible display forever, about one
#   guest core; asleep it idles. The iOS simulator renders off-screen, so a
#   sleeping display does not affect it.
# - Remove crash and spin reports left by earlier bakes. Without a GPU,
#   WindowServer aborts every minute ("No suitable Metal devices present") and
#   ReportCrash/spindump symbolication then reads gigabytes into the file cache.
# - Check that a Metal device exists, so a bake without the GPU fails loudly.
# The whole layer is one function called with stdin from /dev/null (see
# docs/IMAGES.md: bash reads a piped script incrementally).
main() {
    set -euo pipefail

    sudo -n pmset -a displaysleep 1
    pmset -g | grep -E '^ *displaysleep +1$' >/dev/null || { echo "displaysleep not set" >&2; exit 1; }

    sudo -n find /Library/Logs/DiagnosticReports "$HOME/Library/Logs/DiagnosticReports" \
        -maxdepth 1 -type f \( -name '*.ips' -o -name '*.diag' -o -name '*.spin' -o -name '*.hang' \) -delete 2>/dev/null || true

    swift -e 'import Metal; guard let d = MTLCreateSystemDefaultDevice() else { fatalError("no Metal device: bake with the GPU on") }; print("Metal:", d.name)'

    echo "+ GPU headless (images/65-gpu-headless.sh): displaysleep 1, diagnostic reports cleared" |
        sudo -n tee -a /etc/vmapple-image-version >/dev/null
    echo "layer 65-gpu-headless complete"
}
main "$@" < /dev/null
