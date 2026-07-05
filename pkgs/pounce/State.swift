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
}

// MARK: - State

enum DisplayMode { case list, clipboard, emoji, screenshots, camera, cheatsheet }

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
        case .list: return metrics.width
        }
    }

    let frecency = Frecency()
    private var frecencyScores: [UUID: Double] = [:]

    var onCommit: ((Commit) -> Void)?
    var onResize: (() -> Void)?       // content height changed; window should refit
    weak var textField: NSTextField?

    func reset() {
        // A new request replaces whatever mode is up; make sure a live camera
        // session from a previous peek doesn't keep the hardware (and its
        // indicator light) on behind the next view.
        if displayMode == .camera { CameraController.shared.stop() }
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

    // Load the cheatsheet overlay from JSON.
    func loadCheatsheet(path: String, placeholder: String?) {
        displayMode = .cheatsheet
        placeholderText = placeholder ?? "Cheatsheet"
        cheatsheetGroups = CheatsheetStore.load(path: path)
    }

    // Load the emoji grid from the bundled dataset.
    func loadEmoji(placeholder: String?) {
        displayMode = .emoji
        emojiEntries = EmojiStore.shared.all
        placeholderText = placeholder ?? "Search emoji…"
    }

    func emojiFrecency(_ c: String) -> Double { frecency.score(for: "emoji:\(c)") }

    // Relevance of an emoji for a typed query (name + keywords), nil → no match.
    func emojiMatch(_ e: EmojiEntry, query: [Character]) -> Double? {
        guard let s = Fuzzy.score(query, e.search) else { return nil }
        let frec = emojiFrecency(e.c)
        return s + (frec / (frec + 5)) * 1.5
    }

    // Copy the emoji to the clipboard, record frecency, and echo it to the client.
    func commitEmoji(_ e: EmojiEntry) {
        frecency.record("emoji:\(e.c)")
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(e.c, forType: .string)
        onCommit?(Commit(clientString: e.c, disposition: .hideNow, appLaunch: nil))
    }

    func load(lines: [String], placeholder: String?, icon: String?, launcher: Bool, maxEmpty: Int?) {
        globalIcon = icon
        isLauncher = launcher
        self.maxEmpty = maxEmpty ?? (launcher ? 7 : Int.max)

        var built: [PounceItem] = []
        if launcher {
            built.append(contentsOf: lines.filter { !$0.isEmpty }.map { PounceItem.parseCommand($0) })
            built.append(contentsOf: AppScanner.shared.apps())
            placeholderText = placeholder ?? "Search apps & actions..."
        } else {
            built = lines.map { PounceItem.parsePlain($0, globalIcon: icon) }
            placeholderText = placeholder ?? (lines.isEmpty ? "Input..." : "Search...")
        }
        items = built
        frecencyScores = Dictionary(uniqueKeysWithValues: built.map { ($0.id, frecency.score(for: $0.frecencyKey)) })

        itemsSorted = built.sorted { a, b in
            (frecencyScores[a.id] ?? 0) + a.baseBoost > (frecencyScores[b.id] ?? 0) + b.baseBoost
        }
    }

    private func frecency(for item: PounceItem) -> Double { frecencyScores[item.id] ?? 0 }

    // Combined relevance for a typed query. nil → no match.
    func matchScore(_ item: PounceItem, query: [Character]) -> Double? {
        let title = Fuzzy.score(query, item.title.lowercased())
        let sub = item.subtitle.flatMap { Fuzzy.score(query, $0.lowercased()) }
        let candidates = [title, sub.map { $0 * 0.5 }].compactMap { $0 }
        guard let best = candidates.max() else { return nil }
        let frec = frecency(for: item)
        let normFrec = frec / (frec + 5)                 // 0..1
        let boost = item.baseBoost > 0 ? 0.8 : 0
        return best + normFrec * 1.5 + boost
    }

    func commit(_ item: PounceItem, action: String) {
        frecency.record(item.frecencyKey)
        // For a two-step command, seed the loading header with its name + icon so
        // it matches the step-2 header (which arrives with the same -p / -i).
        if item.kind == .command && item.submenu {
            loadingTitle = item.title
            loadingIcon = item.icon ?? "magnifyingglass"
        }
        onCommit?(buildCommit(item, action: action))
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
        }
    }
}
