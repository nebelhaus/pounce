import Foundation

// MARK: - Quick Answers (inline calculator & friends)
//
// The launcher answers some queries *right in the palette* instead of fuzzy-
// matching them against apps and commands: `2*847`, `72 f in c`,
// `14:00 utc in pst`. The answer renders as a pinned first row (AnswerRow) and
// ⏎ copies it to the clipboard — Spotlight/Raycast's inline calculator.
//
//   keystroke ──▶ QuickAnswerHub.answer(for:) ──▶ first engine that parses it
//
// The contract for adding an engine (this is the whole extension surface):
//
// * An engine is a pure `evaluate(query) -> QuickAnswer?`. It runs on the main
//   thread on EVERY keystroke, so it must be synchronous and fast (budget:
//   well under a millisecond) and must return nil cheaply for queries it
//   doesn't own. Parse failure IS the gate — there's no trigger prefix, no
//   registration of keywords.
// * Engines that need external data (a future CurrencyEngine for
//   `100 usd in eur`) still evaluate synchronously: they read an in-memory
//   cache that a background task refreshes (the AppScanner.warm pattern) and
//   return nil until it's warm. Never block a keystroke on I/O.
// * Order in `engines` is priority: the first non-nil answer wins, so put
//   cheap/likely engines first.
// * Keep engine files Foundation-only (no AppKit/SwiftUI) so tests/run.sh can
//   compile them into the pure-logic test binary — and add cases to
//   tests/quickanswer.swift.

struct QuickAnswer {
    let display: String   // what the row shows big: "1,694"
    let detail: String    // the interpretation, right-aligned: "2 × 847"
    let icon: String      // SF Symbol for the row
    let copyText: String  // what ⏎ copies: "1694" — plain, no grouping
}

protocol QuickAnswerEngine {
    func evaluate(_ query: String) -> QuickAnswer?
}

enum QuickAnswerHub {
    static let engines: [QuickAnswerEngine] = [
        MathEngine(),
        UnitConversionEngine(),
        TimeZoneEngine(),
    ]

    static func answer(for query: String) -> QuickAnswer? {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2, q.count <= 256 else { return nil }
        // Every current engine needs a digit or a math constant somewhere;
        // bail before running engines on app-shaped queries ("safari").
        let lower = q.lowercased()
        guard lower.contains(where: { $0.isNumber })
            || lower.contains("pi") || lower.contains("π") || lower.contains("tau")
        else { return nil }
        for engine in engines {
            if let a = engine.evaluate(q) { return a }
        }
        return nil
    }
}

// MARK: - Conversion query shape

// "AMOUNT UNIT in UNIT" — the shared shape for unit, timezone-free currency
// (future), and similar `X in Y` conversions. Parsing returns every plausible
// split because the separator words double as units ("10 in in cm") — the
// caller tries candidates against its own vocabulary and takes the first that
// resolves.
struct ConversionQuery {
    let amount: Double
    let from: String   // normalized (lowercased, single-spaced) unit token(s)
    let to: String

    static let separators: Set<String> = ["in", "to", "as"]

    static func parse(_ query: String) -> [ConversionQuery] {
        let words = query.lowercased()
            .split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)
        guard words.count >= 3 else { return [] }

        var out: [ConversionQuery] = []
        // A separator needs a number+unit on its left and a unit on its right.
        for i in 1..<(words.count - 1) where separators.contains(words[i]) {
            let lhs = Array(words[0..<i])
            let rhs = words[(i + 1)...].joined(separator: " ")
            guard let (amount, unitStart) = splitAmount(lhs[0]) else { continue }
            var fromParts = Array(lhs.dropFirst())
            if !unitStart.isEmpty { fromParts.insert(unitStart, at: 0) }
            let from = fromParts.joined(separator: " ")
            guard !from.isEmpty, !rhs.isEmpty else { continue }
            out.append(ConversionQuery(amount: amount, from: from, to: rhs))
        }
        return out
    }

    // "100km" -> (100, "km"); "72" -> (72, ""); "1,500.5" -> (1500.5, "").
    private static func splitAmount(_ token: String) -> (Double, String)? {
        var numeric = ""
        var rest = token[token.startIndex...]
        if rest.first == "-" { numeric = "-"; rest = rest.dropFirst() }
        let head = rest.prefix { $0.isNumber || $0 == "." || $0 == "," }
        guard !head.isEmpty else { return nil }
        numeric += head.replacingOccurrences(of: ",", with: "")
        guard let value = Double(numeric) else { return nil }
        return (value, String(rest.dropFirst(head.count)))
    }
}
