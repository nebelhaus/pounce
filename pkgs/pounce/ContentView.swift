import SwiftUI

// MARK: - ContentView

struct ContentView: View {
    @ObservedObject var state: DaemonState
    @State private var selectedIndex = 0
    @State private var revealed = false   // compact mode: list shown after ↓ / typing

    var rowHeight: CGFloat { state.metrics.rowHeight }
    var maxVisibleItems: Int { state.metrics.maxVisibleItems }

    var queryIsEmpty: Bool {
        state.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // True when any item carries a group → render with section headers.
    var hasGroups: Bool { state.items.contains { $0.group != nil } }

    // Distinct groups in first-seen (input) order; this is the section order.
    var groupOrder: [String] {
        var seen = Set<String>(); var order: [String] = []
        for it in state.items {
            if let g = it.group, !seen.contains(g) { seen.insert(g); order.append(g) }
        }
        return order
    }

    // Re-bucket a priority-ordered list into section order, preserving each
    // item's incoming order within its section. (Swift's sort isn't stable, so
    // we bucket explicitly rather than sort by group index.)
    func grouped(_ items: [PounceItem]) -> [PounceItem] {
        guard hasGroups else { return items }
        var buckets: [String: [PounceItem]] = [:]
        for it in items { buckets[it.group ?? "", default: []].append(it) }
        return groupOrder.flatMap { buckets[$0] ?? [] }
    }

    var filtered: [PounceItem] {
        let trimmed = state.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let base: [PounceItem]
        if queryIsEmpty {
            base = Array(state.itemsSorted.prefix(state.maxEmpty))
        } else {
            let q = Array(trimmed.lowercased())
            let scored = state.items.compactMap { item -> (PounceItem, Double)? in
                guard let s = state.matchScore(item, query: q) else { return nil }
                return (item, s)
            }
            base = scored.sorted { $0.1 > $1.1 }.map { $0.0 }
        }
        let rows = grouped(base)
        // Expression-shaped query? Pin its quick answer (inline calculator,
        // conversions, …) above the matches; ⏎ on it copies.
        if let answer = state.quickAnswerItem(for: trimmed) { return [answer] + rows }
        return rows
    }

    // In compact mode the launcher hides its list on an empty query until the
    // user types or presses ↓. This is a launcher-only affordance — utility /
    // second-step menus (ports, brew, force-quit…) always show their list.
    var showList: Bool {
        if !queryIsEmpty { return true }
        if state.isLauncher && state.metrics.hideEmptyList { return revealed }
        return true
    }

    var visible: [PounceItem] { showList ? filtered : [] }

    var selectedItem: PounceItem? {
        guard selectedIndex < visible.count else { return nil }
        return visible[selectedIndex]
    }

    // Render model: section headers interleaved with the selectable items.
    // `index` is the position in `visible` (headers are not selectable, so
    // keyboard nav over `visible` skips them for free).
    enum RenderRow: Identifiable {
        case header(String)
        case item(PounceItem, Int)
        var id: String {
            switch self {
            case .header(let g): return "header:\(g)"
            case .item(let it, _): return "item:\(it.id)"
            }
        }
    }

    var renderRows: [RenderRow] {
        var rows: [RenderRow] = []
        var lastGroup: String?? = .none
        for (i, item) in visible.enumerated() {
            if hasGroups, item.group != (lastGroup ?? nil) {
                if let g = item.group { rows.append(.header(g)) }
                lastGroup = .some(item.group)
            }
            rows.append(.item(item, i))
        }
        return rows
    }

    var listHeight: CGFloat {
        let cap = min(visible.count, maxVisibleItems)
        guard hasGroups else { return CGFloat(cap) * rowHeight }
        // Fit `cap` items plus whatever headers precede them in the window.
        var items = 0, headers = 0
        for row in renderRows {
            if items >= cap { break }
            switch row {
            case .header: headers += 1
            case .item: items += 1
            }
        }
        return CGFloat(cap) * rowHeight + CGFloat(headers) * GroupHeaderRow.height
    }

    var body: some View {
        Group {
            if state.isLoading {
                SkeletonView(state: state)
            } else if state.displayMode == .clipboard {
                ClipboardView(state: state)
            } else if state.displayMode == .emoji {
                EmojiView(state: state)
            } else if state.displayMode == .screenshots {
                ScreenshotsView(state: state)
            } else if state.displayMode == .camera {
                CameraView(state: state)
            } else if state.displayMode == .cheatsheet {
                CheatsheetView(state: state)
            } else {
                launcherBody
            }
        }
        // New identity per request resets the child views' @State (clipboard /
        // emoji / screenshots queries).
        .id(state.requestID)
        // query itself is cleared synchronously in reset() (no flash). These are
        // local @State, so reset them per request here.
        .onReceive(state.$requestID) { _ in
            selectedIndex = 0
            revealed = false
        }
    }

    var launcherBody: some View {
        VStack(spacing: 0) {
            // Search header
            HStack(spacing: 12) {
                Image(systemName: state.globalIcon ?? "magnifyingglass")
                    .font(.system(size: state.metrics.searchIconSize, weight: .medium))
                    .foregroundColor(Theme.subtext)
                CustomTextField(
                    text: $state.query,
                    selectedIndex: $selectedIndex,
                    itemCount: visible.count,
                    placeholder: state.placeholderText,
                    fontSize: state.metrics.searchFontSize,
                    state: state,
                    onSubmit: { action in select(action: action) },
                    onRevealDown: { revealed = true }
                )
            }
            .padding(.horizontal, 20)
            .frame(height: state.metrics.headerHeight)

            if !visible.isEmpty {
                Divider().background(Theme.surface1.opacity(0.3))

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(renderRows) { row in
                                switch row {
                                case .header(let title):
                                    GroupHeaderRow(title: title)
                                        .frame(height: GroupHeaderRow.height)
                                        .id(row.id)
                                case .item(let item, let i):
                                    Group {
                                        if item.kind == .answer {
                                            AnswerRow(item: item, isSelected: i == selectedIndex)
                                        } else {
                                            ItemRow(item: item, isSelected: i == selectedIndex)
                                        }
                                    }
                                    .frame(height: rowHeight)
                                    .id(item.id)
                                    .onTapGesture { selectedIndex = i; select(action: "enter") }
                                }
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    .frame(height: listHeight + 12)
                    .onChange(of: selectedIndex) {
                        if selectedIndex < visible.count { proxy.scrollTo(visible[selectedIndex].id) }
                    }
                }

                if let item = selectedItem {
                    Divider().background(Theme.surface1.opacity(0.3))
                    ActionBar(actions: item.actions)
                        .frame(height: 44)
                }
            }
        }
        .frame(width: state.metrics.width)
        .fixedSize(horizontal: false, vertical: true)
        .background(Theme.base.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .onChange(of: state.query) { selectedIndex = 0; revealed = false }
        .onChange(of: visible.count) { state.onResize?() }
        .onChange(of: renderRows.count) { state.onResize?() }
        .onChange(of: state.requestID) { selectedIndex = 0; revealed = false; state.onResize?() }
    }

    func select(action: String) {
        if visible.isEmpty {
            if !state.query.isEmpty { state.commitText(state.query) } else { state.cancel() }
            return
        }
        guard selectedIndex < visible.count else { state.cancel(); return }
        state.commit(visible[selectedIndex], action: action)
    }
}

// MARK: - Loading (skeleton) View

// Shown between a two-step command's steps. The search header stays put — now
// carrying the command's name + icon with a cleared field, matching the step-2
// header that's about to arrive — while the results area shows pulsing skeleton
// rows. Reads as "results loading", not a window reload.
struct SkeletonView: View {
    @ObservedObject var state: DaemonState

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: state.loadingIcon)
                    .font(.system(size: state.metrics.searchIconSize, weight: .medium))
                    .foregroundColor(Theme.subtext)
                Text(state.loadingTitle)
                    .font(.system(size: state.metrics.searchFontSize, weight: .regular))
                    .foregroundColor(Theme.subtext0)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 20)
            .frame(height: state.metrics.headerHeight)

            Divider().background(Theme.surface1.opacity(0.3))

            // Fill the window at its CURRENT height (it isn't resized when loading
            // begins) with exactly enough skeleton rows — no arbitrary intermediary
            // height. The single animated resize happens when step 2's data lands.
            GeometryReader { geo in
                let n = max(1, Int(geo.size.height / state.metrics.rowHeight))
                VStack(spacing: 0) {
                    ForEach(0..<n, id: \.self) { i in
                        SkeletonRow(delay: Double(i) * 0.1)
                            .frame(height: state.metrics.rowHeight)
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(.vertical, 6)
        }
        .frame(width: state.targetWidth)
        .frame(maxHeight: .infinity)
        .background(Theme.base.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

// A single placeholder row with a staggered, gentle pulse.
struct SkeletonRow: View {
    let delay: Double
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 6)
                .fill(Theme.surface1)
                .frame(width: 24, height: 24)
            RoundedRectangle(cornerRadius: 5)
                .fill(Theme.surface1)
                .frame(width: 150, height: 11)
            Spacer()
        }
        .padding(.horizontal, 18)
        .opacity(pulse ? 0.9 : 0.3)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true).delay(delay)) {
                pulse = true
            }
        }
    }
}
