import SwiftUI
import AppKit

// MARK: - Clipboard View

func relativeTime(_ ts: Double) -> String {
    let s = max(0, Date().timeIntervalSince1970 - ts)
    if s < 60 { return "just now" }
    if s < 3600 { return "\(Int(s / 60))m ago" }
    if s < 86400 { return "\(Int(s / 3600))h ago" }
    return "\(Int(s / 86400))d ago"
}

// Resolves a source app's icon from its bundle id (cached), falling back to an
// SF Symbol by clip kind.
final class AppIconResolver {
    static let shared = AppIconResolver()
    private let cache = NSCache<NSString, NSImage>()

    func icon(forBundleId bundleId: String?, kind: ClipKind) -> NSImage {
        if let b = bundleId {
            if let c = cache.object(forKey: b as NSString) { return c }
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: b) {
                let icon = NSWorkspace.shared.icon(forFile: url.path)
                cache.setObject(icon, forKey: b as NSString)
                return icon
            }
        }
        let name = kind == .image ? "photo" : "doc.on.clipboard"
        return NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage()
    }
}

struct ClipboardView: View {
    @ObservedObject var state: DaemonState
    @State private var query = ""
    @State private var selectedIndex = 0

    var filtered: [ClipEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return state.clipEntries }
        return state.clipEntries.filter {
            $0.preview.lowercased().contains(q) || ($0.appName?.lowercased().contains(q) ?? false)
        }
    }

    var selected: ClipEntry? {
        guard selectedIndex < filtered.count else { return nil }
        return filtered[selectedIndex]
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(Theme.subtext)
                CustomTextField(
                    text: $query, selectedIndex: $selectedIndex,
                    itemCount: filtered.count, placeholder: state.placeholderText,
                    fontSize: 18, state: state, onSubmit: { _ in commit() }
                )
            }
            .padding(.horizontal, 20)
            .frame(height: 52)

            Divider().background(Theme.surface1.opacity(0.3))

            HStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(filtered.enumerated()), id: \.element.id) { i, entry in
                                ClipRow(entry: entry, isSelected: i == selectedIndex)
                                    .id(entry.id)
                                    .onTapGesture { selectedIndex = i; commit() }
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    .onChange(of: selectedIndex) {
                        if selectedIndex < filtered.count { proxy.scrollTo(filtered[selectedIndex].id) }
                    }
                }
                .frame(width: ClipboardLayout.listWidth)

                Divider().background(Theme.surface1.opacity(0.3))

                ClipPreview(entry: selected)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(width: ClipboardLayout.width, height: ClipboardLayout.height)
        .background(Theme.base.opacity(0.55))
        .onChange(of: query) { selectedIndex = 0 }
        .onChange(of: state.requestID) { query = ""; selectedIndex = 0 }
    }

    func commit() {
        guard let entry = selected else { state.cancel(); return }
        state.commitClip(entry)
    }
}

struct ClipRow: View {
    let entry: ClipEntry
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: AppIconResolver.shared.icon(forBundleId: entry.bundleId, kind: entry.kind))
                .resizable().aspectRatio(contentMode: .fit)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.kind == .image ? "Image — \(entry.preview)" : entry.preview)
                    .foregroundColor(Theme.text)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text([entry.appName, relativeTime(entry.ts)].compactMap { $0 }.joined(separator: " · "))
                    .foregroundColor(Theme.subtext0)
                    .font(.system(size: 11))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 12)
        .frame(height: ClipboardLayout.rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Theme.mauve.opacity(0.20) : Color.clear)
                .padding(.horizontal, 6)
        )
        .contentShape(Rectangle())
    }
}

struct ClipPreview: View {
    let entry: ClipEntry?

    var body: some View {
        if let entry = entry {
            VStack(alignment: .leading, spacing: 0) {
                if entry.kind == .image, let img = ClipboardStore.shared.image(for: entry) {
                    ScrollView {
                        Image(nsImage: img)
                            .resizable().aspectRatio(contentMode: .fit)
                            .frame(maxWidth: .infinity)
                            .padding(16)
                    }
                } else {
                    ScrollView {
                        Text(ClipboardStore.shared.text(for: entry))
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(Theme.text)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                    }
                }
                Divider().background(Theme.surface1.opacity(0.3))
                HStack(spacing: 8) {
                    Text([entry.appName, entry.kind == .image ? entry.preview : nil]
                        .compactMap { $0 }.joined(separator: " · "))
                        .foregroundColor(Theme.subtext)
                    Spacer()
                    Text(relativeTime(entry.ts)).foregroundColor(Theme.subtext0)
                }
                .font(.system(size: 11))
                .padding(.horizontal, 16)
                .frame(height: 32)
            }
        } else {
            Text("No clipboard history yet")
                .foregroundColor(Theme.subtext0)
                .font(.system(size: 13))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
