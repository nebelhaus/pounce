import Foundation

// MARK: - Frecency

final class Frecency {
    struct Entry: Codable { var count: Int; var lastUsed: Double }

    private var data: [String: Entry] = [:]
    private let path: URL
    private let lambda: Double

    // Each consumer gets its own file: two live Frecency instances sharing one
    // path would clobber each other's whole-file writes (the launcher and the
    // window switcher both run inside the daemon).
    init(filename: String = "frecency.json") {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/pounce")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.path = dir.appendingPathComponent(filename)
        self.lambda = log(2.0) / (72 * 3600)
        load()
    }

    private func load() {
        guard let raw = try? Data(contentsOf: path),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: raw) else { return }
        data = decoded
    }

    private func save() {
        guard let encoded = try? JSONEncoder().encode(data) else { return }
        try? encoded.write(to: path, options: .atomic)
    }

    // Pure decay math, split out so it can be unit-tested without touching the
    // filesystem or the wall clock: score = count · e^(−λ·age). With
    // λ = ln2 / 72h, one 72-hour gap halves an entry's weight.
    static func decayedScore(count: Int, lastUsed: Double, now: Double, lambda: Double) -> Double {
        Double(count) * exp(-lambda * (now - lastUsed))
    }

    func score(for key: String) -> Double {
        guard let entry = data[key] else { return 0 }
        return Self.decayedScore(
            count: entry.count,
            lastUsed: entry.lastUsed,
            now: Date().timeIntervalSince1970,
            lambda: lambda
        )
    }

    func record(_ key: String) {
        var entry = data[key] ?? Entry(count: 0, lastUsed: 0)
        entry.count += 1
        entry.lastUsed = Date().timeIntervalSince1970
        data[key] = entry
        save()
    }
}
