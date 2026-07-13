import AppKit
import ApplicationServices

// MARK: - Focus (hush)

// `pounce focus <status|toggle|on|off>` — the privileged half of nebelhaus's
// hush room. macOS has no public API to set a Focus, so nebelhaus binds the
// "Turn Do Not Disturb On/Off" symbolic hotkey (AppleSymbolicHotKeys 175)
// declaratively to ⌃⌥⇧⌘F13 and this subcommand presses that chord
// synthetically; state is read from the DoNotDisturb assertions DB.
//
// TCC is the whole reason this lives in pounce — and TCC checks the
// RESPONSIBLE process, not the binary: `pounce focus` spawned by sketchybar
// (the bar pill) or a terminal is attributed to THAT app, so the signed
// copy's grants only count when pounce answers for itself. The daemon
// (launchd-spawned from ~/.local/state/pounce/Pounce.app — see nebelhaus
// modules/pounce) IS its own responsible process, so when the calling
// context lacks a grant the op is forwarded over the pounce socket and runs
// under the daemon's Accessibility / Full Disk Access. One pair of
// checkboxes on Pounce.app covers every caller: bar pill, palette, scripts,
// any terminal.
//
// Exit codes are the contract hush scripts rely on:
//   0  done (status printed / chord pressed / already in the wanted state)
//   1  pressed but the DB never showed the wanted state (on|off only)
//   2  DB unreadable — no Full Disk Access here or in the daemon
//   3  no Accessibility grant anywhere — refuse to press blind
//   64 usage
enum FocusMode {
    // ⌃⌥⇧⌘ F13 — lockstep with modules/hush in the nebelhaus repo. The
    // binding (1966080) is only the four modifiers, but the synthetic press
    // must ALSO carry .maskSecondaryFn: physical F-key events always have the
    // fn bit set, and the hotkey matcher rejects an F13 chord without it.
    static let keyCode: CGKeyCode = 105
    static let chordFlags: CGEventFlags = [
        .maskControl, .maskAlternate, .maskShift, .maskCommand, .maskSecondaryFn,
    ]
    static let dbPath = NSString(string: "~/Library/DoNotDisturb/DB/Assertions.json").expandingTildeInPath

    // Everything perform() can report, kept exit-free so the daemon can run
    // the same code without a CLI-style exit() killing it.
    struct Outcome {
        let code: Int32
        var out = ""   // stdout payload ("on"/"off" for status)
        var err = ""   // human hint, printed to stderr by the CLI
    }

    // CLI entry: run locally when this context holds the needed grants,
    // otherwise hand the whole op to the daemon. If no daemon answers (not
    // running, or too old to know FOCUS never happens — hush always calls
    // the same signed copy the daemon runs from), fall through to the local
    // attempt so the error message and exit code match the old behavior.
    static func run(op: String?) -> Never {
        let operation = op ?? ""
        guard ["status", "toggle", "on", "off"].contains(operation) else {
            finish(Outcome(code: 64, err: "usage: pounce focus <status|toggle|on|off>"))
        }
        let localOK: Bool
        switch operation {
        case "status": localOK = readState() != nil
        case "toggle": localOK = AXIsProcessTrusted()
        default: localOK = AXIsProcessTrusted() && readState() != nil
        }
        if !localOK, let reply = askDaemon(operation) {
            if reply.hasPrefix("err\t") {
                let parts = reply.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                finish(Outcome(code: parts.count > 1 ? Int32(parts[1]) ?? 1 : 1,
                               err: parts.count > 2 ? parts[2] : ""))
            }
            finish(Outcome(code: 0, out: operation == "status" ? reply : ""))
        }
        finish(perform(operation))
    }

    static func finish(_ r: Outcome) -> Never {
        if !r.out.isEmpty { print(r.out) }
        if !r.err.isEmpty { warn(r.err) }
        exit(r.code)
    }

    // The exit-free core — shared verbatim by the CLI and the daemon's
    // FOCUS socket handler (Entry.swift).
    static func perform(_ operation: String) -> Outcome {
        switch operation {
        case "status":
            guard let on = readState() else { return noFDA() }
            return Outcome(code: 0, out: on ? "on" : "off")
        case "toggle":
            return press()
        case "on", "off":
            // Deterministic form: needs a readable DB, presses only on a real
            // state change, and verifies the DB agrees before reporting done.
            let want = (operation == "on")
            guard let current = readState() else { return noFDA() }
            if current == want { return Outcome(code: 0) }
            let pressed = press()
            if pressed.code != 0 { return pressed }
            for _ in 0..<20 {           // the DB updates asynchronously
                usleep(100_000)
                if readState() == want { return Outcome(code: 0) }
            }
            return Outcome(code: 1, err: "pressed the chord but the DoNotDisturb DB never read '\(operation)' — is symbolic hotkey 175 bound? (darwin-rebuild switch re-binds it)")
        default:
            return Outcome(code: 64, err: "usage: pounce focus <status|toggle|on|off>")
        }
    }

    // An active Focus shows up as assertion records on this device. Absent
    // records = no Focus. nil = the DB itself is unreadable (no FDA).
    static func readState() -> Bool? {
        guard let data = FileManager.default.contents(atPath: dbPath),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let outer = json["data"] as? [[String: Any]]
        else { return nil }
        let records = outer.first?["storeAssertionRecords"] as? [[String: Any]] ?? []
        return !records.isEmpty
    }

    static func press() -> Outcome {
        guard AXIsProcessTrusted() else {
            return Outcome(code: 3, err: "no Accessibility grant for this context — grant the signed Pounce.app once (pounce --request-accessibility) and keep its daemon running; it presses on behalf of any caller")
        }
        // .combinedSessionState, not .hidSystemState: an hidSystemState source
        // re-derives modifier flags from the real keyboard state, stripping the
        // synthetic chord's flags — the matcher then never sees ⌃⌥⇧⌘fn.
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else {
            return Outcome(code: 1, err: "could not create the keyboard event")
        }
        down.flags = chordFlags
        up.flags = chordFlags
        down.post(tap: .cghidEventTap)
        usleep(20_000)
        up.post(tap: .cghidEventTap)
        return Outcome(code: 0)
    }

    static func noFDA() -> Outcome {
        Outcome(code: 2, err: "cannot read \(dbPath) — grant Full Disk Access to the signed Pounce.app (System Settings → Privacy & Security → Full Disk Access)")
    }

    // One round-trip to the resident daemon: "FOCUS\t<op>\n" in, one reply
    // line out ("ok", "on"/"off", or "err\t<code>\t<hint>"). nil when no
    // daemon answers — the caller falls back to the local attempt.
    static func askDaemon(_ operation: String) -> String? {
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
        let connected = withUnsafePointer(to: &addr, { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, addrLen) }
        }) == 0
        guard connected else { return nil }

        let payload = "FOCUS\t\(operation)\n".data(using: .utf8)!
        payload.withUnsafeBytes { ptr in _ = write(fd, ptr.baseAddress!, payload.count) }
        shutdown(fd, SHUT_WR)

        var replyData = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            replyData.append(contentsOf: buf[0..<n])
        }
        guard let reply = String(data: replyData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !reply.isEmpty else { return nil }
        return reply
    }

    static func warn(_ message: String) {
        FileHandle.standardError.write(Data(("pounce focus: " + message + "\n").utf8))
    }
}
