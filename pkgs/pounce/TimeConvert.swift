import Foundation

// MARK: - Timezone conversions ("14:00 utc in pst", "9pm in tokyo")

// Quick-answer engine for `TIME [ZONE] in ZONE` queries. The source zone is
// optional (defaults to the local zone: "3pm in tokyo"). Zones resolve from a
// curated abbreviation map, then GMT offsets ("utc+5:30"), then any IANA
// identifier or city name ("america/new_york", "new york", "tokyo").
//
// All date math is deterministic against an injected `Date` so tests can pin
// a day (DST!) — the keystroke path just passes the current instant.

struct TimeZoneEngine: QuickAnswerEngine {
    func evaluate(_ query: String) -> QuickAnswer? {
        evaluate(query, on: Date())
    }

    func evaluate(_ query: String, on now: Date) -> QuickAnswer? {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        for sep in [" in ", " to "] {
            guard let range = q.range(of: sep) else { continue }
            let lhs = String(q[..<range.lowerBound])
            let rhs = String(q[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            guard let (time, sourceRaw) = ZoneParse.time(from: lhs) else { continue }
            let source: ZoneParse.Zone
            if sourceRaw.isEmpty {
                source = ZoneParse.Zone(tz: .current, label: "local")
            } else if let z = ZoneParse.zone(sourceRaw) {
                source = z
            } else {
                continue
            }
            guard let dest = ZoneParse.zone(rhs) else { continue }
            return answer(time: time, from: source, to: dest, on: now)
        }
        return nil
    }

    private func answer(time: ZoneParse.Time, from source: ZoneParse.Zone,
                        to dest: ZoneParse.Zone, on now: Date) -> QuickAnswer? {
        var sourceCal = Calendar(identifier: .gregorian)
        sourceCal.timeZone = source.tz
        var comps = sourceCal.dateComponents([.year, .month, .day], from: now)
        comps.hour = time.hour
        comps.minute = time.minute
        guard let instant = sourceCal.date(from: comps) else { return nil }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = dest.tz
        formatter.dateFormat = "h:mm a"
        var display = formatter.string(from: instant)

        // Crossing midnight is the detail people get wrong — call it out.
        var destCal = Calendar(identifier: .gregorian)
        destCal.timeZone = dest.tz
        let d1 = sourceCal.dateComponents([.year, .month, .day], from: instant)
        let d2 = destCal.dateComponents([.year, .month, .day], from: instant)
        let key = { (c: DateComponents) in (c.year! * 100 + c.month!) * 100 + c.day! }
        if key(d2) > key(d1) { display += " (next day)" }
        if key(d2) < key(d1) { display += " (prev day)" }

        let destAbbrev = dest.tz.abbreviation(for: instant).map { " (\($0))" } ?? ""
        return QuickAnswer(
            display: display,
            detail: "\(time.text) \(source.label) → \(dest.label)\(destAbbrev)",
            icon: "clock",
            copyText: display)
    }
}

enum ZoneParse {
    struct Time {
        let hour: Int
        let minute: Int
        var text: String { String(format: "%d:%02d", hour, minute) }
    }

    struct Zone {
        let tz: TimeZone
        let label: String
    }

    // "2:30pm est" -> (14:30, "est"); "14:00" -> (14:00, ""). nil if the
    // string doesn't start with a plausible clock time.
    static func time(from input: String) -> (Time, String)? {
        var rest = input.trimmingCharacters(in: .whitespaces)[...]
        let digits = rest.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 2, let hourRaw = Int(digits) else { return nil }
        rest = rest.dropFirst(digits.count)

        var minute = 0
        if rest.first == ":" {
            let m = rest.dropFirst().prefix { $0.isNumber }
            guard m.count == 2, let parsed = Int(m), parsed <= 59 else { return nil }
            minute = parsed
            rest = rest.dropFirst(1 + m.count)
        }

        var hour = hourRaw
        var meridiem = rest.trimmingCharacters(in: .whitespaces)[...]
        if meridiem.hasPrefix("am") || meridiem.hasPrefix("pm") {
            guard (1...12).contains(hourRaw) else { return nil }
            if meridiem.hasPrefix("pm") { hour = hourRaw == 12 ? 12 : hourRaw + 12 }
            else { hour = hourRaw == 12 ? 0 : hourRaw }
            meridiem = meridiem.dropFirst(2)
        } else {
            guard hourRaw <= 23 else { return nil }
        }

        let zone = meridiem.trimmingCharacters(in: .whitespaces)
        return (Time(hour: hour, minute: minute), zone)
    }

    // Common abbreviations, pinned so the answer is deterministic (Apple's
    // own abbreviation table shifts between OS releases). Ambiguous ones take
    // the majority reading (IST → India, CST → US Central).
    static let abbreviations: [String: String] = [
        "utc": "UTC", "gmt": "GMT", "z": "UTC",
        "pst": "America/Los_Angeles", "pdt": "America/Los_Angeles", "pt": "America/Los_Angeles",
        "mst": "America/Denver", "mdt": "America/Denver",
        "cst": "America/Chicago", "cdt": "America/Chicago", "ct": "America/Chicago",
        "est": "America/New_York", "edt": "America/New_York", "et": "America/New_York",
        "ast": "America/Halifax", "brt": "America/Sao_Paulo",
        "bst": "Europe/London", "wet": "Europe/Lisbon",
        "cet": "Europe/Paris", "cest": "Europe/Paris",
        "eet": "Europe/Athens", "eest": "Europe/Athens", "msk": "Europe/Moscow",
        "ist": "Asia/Kolkata", "gst": "Asia/Dubai", "sgt": "Asia/Singapore",
        "hkt": "Asia/Hong_Kong", "jst": "Asia/Tokyo", "kst": "Asia/Seoul",
        "aest": "Australia/Sydney", "aedt": "Australia/Sydney",
        "awst": "Australia/Perth", "nzst": "Pacific/Auckland", "nzdt": "Pacific/Auckland",
    ]

    // lowercased identifier ("asia/tokyo") and city ("tokyo", "new york") →
    // canonical IANA identifier. Sorted source so collisions resolve stably.
    static let identifiers: [String: String] = {
        var t: [String: String] = [:]
        for id in TimeZone.knownTimeZoneIdentifiers.sorted() {
            t[id.lowercased()] = t[id.lowercased()] ?? id
            if let city = id.split(separator: "/").last {
                let key = city.replacingOccurrences(of: "_", with: " ").lowercased()
                t[key] = t[key] ?? id
            }
        }
        return t
    }()

    static func zone(_ raw: String) -> Zone? {
        let token = raw.trimmingCharacters(in: .whitespaces)
        guard !token.isEmpty else { return nil }
        if token == "local" || token == "here" {
            return Zone(tz: .current, label: "local")
        }
        if let id = abbreviations[token], let tz = TimeZone(identifier: id) {
            return Zone(tz: tz, label: token.uppercased())
        }
        // "utc+5:30", "gmt-8"
        if token.hasPrefix("utc") || token.hasPrefix("gmt") {
            let offset = String(token.dropFirst(3))
            if let seconds = parseOffset(offset), let tz = TimeZone(secondsFromGMT: seconds) {
                return Zone(tz: tz, label: token.uppercased())
            }
        }
        if let id = identifiers[token], let tz = TimeZone(identifier: id) {
            return Zone(tz: tz, label: id)
        }
        return nil
    }

    private static func parseOffset(_ s: String) -> Int? {
        guard let sign = s.first, sign == "+" || sign == "-" else { return nil }
        let parts = s.dropFirst().split(separator: ":", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count),
              let hours = Int(parts[0]), (0...14).contains(hours) else { return nil }
        var minutes = 0
        if parts.count == 2 {
            guard let m = Int(parts[1]), (0...59).contains(m) else { return nil }
            minutes = m
        }
        let total = hours * 3600 + minutes * 60
        return sign == "-" ? -total : total
    }
}
