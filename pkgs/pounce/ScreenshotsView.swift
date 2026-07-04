import SwiftUI
import AppKit

// MARK: - Screenshots View

// Two-pane recent-screenshots picker: a filterable list on the left, a large
// preview of the highlighted shot on the right. Enter (or click) copies it to
// the clipboard as both image data and a file reference. Mirrors ClipboardView.
struct ScreenshotsView: View {
    @ObservedObject var state: DaemonState
    @State private var query = ""
    @State private var selectedIndex = 0

    var filtered: [ScreenshotEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return state.screenshotEntries }
        return state.screenshotEntries.filter { $0.name.lowercased().contains(q) }
    }

    var selected: ScreenshotEntry? {
        guard selectedIndex < filtered.count else { return nil }
        return filtered[selectedIndex]
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "photo.on.rectangle")
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

            if filtered.isEmpty {
                Text("No screenshots found")
                    .foregroundColor(Theme.subtext0)
                    .font(.system(size: 13))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(Array(filtered.enumerated()), id: \.element.id) { i, entry in
                                    ScreenshotRow(entry: entry, isSelected: i == selectedIndex)
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
                    .frame(width: ScreenshotLayout.listWidth)

                    Divider().background(Theme.surface1.opacity(0.3))

                    ScreenshotPreview(entry: selected)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxHeight: .infinity)
            }
        }
        .frame(width: ScreenshotLayout.width, height: ScreenshotLayout.height)
        .background(Theme.base.opacity(0.55))
        .onChange(of: query) { selectedIndex = 0 }
        .onChange(of: state.requestID) { query = ""; selectedIndex = 0 }
    }

    func commit() {
        guard let entry = selected else { state.cancel(); return }
        state.commitScreenshot(entry)
    }
}

struct ScreenshotRow: View {
    let entry: ScreenshotEntry
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: ThumbResolver.shared.thumb(entry.path))
                .resizable().aspectRatio(contentMode: .fit)
                .frame(width: 48, height: 32)
                .background(Theme.surface0.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .foregroundColor(Theme.text)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1).truncationMode(.middle)
                Text(relativeTime(entry.ts))
                    .foregroundColor(Theme.subtext0)
                    .font(.system(size: 11))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 12)
        .frame(height: ScreenshotLayout.rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Theme.mauve.opacity(0.20) : Color.clear)
                .padding(.horizontal, 6)
        )
        .contentShape(Rectangle())
    }
}

struct ScreenshotPreview: View {
    let entry: ScreenshotEntry?

    var body: some View {
        if let entry = entry {
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    if let img = NSImage(contentsOfFile: entry.path) {
                        Image(nsImage: img)
                            .resizable().aspectRatio(contentMode: .fit)
                            .frame(maxWidth: .infinity)
                            .padding(16)
                    } else {
                        Text("Can't preview \(entry.name)")
                            .foregroundColor(Theme.subtext0)
                            .padding(16)
                    }
                }
                Divider().background(Theme.surface1.opacity(0.3))
                HStack(spacing: 8) {
                    Text(entry.name).foregroundColor(Theme.subtext).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(relativeTime(entry.ts)).foregroundColor(Theme.subtext0)
                }
                .font(.system(size: 11))
                .padding(.horizontal, 16)
                .frame(height: 32)
            }
        } else {
            Text("No screenshots yet")
                .foregroundColor(Theme.subtext0)
                .font(.system(size: 13))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
