import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Currency conversions ("100 usd in eur", "$100 in gbp", "50 euros in yen")

// The one quick-answer engine that needs external data, and the reference
// implementation of the contract's cache pattern (QuickAnswer.swift):
// `evaluate` only reads CurrencyRates' in-memory table — the daemon warms it
// in the background (disk cache first, then the network when stale) and a
// keystroke is never blocked on I/O. Cold cache → nil → the query stays an
// ordinary search until rates arrive.
//
// Rates are the ECB daily reference set via api.frankfurter.app (no key, no
// account) — pounce's ONLY outbound network call, so it's gated behind
// `quickAnswers.currency` in config.json for the fully-offline crowd.

struct CurrencyEngine: QuickAnswerEngine {
    func evaluate(_ query: String) -> QuickAnswer? {
        let store = CurrencyRates.shared
        guard !store.rates.isEmpty else { return nil }
        for candidate in ConversionQuery.parse(CurrencySyntax.normalize(query)) {
            guard let from = CurrencySyntax.code(candidate.from),
                  let to = CurrencySyntax.code(candidate.to),
                  let rateFrom = store.rate(from),
                  let rateTo = store.rate(to)
            else { continue }
            let value = candidate.amount / rateFrom * rateTo
            guard value.isFinite else { continue }
            let toName = CalcFormat.locale.localizedString(forCurrencyCode: to) ?? to
            return QuickAnswer(
                display: "\(Self.money(value, grouping: true)) \(to)",
                detail: "\(Self.money(candidate.amount, grouping: true)) \(from) → \(toName) · ECB \(store.asOf)",
                icon: "dollarsign.circle",
                copyText: Self.money(value, grouping: false))
        }
        return nil
    }

    // Fiat convention: up to 2 fraction digits; sub-unit amounts (1 jpy in
    // usd) fall back to significant digits so they don't round to "0.01".
    private static func money(_ v: Double, grouping: Bool) -> String {
        if abs(v) >= 1 || v == 0 {
            let f = NumberFormatter()
            f.locale = CalcFormat.locale
            f.numberStyle = .decimal
            f.usesGroupingSeparator = grouping
            f.minimumFractionDigits = 0
            f.maximumFractionDigits = 2
            return f.string(from: NSNumber(value: v)) ?? String(v)
        }
        return grouping ? CalcFormat.display(v, maxSignificant: 4)
                        : CalcFormat.copyText(v, maxSignificant: 4)
    }
}

// MARK: - Query vocabulary

enum CurrencySyntax {
    static let symbols: [Character: String] = [
        "$": "usd", "€": "eur", "£": "gbp", "¥": "jpy", "₹": "inr", "₩": "krw",
    ]

    static let names: [String: String] = [
        "dollar": "usd", "dollars": "usd", "buck": "usd", "bucks": "usd",
        "euro": "eur", "euros": "eur",
        "pound": "gbp", "pounds": "gbp", "quid": "gbp", "sterling": "gbp",
        "yen": "jpy", "franc": "chf", "francs": "chf",
        "rupee": "inr", "rupees": "inr",
        "yuan": "cny", "rmb": "cny", "renminbi": "cny",
        "won": "krw", "zloty": "pln",
        "krona": "sek", "kronor": "sek",
        "real": "brl", "reais": "brl",
    ]

    // "$100 in eur" / "100$ in eur" → "100 usd in eur", so ConversionQuery's
    // number-first shape applies unchanged.
    static func normalize(_ query: String) -> String {
        var words = query.split(separator: " ").map(String.init)
        guard let first = words.first, !first.isEmpty else { return query }
        if let sym = first.first, let code = symbols[sym],
           first.dropFirst().first?.isNumber == true {
            words[0] = String(first.dropFirst())
            words.insert(code, at: 1)
        } else if let sym = first.last, let code = symbols[sym],
                  first.first?.isNumber == true {
            words[0] = String(first.dropLast())
            words.insert(code, at: 1)
        }
        return words.joined(separator: " ")
    }

    // Currency token → ISO code candidate. Any 3-letter word qualifies; the
    // engine's rate lookup is the real validator ("xyz" resolves here, then
    // finds no rate). Names cover the common spoken forms; "pound" the mass
    // never reaches us — the unit engine runs first and wins when both sides
    // are units.
    static func code(_ token: String) -> String? {
        if let named = names[token] { return named.uppercased() }
        guard token.count == 3, token.allSatisfy({ $0.isLetter }) else { return nil }
        return token.uppercased()
    }
}

// MARK: - Rates cache

// In-memory ECB reference rates (ISO code → units per EUR), read by the
// engine on the main thread per keystroke and written on the main thread
// only (background work hops back), so no locking. Persisted to disk so a
// daemon restart keeps answering offline with the last known rates.
final class CurrencyRates {
    static let shared = CurrencyRates()

    private(set) var rates: [String: Double] = [:]
    private(set) var asOf = ""            // the feed's own date stamp, shown in the detail line
    private var fetchedAt: Date?
    private var fetching = false

    static let endpoint = URL(string: "https://api.frankfurter.app/latest")!
    static let maxAge: TimeInterval = 12 * 3600
    static var cachePath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/pounce/currency-rates.json")
    }

    func rate(_ code: String) -> Double? { rates[code] }

    // Also the test seam: suites inject a fixed table instead of fetching.
    func install(_ newRates: [String: Double], asOf date: String, fetchedAt: Date = Date()) {
        var r: [String: Double] = [:]
        for (code, value) in newRates { r[code.uppercased()] = value }
        r["EUR"] = 1
        rates = r
        asOf = date
        self.fetchedAt = fetchedAt
    }

    // Non-blocking refresh; safe to call repeatedly (daemon start + a 6h
    // timer). Must be called from the main thread.
    func warm() {
        if let f = fetchedAt, Date().timeIntervalSince(f) < Self.maxAge { return }
        if fetching { return }
        fetching = true
        DispatchQueue.global(qos: .utility).async {
            // Disk first: a restart shouldn't lose answers while offline.
            if let disk = Self.readDisk() {
                DispatchQueue.main.async {
                    if self.rates.isEmpty {
                        self.install(disk.rates, asOf: disk.asOf, fetchedAt: disk.fetchedAt)
                    }
                }
                if Date().timeIntervalSince(disk.fetchedAt) < Self.maxAge {
                    DispatchQueue.main.async { self.fetching = false }
                    return
                }
            }
            self.fetchRemote()
        }
    }

    private func fetchRemote() {
        URLSession.shared.dataTask(with: Self.endpoint) { data, _, _ in
            defer { DispatchQueue.main.async { self.fetching = false } }
            guard let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rates = obj["rates"] as? [String: Double],
                  let date = obj["date"] as? String,
                  !rates.isEmpty
            else { return }
            let now = Date()
            DispatchQueue.main.async { self.install(rates, asOf: date, fetchedAt: now) }
            Self.writeDisk(rates: rates, asOf: date, fetchedAt: now)
        }.resume()
    }

    private struct DiskCache {
        let rates: [String: Double]
        let asOf: String
        let fetchedAt: Date
    }

    private static func readDisk() -> DiskCache? {
        guard let data = try? Data(contentsOf: cachePath),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rates = obj["rates"] as? [String: Double],
              let asOf = obj["asOf"] as? String,
              let epoch = obj["fetchedAt"] as? Double
        else { return nil }
        return DiskCache(rates: rates, asOf: asOf, fetchedAt: Date(timeIntervalSince1970: epoch))
    }

    private static func writeDisk(rates: [String: Double], asOf: String, fetchedAt: Date) {
        let obj: [String: Any] = [
            "rates": rates, "asOf": asOf, "fetchedAt": fetchedAt.timeIntervalSince1970,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        try? FileManager.default.createDirectory(at: cachePath.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: cachePath, options: .atomic)
    }
}
