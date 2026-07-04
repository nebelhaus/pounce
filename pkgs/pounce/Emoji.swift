import AppKit
import CoreText

// MARK: - Emoji

struct EmojiEntry: Identifiable {
    let c: String          // the glyph
    let name: String
    let keywords: String
    let search: String     // precomputed "name keywords", lowercased
    var id: String { c }
}

// Loads the bundled emoji dataset (Resources/emoji.json) and filters it to the
// glyphs the running macOS can actually render. The vendored dataset is a
// superset spanning many Unicode releases; this keeps only what THIS OS draws,
// so the picker matches the installed macOS version exactly (no tofu, no
// half-supported sequences) and self-corrects on OS upgrades — no hardcoded
// version table to maintain.
final class EmojiStore {
    static let shared = EmojiStore()
    let all: [EmojiEntry]

    private init() {
        guard let url = Bundle.main.url(forResource: "emoji", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { all = []; return }

        let probeFont = NSFont(name: "Apple Color Emoji", size: 24)
        all = arr.compactMap { o -> EmojiEntry? in
            guard let c = o["c"] as? String, let n = o["n"] as? String else { return nil }
            // If the emoji font is somehow unavailable, don't filter at all.
            if let f = probeFont, !EmojiStore.renders(c, font: f) { return nil }
            let k = (o["k"] as? String) ?? ""
            return EmojiEntry(c: c, name: n, keywords: k, search: "\(n) \(k)".lowercased())
        }
    }

    // Supported on this OS == every run is still drawn by Apple Color Emoji.
    // CoreText falls back to another font for any glyph the emoji font lacks
    // (e.g. emoji newer than the installed macOS), so a fallback run means the
    // glyph isn't in this OS's set. This allows multi-glyph ligatures (gendered
    // couples, families) while dropping tofu — no Unicode-version table needed.
    private static func renders(_ s: String, font: NSFont) -> Bool {
        let attr = NSAttributedString(string: s, attributes: [.font: font])
        let line = CTLineCreateWithAttributedString(attr)
        guard let runs = CTLineGetGlyphRuns(line) as? [CTRun], !runs.isEmpty else { return false }
        for run in runs {
            let attrs = CTRunGetAttributes(run) as NSDictionary
            guard let runFont = attrs[kCTFontAttributeName as String] else { return false }
            if CTFontCopyPostScriptName(runFont as! CTFont) as String != "AppleColorEmoji" {
                return false
            }
        }
        return true
    }

    func warm() { DispatchQueue.global(qos: .utility).async { _ = EmojiStore.shared.all } }
}
