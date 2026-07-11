// Quick-answer engine tests (calculator, unit conversion, timezone), compiled
// into the same pure-logic test binary as the Frecency suite — see
// tests/run.sh and the assertions' entry point in tests/main.swift. Everything
// exercised here is Foundation-only by design (the QuickAnswer.swift
// contract), which is what makes this possible without a UI test rig.

import Foundation

func runQuickAnswerTests() -> Int {
    var failures = 0
    func expect(_ condition: Bool, _ message: String) {
        if !condition {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            failures += 1
        }
    }
    // The clipboard payload is the strict, machine-friendly form — assert on it.
    func copies(_ query: String, _ expected: String) {
        let got = QuickAnswerHub.answer(for: query)?.copyText
        expect(got == expected, "\(query) → \(got ?? "nil"), want \(expected)")
    }
    func rejects(_ query: String) {
        let got = QuickAnswerHub.answer(for: query)
        expect(got == nil, "\(query) → \(got?.copyText ?? "?"), want no answer")
    }

    // MARK: math — the basics

    copies("2*847", "1694")
    copies("2 × 847", "1694")
    copies("1,000 + 5", "1005")
    copies("2^10", "1024")
    copies("2**10", "1024")
    copies("-2^2", "-4")           // unary minus binds looser than ^
    copies("2^3^2", "512")         // ^ is right-associative
    copies("10 mod 3", "1")
    copies("1/3", "0.3333333333")  // 10 significant digits
    copies("0.1 + 0.2", "0.3")     // float noise swallowed
    copies("2e3 + 1", "2001")

    // display formatting groups thousands; copy text never does
    expect(QuickAnswerHub.answer(for: "2*847")?.display == "1,694",
           "display should group thousands")

    // MARK: math — percent semantics (the Raycast/soulver rules)

    copies("100 + 10%", "110")
    copies("100 - 10%", "90")
    copies("50 * 10%", "5")
    copies("20% of 150", "30")
    copies("50%", "0.5")

    // MARK: math — functions, constants, implicit multiplication

    copies("sqrt(9)", "3")
    copies("2(3+4)", "14")
    copies("round(2pi)", "6")
    copies("cos(0)", "1")

    // MARK: math — searches must never trigger the calculator

    rejects("847")            // bare number: a search
    rejects("-5")             // signed bare number
    rejects("(42)")           // parens only, no operation
    rejects("pi")             // bare constant
    rejects("safari")
    rejects("1password")      // number-prefixed app name
    rejects("2fa codes")
    rejects("3.14.15")        // version string, not math
    rejects("14:00")          // clock time alone

    // MARK: unit conversions

    copies("10 km in mi", "6.21371")
    copies("72 f in c", "22.2222")
    copies("100km in m", "100000")    // amount glued to unit
    copies("1 h in min", "60")
    copies("2 days in hours", "48")
    copies("1 gb in mb", "1000")
    copies("1 gib in mib", "1024")
    copies("10 inches to cm", "25.4")
    copies("-40 f in c", "-40")

    expect(QuickAnswerHub.answer(for: "10 km in mi")?.display == "6.21371 mi",
           "unit display carries the target symbol")

    rejects("10 km in kg")       // cross-dimension
    rejects("100 usd in eur")    // currency needs its own (future) engine
    rejects("10 zorble in mi")

    // MARK: timezone (pinned date: 2026-01-15, so PST not PDT)

    let jan15 = Date(timeIntervalSince1970: 1_768_500_000)  // 2026-01-15T18:40Z
    let tz = TimeZoneEngine()
    func zone(_ query: String, _ expected: String) {
        let got = tz.evaluate(query, on: jan15)?.copyText
        expect(got == expected, "\(query) → \(got ?? "nil"), want \(expected)")
    }

    zone("14:00 utc in pst", "6:00 AM")
    zone("2pm utc in pst", "6:00 AM")
    zone("2:30pm utc to pst", "6:30 AM")
    zone("9pm pst in utc", "5:00 AM (next day)")
    zone("2am utc in pst", "6:00 PM (prev day)")
    zone("12pm utc in utc", "12:00 PM")
    zone("12am utc in utc", "12:00 AM")
    zone("14:00 utc in tokyo", "11:00 PM")            // city name
    zone("14:00 utc in asia/tokyo", "11:00 PM")       // IANA identifier
    zone("14:00 utc in utc+5:30", "7:30 PM")          // explicit offset
    zone("14:00 gmt-8 in utc", "10:00 PM")

    expect(tz.evaluate("25:00 utc in pst", on: jan15) == nil, "hour 25 must not parse")
    expect(tz.evaluate("13pm utc in pst", on: jan15) == nil, "13pm must not parse")
    expect(tz.evaluate("14:00 zorble in pst", on: jan15) == nil, "unknown source zone")
    expect(tz.evaluate("14:00 utc in zorble", on: jan15) == nil, "unknown dest zone")

    if failures == 0 { print("ok — all quick-answer tests passed") }
    return failures
}
