#!/bin/bash
# Compile + run pounce's pure-logic unit tests with the same /usr/bin/xcrun
# swiftc the app build uses (macOS + Xcode CLT required). Kept out of
# pkgs/pounce/*.swift so test code never lands in the shipped Pounce.app.
#
#   pkgs/pounce/tests/run.sh
set -euo pipefail
cd "$(dirname "$0")/.." # -> pkgs/pounce

bin="$(mktemp -d)/pounce-tests"
# The sources under test are Foundation-only by design (no AppKit/SwiftUI) —
# for the quick-answer engines that's the QuickAnswer.swift contract — which is
# what keeps this a plain swiftc compile. Compiling them with the test files as
# one module lets tests reach module-internal API. The entry file is named
# main.swift because swiftc only permits top-level executable code (the
# assertions) in a file with that base name when several files are compiled
# together.
/usr/bin/xcrun swiftc -o "$bin" \
  Frecency.swift QuickAnswer.swift Calculator.swift UnitConvert.swift TimeConvert.swift \
  tests/main.swift tests/quickanswer.swift
"$bin"
