import SwiftUI
import AppKit
import ApplicationServices

// MARK: - Commit

// hideNow: close immediately. linger: brief fade (terminal action). loading:
// keep the window up showing a spinner until the next request swaps in (a
// two-step command re-invoking pounce) — never a gap between steps.
enum Disposition { case hideNow, linger, loading }

struct Commit {
    let clientString: String?               // sent back to the connected client (nil → "")
    let disposition: Disposition
    let appLaunch: (path: String, reveal: Bool)?
    // When true, after hiding the window the daemon reactivates the previously
    // focused app and synthesizes ⌘V (clipboard auto-paste). Defaults false so
    // the existing memberwise-init call sites need no change.
    var pasteAfter: Bool = false
    // A Find Files hit to act on: open it in its default app (reveal false) or
    // reveal it in Finder (reveal true). Distinct from appLaunch, which uses the
    // app-specific openApplication path; files open via NSWorkspace.open.
    var fileOpen: (path: String, reveal: Bool)? = nil
}

// MARK: - State

enum DisplayMode { case list, clipboard, emoji, screenshots, camera, cheatsheet, fileSearch }

final class DaemonState: ObservableObject {
    @Published var items: [PounceItem] = []
    @Published var itemsSorted: [PounceItem] = []   // empty-query order
    @Published var placeholderText: String = "Search..."
    @Published var globalIcon: String? = nil
    @Published var isVisible: Bool = false
    @Published var requestID = UUID()
    @Published var metrics: LayoutMetrics = .standard
    @Published var displayMode: DisplayMode = .list
    @Published var clipEntries: [ClipEntry] = []
    @Published var emojiEntries: [EmojiEntry] = []
    @Published var screenshotEntries: [ScreenshotEntry] = []
    @Published var cheatsheetGroups: [CheatsheetGroup] = []
    // Find Files: live results and whether a search is in flight (spinner/hint).
    @Published var fileResults: [FileHit] = []
    @Published var fileSearching = false
    @Published var fileSearchEnabled = true   // false → mode shows a "disabled" note
    var cheatsheetPath = ""            // set with cheatsheetGroups; read-only for the view
    @Published var isLoading = false   // skeleton shown between a two-step command's steps
    @Published var loadingTitle = ""   // selected command's name, shown in the static header
    @Published var loadingIcon = "magnifyingglass"
    // The launcher's search text. Held here (not as ContentView @State) so reset()
    // can clear it synchronously before step 2 renders — no one-frame flash of the
    // previous query.
    @Published var query = ""

    var isLauncher = false
    var maxEmpty = Int.max

    // The clipboard and emoji views are fixed-size windows; everything else
    // follows the launcher's windowMode width.
    var targetWidth: CGFloat {
        switch displayMode {
        case .clipboard: return ClipboardLayout.width
        case .emoji: return EmojiLayout.width
        case .screenshots: return ScreenshotLayout.width
        case .camera: return CameraLayout.width
        case .cheatsheet: return CheatsheetLayout.width
        case .fileSearch: return FileSearchLayout.width
        case .list: return metrics.width
        }
    }

    let frecency = Frecency()
    // Lazily created the first time Find Files mode opens (no cost otherwise);
    // holds the live NSMetadataQuery. reset() stops it so it never runs on after
    // the palette closes.
    private var fileSearcher: FileSearchController?
    private var frecencyScores: [UUID: Double] = [:]

    // Quick answer (inline calculator & friends) for the current launcher
    // query. Memoized per query string because ContentView.filtered — where
    // this is read — re-evaluates on every render, not just on keystrokes.
    private var answerQuery = ""
    private var answerItem: PounceItem?

    var onCommit: ((Commit) -> Void)?
    var onResize: (() -> Void)?       // content height changed; window should refit
    // When the view knows its exact target height (the launcher computes it from
    // row metrics — see ContentView.contentHeight), it stashes it here right
    // before calling onResize so the window can resize to it synchronously, in
    // the same turn, without measuring hosting.fittingSize (stale same-turn on
    // Tahoe). nil → the window measures (command/cheatsheet views). resizeToFit
    // consumes and clears it.
    var pendingContentHeight: CGFloat?
    weak var textField: NSTextField?

    func reset() {
        // A new request replaces whatever mode is up; make sure a live camera
        // session from a previous peek doesn't keep the hardware (and its
        // indicator light) on behind the next view.
        if displayMode == .camera { CameraController.shared.stop() }
        // Stop any live file-search query so it doesn't keep hitting the metadata
        // index after the palette is dismissed.
        fileSearcher?.stop()
        fileResults = []
        fileSearching = false
        items = []
        itemsSorted = []
        frecencyScores = [:]
        placeholderText = "Search..."
        globalIcon = nil
        isLauncher = false
        maxEmpty = Int.max
        requestID = UUID()
        displayMode = .list
        clipEntries = []
        emojiEntries = []
        screenshotEntries = []
        cheatsheetGroups = []
        isLoading = false
        query = ""
        answerQuery = ""
        answerItem = nil
    }

    // The quick answer pinned above the launcher's results, if the query is
    // expression-shaped (see QuickAnswerHub). Launcher-only: utility menus
    // pipe arbitrary lines where "2*3" may be a legitimate item filter.
    func quickAnswerItem(for query: String) -> PounceItem? {
        guard isLauncher, displayMode == .list else { return nil }
        if query != answerQuery {
            answerQuery = query
            answerItem = QuickAnswerHub.answer(for: query).map(PounceItem.answer)
        }
        return answerItem
    }

    // Load the clipboard history view from the daemon's own store.
    func loadClipboard(placeholder: String?) {
        displayMode = .clipboard
        clipEntries = ClipboardStore.shared.entries()
        placeholderText = placeholder ?? "Clipboard history…"
    }

    func commitClip(_ entry: ClipEntry) {
        ClipboardStore.shared.restore(entry)
        // Auto-paste when enabled AND we hold the Accessibility grant; otherwise
        // fall back to clipboard-only (restore already ran) and nudge once.
        var paste = false
        if Settings.load().clipboard.autoPaste {
            if AXIsProcessTrusted() {
                paste = true
            } else {
                AccessibilityHint.promptOnce()
            }
        }
        onCommit?(Commit(clientString: "", disposition: .hideNow, appLaunch: nil, pasteAfter: paste))
    }

    // Load the recent-screenshots grid from the configured screencapture folder.
    func loadScreenshots(placeholder: String?) {
        displayMode = .screenshots
        screenshotEntries = ScreenshotStore.recent()
        placeholderText = placeholder ?? "Recent screenshots…"
    }

    // Copy the selected screenshot to the clipboard as both an image (paste into
    // Slack/Notion) and a file reference (⌘V in Finder pastes the file).
    func commitScreenshot(_ entry: ScreenshotEntry) {
        Pasteboard.copyFile(URL(fileURLWithPath: entry.path))
        onCommit?(Commit(clientString: "", disposition: .hideNow, appLaunch: nil))
    }

    // Show the live camera peek; the capture session starts immediately so the
    // first frames are already flowing by the time the window fades in.
    func loadCamera(placeholder: String?) {
        displayMode = .camera
        placeholderText = placeholder ?? "Camera"
        CameraController.shared.start()
    }

    // Load the cheatsheet overlay from JSON. The path is kept so the view can
    // say where it looked when the file is missing or malformed.
    func loadCheatsheet(path: String, placeholder: String?) {
        displayMode = .cheatsheet
        placeholderText = placeholder ?? "Cheatsheet"
        cheatsheetPath = path
        cheatsheetGroups = CheatsheetStore.load(path: path)
    }

    // Load the emoji grid from the bundled dataset.
    func loadEmoji(placeholder: String?) {
        displayMode = .emoji
        emojiEntries = EmojiStore.shared.all
        placeholderText = placeholder ?? "Search emoji…"
    }

    // MARK: Find Files

    // Enter Find Files mode. The searcher is created on first use (wired to
    // publish results here) and configured from live settings each time.
    func loadFileSearch(placeholder: String?) {
        displayMode = .fileSearch
        let cfg = Settings.load().fileSearch
        fileSearchEnabled = cfg.enabled
        fileResults = []
        fileSearching = false
        placeholderText = placeholder ?? "Search files & folders…"
        guard cfg.enabled else { return }

        let searcher = fileSearcher ?? FileSearchController(
            frecency: { [weak self] key in self?.frecency.score(for: key) ?? 0 })
        searcher.maxResults = cfg.maxResults
        searcher.homeOnly = cfg.homeOnly
        searcher.onUpdate = { [weak self] hits, searching in
            // The query runs on main, but guard the hop so a stray notification
            // can never touch @Published off-main.
            if Thread.isMainThread {
                self?.fileResults = hits; self?.fileSearching = searching
            } else {
                DispatchQueue.main.async { self?.fileResults = hits; self?.fileSearching = searching }
            }
        }
        fileSearcher = searcher
    }

    // A keystroke in Find Files mode: drive the live query (debounced inside).
    func fileQueryChanged(_ query: String) {
        fileSearcher?.search(query)
    }

    // Act on a selected file. Open (⏎) and reveal (⌘⏎) route through the daemon's
    // NSWorkspace; copy-path (⌥⏎) is handled here (clipboard + client echo). Every
    // path records frecency so files you open float up next time. All read-only —
    // nothing here moves or deletes a file.
    func commitFile(_ hit: FileHit, action: String) {
        frecency.record("file:\(hit.path)")
        switch action {
        case "cmd":
            onCommit?(Commit(clientString: "", disposition: .hideNow, appLaunch: nil,
                             fileOpen: (hit.path, true)))
        case "opt":
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(hit.path, forType: .string)
            onCommit?(Commit(clientString: hit.path, disposition: .hideNow, appLaunch: nil))
        default:
            onCommit?(Commit(clientString: "", disposition: .hideNow, appLaunch: nil,
                             fileOpen: (hit.path, false)))
        }
    }

    func emojiFrecency(_ c: String) -> Double { frecency.score(for: "emoji:\(c)") }

    // Relevance of an emoji for a typed query (name + keywords), nil → no match.
    func emojiMatch(_ e: EmojiEntry, query: [Character]) -> Double? {
        guard let s = Fuzzy.score(query, e.search) else { return nil }
        let frec = emojiFrecency(e.c)
        return s + (frec / (frec + 5)) * 1.5
    }

    // Copy the emoji to the clipboard, record frecency, and echo it to the client.
    // Same auto-paste contract as commitClip: with clipboard.autoPaste on and the
    // Accessibility grant held, the emoji lands straight at the cursor of the
    // previously-focused app instead of stopping at the clipboard.
    func commitEmoji(_ e: EmojiEntry) {
        frecency.record("emoji:\(e.c)")
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(e.c, forType: .string)
        var paste = false
        if Settings.load().clipboard.autoPaste {
            if AXIsProcessTrusted() {
                paste = true
            } else {
                AccessibilityHint.promptOnce()
            }
        }
        onCommit?(Commit(clientString: e.c, disposition: .hideNow, appLaunch: nil, pasteAfter: paste))
    }

    func load(lines: [String], placeholder: String?, icon: String?, launcher: Bool, maxEmpty: Int?) {
        globalIcon = icon
        isLauncher = launcher
        self.maxEmpty = maxEmpty ?? (launcher ? 7 : Int.max)

        var built: [PounceItem] = []
        if launcher {
            built.append(contentsOf: lines.filter { !$0.isEmpty }.map { PounceItem.parseCommand($0) })
            let launcherCfg = Settings.load().appLauncher
            built.append(contentsOf: AppScanner.shared.apps(
                demotedBundleIds: launcherCfg.demoteBundleIds,
                hiddenBundleIds: Set(launcherCfg.hideBundleIds)))
            placeholderText = placeholder ?? "Search apps & actions..."
        } else {
            built = lines.map { PounceItem.parsePlain($0, globalIcon: icon) }
            placeholderText = placeholder ?? (lines.isEmpty ? "Input..." : "Search...")
        }
        items = built
        frecencyScores = Dictionary(uniqueKeysWithValues: built.map { ($0.id, frecency.score(for: $0.frecencyKey)) })

        itemsSorted = built.sorted { a, b in
            let sa = (frecencyScores[a.id] ?? 0) + a.baseBoost
            let sb = (frecencyScores[b.id] ?? 0) + b.baseBoost
            if sa != sb { return sa > sb }
            // Deterministic tie-break so the empty list isn't filesystem-order
            // roulette among the many zero-score apps (case-insensitive by title).
            return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }
    }

    private func frecency(for item: PounceItem) -> Double { frecencyScores[item.id] ?? 0 }

    // Combined relevance for a typed query. nil → no match.
    func matchScore(_ item: PounceItem, query: [Character]) -> Double? {
        let title = Fuzzy.score(query, item.title.lowercased())
        // An app's bundle name (e.g. "Live" for Ableton) scores at full weight —
        // it's a legitimate name for the app, just not the one we display.
        let alias = item.searchAlias.flatMap { Fuzzy.score(query, $0.lowercased()) }
        let sub = item.subtitle.flatMap { Fuzzy.score(query, $0.lowercased()) }
        let candidates = [title, alias, sub.map { $0 * 0.5 }].compactMap { $0 }
        guard let best = candidates.max() else { return nil }
        let frec = frecency(for: item)
        let normFrec = frec / (frec + 5)                 // 0..1
        let boost = item.baseBoost > 0 ? 0.8 : 0
        return best + normFrec * 1.5 + boost
    }

    func commit(_ item: PounceItem, action: String) {
        // A quick answer copies to the clipboard — no frecency (it's derived
        // from the query, its rank is fixed) and no client round-trip.
        if item.kind == .answer { commitAnswer(item); return }
        frecency.record(item.frecencyKey)
        // For a two-step command, seed the loading header with its name + icon so
        // it matches the step-2 header (which arrives with the same -p / -i).
        if item.kind == .command && item.submenu {
            loadingTitle = item.title
            loadingIcon = item.icon ?? "magnifyingglass"
        }
        onCommit?(buildCommit(item, action: action))
    }

    // Copy the answer's plain text. Same auto-paste contract as commitClip /
    // commitEmoji: with clipboard.autoPaste on and the Accessibility grant
    // held, the answer lands straight at the cursor of the previous app.
    private func commitAnswer(_ item: PounceItem) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(item.payload, forType: .string)
        var paste = false
        if Settings.load().clipboard.autoPaste {
            if AXIsProcessTrusted() {
                paste = true
            } else {
                AccessibilityHint.promptOnce()
            }
        }
        onCommit?(Commit(clientString: item.payload, disposition: .hideNow,
                         appLaunch: nil, pasteAfter: paste))
    }

    func commitText(_ text: String) {
        onCommit?(Commit(clientString: "enter\t\(text)", disposition: .linger, appLaunch: nil))
    }

    func cancel() {
        onCommit?(Commit(clientString: "", disposition: .hideNow, appLaunch: nil))
    }

    private func buildCommit(_ item: PounceItem, action: String) -> Commit {
        switch item.kind {
        case .app:
            return Commit(clientString: "", disposition: .hideNow,
                          appLaunch: (item.payload, action == "cmd"))
        case .command:
            // Two-step commands re-invoke pounce → keep the window up (loading)
            // so step 2 swaps in without a gap. Terminal commands briefly linger.
            return Commit(clientString: "run\t\(item.payload)",
                          disposition: item.submenu ? .loading : .linger, appLaunch: nil)
        case .plain:
            let a = item.action(for: action) != nil ? action : "enter"
            return Commit(clientString: "\(a)\t\(item.raw)", disposition: .linger, appLaunch: nil)
        case .answer:
            // Unreachable — commit() routes .answer to commitAnswer first.
            return Commit(clientString: item.payload, disposition: .hideNow, appLaunch: nil)
        }
    }
}
