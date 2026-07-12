import AppKit
import Carbon
import SwiftUI

// MARK: - Window Switcher (⌘Tab quasimode)

// The MRU window switcher: hold the modifier, tap the trigger key to walk
// windows most-recent-first, release to land. A single tap-and-release toggles
// to the LAST window — the gesture that makes it a real ⌘Tab replacement.
// Typing while holding filters (fuzzy + frecency). ⇧ walks backwards, ⎋
// cancels, ↵ commits without releasing.
//
// ⌘Tab is not a symbolic hotkey macOS lets you rebind — the Dock owns it. The
// only way in is a session CGEventTap that swallows the keyDown before the Dock
// sees it, and keyboard taps are gated behind the Accessibility grant (the same
// one the rice's stable-signing dance preserves across rebuilds). No grant → no
// tap → stock ⌘Tab keeps working; the daemon just logs and moves on.
//
// The tap callback runs on the main run loop and must return fast — macOS
// disables taps that stall (~1s). Everything here is O(cached list); the AX
// walking lives in WindowTracker, off this path. During Secure Input (password
// fields) keyboard taps go deaf and events flow to the stock switcher — an
// acceptable, self-healing fallback.
final class WindowSwitcher {
    private let tracker = WindowTracker()
    // Separate store from the launcher's frecency.json: two live Frecency
    // instances on one file would clobber each other's writes.
    private let frecency = Frecency(filename: "window-frecency.json")
    private let state = SwitcherState()
    private lazy var panel = SwitcherPanel(state: state)

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private let triggerKey: CGKeyCode
    private let requiredFlags: CGEventFlags
    private static let relevantFlags: CGEventFlags =
        [.maskCommand, .maskShift, .maskAlternate, .maskControl]

    // Quasimode session. `sessionWindows` is frozen at activation — a snapshot
    // refresh mid-cycle would shuffle rows under the user's selection.
    private var active = false
    private var sessionWindows: [WindowInfo] = []
    private var hudShown = false
    private var hudTimer: DispatchWorkItem?
    // A quick tap-release toggle shouldn't flash a window; the HUD appears
    // only if the modifier is still held after this delay (or on any explicit
    // cycle/typing, immediately).
    private static let hudDelay: TimeInterval = 0.1

    init?(settings: WindowSwitcherSettings) {
        guard let code = HotKeyParser.keyCode(for: settings.key) else {
            NSLog("pounce switcher: unknown key '\(settings.key)'")
            return nil
        }
        triggerKey = CGKeyCode(code)
        requiredFlags = Self.eventFlags(for: settings.modifiers)
        // Release-to-commit needs a modifier to release; a bare key would also
        // swallow ordinary typing.
        guard !requiredFlags.isEmpty else {
            NSLog("pounce switcher: refusing to bind without a modifier")
            return nil
        }

        state.onSelect = { [weak self] index in
            guard let self, self.active else { return }
            self.state.selection = index
            self.commit()
        }

        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
                              | (1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                return Unmanaged<WindowSwitcher>.fromOpaque(refcon).takeUnretainedValue()
                    .handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return nil }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    deinit {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
    }

    // MARK: Event tap

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // Re-arm and bail out of any half-open session — better a cancelled
            // switch than a dead ⌘Tab until the daemon restarts.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            cancelSession()
            return Unmanaged.passUnretained(event)

        case .flagsChanged:
            // Never swallow modifier transitions — the rest of the system
            // tracks them too. Releasing the required modifiers commits.
            if active, !event.flags.contains(requiredFlags) { commit() }
            return Unmanaged.passUnretained(event)

        case .keyDown:
            let code = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            let held = event.flags.intersection(Self.relevantFlags)

            if !active {
                // ⇧ on top of the chord starts the walk backwards.
                guard code == triggerKey,
                      held == requiredFlags || held == requiredFlags.union(.maskShift),
                      begin(reverse: held.contains(.maskShift))
                else { return Unmanaged.passUnretained(event) }
                return nil
            }
            handleActiveKey(code: code, event: event)
            return nil   // the quasimode owns the keyboard while it's up

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func handleActiveKey(code: CGKeyCode, event: CGEvent) {
        if code == triggerKey {
            cycle(event.flags.contains(.maskShift) ? -1 : +1)
            return
        }
        switch Int(code) {
        case kVK_Escape:     cancelSession()
        case kVK_Return:     commit()
        case kVK_DownArrow:  cycle(+1)
        case kVK_UpArrow:    cycle(-1)
        case kVK_Delete:
            if !state.query.isEmpty { state.query.removeLast(); refilter() }
        default:
            if let ch = Self.typedCharacter(event) {
                state.query.append(ch)
                refilter()
                showHUDNow()
            }
        }
    }

    // MARK: Session

    // False when there's nothing to switch between — the trigger passes through
    // to the stock switcher rather than dying on a swallowed key.
    private func begin(reverse: Bool) -> Bool {
        let windows = tracker.orderedWindows()
        guard !windows.isEmpty else { return false }

        active = true
        sessionWindows = windows
        state.query = ""
        state.workspaces = [:]
        state.visible = windows
        // Index 1 — "the window before this one" — is the whole point of MRU:
        // tap-release lands there without ever seeing the HUD.
        state.selection = windows.count > 1 ? (reverse ? windows.count - 1 : 1) : 0

        tracker.refreshSoon()   // freshen the snapshot for the NEXT activation

        let show = DispatchWorkItem { [weak self] in self?.showHUD() }
        hudTimer = show
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hudDelay, execute: show)
        return true
    }

    private func cycle(_ delta: Int) {
        guard active, !state.visible.isEmpty else { return }
        state.selection = (state.selection + delta + state.visible.count) % state.visible.count
        showHUDNow()   // explicitly walking means the user wants to see the list
    }

    private func refilter() {
        let q = state.query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty {
            state.visible = sessionWindows
        } else {
            let chars = Array(q.lowercased())
            state.visible = sessionWindows
                .compactMap { w -> (WindowInfo, Double)? in
                    guard let s = Fuzzy.score(chars, w.searchText) else { return nil }
                    let f = frecency.score(for: w.frecencyKey)
                    return (w, s + (f / (f + 5)) * 1.5)   // same shaping as the launcher
                }
                .sorted { $0.1 > $1.1 }
                .map { $0.0 }
        }
        state.selection = 0
    }

    private func showHUDNow() {
        hudTimer?.cancel()
        hudTimer = nil
        showHUD()
    }

    private func showHUD() {
        guard active, !hudShown else { return }
        hudShown = true
        Theme.current = Settings.load().palette   // config edits apply on next show
        panel.show()
        // Badges arrive async — the HUD is already up and usable without them.
        Aerospace.workspaces { [weak self] map in
            guard let self, self.active else { return }
            self.state.workspaces = map
        }
    }

    private func commit() {
        guard active else { return }
        let target = state.visible.indices.contains(state.selection)
            ? state.visible[state.selection] : nil
        endSession()
        if let target {
            frecency.record(target.frecencyKey)
            tracker.focus(target)
        }
    }

    private func cancelSession() {
        guard active else { return }
        endSession()
    }

    private func endSession() {
        active = false
        hudShown = false
        hudTimer?.cancel()
        hudTimer = nil
        sessionWindows = []
        panel.hide()
    }

    // MARK: Parsing

    // CG-flavored sibling of HotKeyParser.modifierMask (that one speaks Carbon;
    // the tap compares CGEventFlags).
    static func eventFlags(for names: [String]) -> CGEventFlags {
        var flags: CGEventFlags = []
        for name in names {
            switch name.lowercased() {
            case "cmd", "command", "super", "meta": flags.insert(.maskCommand)
            case "shift":                           flags.insert(.maskShift)
            case "opt", "option", "alt":            flags.insert(.maskAlternate)
            case "ctrl", "control":                 flags.insert(.maskControl)
            default: break
            }
        }
        return flags
    }

    // The character a keyDown would type, for the filter query. Control keys
    // (and anything unprintable) return nil and fall through untyped.
    private static func typedCharacter(_ event: CGEvent) -> Character? {
        var length = 0
        var buf = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &length,
                                       unicodeString: &buf)
        guard length > 0 else { return nil }
        let s = String(utf16CodeUnits: buf, count: length)
        guard !s.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let ch = s.first else { return nil }
        return ch
    }
}
