import AppKit
import CoreServices

// MARK: - Screenshots

struct ScreenshotEntry: Identifiable {
    let id: String      // absolute path, also the thumbnail cache key
    let path: String
    let name: String
    let ts: Double      // file modification time (unix)
}

// Enumerates recent screenshots from the folder `screencapture` writes to.
enum ScreenshotStore {
    // Where macOS saves screenshots: the `location` default (≈ Raycast/Finder),
    // ~-expanded, falling back to ~/Desktop when unset.
    static func directory() -> URL {
        if let loc = CFPreferencesCopyAppValue("location" as CFString,
                                               "com.apple.screencapture" as CFString) as? String,
           !loc.isEmpty {
            return URL(fileURLWithPath: (loc as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
    }

    private static let imageExts: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "gif", "bmp", "pdf"]

    static func recent(limit: Int = 60) -> [ScreenshotEntry] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let urls = try? fm.contentsOfDirectory(at: directory(),
                                                     includingPropertiesForKeys: keys,
                                                     options: [.skipsHiddenFiles]) else { return [] }
        var dated: [(ScreenshotEntry, Date)] = []
        for url in urls {
            guard imageExts.contains(url.pathExtension.lowercased()), isScreenshot(url) else { continue }
            let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? Date(timeIntervalSince1970: 0)
            dated.append((ScreenshotEntry(id: url.path, path: url.path,
                                          name: url.lastPathComponent,
                                          ts: mod.timeIntervalSince1970), mod))
        }
        return dated.sorted { $0.1 > $1.1 }.prefix(limit).map { $0.0 }
    }

    // Spotlight's screenshot flag is locale/format-independent (unlike a filename
    // glob). Falls back to a name heuristic when the file isn't indexed yet.
    static func isScreenshot(_ url: URL) -> Bool {
        if let item = MDItemCreate(nil, url.path as CFString),
           let val = MDItemCopyAttribute(item, "kMDItemIsScreenCapture" as CFString) {
            return (val as? NSNumber)?.boolValue ?? false
        }
        let n = url.lastPathComponent.lowercased()
        return n.hasPrefix("screenshot") || n.hasPrefix("screen shot") || n.hasPrefix("cleanshot")
    }
}

// Downscaled thumbnails for the screenshot list rows, generated once and cached
// so scrolling doesn't re-decode full-resolution PNGs.
final class ThumbResolver {
    static let shared = ThumbResolver()
    private let cache = NSCache<NSString, NSImage>()

    func thumb(_ path: String) -> NSImage {
        if let c = cache.object(forKey: path as NSString) { return c }
        let target = NSSize(width: 96, height: 64)
        let thumb = NSImage(size: target)
        if let full = NSImage(contentsOfFile: path) {
            thumb.lockFocus()
            NSGraphicsContext.current?.imageInterpolation = .high
            // Aspect-fit the screenshot inside the thumbnail box.
            let s = min(target.width / max(full.size.width, 1), target.height / max(full.size.height, 1))
            let w = full.size.width * s, h = full.size.height * s
            full.draw(in: NSRect(x: (target.width - w) / 2, y: (target.height - h) / 2, width: w, height: h),
                      from: .zero, operation: .copy, fraction: 1.0)
            thumb.unlockFocus()
        }
        cache.setObject(thumb, forKey: path as NSString)
        return thumb
    }
}
