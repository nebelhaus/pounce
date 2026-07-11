// Unit tests for pounce's pure logic: Frecency's ranking math (below) and the
// quick-answer engines (tests/quickanswer.swift). Deliberately assertion-based
// (no XCTest/SwiftPM) so it compiles with the very same `xcrun swiftc` the app
// build uses — see tests/run.sh. Lives under tests/ so pkgs/pounce/*.swift (the
// app's single-module glob) never sweeps it into the shipped binary. Named
// main.swift because the assertions run as top-level code, which swiftc only
// allows in a file with that base name when compiled alongside the sources
// under test.
//
// Only the pure Frecency.decayedScore is exercised here; the instance
// score(for:)/record touch the filesystem and the wall clock, which is exactly
// what decayedScore was split out to avoid.

import Foundation

var failures = 0
func expect(_ condition: Bool, _ message: String) {
    if !condition {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        failures += 1
    }
}
func expectClose(_ a: Double, _ b: Double, _ message: String, eps: Double = 1e-9) {
    expect(abs(a - b) <= eps, "\(message) (got \(a), want \(b))")
}

let lambda = log(2.0) / (72 * 3600) // ln2 / 72h — the app's decay constant

// A brand-new-relative-to-now hit scores exactly its count (age 0 → e^0 = 1).
expectClose(Frecency.decayedScore(count: 5, lastUsed: 1000, now: 1000, lambda: lambda), 5,
            "age 0 scores the raw count")

// One half-life (72h) halves the weight; two quarters it.
expectClose(Frecency.decayedScore(count: 8, lastUsed: 0, now: 72 * 3600, lambda: lambda), 4,
            "one half-life halves the score", eps: 1e-6)
expectClose(Frecency.decayedScore(count: 8, lastUsed: 0, now: 2 * 72 * 3600, lambda: lambda), 2,
            "two half-lives quarter the score", eps: 1e-6)

// A count-0 entry always scores 0, regardless of recency.
expectClose(Frecency.decayedScore(count: 0, lastUsed: 0, now: 0, lambda: lambda), 0,
            "zero count scores zero")

// Monotonicity the ranking relies on: fresher and more-used both rank higher.
let older = Frecency.decayedScore(count: 3, lastUsed: 0, now: 100_000, lambda: lambda)
let newer = Frecency.decayedScore(count: 3, lastUsed: 50_000, now: 100_000, lambda: lambda)
expect(newer > older, "more recent use outranks staler use at equal count")

let fewer = Frecency.decayedScore(count: 2, lastUsed: 0, now: 10_000, lambda: lambda)
let more = Frecency.decayedScore(count: 9, lastUsed: 0, now: 10_000, lambda: lambda)
expect(more > fewer, "higher count outranks lower at equal recency")

if failures == 0 { print("ok — all Frecency ranking tests passed") }

failures += runQuickAnswerTests()

if failures == 0 {
    exit(0)
} else {
    FileHandle.standardError.write(Data("\(failures) test(s) failed\n".utf8))
    exit(1)
}
