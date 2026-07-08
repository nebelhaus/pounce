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
