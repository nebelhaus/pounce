import Foundation

// MARK: - App Scanner

final class AppScanner {
    static let shared = AppScanner()

    private struct Meta { let name: String; let ctime: Double }
    private var cache: [String: Meta] = [:]          // path -> metadata
    private let lock = NSLock()

    private let searchDirs: [URL] = {
        var dirs = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/System/Applications/Utilities"),
        ]
        dirs.append(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"))
        return dirs
    }()

    // Boost freshly-installed apps so they surface at the top, decaying over a week.
    private func boost(forAge age: Double) -> Double {
        let week = 7.0 * 86400
        guard age >= 0, age < week else { return 0 }
        let halfLife = 2.0 * 86400
        return 1000.0 * exp(-log(2.0) / halfLife * age)
    }

    func apps() -> [PounceItem] {
        let fm = FileManager.default
        let now = Date().timeIntervalSince1970
        var seen = Set<String>()
        var result: [PounceItem] = []

        lock.lock(); defer { lock.unlock() }

        for dir in searchDirs {
            let keys: [URLResourceKey] = [.isDirectoryKey, .creationDateKey]
            guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: keys,
                                         options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            while let url = en.nextObject() as? URL {
                guard url.pathExtension == "app" else { continue }
                let path = url.path
                if seen.contains(path) { continue }
                seen.insert(path)

                let ctime = (try? url.resourceValues(forKeys: [.creationDateKey]))?
                    .creationDate?.timeIntervalSince1970 ?? 0

                let name: String
                if let m = cache[path], m.ctime == ctime {
                    name = m.name
                } else {
                    name = displayName(for: url)
                    cache[path] = Meta(name: name, ctime: ctime)
                }
                result.append(.app(name: name, path: path, boost: boost(forAge: now - ctime)))
            }
        }
        return result
    }

    private func displayName(for url: URL) -> String {
        if let info = Bundle(url: url)?.infoDictionary {
            if let n = info["CFBundleDisplayName"] as? String, !n.isEmpty { return n }
            if let n = info["CFBundleName"] as? String, !n.isEmpty { return n }
        }
        return url.deletingPathExtension().lastPathComponent
    }

    // Warm the cache off the main thread at startup.
    func warm() {
        DispatchQueue.global(qos: .utility).async { _ = self.apps() }
    }
}
