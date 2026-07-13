import Foundation

// MARK: - App Scanner

final class AppScanner {
    static let shared = AppScanner()

    private struct Meta { let name: String; let bundleId: String; let ctime: Double }
    private var cache: [String: Meta] = [:]          // path -> metadata
    private let lock = NSLock()

    // Rarely-launched apps get pushed below everything at an empty query, so they
    // never squat the top slot on their own. It's a soft demotion: the penalty is
    // sized to the frecency scale (see Frecency: steady daily use lands in the
    // single digits), so actually using one lifts it back — "rely on frequency to
    // move up at all". Typed search is unaffected: matchScore only reads
    // baseBoost > 0, so a negative boost is treated as neutral there.
    static let demotionPenalty = 5.0

    // Curated default: the Apple system utilities nobody opens from a palette.
    // User-extendable / clearable via config (apps.demoteBundleIds). Unknown ids
    // are harmless no-ops, so the list can afford to be generous.
    static let defaultDemotedBundleIds: Set<String> = [
        "com.apple.appleseed.FeedbackAssistant",  // Feedback Assistant
        "com.apple.AudioMIDISetup",               // Audio MIDI Setup
        "com.apple.ColorSyncUtility",             // ColorSync Utility
        "com.apple.DigitalColorMeter",            // Digital Color Meter
        "com.apple.grapher",                      // Grapher
        "com.apple.BluetoothFileExchange",        // Bluetooth File Exchange
        "com.apple.bootcampassistant",            // Boot Camp Assistant
        "com.apple.MigrateAssistant",             // Migration Assistant
        "com.apple.ScriptEditor2",                // Script Editor
        "com.apple.ScreenSharing",                // Screen Sharing
        "com.apple.VoiceOverUtility",             // VoiceOver Utility
        "com.apple.SystemProfiler",               // System Information
        "com.apple.TicketViewer",                 // Ticket Viewer
    ]

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

    func apps(demotedBundleIds: Set<String> = defaultDemotedBundleIds) -> [PounceItem] {
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

                let meta: Meta
                if let m = cache[path], m.ctime == ctime {
                    meta = m
                } else {
                    meta = metadata(for: url, ctime: ctime)
                    cache[path] = meta
                }
                // Install-recency boost minus a demotion penalty for junk apps. A
                // freshly installed demoted app still surfaces (boost 1000 ≫ 5)
                // until that boost decays; after that only frecency can lift it.
                let demoted = demotedBundleIds.contains(meta.bundleId)
                let boost = boost(forAge: now - ctime) - (demoted ? Self.demotionPenalty : 0)
                result.append(.app(name: meta.name, path: path, boost: boost))
            }
        }
        return result
    }

    private func metadata(for url: URL, ctime: Double) -> Meta {
        let info = Bundle(url: url)?.infoDictionary
        let name: String = {
            if let n = info?["CFBundleDisplayName"] as? String, !n.isEmpty { return n }
            if let n = info?["CFBundleName"] as? String, !n.isEmpty { return n }
            return url.deletingPathExtension().lastPathComponent
        }()
        let bundleId = (info?["CFBundleIdentifier"] as? String) ?? ""
        return Meta(name: name, bundleId: bundleId, ctime: ctime)
    }

    // Warm the cache off the main thread at startup.
    func warm() {
        DispatchQueue.global(qos: .utility).async { _ = self.apps() }
    }
}
