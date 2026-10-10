#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Layer 60: CI toolchain on top of Xcode + iOS simulator (layer 50).
# Runs inside the guest as the guest user (passwordless sudo):
#
#   scripts/bake-golden.sh <src> <dst> "CI tools (images/60-ci-tools.sh)" "bash -s" < images/60-ci-tools.sh
#
# Installs Homebrew and, from it: JDK 21 (Temurin-equivalent OpenJDK), actionlint,
# shellcheck, xcodegen, xcbeautify, SwiftLint, Carthage, CocoaPods, fastlane.
# Homebrew formulae are not pinnable in practice: the exact versions installed are
# recorded in /etc/vmapple-image-version and ~/ci-tools-versions.txt, and
# HOMEBREW_NO_AUTO_UPDATE keeps jobs from updating them.
#
# Project-specific toolchains (e.g. a pinned GraalVM, Gradle and Kotlin/Native
# downloads) are better served by `actions/cache` against a persistent cache
# server (see docs/IMAGES.md, "Runner cache") than baked in here.
# The whole layer is one function, called last with stdin from /dev/null: the
# script reaches the guest's bash on stdin (bake-golden.sh ... "bash -s"), and
# bash reads it incrementally, so a command reading stdin (brew does) would
# otherwise swallow the rest of the script and end the bake early with status 0.
main() {
    set -euo pipefail

    # Homebrew's installer, pinned to a commit of github.com/Homebrew/install.
    BREW_INSTALL_REV="${BREW_INSTALL_REV:-8ab1549dfa1189fd4d818a2116592d8f0ee06d8c}"
    FORMULAE=(openjdk@21 actionlint shellcheck xcodegen xcbeautify swiftlint carthage cocoapods fastlane)

    if ! test -x /opt/homebrew/bin/brew; then
        # The installer wants a sudo-capable user and no TTY prompts.
        NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL "https://raw.githubusercontent.com/Homebrew/install/$BREW_INSTALL_REV/install.sh")"
    fi
    eval "$(/opt/homebrew/bin/brew shellenv)"
    export HOMEBREW_NO_ANALYTICS=1 HOMEBREW_NO_ENV_HINTS=1

    brew install --quiet "${FORMULAE[@]}"

    # System Java wrappers (/usr/bin/java, /usr/libexec/java_home) find the JDK here.
    jdk=/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk
    sudo ln -sfn "$jdk" /Library/Java/JavaVirtualMachines/openjdk-21.jdk

    # Non-interactive shells (runner processes started over SSH) read only ~/.zshenv.
    marker="# --- ci-tools (images/60-ci-tools.sh) ---"
    if ! grep -qF "$marker" ~/.zshenv 2>/dev/null; then
        cat >> ~/.zshenv <<EOF
$marker
eval "\$(/opt/homebrew/bin/brew shellenv)"
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ANALYTICS=1 HOMEBREW_NO_ENV_HINTS=1
export JAVA_HOME=$jdk/Contents/Home
# CocoaPods and fastlane need a UTF-8 locale.
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
EOF
    fi

    # Verify and record what was installed.
    zsh -c 'source ~/.zshenv
    java -version 2>&1 | head -1
    actionlint -version | head -1
    shellcheck --version | sed -n 2p
    xcodegen --version
    xcbeautify --version
    swiftlint version
    carthage version
    pod --version
    fastlane --version 2>/dev/null | grep -m1 -E "^fastlane [0-9]"
    brew --version | head -1' | tee ~/ci-tools-versions.txt
    brew list --versions "${FORMULAE[@]}" >> ~/ci-tools-versions.txt
    echo "+ CI tools (images/60-ci-tools.sh): $(brew list --versions "${FORMULAE[@]}" | tr '\n' ';')" |
        sudo tee -a /etc/vmapple-image-version >/dev/null
    brew cleanup --prune=all -s >/dev/null 2>&1 || true
    echo "layer 60-ci-tools complete"
}
main "$@" < /dev/null
