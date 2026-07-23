import Foundation
import ApplicationServices

// MARK: - pounce doctor
//
// A one-shot health check for the palette hotkey path. It exists because a
// whole class of "pounce is slow / won't open" reports trace to the SAME root
// cause: an external hotkey tool (skhd, AeroSpace, Raycast) is bound to the same
// key pounce registers, so the keypress never reaches the daemon's fast
// in-process path and instead spawns a client on every summon. That failure is
// invisible — registration reports success, the palette still opens (slowly) —
// so it historically cost many rounds of back-and-forth to find. doctor surfaces
// it, and the neighbouring snags (daemon down, missing Accessibility, a macOS
// system-shortcut clash), in one command.
//
// It combines two views: what the live daemon knows about itself (queried over
// the socket — only it knows whether the in-process hotkey has actually FIRED)
// and what the environment looks like from outside (system shortcuts, running
// hotkey daemons, their configs).

enum DoctorMode {
    private struct Status {
        let version: String
        let accessibility: Bool
        let hotkeyEnabled: Bool
        let hotkeyCombo: String
        let hotkeyRegistered: Bool
        let hotkeyReceived: Bool
    }

    static func run() {
        let settings = Settings.load()
        let status = queryDaemon()
        let combo = status?.hotkeyCombo
            ?? "\(settings.hotkey.modifiers.joined(separator: "+"))+\(settings.hotkey.key)"

        var lines: [String] = []
        var problems: [String] = []
        func ok(_ s: String)   { lines.append("  \u{2714} \(s)") }
        func warn(_ s: String) { lines.append("  \u{26A0} \(s)") }
        func bad(_ s: String)  { lines.append("  \u{2718} \(s)") }

        print("pounce doctor\n")

        // Daemon + version.
        if let status {
            ok("daemon running — version \(status.version)")
        } else {
            bad("daemon not running — start it: `brew services start pounce`")
            problems.append("The daemon isn't running, so nothing responds to the hotkey.")
        }

        // Accessibility (only knowable from the daemon's own identity).
        if let status {
            if status.accessibility {
                ok("Accessibility granted")
            } else {
                warn("Accessibility not granted — auto-paste, the \u{2318}Tab switcher, and "
                     + "--transform need it (`pounce --request-accessibility`)")
            }
        }

        // The crux: registered vs. actually received.
        if let status, !status.hotkeyEnabled {
            warn("in-process hotkey disabled in config (hotkey.enabled=false) — you're "
                 + "relying on an external tool to bind \(combo)")
        } else if let status {
            if status.hotkeyRegistered {
                ok("hotkey \(combo) registered")
            } else {
                bad("hotkey \(combo) failed to register — another app already owns it")
                problems.append("Another app holds \(combo); pounce couldn't register it.")
            }
            if status.hotkeyReceived {
                ok("hotkey has fired — you're on the fast in-process path")
            } else if status.hotkeyRegistered {
                bad("hotkey \(combo) has NEVER fired since the daemon started")
                problems.append("\(combo) is registered but has never reached pounce — "
                                + "something is intercepting it (see below).")
            }
        }

        // A macOS system shortcut on the same combo (Spotlight, input sources, …).
        if let conflict = HotKeyConflict.systemConflict(keyName: settings.hotkey.key,
                                                        modifierNames: settings.hotkey.modifiers) {
            bad("\(combo) is also bound to \(conflict) — macOS routes the key there")
            problems.append("Disable that shortcut: System Settings \u{2192} Keyboard \u{2192} "
                            + "Keyboard Shortcuts.")
        } else {
            ok("no macOS system shortcut on \(combo)")
        }

        // External hotkey daemons that could be intercepting the key with an event tap.
        let daemons = runningHotkeyDaemons()
        if daemons.isEmpty {
            ok("no external hotkey daemons running")
        } else {
            for d in daemons { warn("external hotkey daemon running: \(d)") }
        }

        // Their configs, scanned for a binding that runs the pounce LAUNCHER
        // (pounce-palette / `pounce --launcher`) — the thing that duplicates the
        // in-process hotkey. Sub-command bindings (--emoji, --clipboard on other
        // keys) are legitimate and deliberately not flagged. A launcher binding
        // is only a *problem* when the in-process hotkey has never fired (i.e.
        // it's actually shadowing it); otherwise it's a benign redundancy.
        let hotkeyDead = (status?.hotkeyEnabled ?? true) && !(status?.hotkeyReceived ?? false)
        let binds = configBindings()
        for b in binds {
            if hotkeyDead {
                bad("launcher binding shadowing your hotkey — \(b.file):\(b.line)  \(b.text)")
            } else {
                warn("redundant launcher binding — \(b.file):\(b.line)  \(b.text)")
            }
        }
        if hotkeyDead, let b = binds.first {
            problems.append("Remove the pounce-launcher binding in \(b.file) so the daemon's own "
                            + "hotkey receives the key (e.g. `skhd --stop-service`, or delete the line).")
        }
        if binds.isEmpty, !daemons.isEmpty, hotkeyDead {
            lines.append("    (no launcher binding found in the usual configs — check the running "
                         + "tool's own settings for whatever is bound to \(combo))")
        }

        print(lines.joined(separator: "\n"))
        print("")

        if problems.isEmpty {
            print("\u{25B6} Healthy. \(combo) reaches pounce's fast in-process path.")
            exit(0)
        }
        print("\u{25B6} Likely issue\(problems.count == 1 ? "" : "s"):")
        for p in problems { print("  \u{2022} \(p)") }
        exit(1)
    }

    // MARK: Daemon query

    // Ask the running daemon for its live state (STATUS verb, JSON reply). Returns
    // nil if the daemon isn't listening.
    private static func queryDaemon() -> Status? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            SocketConfig.path.withCString { cstr in
                _ = memcpy(ptr, cstr, min(strlen(cstr) + 1, MemoryLayout.size(ofValue: ptr.pointee)))
            }
        }
        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, addrLen) }
        } == 0
        guard connected else { return nil }

        let req = Data("STATUS\n".utf8)
        req.withUnsafeBytes { ptr in _ = write(fd, ptr.baseAddress!, req.count) }
        shutdown(fd, SHUT_WR)

        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            data.append(contentsOf: buf[0..<n])
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return Status(
            version: obj["version"] as? String ?? "?",
            accessibility: obj["accessibility"] as? Bool ?? false,
            hotkeyEnabled: obj["hotkeyEnabled"] as? Bool ?? false,
            hotkeyCombo: obj["hotkeyCombo"] as? String ?? "",
            hotkeyRegistered: obj["hotkeyRegistered"] as? Bool ?? false,
            hotkeyReceived: obj["hotkeyReceived"] as? Bool ?? false)
    }

    // MARK: Environment probes

    // Running processes that grab global hotkeys via their own event tap (which
    // sits ahead of Carbon's RegisterEventHotKey, so they win the key). Name →
    // pgrep pattern; report the friendly names found.
    private static func runningHotkeyDaemons() -> [String] {
        let probes: [(name: String, pattern: String)] = [
            ("skhd", "skhd"),
            ("AeroSpace", "AeroSpace"),
            ("Raycast", "Raycast"),
            ("Karabiner-Elements", "karabiner"),
            ("Hammerspoon", "Hammerspoon"),
            ("BetterTouchTool", "BetterTouchTool"),
            ("Keyboard Maestro", "Keyboard Maestro"),
        ]
        return probes.filter { pgrepMatches($0.pattern) }.map(\.name)
    }

    private static func pgrepMatches(_ pattern: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-i", "-f", pattern]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    private struct Binding { let file: String; let line: Int; let text: String }

    // Scan the usual external-hotkey configs for a binding that runs the pounce
    // LAUNCHER — `pounce-palette` or `pounce --launcher` — the stale
    // `cmd - space : pounce-palette` class that shadows the in-process hotkey.
    // Sub-command invocations (pounce --emoji, pounce-clipboard, …) are a
    // deliberate, legitimate pattern and are NOT flagged.
    private static func configBindings() -> [Binding] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let files = [
            "\(home)/.config/skhd/skhdrc",
            "\(home)/.skhdrc",
            "\(home)/.config/aerospace/aerospace.toml",
            "\(home)/.aerospace.toml",
        ]
        var found: [Binding] = []
        for path in files {
            guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            for (i, raw) in contents.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("#") { continue }
                if launchesPounceLauncher(line) {
                    found.append(Binding(file: prettyHome(path), line: i + 1, text: line))
                }
            }
        }
        return found
    }

    // True only for launcher invocations: pounce-palette, or `pounce … --launcher`.
    private static func launchesPounceLauncher(_ line: String) -> Bool {
        let l = line.lowercased()
        if l.contains("pounce-palette") { return true }
        if l.contains("pounce") && l.contains("--launcher") { return true }
        return false
    }

    private static func prettyHome(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
