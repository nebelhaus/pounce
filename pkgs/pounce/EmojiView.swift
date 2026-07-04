import SwiftUI

// MARK: - Emoji View

struct EmojiView: View {
    @ObservedObject var state: DaemonState
    @State private var query = ""
    @State private var selectedIndex = 0

    var filtered: [EmojiEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            // Empty query: most-used first (frecency), stable dataset order otherwise.
            return state.emojiEntries.enumerated().sorted { a, b in
                let fa = state.emojiFrecency(a.element.c)
                let fb = state.emojiFrecency(b.element.c)
                return fa != fb ? fa > fb : a.offset < b.offset
            }.map { $0.element }
        }
        let q = Array(trimmed.lowercased())
        let scored = state.emojiEntries.compactMap { e -> (EmojiEntry, Double)? in
            guard let s = state.emojiMatch(e, query: q) else { return nil }
            return (e, s)
        }
        return scored.sorted { $0.1 > $1.1 }.map { $0.0 }
    }

    var selected: EmojiEntry? {
        guard selectedIndex < filtered.count else { return nil }
        return filtered[selectedIndex]
    }

    var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 4), count: EmojiLayout.columns)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "face.smiling")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(Theme.subtext)
                CustomTextField(
                    text: $query, selectedIndex: $selectedIndex,
                    itemCount: filtered.count, placeholder: state.placeholderText,
                    fontSize: 18, state: state,
                    onSubmit: { _ in commit() },
                    gridColumns: EmojiLayout.columns
                )
            }
            .padding(.horizontal, 20)
            .frame(height: 52)

            Divider().background(Theme.surface1.opacity(0.3))

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 4) {
                        ForEach(Array(filtered.enumerated()), id: \.element.id) { i, e in
                            Text(e.c)
                                .font(.system(size: 26))
                                .frame(maxWidth: .infinity)
                                .frame(height: EmojiLayout.cellHeight)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(i == selectedIndex ? Theme.mauve.opacity(0.30) : Color.clear)
                                )
                                .id(e.c)
                                .onTapGesture { selectedIndex = i; commit() }
                        }
                    }
                    .padding(8)
                }
                .frame(height: EmojiLayout.gridHeight)
                .onChange(of: selectedIndex) {
                    if selectedIndex < filtered.count { proxy.scrollTo(filtered[selectedIndex].c) }
                }
            }

            Divider().background(Theme.surface1.opacity(0.3))

            HStack(spacing: 10) {
                if let e = selected {
                    Text(e.c).font(.system(size: 18))
                    Text(e.name)
                        .foregroundColor(Theme.subtext)
                        .font(.system(size: 12))
                        .lineLimit(1)
                } else {
                    Text("No match").foregroundColor(Theme.subtext0).font(.system(size: 12))
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(height: 36)
        }
        .frame(width: EmojiLayout.width)
        .fixedSize(horizontal: false, vertical: true)
        .background(Theme.base.opacity(0.55))
        .onChange(of: query) { selectedIndex = 0 }
        .onChange(of: state.requestID) { query = ""; selectedIndex = 0 }
    }

    func commit() {
        guard let e = selected else { state.cancel(); return }
        state.commitEmoji(e)
    }
}
