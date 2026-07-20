import Foundation

// MARK: - File Search
//
// The launcher's "Find Files" mode: a Spotlight-style search for files & folders
// by name, live as you type. Same machinery AppScanner uses for apps
// (NSMetadataQuery — the API behind Spotlight / `mdfind`), but pointed at files
// and driven by the typed query instead of a fixed "all app bundles" predicate.
//
//   keystroke ──▶ search(query) ──(debounce)──▶ NSMetadataQuery(name LIKE *q*)
//              ──▶ DidFinishGathering ──▶ filter noise ──▶ rank ──▶ onUpdate(hits)
//
// Read-only by construction: the mode only ever opens / reveals / copies the
// path of a hit (see DaemonState.commitFile) — never moves or deletes. The query
// is a per-search restart (stop → set predicate → start), so nothing keeps
// running once the palette closes (DaemonState.reset → stop()).
//
// Foundation-only on purpose (no AppKit/SwiftUI): the ranking is pure and the
// query is Foundation, so this file stays a plain-swiftc compile like the
// quick-answer engines — the AppKit side (icons, open/reveal/copy) lives in the
// view and DaemonState.

// A single file/folder hit, kept minimal: everything the row needs to render and
// everything commit needs to act. `id` is the path (stable, unique per result)
// so SwiftUI diffs the list cleanly as async results stream in.
struct FileHit: Identifiable {
    var id: String { path }
    let name: String          // the display / file-system name ("report.pdf")
    let path: String          // absolute path
    let parent: String        // abbreviated containing dir ("~/Documents/Work")
    let isDirectory: Bool
    let modified: Double       // content-change date, for the recency tiebreak
}

final class FileSearchController {
    // Frecency lookup, injected so this file stays Foundation-only and the store
    // stays owned by DaemonState. Called on the main thread (where the query
    // runs), matching Frecency's single-thread contract.
    private let frecency: (String) -> Double
    // Published back to DaemonState: (hits, stillSearching). Invoked on main.
    var onUpdate: (([FileHit], Bool) -> Void)?

    // Config, set at mode entry from Settings.fileSearch.
    var maxResults = 60
    var homeOnly = true

    private var query: NSMetadataQuery?
    private var debounce: DispatchWorkItem?
    private var lastQuery = ""

    // Below this length a query would match a firehose of files, so we don't run
    // it — the view shows a hint instead.
    static let minQueryLength = 2
    // Debounce so a fast typist restarts the Spotlight query once, when they
    // pause, not once per keystroke.
    static let debounceSeconds = 0.14
    // Cap the results we inspect: NSMetadataQuery is sorted newest-first, so the
    // first slice already holds the freshest matches; scanning all of a
    // many-thousand-hit set on the main thread would stutter for no gain.
    static let scanCap = 500

    init(frecency: @escaping (String) -> Double) {
        self.frecency = frecency
    }

    // MARK: Driving the search

    // Kick a search for the current query. Debounced; a query shorter than
    // minQueryLength clears the results (and drops any running query) so the
    // mode returns to its empty/hint state.
    func search(_ raw: String) {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        lastQuery = q
        debounce?.cancel()

        guard q.count >= Self.minQueryLength else {
            stopQuery()
            onUpdate?([], false)
            return
        }

        onUpdate?([], true)   // show "searching" until the first gather lands
        let work = DispatchWorkItem { [weak self] in self?.start(query: q) }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounceSeconds, execute: work)
    }

    // (Re)start the live query for `q`. NSMetadataQuery drives itself off the run
    // loop and must be started on a run-loop thread, so this runs on main (the
    // debounce fires there).
    private func start(query q: String) {
        let query = self.query ?? makeQuery()
        query.stop()

        // Match the name as a case/diacritic-insensitive substring — the "I
        // half-remember what it's called" search. A user's own `*`/`?` fall
        // through as globs, a small power-user bonus; backslashes are stripped so
        // they can't break the predicate.
        let needle = "*" + q.replacingOccurrences(of: "\\", with: "") + "*"
        query.predicate = NSPredicate(format: "kMDItemFSName LIKE[cd] %@", needle)
        query.searchScopes = homeOnly
            ? [FileManager.default.homeDirectoryForCurrentUser.path]
            : [NSMetadataQueryLocalComputerScope]
        query.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemFSContentChangeDateKey,
                                                  ascending: false)]
        if !query.start() {
            NSLog("pounce FileSearch: query failed to start")
            onUpdate?([], false)
        }
    }

    private func makeQuery() -> NSMetadataQuery {
        let q = NSMetadataQuery()
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(gathered(_:)),
                       name: .NSMetadataQueryDidFinishGathering, object: q)
        nc.addObserver(self, selector: #selector(gathered(_:)),
                       name: .NSMetadataQueryDidUpdate, object: q)
        self.query = q
        return q
    }

    @objc private func gathered(_ note: Notification) {
        guard let q = note.object as? NSMetadataQuery else { return }
        q.disableUpdates()
        var hits: [FileHit] = []
        let limit = min(q.resultCount, Self.scanCap)
        for i in 0..<limit {
            guard let item = q.result(at: i) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
                  Self.accepts(path: path) else { continue }
            let name = (item.value(forAttribute: NSMetadataItemFSNameKey) as? String)
                ?? (path as NSString).lastPathComponent
            let isDir = (item.value(forAttribute: NSMetadataItemContentTypeTreeKey) as? [String])?
                .contains("public.folder") ?? false
            let modified = (item.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as? Date)?
                .timeIntervalSince1970 ?? 0
            hits.append(FileHit(name: name, path: path, parent: Self.abbreviate(parentOf: path),
                                isDirectory: isDir, modified: modified))
        }
        q.enableUpdates()

        let ranked = Self.rank(hits, query: lastQuery, now: Date().timeIntervalSince1970,
                               frecency: frecency)
        onUpdate?(Array(ranked.prefix(maxResults)), false)
    }

    private func stopQuery() {
        query?.stop()
    }

    // Full teardown: cancel any pending search and stop the live query so nothing
    // keeps hitting the metadata index once the palette is dismissed.
    func stop() {
        debounce?.cancel()
        debounce = nil
        stopQuery()
    }

    // MARK: Noise filter
    //
    // A raw name query is dominated by things nobody means when they search for
    // "a file": framework internals, caches, package contents, VCS guts, build
    // output. Drop them so the list reads as the user's own documents — the same
    // spirit as AppScanner.spotlightAccepts, tuned for files.
    static func accepts(path: String) -> Bool {
        let lower = path.lowercased()
        // System / cross-user areas and package internals.
        for bad in ["/system/", "/library/", "/private/", "/nix/store/", "/.trash/",
                    "/node_modules/", "/deriveddata/", "/.build/", "/.cache/",
                    "/caches/", ".app/", ".framework/", ".bundle/", ".xcassets/",
                    ".photoslibrary/", ".photolibrary/"] {
            if lower.contains(bad) { return false }
        }
        // Skip files nested inside a dot-directory (e.g. ~/.git/, ~/.config guts),
        // but allow a leading dot on the leaf itself so a real dotfile is findable.
        let parent = (path as NSString).deletingLastPathComponent
        for comp in (parent as NSString).pathComponents where comp.hasPrefix(".") && comp.count > 1 {
            return false
        }
        return true
    }

    // MARK: Ranking
    //
    // Spotlight hands back matches newest-first; we re-rank the slice so the
    // obvious target wins: name-match quality (reusing the launcher's Fuzzy so
    // prefix / word-boundary hits lead), lifted by how often the user opens the
    // file (frecency) and gently by recency. Pure so it's testable in isolation.
    static func rank(_ hits: [FileHit], query: String, now: Double,
                     frecency: (String) -> Double) -> [FileHit] {
        let q = Array(query.lowercased())
        let week = 7.0 * 86400
        return hits.map { h -> (FileHit, Double) in
            let name = Fuzzy.score(q, h.name.lowercased()) ?? 0
            let frec = frecency("file:\(h.path)")
            let normFrec = frec / (frec + 5)                       // 0..1
            let age = max(0, now - h.modified)
            let recency = age < week ? (1 - age / week) : 0        // 0..1, last week only
            return (h, name + normFrec * 2.0 + recency * 0.75)
        }
        .sorted { $0.1 > $1.1 }
        .map { $0.0 }
    }

    // MARK: Path helpers

    private static func abbreviate(parentOf path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if parent == home { return "~" }
        if parent.hasPrefix(home + "/") { return "~" + parent.dropFirst(home.count) }
        return parent
    }
}
