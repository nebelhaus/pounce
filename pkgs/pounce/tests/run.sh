#!/bin/bash
# Compile + run pounce's pure-logic unit tests with the same /usr/bin/xcrun
# swiftc the app build uses (macOS + Xcode CLT required). Kept out of
# pkgs/pounce/*.swift so test code never lands in the shipped Pounce.app.
#
#   pkgs/pounce/tests/run.sh
set -euo pipefail
cd "$(dirname "$0")/.." # -> pkgs/pounce

bin="$(mktemp -d)/frecency-tests"
# Frecency.swift only needs Foundation; compiling it together with the test file
# as one module lets the test reach the module-internal decayedScore(). The test
# file is named main.swift because swiftc only permits top-level executable code
# (the assertions below) in a file with that base name when several files are
# compiled together.
/usr/bin/xcrun swiftc -o "$bin" Frecency.swift tests/main.swift
"$bin"
