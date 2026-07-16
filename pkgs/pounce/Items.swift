import Foundation

// MARK: - Data Types

enum ItemKind {
    case plain     // generic item from stdin (utility menus): client interprets it
    case command   // launcher command: selecting returns its id to the client
    case app       // launcher app: the daemon launches it natively
    case answer    // inline quick answer (calculator etc.): ⏎ copies it
}

struct ItemAction {
    let key: String      // "enter", "cmd", "opt", "ctrl"
    let label: String

    var displayKey: String {
        switch key {
        case "enter": return "↵"
        case "cmd": return "⌘↵"
        case "opt": return "⌥↵"
        case "ctrl": return "⌃↵"
        default: return key
        }
    }
}

struct PounceItem: Identifiable {
    let id = UUID()
    let raw: String
    let title: String
    // An extra name to fuzzy-match against, beyond the displayed `title` — for
    // apps whose Finder name (shown as `title`) differs from their Info.plist
    // bundle name, so "Ableton Live 11 Suite" stays findable by typing "live"
    // and "Visual Studio Code" by typing "code". nil for everything else.
    let searchAlias: String?
    let subtitle: String?
    let icon: String?
    let actions: [ItemAction]
    let kind: ItemKind
    let payload: String       // cmd id (command) / bundle path (app) / raw (plain)
    let frecencyKey: String   // stable key for usage history
    let baseBoost: Double     // recency boost for freshly-installed apps
    let group: String?        // optional section header; nil → flat (ungrouped) list
    let submenu: Bool         // command re-invokes pounce (two-step) → loading state

    // Generic stdin line: title \t subtitle \t icon \t actions \t group
    // The trailing `group` field is optional; when any line carries one the list
    // renders with section headers (see ContentView), otherwise it stays flat.
    static func parsePlain(_ line: String, globalIcon: String?) -> PounceItem {
        let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        let title = parts.count > 0 ? parts[0] : line
        let subtitle = parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil
        let icon = (parts.count > 2 && !parts[2].isEmpty ? parts[2] : nil) ?? globalIcon

        var actions: [ItemAction] = []
        if parts.count > 3 && !parts[3].isEmpty {
            let actionParts = parts[3].split(separator: "|").map(String.init)
            for (index, part) in actionParts.enumerated() {
                if index == 0 {
                    actions.append(ItemAction(key: "enter", label: part))
                } else if part.contains(":") {
                    let kv = part.split(separator: ":", maxSplits: 1).map(String.init)
                    if kv.count == 2 { actions.append(ItemAction(key: kv[0], label: kv[1])) }
                }
            }
        }
        if actions.isEmpty { actions.append(ItemAction(key: "enter", label: "Select")) }

        let group = parts.count > 4 && !parts[4].isEmpty ? parts[4] : nil

        return PounceItem(raw: line, title: title, searchAlias: nil, subtitle: subtitle, icon: icon,
                          actions: actions, kind: .plain, payload: line,
                          frecencyKey: title, baseBoost: 0, group: group, submenu: false)
    }

    // Launcher command registry line: name \t description \t icon \t id \t submenu(1|0)
    static func parseCommand(_ line: String) -> PounceItem {
        let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        let title = parts.count > 0 ? parts[0] : line
        let subtitle = parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil
        let icon = parts.count > 2 && !parts[2].isEmpty ? parts[2] : "sparkles"
        let id = parts.count > 3 ? parts[3] : title
        let submenu = parts.count > 4 && parts[4] == "1"
        return PounceItem(raw: line, title: title, searchAlias: nil, subtitle: subtitle, icon: icon,
                          actions: [ItemAction(key: "enter", label: "Run")],
                          kind: .command, payload: id,
                          frecencyKey: "cmd:\(id)", baseBoost: 0, group: nil, submenu: submenu)
    }

    // A quick answer (inline calculator & friends) pinned as the first row.
    // Query-derived, so it lives outside state.items/frecency: ContentView
    // prepends it per keystroke and commit() copies `payload` instead of
    // round-tripping to a client.
    static func answer(_ a: QuickAnswer) -> PounceItem {
        return PounceItem(raw: a.copyText, title: a.display, searchAlias: nil, subtitle: a.detail,
                          icon: a.icon,
                          actions: [ItemAction(key: "enter", label: "Copy Answer")],
                          kind: .answer, payload: a.copyText,
                          frecencyKey: "answer", baseBoost: 0, group: nil, submenu: false)
    }

    static func app(name: String, path: String, boost: Double, alias: String? = nil) -> PounceItem {
        return PounceItem(raw: path, title: name, searchAlias: alias, subtitle: "Application",
                          icon: "app:\(path)",
                          actions: [ItemAction(key: "enter", label: "Open"),
                                    ItemAction(key: "cmd", label: "Reveal in Finder")],
                          kind: .app, payload: path,
                          frecencyKey: "app:\(path)", baseBoost: boost, group: nil, submenu: false)
    }

    func action(for key: String) -> ItemAction? { actions.first { $0.key == key } }
}

// MARK: - Fuzzy Matching

enum Fuzzy {
    // Subsequence match with quality scoring. Returns nil if `query` is not a
    // subsequence of `target`. Higher = tighter / earlier / word-boundary match.
    static func score(_ query: [Character], _ target: String) -> Double? {
        let t = Array(target)
        guard !query.isEmpty else { return 0 }
        var qi = 0
        var score = 0.0
        var prevMatch = -2
        var firstIdx = -1

        for (ti, ch) in t.enumerated() {
            guard qi < query.count, ch == query[qi] else { continue }
            if firstIdx < 0 { firstIdx = ti }
            var s = 1.0
            if ti == prevMatch + 1 { s += 2.5 }                    // consecutive run
            if ti == 0 { s += 2.0 }                                // very start
            else {
                let p = t[ti - 1]
                if p == " " || p == "-" || p == "_" || p == "." { s += 1.5 } // word boundary
            }
            score += s
            prevMatch = ti
            qi += 1
        }
        guard qi == query.count else { return nil }

        // Reward tight targets and front-loaded matches.
        let coverage = Double(query.count) / Double(max(t.count, 1))
        let frontBonus = firstIdx == 0 ? 1.5 : 0
        return score + coverage * 2.0 + frontBonus
    }
}
