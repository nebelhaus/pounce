import SwiftUI

// MARK: - Socket Path

enum SocketConfig {
    static let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/share/pounce").path
    static let path = dir + "/pounce.sock"
}

// MARK: - Settings & Layout

// Layout dimensions for a given window mode. The window resizes to `width` and
// the list/header shrink with the other fields, so "compact" reads as a tighter
// launcher.
struct LayoutMetrics {
    let width: CGFloat
    let rowHeight: CGFloat
    let maxVisibleItems: Int
    let headerHeight: CGFloat
    let searchIconSize: CGFloat
    let searchFontSize: CGFloat
    let topInsetFraction: CGFloat   // distance from top of screen, as a fraction of height
    // When true, an empty query shows no list until the user types or presses ↓
    // (the compact behaviour). When false, the empty query shows the top-N.
    let hideEmptyList: Bool

    static let standard = LayoutMetrics(
        width: 720, rowHeight: 46, maxVisibleItems: 8, headerHeight: 60,
        searchIconSize: 18, searchFontSize: 20, topInsetFraction: 0.16,
        hideEmptyList: false)

    static let compact = LayoutMetrics(
        width: 600, rowHeight: 42, maxVisibleItems: 6, headerHeight: 52,
        searchIconSize: 16, searchFontSize: 18, topInsetFraction: 0.20,
        hideEmptyList: true)
}

// Fixed geometry for the clipboard history's two-pane window (independent of the
// launcher's windowMode).
enum ClipboardLayout {
    static let width: CGFloat = 820
    static let height: CGFloat = 480
    static let listWidth: CGFloat = 300
    static let rowHeight: CGFloat = 56
}

// Fixed geometry for the emoji grid window.
enum EmojiLayout {
    static let width: CGFloat = 520
    static let columns = 9
    static let cellHeight: CGFloat = 50
    static let gridHeight: CGFloat = 320
}

// Fixed geometry for the recent-screenshots two-pane window. Mirrors the
// clipboard history layout (list on the left, large preview on the right).
enum ScreenshotLayout {
    static let width: CGFloat = 820
    static let height: CGFloat = 480
    static let listWidth: CGFloat = 300
    static let rowHeight: CGFloat = 64
}

// User settings, read from ~/.config/pounce/config.json. Parsed leniently via
// JSONSerialization so unknown/extra keys (added by future versions) never break
// an older binary, and any missing/malformed value falls back to a default.
struct ClipboardSettings {
    var enabled: Bool = true
    var maxEntries: Int = 200
    // Copies whose frontmost app matches one of these bundle ids are never
    // recorded (belt-and-suspenders on top of the org.nspasteboard.ConcealedType
    // filter, which already drops password-manager copies).
    var blacklistBundleIds: [String] = ["com.apple.Passwords"]
    // Auto-paste a selected entry into the previously-focused app (synthesize ⌘V)
    // instead of only setting the clipboard. Requires the daemon to hold an
    // Accessibility grant; falls back to clipboard-only when untrusted. Default
    // off so a fresh install never silently needs a TCC permission.
    var autoPaste: Bool = false
}

struct Settings {
    enum WindowMode: String { case standard = "default", compact }

    var windowMode: WindowMode = .standard
    var clipboard = ClipboardSettings()
    // Named color palette (see Palette.named). Defaults to nebelung.
    var theme: String = "nebelung"

    var metrics: LayoutMetrics {
        switch windowMode {
        case .standard: return .standard
        case .compact: return .compact
        }
    }

    var palette: Palette { Palette.named(theme) }

    static var configPath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/pounce/config.json")
    }

    // Cheap enough (tiny file) to re-read per invocation, so edits take effect
    // on the next open without restarting the daemon.
    static func load() -> Settings {
        var s = Settings()
        guard let data = try? Data(contentsOf: configPath),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return s }
        if let wm = obj["windowMode"] as? String, let mode = WindowMode(rawValue: wm) {
            s.windowMode = mode
        }
        if let t = obj["theme"] as? String { s.theme = t }
        if let cb = obj["clipboard"] as? [String: Any] {
            if let e = cb["enabled"] as? Bool { s.clipboard.enabled = e }
            if let m = cb["maxEntries"] as? Int { s.clipboard.maxEntries = m }
            if let bl = cb["blacklistBundleIds"] as? [String] { s.clipboard.blacklistBundleIds = bl }
            if let ap = cb["autoPaste"] as? Bool { s.clipboard.autoPaste = ap }
        }
        return s
    }
}
