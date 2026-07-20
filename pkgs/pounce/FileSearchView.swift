import SwiftUI

// MARK: - Find Files View
//
// Spotlight-style file search, live as you type. A fixed-size window (results
// stream in asynchronously from the metadata query, so the frame must NOT resize
// under the cursor) with the launcher's own row + action-bar chrome for a
// seamless feel. Selection routes to DaemonState.commitFile — open (⏎), reveal
// in Finder (⌘⏎), or copy path (⌥⏎). Read-only: nothing here moves or deletes.

struct FileSearchView: View {
    @ObservedObject var state: DaemonState
    @State private var query = ""
    @State private var selectedIndex = 0

    var results: [FileHit] { state.fileResults }

    var selected: FileHit? {
        guard selectedIndex >= 0, selectedIndex < results.count else { return nil }
        return results[selectedIndex]
    }

    // The chrome shows the selected row's actions; constant across files.
    private var actions: [ItemAction] {
        [ItemAction(key: "enter", label: "Open"),
         ItemAction(key: "cmd", label: "Reveal in Finder"),
         ItemAction(key: "opt", label: "Copy Path")]
    }

    private var trimmed: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: state.metrics.searchIconSize, weight: .medium))
                    .foregroundColor(Theme.subtext)
                CustomTextField(
                    text: $query, selectedIndex: $selectedIndex,
                    itemCount: results.count, placeholder: state.placeholderText,
                    fontSize: state.metrics.searchFontSize, state: state,
                    onSubmit: { action in commit(action: action) })
            }
            .padding(.horizontal, 20)
            .frame(height: FileSearchLayout.headerHeight)

            Divider().frame(height: 1).background(Theme.surface1.opacity(0.3))

            listArea
                .frame(height: FileSearchLayout.listHeight)

            Divider().frame(height: 1).background(Theme.surface1.opacity(0.3))
            ActionBar(actions: selected != nil ? actions : [])
                .frame(height: 44)
        }
        .frame(width: FileSearchLayout.width)
        .fixedSize(horizontal: false, vertical: true)
        .background(Theme.base.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .onChange(of: query) {
            selectedIndex = 0
            state.fileQueryChanged(query)
        }
        .onChange(of: state.requestID) { query = ""; selectedIndex = 0 }
    }

    @ViewBuilder
    var listArea: some View {
        if !state.fileSearchEnabled {
            centeredNote("File search is disabled", "Set fileSearch.enabled in config.json")
        } else if results.isEmpty {
            if trimmed.count < FileSearchController.minQueryLength {
                centeredNote("Search your files & folders", "Type a name to find it")
            } else if state.fileSearching {
                centeredNote("Searching…", nil)
            } else {
                centeredNote("No files found", "for “\(trimmed)”")
            }
        } else {
            resultsList
        }
    }

    var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { i, hit in
                        ItemRow(item: PounceItem.file(name: hit.name, path: hit.path, parent: hit.parent),
                                isSelected: i == selectedIndex)
                            .frame(height: FileSearchLayout.rowHeight)
                            .id(hit.id)
                            .onTapGesture { selectedIndex = i; commit(action: "enter") }
                    }
                }
                .padding(.vertical, 6)
            }
            .onChange(of: selectedIndex) {
                if let hit = selected { proxy.scrollTo(hit.id) }
            }
        }
    }

    func centeredNote(_ title: String, _ subtitle: String?) -> some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundColor(Theme.subtext)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 12, design: .rounded))
                    .foregroundColor(Theme.subtext0)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    func commit(action: String) {
        guard let hit = selected else { state.cancel(); return }
        state.commitFile(hit, action: action)
    }
}
