import Foundation

// MARK: - Frecency

final class Frecency {
    struct Entry: Codable { var count: Int; var lastUsed: Double }

    private var data: [String: Entry] = [:]
    private let path: URL
    private let lambda: Double

    init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/pounce")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.path = dir.appendingPathComponent("frecency.json")
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

    func score(for key: String) -> Double {
        guard let entry = data[key] else { return 0 }
        let age = Date().timeIntervalSince1970 - entry.lastUsed
        return Double(entry.count) * exp(-lambda * age)
    }

    func record(_ key: String) {
        var entry = data[key] ?? Entry(count: 0, lastUsed: 0)
        entry.count += 1
        entry.lastUsed = Date().timeIntervalSince1970
        data[key] = entry
        save()
    }
}
