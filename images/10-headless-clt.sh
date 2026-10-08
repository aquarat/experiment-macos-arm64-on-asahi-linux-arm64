#!/usr/bin/env bash
# Layer 10: headless settings, clock, Command Line Tools.     (Tahoe v1, 2nd half)
# Runs INSIDE the guest as the guest user (passwordless sudo), via:
#
#   scripts/bake-golden.sh <account-bundle> tahoe-26.4-25E246-v1 \
#       "headless settings, CLT for Xcode 26.6, TZ $GUEST_TZ" "bash -s" < images/10-headless-clt.sh
#
# Override a variable by prefixing the remote command: "env GUEST_TZ=America/New_York bash -s".
# Takes ~4 min (CLT download over slirp ~3 min). Idempotent.
# The body is a function run with stdin from /dev/null: bash -s reads this
# script from stdin incrementally, so any command reading stdin would swallow
# the rest of it and the bake would "succeed" with half a layer.
main() {
    set -euo pipefail

    GUEST_TZ="${GUEST_TZ:-UTC}"
    NTP_SERVER="${NTP_SERVER:-time.apple.com}"
    # Apple offers only the CLT current for the guest OS, so this pins by
    # assertion: the install fails if the offered label does not contain it.
    # Reference: "26.6" on macOS 26.4, "14.3" on Ventura 13.6. "any" = newest offered.
    CLT_VERSION="${CLT_VERSION:-26.6}"

    # Never sleep (system/disk), no screen saver, no Spotlight indexing (mds
    # stays resident). The display does sleep after 1 minute: awake, WindowServer
    # composites the invisible headless display forever (about one guest core).
    sudo -n pmset -a sleep 0 displaysleep 1 disksleep 0 standby 0 powernap 0
    sudo -n mdutil -a -i off || true
    defaults -currentHost write com.apple.screensaver idleTime 0

    # Automatic updates off. NOTE: on macOS 26.4 these keys are ignored and
    # `softwareupdate --schedule off` is a no-op (needs a configuration profile);
    # kept because they do work on Ventura and cost nothing.
    for k in AutomaticCheckEnabled AutomaticDownload AutomaticallyInstallMacOSUpdates; do
        sudo -n defaults write /Library/Preferences/com.apple.SoftwareUpdate "$k" -bool false
    done
    sudo -n defaults write /Library/Preferences/com.apple.commerce AutoUpdate -bool false

    # Clock: network time and time zone.
    sudo -n systemsetup -setusingnetworktime on >/dev/null 2>&1 || true
    sudo -n sntp -sS "$NTP_SERVER" || true
    sudo -n systemsetup -settimezone "$GUEST_TZ" >/dev/null 2>&1 || true
    sudo -n systemsetup -gettimezone | grep -qF "$GUEST_TZ" || { echo "time zone not set" >&2; exit 1; }

    # Command Line Tools via softwareupdate (no Apple ID needed). The marker file
    # makes softwareupdate list the CLT as an installable item.
    clt=/Library/Developer/CommandLineTools
    if ! test -x "$clt/usr/bin/clang"; then
        marker=/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
        touch "$marker"
        trap 'rm -f "$marker"' EXIT
        labels="$(softwareupdate -l 2>&1 | sed -n 's/^\* Label: \(Command Line Tools.*\)$/\1/p')"
        test "$CLT_VERSION" = any || labels="$(grep -F -- "$CLT_VERSION" <<<"$labels" || true)"
        label="$(sort -V <<<"$labels" | tail -1)"
        test -n "$label" || { echo "no Command Line Tools label matching '$CLT_VERSION' offered" >&2; exit 1; }
        echo "installing: $label"
        sudo -n softwareupdate -i "$label"
        rm -f "$marker"
    fi
    xcode-select -p
    clang --version | head -1
    swift --version 2>&1 | head -1
    git --version
    date
    echo "layer 10 complete"
}
main "$@" < /dev/null
