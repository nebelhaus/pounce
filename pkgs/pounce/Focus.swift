import AppKit
import ApplicationServices

// MARK: - Focus (hush)

// `pounce focus <status|toggle|on|off>` — the privileged half of nebelhaus's
// hush room. macOS has no public API to set a Focus, so nebelhaus binds the
// "Turn Do Not Disturb On/Off" symbolic hotkey (AppleSymbolicHotKeys 175)
// declaratively to ⌃⌥⇧⌘F13 and this subcommand presses that chord
// synthetically; state is read from the DoNotDisturb assertions DB.
//
// TCC is the whole reason this lives in pounce: run from the STABLE-SIGNED
// daemon copy (~/.local/state/pounce/Pounce.app — see nebelhaus
// modules/pounce), the Accessibility grant (keypress) and Full Disk Access
// grant (DB read) stick across rebuilds. The store binary is adhoc-signed
// and holds no grants.
//
// Exit codes are the contract hush scripts rely on:
//   0  done (status printed / chord pressed / already in the wanted state)
//   1  pressed but the DB never showed the wanted state (on|off only)
//   2  DB unreadable — no Full Disk Access in this context
//   3  no Accessibility grant — refuse to press blind
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

    static func run(op: String?) -> Never {
        let operation = op ?? ""
        switch operation {
        case "status":
            guard let on = readState() else { dieNoFDA() }
            print(on ? "on" : "off")
            exit(0)
        case "toggle":
            press()
            exit(0)
        case "on", "off":
            // Deterministic form: needs a readable DB, presses only on a real
            // state change, and verifies the DB agrees before reporting done.
            let want = (operation == "on")
            guard let current = readState() else { dieNoFDA() }
            if current == want { exit(0) }
            press()
            for _ in 0..<20 {           // the DB updates asynchronously
                usleep(100_000)
                if readState() == want { exit(0) }
            }
            warn("pressed the chord but the DoNotDisturb DB never read '\(operation)' — is symbolic hotkey 175 bound? (darwin-rebuild switch re-binds it)")
            exit(1)
        default:
            warn("usage: pounce focus <status|toggle|on|off>")
            exit(64)
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

    static func press() {
        guard AXIsProcessTrusted() else {
            warn("no Accessibility grant for this binary — grant the signed Pounce.app (pounce --request-accessibility), or this call inherits nothing to press with")
            exit(3)
        }
        // .combinedSessionState, not .hidSystemState: an hidSystemState source
        // re-derives modifier flags from the real keyboard state, stripping the
        // synthetic chord's flags — the matcher then never sees ⌃⌥⇧⌘fn.
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else {
            warn("could not create the keyboard event")
            exit(1)
        }
        down.flags = chordFlags
        up.flags = chordFlags
        down.post(tap: .cghidEventTap)
        usleep(20_000)
        up.post(tap: .cghidEventTap)
    }

    static func dieNoFDA() -> Never {
        warn("cannot read \(dbPath) — grant Full Disk Access to the signed Pounce.app (System Settings → Privacy & Security → Full Disk Access)")
        exit(2)
    }

    static func warn(_ message: String) {
        FileHandle.standardError.write(Data(("pounce focus: " + message + "\n").utf8))
    }
}
