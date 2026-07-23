import Foundation

// MARK: - Command discovery (daemon-side)

// Owns command discovery so the in-process launcher never shells out. The bash
// launcher (pounce-palette) rebuilt this on *every* ⌘Space — a mktemp, a dozen
// symlinks, and an awk fork per command — to produce a byte-identical registry
// each time. Here the daemon scans the same directories once and re-reads a
// script only when its mtime changes (a stat, not a subprocess), then spawns the
// selected script itself with no client round-trip.
//
// Discovery order mirrors pounce-palette exactly (later shadows earlier by id):
//   POUNCE_BUILTIN_DIR
//   POUNCE_EXTRA_COMMAND_DIRS   (colon-separated)
//   POUNCE_COMMAND_PATH         (colon-separated)
//   ~/.config/pounce/commands
//
// The daemon reads these from its OWN environment, so the launch agent that
// starts the daemon must export the same values the pounce-palette wrapper does
// (see nebelhaus/modules/pounce). Missing dirs are simply skipped.
final class CommandRegistry {
    struct Entry {
        let id: String
        let name: String
        let description: String
        let icon: String
        let submenu: Bool
        let scriptPath: String

        // The tab-separated line the launcher parses (PounceItem.parseCommand):
        //   name \t description \t icon \t id \t submenu(1|0)
        var registryLine: String {
            "\(name)\t\(description)\t\(icon)\t\(id)\t\(submenu ? "1" : "0")"
        }
    }

    private struct Header {
        var name = ""
        var description = ""
        var icon = ""
        var submenu = false
    }

    private let env: [String: String]
    private let home: String

    // scriptPath → (mtime, parsed header), so an unchanged file is never re-read.
    private var headerCache: [String: (mtime: TimeInterval, header: Header)] = [:]

    // Result of the last refresh(): entries in id order, plus the id→path map the
    // spawner uses on selection.
    private(set) var entries: [Entry] = []
    private var scriptByID: [String: String] = [:]

    init(env: [String: String] = ProcessInfo.processInfo.environment,
         home: String = FileManager.default.homeDirectoryForCurrentUser.path) {
        self.env = env
        self.home = home
    }

    func scriptPath(for id: String) -> String? { scriptByID[id] }

    // Re-resolve the id→script map and (re)parse changed headers. Cheap enough to
    // call on every hotkey press: it lists a handful of dirs and stats a dozen
    // files; only genuinely-changed scripts are re-read.
    func refresh() {
        var resolved: [String: String] = [:]   // id → path (later dir wins)
        for dir in searchDirs() {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for name in names.sorted() {
                let path = dir + "/" + name
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue
                else { continue }
                let id = idFromFilename(name)
                resolved[id] = path   // later dir in the search order shadows earlier
            }
        }

        var built: [Entry] = []
        for id in resolved.keys.sorted() {
            let path = resolved[id]!
            let header = header(forScriptAt: path)
            built.append(Entry(
                id: id,
                name: header.name.isEmpty ? id : header.name,
                description: header.description,
                icon: header.icon.isEmpty ? "sparkles" : header.icon,
                submenu: header.submenu,
                scriptPath: path))
        }

        entries = built
        scriptByID = resolved
        // Drop cache entries for scripts that no longer resolve.
        let live = Set(resolved.values)
        headerCache = headerCache.filter { live.contains($0.key) }
    }

    // MARK: - Internals

    private func searchDirs() -> [String] {
        var dirs: [String] = []
        // The built-in set. A packager's launch agent is expected to export
        // POUNCE_BUILTIN_DIR (the Nix rice does); when it doesn't — notably the
        // Homebrew launchd service, which only sets LANG — fall back to the same
        // default pounce-palette uses (<prefix>/share/pounce/commands, derived
        // from the executable). Without this the in-process launcher finds zero
        // built-ins (Emoji, Clipboard, Find Files, …) while apps still list,
        // since AppScanner needs no environment. Missing dirs are skipped later.
        if let builtin = env["POUNCE_BUILTIN_DIR"], !builtin.isEmpty {
            dirs.append(builtin)
        } else if let fallback = Self.defaultBuiltinDir() {
            dirs.append(fallback)
        }
        for key in ["POUNCE_EXTRA_COMMAND_DIRS", "POUNCE_COMMAND_PATH"] {
            if let value = env[key], !value.isEmpty {
                dirs.append(contentsOf: value.split(separator: ":").map(String.init))
            }
        }
        let configHome = env["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? (home + "/.config")
        dirs.append(configHome + "/pounce/commands")
        return dirs
    }

    // The built-in command dir relative to the running binary, for launchers
    // that don't export POUNCE_BUILTIN_DIR. Mirrors pounce-palette's
    // `<script dir>/../share/pounce/commands` default. The daemon runs as the
    // bundle executable (<prefix>/Pounce.app/Contents/MacOS/pounce), so the
    // keg's share dir is four components up; a plain `<prefix>/bin/pounce`
    // layout is one deletion shallower — try both, return the first that exists.
    private static func defaultBuiltinDir() -> String? {
        guard let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
        let candidates = [
            exe.deletingLastPathComponent()   // …/Contents/MacOS
               .deletingLastPathComponent()   // …/Contents
               .deletingLastPathComponent()   // …/Pounce.app
               .deletingLastPathComponent()   // <prefix>
               .appendingPathComponent("share/pounce/commands"),
            exe.deletingLastPathComponent()   // …/bin
               .deletingLastPathComponent()   // <prefix>
               .appendingPathComponent("share/pounce/commands"),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }?.path
    }

    private func idFromFilename(_ name: String) -> String {
        name.hasSuffix(".sh") ? String(name.dropLast(3)) : name
    }

    private func header(forScriptAt path: String) -> Header {
        let mtime = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)?
            .timeIntervalSinceReferenceDate ?? 0
        if let cached = headerCache[path], cached.mtime == mtime { return cached.header }
        let parsed = parseHeader(at: path)
        headerCache[path] = (mtime, parsed)
        return parsed
    }

    // Read the `# pounce: key = value` header. Headers live at the top of the
    // file, so we stop after the first 30 lines rather than slurping whole
    // scripts — the same bound the awk in pounce-palette used.
    private func parseHeader(at path: String) -> Header {
        var header = Header()
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return header }
        var seen = 0
        for line in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            seen += 1
            if seen > 30 { break }
            guard let value = value(of: line, after: "# pounce:") else { continue }
            if let v = field(value, "name"), header.name.isEmpty { header.name = v }
            else if let v = field(value, "description"), header.description.isEmpty { header.description = v }
            else if let v = field(value, "icon"), header.icon.isEmpty { header.icon = v }
            else if let v = field(value, "submenu") { header.submenu = (v == "true" || v == "1") }
        }
        return header
    }

    private func value(of line: Substring, after prefix: String) -> Substring? {
        let trimmed = line.drop { $0 == " " || $0 == "\t" }
        guard trimmed.hasPrefix(prefix) else { return nil }
        return trimmed.dropFirst(prefix.count)
    }

    // "key = value" → value, if `rest` names `key`. Whitespace-tolerant to match
    // the awk header parser (`# pounce: name  =  Foo`).
    private func field(_ rest: Substring, _ key: String) -> String? {
        let s = rest.drop { $0 == " " || $0 == "\t" }
        guard s.hasPrefix(key) else { return nil }
        let afterKey = s.dropFirst(key.count).drop { $0 == " " || $0 == "\t" }
        guard afterKey.first == "=" else { return nil }
        return afterKey.dropFirst().drop { $0 == " " || $0 == "\t" }
            .trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Spawning the selected command

// Runs a selected command script detached from the daemon, the way pounce-palette
// used to `exec` it. Submenu commands re-invoke `pounce` (the client), so the
// child's PATH gets this binary's directory prepended so that resolves.
enum CommandSpawner {
    static func run(scriptPath: String) {
        let process = Process()
        var environment = ProcessInfo.processInfo.environment
        let binDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().path
        environment["PATH"] = binDir + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        process.environment = environment

        // Mirror pounce-palette: exec directly when executable, else run via bash.
        if FileManager.default.isExecutableFile(atPath: scriptPath) {
            process.executableURL = URL(fileURLWithPath: scriptPath)
        } else {
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [scriptPath]
        }
        process.terminationHandler = { _ in }   // reap asynchronously; never block the daemon
        do {
            try process.run()
        } catch {
            NSLog("pounce daemon: failed to spawn command \(scriptPath): \(error)")
        }
    }
}
