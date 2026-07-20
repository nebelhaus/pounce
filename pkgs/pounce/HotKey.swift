import AppKit
import Carbon

// MARK: - Global hotkey (in-process)

// A single global hotkey registered by the daemon via Carbon's
// RegisterEventHotKey. The whole point is latency: Carbon delivers the keypress
// straight into this already-running, already-warm process, so ⌘Space →
// present() happens with zero shell/exec/socket hops in between. (Contrast the
// pounce-palette path, which forks bash, rebuilds the registry, and spawns a
// fresh AppKit client on every press.)
//
// Registration can fail if the combo is already owned by another app — the
// caller logs and leaves the socket launch path as the fallback.
final class HotKeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let onFire: () -> Void

    // Four-char signature that tags our hotkey to Carbon ('POUN'), so the shared
    // application event handler can tell our event apart from anyone else's.
    private static let signature: OSType = 0x504F_554E   // 'POUN'
    private let hotKeyID = EventHotKeyID(signature: HotKeyManager.signature, id: 1)

    init(onFire: @escaping () -> Void) {
        self.onFire = onFire
    }

    // Register `keyCode` (a Carbon virtual keycode, e.g. kVK_Space) plus
    // `modifiers` (a Carbon modifier mask, e.g. cmdKey). Returns false if Carbon
    // refused either the handler install or the registration.
    @discardableResult
    func register(keyCode: UInt32, modifiers: UInt32) -> Bool {
        unregister()

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        // One application-target handler for hot-key-pressed; it routes back to
        // this instance through the userData pointer. Carbon delivers hotkey
        // events on the main run loop, so onFire runs on the main thread.
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let userData, let event else { return OSStatus(eventNotHandledErr) }
            var fired = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &fired)
            guard fired.signature == HotKeyManager.signature else {
                return OSStatus(eventNotHandledErr)
            }
            let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            manager.onFire()
            return noErr
        }, 1, &spec, selfPtr, &eventHandler)
        guard installed == noErr else { return false }

        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        return status == noErr && hotKeyRef != nil
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef); self.hotKeyRef = nil }
        if let eventHandler { RemoveEventHandler(eventHandler); self.eventHandler = nil }
    }

    deinit { unregister() }
}

// MARK: - Parsing config strings → Carbon codes

// Translates the config.json `hotkey` spec ("space" + ["cmd"]) into the Carbon
// virtual keycode + modifier mask RegisterEventHotKey wants. Unknown keys fall
// back to Space so a typo can't silently produce an unregisterable combo.
enum HotKeyParser {
    static func keyCode(for name: String) -> UInt32? {
        keyCodes[name.lowercased()].map(UInt32.init)
    }

    static func modifierMask(for names: [String]) -> UInt32 {
        var mask: Int = 0
        for name in names {
            switch name.lowercased() {
            case "cmd", "command", "super", "meta": mask |= cmdKey
            case "shift":                           mask |= shiftKey
            case "opt", "option", "alt":            mask |= optionKey
            case "ctrl", "control":                 mask |= controlKey
            default: break
            }
        }
        return UInt32(mask)
    }

    // Expose the parsed keycode as an Int for conflict-checking against macOS's
    // own shortcut registry (which stores the same virtual keycodes).
    static func virtualKeyCode(for name: String) -> Int? {
        keyCodes[name.lowercased()]
    }

    // Named keys → Carbon virtual keycodes (kVK_*). Only the keys worth binding
    // to a launcher; everything else can be added here as needed.
    private static let keyCodes: [String: Int] = [
        "space": kVK_Space, "return": kVK_Return, "enter": kVK_Return,
        "tab": kVK_Tab, "escape": kVK_Escape, "esc": kVK_Escape,
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D,
        "e": kVK_ANSI_E, "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H,
        "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
        "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P,
        "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
        "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
        "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
        "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
        "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7,
        "8": kVK_ANSI_8, "9": kVK_ANSI_9,
    ]
}

// MARK: - System shortcut conflict detection

// macOS keeps its own global shortcuts — Spotlight's ⌘Space above all — in the
// com.apple.symbolichotkeys preference domain. When pounce's configured hotkey
// collides with one that's still enabled, RegisterEventHotKey SUCCEEDS but the
// system shortcut wins the keypress: the daemon holds a registration it never
// receives events for, so the palette silently never opens on that key. That's
// invisible from our side (registration reported success) and baffling from the
// user's (⌘Space "does nothing", or opens Spotlight) — the exact "pressed it 15
// times, nothing in the log" failure. Detect the collision against macOS's own
// registry at startup and name the culprit so the fix — free the key in System
// Settings → Keyboard → Keyboard Shortcuts — is obvious. (Third-party launchers
// like Raycast/Alfred grab keys via private event taps, not this domain, so a
// clash with those can't be seen here; the daemon can only flag system ones.)
enum HotKeyConflict {
    // Well-known symbolic-hotkey ids worth naming; Apple's ids are stable across
    // releases. Unknown-but-colliding ids still warn, just generically.
    private static let known: [Int: String] = [
        64: "Spotlight — “Show Spotlight search”",
        65: "Spotlight — “Show Finder search window”",
        60: "Input Sources — “Select the previous input source”",
        61: "Input Sources — “Select next source in Input menu”",
    ]

    // Cocoa NSEvent modifier-flag bits, as stored in symbolichotkeys' parameter
    // triple [char, keyCode, modifierFlags]. Distinct from the Carbon masks
    // HotKeyParser.modifierMask emits, so we compare in these terms.
    private static let cmd = 0x100000, shift = 0x20000, option = 0x80000, control = 0x40000
    private static var modifierMaskBits: Int { cmd | shift | option | control }

    // Description of the first enabled system shortcut bound to the same key +
    // modifiers as (keyName, modifierNames), or nil if none conflicts.
    static func systemConflict(keyName: String, modifierNames: [String]) -> String? {
        guard let keyCode = HotKeyParser.virtualKeyCode(for: keyName) else { return nil }
        let want = cocoaModifiers(modifierNames)

        guard let raw = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString,
                                                  "com.apple.symbolichotkeys" as CFString),
              let dict = raw as? [String: Any] else { return nil }

        for (id, entry) in dict {
            guard let e = entry as? [String: Any] else { continue }
            // `enabled` and the parameter ints normally come back as numbers, but
            // depending on how the pref was written they can arrive as strings —
            // coerce both so a type quirk can't make us miss (or invent) a clash.
            guard asBool(e["enabled"]),
                  let value = e["value"] as? [String: Any],
                  let paramsAny = value["parameters"] as? [Any] else { continue }
            let params = paramsAny.compactMap(asInt)
            guard params.count >= 3,
                  params[1] == keyCode,
                  (params[2] & modifierMaskBits) == want else { continue }
            return known[Int(id) ?? -1] ?? "a macOS system shortcut (symbolic-hotkey id \(id))"
        }
        return nil
    }

    private static func asInt(_ v: Any?) -> Int? {
        if let n = v as? NSNumber { return n.intValue }
        if let s = v as? String { return Int(s) }
        return nil
    }

    private static func asBool(_ v: Any?) -> Bool {
        if let n = v as? NSNumber { return n.intValue == 1 }
        if let s = v as? String { return s == "1" || s.lowercased() == "true" }
        return false
    }

    private static func cocoaModifiers(_ names: [String]) -> Int {
        var m = 0
        for name in names {
            switch name.lowercased() {
            case "cmd", "command", "super", "meta": m |= cmd
            case "shift":                           m |= shift
            case "opt", "option", "alt":            m |= option
            case "ctrl", "control":                 m |= control
            default: break
            }
        }
        return m
    }
}
