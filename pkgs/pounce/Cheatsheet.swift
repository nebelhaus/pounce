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
}

// MARK: - Store

enum CheatsheetStore {
    static func load(path: String) -> [CheatsheetGroup] {
        let expandedPath = (path as NSString).expandingTildeInPath
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: expandedPath)),
              let groups = try? JSONDecoder().decode([CheatsheetGroup].self, from: data) else {
            return []
        }
        return groups
    }
}

// MARK: - View

struct CheatsheetView: View {
    @ObservedObject var state: DaemonState
    @State private var eventMonitor: Any?

    // Split groups into 3 columns (masonry-style layout could be complex in pure SwiftUI without extra math,
    // so let's just lay them out in a LazyVGrid with fixed columns).
    let columns = [
        GridItem(.flexible(), spacing: 24, alignment: .top),
        GridItem(.flexible(), spacing: 24, alignment: .top),
        GridItem(.flexible(), spacing: 24, alignment: .top)
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "keyboard")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(Theme.subtext)
                Text(state.placeholderText)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(Theme.text)
                Spacer()
                Text("Press any key to dismiss")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Theme.subtext0)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Theme.surface1.opacity(0.5))
                    .clipShape(Capsule())
            }
            .padding(.horizontal, 24)
            .frame(height: 64)

            Divider().background(Theme.surface1.opacity(0.3))

            // Content
            ScrollView {
                // Using a simple grid approach where each group fills a cell.
                // Masonry is better achieved by pre-computing 3 columns of groups,
                // but for now a LazyVGrid with alignment top will stack them into rows.
                // A better masonry:
                HStack(alignment: .top, spacing: 24) {
                    ForEach(0..<3, id: \.self) { colIndex in
                        VStack(spacing: 24) {
                            ForEach(columnGroups(for: colIndex)) { group in
                                GroupCard(group: group)
                            }
                        }
                    }
                }
                .padding(24)
            }
            .frame(height: CheatsheetLayout.height - 64)
        }
        .frame(width: CheatsheetLayout.width)
        .fixedSize(horizontal: false, vertical: true)
        .background(Theme.base.opacity(0.65))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .onAppear {
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                state.cancel()
                return event
            }
        }
        .onDisappear {
            if let monitor = eventMonitor {
                NSEvent.removeMonitor(monitor)
                eventMonitor = nil
            }
        }
    }

    // Distribute groups across columns round-robin.
    func columnGroups(for col: Int) -> [CheatsheetGroup] {
        var res: [CheatsheetGroup] = []
        for (i, g) in state.cheatsheetGroups.enumerated() {
            if i % 3 == col { res.append(g) }
        }
        return res
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
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
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
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(Theme.subtext0)
                        .padding(.top, 2)
                    
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
