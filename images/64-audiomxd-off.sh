#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Layer 64: turn off Smart Routing (audiomxd) so playback cannot start its
# no-console-user loop. Runs INSIDE the guest on top of layer 62 (any GFX;
# GFX=none is fine):
#
#   GFX=none scripts/bake-golden.sh <src> <dst> "audiomxd off (images/64-audiomxd-off.sh)" \
#       "bash -s" < images/64-audiomxd-off.sh
#
# On macOS 26, audiomxd is the Smart Routing daemon (automatic switching of
# Bluetooth headphones between devices). Every macOS-side playback (afplay,
# AVAudioEngine, AudioQueue) registers an audio session with it, and it then
# asks the console user's Bluetooth agent about the route. With no console
# user (jobs run over SSH) AudioAccessoryServices reports the agent as dead,
# audiomxd reconnects at once and fails again, forever: audiomxd ~80 %,
# configd ~40 % of a vCPU and 100,000+ log lines a minute, until audiomxd is
# killed. No preference turns the Bluetooth path off (docs/NOTES.md).
#
# Two feature-flag overrides switch it off; they take effect at the next boot:
# - BluetoothFeatures/SmartRoutingMacOS: clients no longer create sessions in
#   audiomxd, launchd drops its com.apple.audio.AudioSession service, and
#   audiomxd exits at launch ("audiomxd feature flag is disabled").
# - MediaExperience/MoveMXRoutingToAudiomxdOnMac: route discovery and AirPlay
#   routing stay out of audiomxd. Without it, AirPlayXPCHelper and mediaremoted
#   leave messages on audiomxd's routing services, and launchd relaunches the
#   exiting daemon every 5 s for the life of the guest.
# Playback through the default output, and in the iOS simulator, is unchanged.
# Undo: sudo rm /Library/Preferences/FeatureFlags/Domain/{BluetoothFeatures,MediaExperience}.plist
# and reboot.
# The body is a function run with stdin from /dev/null (see docs/IMAGES.md).
main() {
    set -euo pipefail

    local dir=/Library/Preferences/FeatureFlags/Domain
    sudo -n mkdir -p "$dir"
    sudo -n defaults write "$dir/BluetoothFeatures.plist" SmartRoutingMacOS -dict Enabled -bool false
    sudo -n defaults write "$dir/MediaExperience.plist" MoveMXRoutingToAudiomxdOnMac -dict Enabled -bool false
    sudo -n chown root:wheel "$dir/BluetoothFeatures.plist" "$dir/MediaExperience.plist"
    sudo -n chmod 644 "$dir/BluetoothFeatures.plist" "$dir/MediaExperience.plist"

    local f flag
    for f in BluetoothFeatures:SmartRoutingMacOS MediaExperience:MoveMXRoutingToAudiomxdOnMac; do
        flag="${f#*:}"
        test "$(/usr/libexec/PlistBuddy -c "Print :$flag:Enabled" "$dir/${f%%:*}.plist")" = false ||
            { echo "override for $f not written" >&2; exit 1; }
        echo "${f%%:*}/$flag: disabled (from the next boot)"
    done

    echo "+ audiomxd off (images/64-audiomxd-off.sh): feature flags BluetoothFeatures/SmartRoutingMacOS, MediaExperience/MoveMXRoutingToAudiomxdOnMac disabled" |
        sudo -n tee -a /etc/vmapple-image-version >/dev/null
    echo "layer 64-audiomxd-off complete"
}
main "$@" < /dev/null
