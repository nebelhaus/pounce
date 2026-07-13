import Foundation

// MARK: - App Scanner
//
// Two sources feed the launcher's app list, unioned so neither can hide an app:
//
//   1. A synchronous filesystem walk of the standard Applications dirs. Always
//      available with zero warm-up, so the very first ⌘Space — before Spotlight
//      has answered, or on a Mac with indexing disabled — still lists every app
//      installed the normal way.
//
//   2. A live Spotlight index (NSMetadataQuery) of every app bundle the system
//      knows, wherever it lives on disk. This is what makes pounce match
//      Spotlight: an app dropped in an odd folder, a Setapp/`nix`-store copy, an
//      installer that skips /Applications — all surface without hardcoding their
//      location. The query stays live, so apps installed or removed while the
//      daemon runs update the list within seconds, no restart needed.
//
// apps() returns the union deduped by (symlink-resolved) path, filesystem entry
// winning a clash so the launch path stays canonical. An empty/late Spotlight
// snapshot never blanks the list — the filesystem scan is the floor.

final class AppScanner {
    static let shared = AppScanner()

    // `helper` flags background/bridge apps that should never appear (see isHelper).
    private struct Meta { let name: String; let bundleId: String; let ctime: Double; let helper: Bool }
    // A Spotlight hit kept raw (no boost baked in) so the recency boost and the
    // demotion penalty are recomputed per apps() call, against the live config
    // and clock rather than frozen at gather time. Helpers are dropped at gather
    // time (see rebuildSpotlight), so a SpotApp is always a launchable app.
    private struct SpotApp { let name: String; let path: String; let bundleId: String; let added: Double }

    private var cache: [String: Meta] = [:]           // path -> metadata (fs scan)
    private var spotlight: [SpotApp]? = nil            // nil until the first gather
    private var query: NSMetadataQuery?
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

    // Fold the install-recency boost together with a demotion penalty for junk
    // apps. A freshly installed demoted app still surfaces (boost 1000 ≫ 5) until
    // that boost decays; after that only frecency can lift it back.
    private func makeApp(name: String, path: String, bundleId: String,
                         age: Double, demoted: Set<String>) -> PounceItem {
        let b = boost(forAge: age) - (demoted.contains(bundleId) ? Self.demotionPenalty : 0)
        return .app(name: name, path: path, boost: b)
    }

    // Stable dedupe key: resolve symlinks so a nix-store app symlinked into
    // ~/Applications and its store-path twin collapse to one entry.
    private func dedupeKey(for item: PounceItem) -> String {
        URL(fileURLWithPath: item.payload).resolvingSymlinksInPath().standardizedFileURL.path
    }

    // The launcher's app list: filesystem scan ∪ live Spotlight index.
    // `hiddenBundleIds` (config: apps.hideBundleIds) drops apps entirely, on top
    // of the built-in helper filter (isHelper) applied to both sources.
    func apps(demotedBundleIds: Set<String> = defaultDemotedBundleIds,
              hiddenBundleIds: Set<String> = []) -> [PounceItem] {
        let now = Date().timeIntervalSince1970
        let fs = filesystemApps(demotedBundleIds: demotedBundleIds,
                                hiddenBundleIds: hiddenBundleIds, now: now)

        lock.lock(); let spot = spotlight; lock.unlock()
        let spotItems: [PounceItem] = (spot ?? [])
            .filter { !hiddenBundleIds.contains($0.bundleId) }
            .map {
                makeApp(name: $0.name, path: $0.path, bundleId: $0.bundleId,
                        age: now - $0.added, demoted: demotedBundleIds)
            }
        guard !spotItems.isEmpty else { return fs }

        var byKey: [String: PounceItem] = [:]
        var order: [String] = []
        // Spotlight first, filesystem second: on a key clash the filesystem entry
        // overwrites, keeping the canonical /Applications launch path and the
        // display name read from the very bundle we're about to launch.
        for item in spotItems + fs {
            let key = dedupeKey(for: item)
            if byKey[key] == nil { order.append(key) }
            byKey[key] = item
        }
        return order.compactMap { byKey[$0] }
    }

    private func filesystemApps(demotedBundleIds: Set<String>,
                                hiddenBundleIds: Set<String>, now: Double) -> [PounceItem] {
        let fm = FileManager.default
        var seen = Set<String>()
        var result: [PounceItem] = []

        lock.lock(); defer { lock.unlock() }

        for dir in searchDirs {
            let keys: [URLResourceKey] = [.isDirectoryKey, .creationDateKey]
            guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: keys,
                                         options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
                // A missing ~/Applications is normal; anything else is a real
                // gap that would silently drop that dir's apps, so log it.
                if fm.fileExists(atPath: dir.path) {
                    NSLog("pounce AppScanner: could not enumerate \(dir.path)")
                }
                continue
            }
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
                // Drop background/bridge helpers (see isHelper) and anything the
                // user pinned to the hide list — neither is a launchable target.
                if meta.helper { continue }
                if hiddenBundleIds.contains(meta.bundleId) { continue }
                result.append(makeApp(name: meta.name, path: path, bundleId: meta.bundleId,
                                      age: now - ctime, demoted: demotedBundleIds))
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
        return Meta(name: name, bundleId: bundleId, ctime: ctime, helper: isHelper(info))
    }

    // Helper/bridge apps that clutter the palette without being things you'd
    // ever launch: pure background agents (LSBackgroundOnly — e.g. Anthropic's
    // "Claude Code URL Handler", which exists only to catch claude:// links) and
    // AppleScript droplets (executable "droplet" — e.g. the nebelhaus EditorOpen
    // file-open bridge). Deliberately NOT gated on LSUIElement: plenty of real
    // menu-bar apps set that yet are worth launching, so filtering it would hide
    // apps the user wants. Mirrors what Launchpad hides.
    private func isHelper(_ info: [String: Any]?) -> Bool {
        guard let info else { return false }
        if info["LSBackgroundOnly"] as? Bool == true { return true }
        if let s = info["LSBackgroundOnly"] as? String, s == "1" || s.lowercased() == "true" { return true }
        if info["CFBundleExecutable"] as? String == "droplet" { return true }
        return false
    }

    // Spotlight gives us a path but not the Info.plist keys isHelper needs, so
    // read the bundle to apply the same filter to the Spotlight source.
    private func isHelperBundle(atPath path: String) -> Bool {
        isHelper(Bundle(url: URL(fileURLWithPath: path))?.infoDictionary)
    }

    // MARK: Spotlight source

    // Keep only top-level, user-launchable apps. A raw "every app bundle" query
    // is dominated by nested helpers (…/Foo.app/Contents/…/Bar.app), framework
    // internals under /Library, and build artifacts — none of which a person
    // launches by name, all of which would drown the palette.
    private func spotlightAccepts(path: String) -> Bool {
        guard path.hasSuffix(".app") else { return false }
        let parent = (path as NSString).deletingLastPathComponent
        if parent.hasSuffix(".app") || parent.contains(".app/") { return false }
        let lower = path.lowercased()
        for bad in ["/library/", "/nix/store/", "/.trash/", "/private/",
                    "/deriveddata/", "/node_modules/", "/.build/"] {
            if lower.contains(bad) { return false }
        }
        return true
    }

    private func rebuildSpotlight(from query: NSMetadataQuery) {
        query.disableUpdates()
        var items: [SpotApp] = []
        for i in 0..<query.resultCount {
            guard let item = query.result(at: i) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
                  spotlightAccepts(path: path),
                  !isHelperBundle(atPath: path) else { continue }

            var name = (item.value(forAttribute: NSMetadataItemDisplayNameKey) as? String)
                ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            if name.hasSuffix(".app") { name = String(name.dropLast(4)) }

            let bundleId = (item.value(forAttribute: "kMDItemCFBundleIdentifier") as? String) ?? ""
            // "Added to the system" is the right recency signal for the new-app
            // boost; fall back to the bundle's creation date.
            let added = (item.value(forAttribute: "kMDItemDateAdded") as? Date)?.timeIntervalSince1970
                ?? (item.value(forAttribute: NSMetadataItemFSCreationDateKey) as? Date)?.timeIntervalSince1970
                ?? 0
            items.append(SpotApp(name: name, path: path, bundleId: bundleId, added: added))
        }
        query.enableUpdates()
        lock.lock(); spotlight = items; lock.unlock()
    }

    @objc private func spotlightUpdated(_ note: Notification) {
        guard let q = note.object as? NSMetadataQuery else { return }
        rebuildSpotlight(from: q)
    }

    // Start the live app index. NSMetadataQuery drives itself off a run loop and
    // posts on the thread it was started from, so anchor it on main.
    private func startSpotlight() {
        DispatchQueue.main.async {
            guard self.query == nil else { return }
            let q = NSMetadataQuery()
            q.predicate = NSPredicate(format: "kMDItemContentTypeTree == 'com.apple.application-bundle'")
            q.searchScopes = [NSMetadataQueryLocalComputerScope]
            let nc = NotificationCenter.default
            nc.addObserver(self, selector: #selector(self.spotlightUpdated(_:)),
                           name: .NSMetadataQueryDidFinishGathering, object: q)
            nc.addObserver(self, selector: #selector(self.spotlightUpdated(_:)),
                           name: .NSMetadataQueryDidUpdate, object: q)
            self.query = q
            if !q.start() {
                NSLog("pounce AppScanner: Spotlight app query failed to start; filesystem scan only")
            }
        }
    }

    // Warm both sources at startup: prime the filesystem name/bundle-id cache off
    // the main thread and kick off the live Spotlight query.
    func warm() {
        DispatchQueue.global(qos: .utility).async {
            _ = self.filesystemApps(demotedBundleIds: Self.defaultDemotedBundleIds,
                                    hiddenBundleIds: [], now: Date().timeIntervalSince1970)
        }
        startSpotlight()
    }
}
