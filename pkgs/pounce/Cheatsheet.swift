import SwiftUI

// MARK: - Models

struct CheatsheetItem: Codable, Identifiable {
    var id: String { key + action }
    let key: String
    let action: String
}

struct CheatsheetGroup: Codable, Identifiable {
    var id: String { title }
    let title: String
    let items: [CheatsheetItem]
    // Optional second axis: groups sharing a page render together and ⇥
    // cycles between pages. Absent → "Keys", so existing sheets stay
    // single-page and no page UI appears.
    var page: String?
    var pageName: String { page ?? "Keys" }
}

// MARK: - Store

enum CheatsheetStore {
    static func load(path: String) -> [CheatsheetGroup] {
        let expanded = (path as NSString).expandingTildeInPath
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: expanded)),
              let groups = try? JSONDecoder().decode([CheatsheetGroup].self, from: data) else {
            return []
        }
        return groups
    }
}

// MARK: - View

private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct CheatsheetView: View {
    @ObservedObject var state: DaemonState
    @State private var eventMonitor: Any?
    @State private var searching = false
    @State private var query = ""
    @State private var currentPage: String?
    @State private var contentHeight: CGFloat = 0

    // Distinct pages in first-seen (input) order.
    var pages: [String] {
        var seen = Set<String>(), order: [String] = []
        for g in state.cheatsheetGroups where seen.insert(g.pageName).inserted {
            order.append(g.pageName)
        }
        return order
    }

    var activePage: String { currentPage ?? pages.first ?? "Keys" }

    var nextPage: String? {
        guard pages.count > 1, let i = pages.firstIndex(of: activePage) else { return nil }
        return pages[(i + 1) % pages.count]
    }

    // What the body shows: the active page — or, while a query is live, the
    // matches from EVERY page (search shouldn't care which page you're on).
    // An item survives if the query hits its key, its action, or its group's
    // title (so "window" keeps the whole Window Management card).
    var visibleGroups: [CheatsheetGroup] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard searching, !q.isEmpty else {
            return state.cheatsheetGroups.filter { $0.pageName == activePage }
        }
        return state.cheatsheetGroups.compactMap { group in
            if group.title.lowercased().contains(q) { return group }
            let items = group.items.filter {
                $0.action.lowercased().contains(q) || $0.key.lowercased().contains(q)
            }
            return items.isEmpty ? nil
                : CheatsheetGroup(title: group.title, items: items, page: group.page)
        }
    }

    // Groups packed into columns greedily by item count — each group lands in
    // the currently-shortest column. Round-robin ignores group size and stacks
    // two long groups while a third column sits near-empty.
    func columns(for groups: [CheatsheetGroup]) -> [[CheatsheetGroup]] {
        let count = max(1, min(3, groups.count))
        var cols = Array(repeating: [CheatsheetGroup](), count: count)
        var weights = Array(repeating: 0, count: count)
        for group in groups {
            let i = weights.indices.min { weights[$0] < weights[$1] } ?? 0
            cols[i].append(group)
            weights[i] += group.items.count + 2   // +2 ≈ the title + card chrome
        }
        return cols
    }

    // The tallest the body may grow: the screen minus the window's top inset
    // (mirroring positionFresh) and a bottom margin, so the sheet hugs its
    // content and only scrolls when it would otherwise kiss the screen edge.
    var maxBodyHeight: CGFloat {
        let screenH = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame.height ?? 900
        let topInset = screenH * state.metrics.topInsetFraction
        return screenH - topInset - 48 - CheatsheetLayout.headerHeight
    }

    var hintText: String {
        if searching { return "⎋ to dismiss" }
        if let next = nextPage { return "⇥ \(next.lowercased())  ·  / search  ·  any key dismisses" }
        return "/ to search  ·  any key dismisses"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: searching ? "magnifyingglass" : "keyboard")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(Theme.subtext)
                if searching {
                    // The launcher's field: takes first responder on creation,
                    // Esc cancels via cancelOperation, ↵ dismisses via onSubmit.
                    CustomTextField(
                        text: $query,
                        selectedIndex: .constant(0),
                        itemCount: 0,
                        placeholder: "Filter shortcuts…",
                        fontSize: 20,
                        state: state,
                        onSubmit: { _ in state.cancel() }
                    )
                } else {
                    Text(state.placeholderText)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(Theme.text)
                    if pages.count > 1 {
                        HStack(spacing: 4) {
                            ForEach(pages, id: \.self) { p in
                                Text(p)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(p == activePage ? Theme.base : Theme.subtext)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(p == activePage ? Theme.mauve : Theme.surface1.opacity(0.5))
                                    .clipShape(Capsule())
                                    .onTapGesture { currentPage = p }
                            }
                        }
                        .padding(.leading, 8)
                    }
                }
                Spacer()
                Text(hintText)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Theme.subtext0)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Theme.surface1.opacity(0.5))
                    .clipShape(Capsule())
            }
            .padding(.horizontal, 24)
            .frame(height: CheatsheetLayout.headerHeight)

            Divider().background(Theme.surface1.opacity(0.3))

            if state.cheatsheetGroups.isEmpty {
                emptyBody
            } else if visibleGroups.isEmpty {
                noMatchBody
            } else {
                let cols = columns(for: visibleGroups)
                ScrollView {
                    HStack(alignment: .top, spacing: 24) {
                        ForEach(cols.indices, id: \.self) { i in
                            VStack(spacing: 24) {
                                ForEach(cols[i]) { group in
                                    GroupCard(group: group)
                                }
                            }
                        }
                    }
                    .padding(24)
                    // Report the columns' natural height so the frame below —
                    // and with it the window — can hug the content.
                    .background(GeometryReader { geo in
                        Color.clear.preference(key: ContentHeightKey.self, value: geo.size.height)
                    })
                }
                .frame(height: min(max(contentHeight, 120), maxBodyHeight))
                .onPreferenceChange(ContentHeightKey.self) { h in
                    guard abs(h - contentHeight) > 0.5 else { return }
                    contentHeight = h
                    state.onResize?()
                }
            }
        }
        .frame(width: CheatsheetLayout.width)
        .fixedSize(horizontal: false, vertical: true)
        // More opaque than the launcher's 0.55: this is a dense wall of 14pt
        // text, and whatever's behind the blur bleeds through smaller type.
        .background(Theme.base.opacity(0.75))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .contentShape(Rectangle())
        .onTapGesture { if !searching { state.cancel() } }
        .onAppear {
            // No text field until search starts, so nothing routes keys for
            // us — catch them app-locally while the sheet is up. "/" flips
            // into search (the field then owns the keys), ⇥ cycles pages;
            // anything else dismisses. Returning nil swallows the event so it
            // can't beep or leak into whatever becomes first responder next.
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard state.displayMode == .cheatsheet, state.isVisible else { return event }
                if searching { return event }
                if event.charactersIgnoringModifiers == "/",
                   event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
                    searching = true
                    return nil
                }
                if event.keyCode == 48, let next = nextPage {   // tab
                    currentPage = next
                    return nil
                }
                state.cancel()
                return nil
            }
        }
        .onDisappear {
            if let monitor = eventMonitor {
                NSEvent.removeMonitor(monitor)
                eventMonitor = nil
            }
        }
    }

    // A missing/unparseable file used to render as a giant blank panel — say
    // where pounce looked instead, so a typo'd path is a ten-second fix.
    var emptyBody: some View {
        VStack(spacing: 10) {
            Image(systemName: "questionmark.square.dashed")
                .font(.system(size: 32, weight: .regular))
                .foregroundColor(Theme.subtext0)
            Text("No cheatsheet at \((state.cheatsheetPath as NSString).abbreviatingWithTildeInPath)")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(Theme.subtext)
            Text("Expected a JSON array of { title, items: [{ key, action }] } groups.")
                .font(.system(size: 12))
                .foregroundColor(Theme.subtext0)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 260)
    }

    var noMatchBody: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 32, weight: .regular))
                .foregroundColor(Theme.subtext0)
            Text("No shortcuts match \u{201C}\(query)\u{201D}")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(Theme.subtext)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 260)
    }
}

struct GroupCard: View {
    let group: CheatsheetGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(group.title)
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(Theme.mauve)
                .padding(.bottom, 4)

            ForEach(group.items) { item in
                HStack(alignment: .top, spacing: 12) {
                    Text(item.key)
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .foregroundColor(Theme.text)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Theme.surface0)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Theme.surface2, lineWidth: 1)
                        )

                    Text(item.action)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(Theme.text)
                        .padding(.top, 3)

                    Spacer()
                }
            }
        }
        .padding(16)
        .background(Theme.surface1.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Theme.surface2.opacity(0.5), lineWidth: 1)
        )
    }
}
