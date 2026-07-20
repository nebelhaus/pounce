import SwiftUI
import AppKit
import ApplicationServices

// MARK: - Entry Point

@main
enum Main {
    static let usage = """
    pounce — summon, aim, pounce. A scriptable command palette for macOS.

    usage:
      pounce [-p <prompt>] [-i <sf-symbol>] [--max-empty <n>]
        generic picker: reads lines from stdin, prints the chosen one

    modes:
      --launcher             apps + commands palette (what the hotkey opens)
      --clipboard            clipboard history
      --emoji                emoji picker
      --screenshots          screenshot browser
      --camera               camera preview
      --find-files           search files & folders by name (Spotlight index)
      --cheatsheet [path]    cheatsheet overlay (default ~/.config/pounce/cheatsheet.json)

    focus (hush):
      focus status              print on/off from the DoNotDisturb DB
      focus toggle              press the DND symbolic-hotkey chord
      focus on|off              deterministic: read, press only if needed, verify
                                the grants (Accessibility + Full Disk Access) live on
                                the signed Pounce.app; a caller without them forwards
                                the op to the running daemon automatically

    selection:
      --transform <filter>      act on the current selection: copy it (⌘C), pipe
                                the text through the shell <filter>, paste back
                                (⌘V). e.g. --transform 'tr "[:lower:]" "[:upper:]"'.
                                Forwarded to the daemon, which holds the grant.

    housekeeping:
      --daemon                  run the resident daemon (launchd uses this; also
                                hosts the MRU window switcher when config.json
                                sets windows.enabled — see the README)
      --copy-file <path>        copy a file to the clipboard and exit
      --request-accessibility   prompt for the Accessibility (TCC) grant
      --check-accessibility     print true/false for the grant
      --request-bluetooth       prompt for the Bluetooth (TCC) grant
      --check-bluetooth         print true/false for the grant
      --version                 print the version
      -h, --help                this text

    config: ~/.config/pounce/config.json   commands: ~/.config/pounce/commands
    docs:   https://nebelhaus.com/reference/pounce/
    """

    static func main() {
        let args = CommandLine.arguments
        if args.contains("--help") || args.contains("-h") {
            print(usage)
        } else if args.contains("--version") {
            // pounceVersion comes from Version.generated.swift (see build.sh).
            print("pounce \(pounceVersion)")
        } else if args.count >= 2 && args[1] == "focus" {
            // Positional on purpose: scripts probe `pounce --help` for
            // "focus" before calling, so an older binary never falls through
            // to ClientMode and opens the palette by accident.
            FocusMode.run(op: args.count >= 3 ? args[2] : nil)
        } else if let i = args.firstIndex(of: "--copy-file"), i + 1 < args.count {
            CopyFileMode.run(path: args[i + 1])
        } else if let i = args.firstIndex(of: "--transform"), i + 1 < args.count {
            // Act on the current selection: ⌘C → pipe through the shell filter
            // → ⌘V. Forwarded to the daemon (which holds Accessibility) like
            // `focus`. See Transform.swift.
            TransformMode.run(filter: args[i + 1])
        } else if args.contains("--check-accessibility") {
            // Silent trust check for scripted verification. AXIsProcessTrusted
            // reflects THIS binary's code identity, so run it from the signed copy
            // to confirm the daemon's identity holds the grant.
            print(AXIsProcessTrusted() ? "true" : "false")
        } else if args.contains("--request-accessibility") {
            // One-shot bootstrap: fire the system "add to Accessibility" prompt.
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            print(AXIsProcessTrustedWithOptions(opts) ? "true" : "false")
        } else if args.contains("--check-bluetooth") {
            print(BluetoothGrant.check() ? "true" : "false")
        } else if args.contains("--request-bluetooth") {
            // One-shot bootstrap: fire the system Bluetooth prompt (see
            // BluetoothGrant.swift for why blueutil can't do this itself).
            BluetoothGrant.request()
        } else if args.contains("--daemon") {
            DaemonMode.run()
        } else {
            ClientMode.run()
        }
    }
}

// `pounce --copy-file <path>`: copy a file to the clipboard as both image and
// file reference (see Pasteboard.copyFile) and exit. Synchronous — no run loop.
enum CopyFileMode {
    static func run(path: String) {
        Pasteboard.copyFile(URL(fileURLWithPath: path))
        exit(0)
    }
}

// MARK: - Argument / Config Parsing

struct Invocation {
    var placeholder: String?
    var icon: String?
    var launcher = false
    var clipboard = false
    var emoji = false
    var screenshots = false
    var camera = false
    var fileSearch = false
    var cheatsheet = false
    var cheatsheetPath = "~/.config/pounce/cheatsheet.json"
    var maxEmpty: Int?
}

// MARK: - Daemon Mode

enum DaemonMode {
    // Retained for the daemon's lifetime so its Carbon handler stays installed.
    static var hotKey: HotKeyManager?
    // Retained so the ⌘Tab event tap + window tracker stay alive.
    static var windowSwitcher: WindowSwitcher?
    // Last Accessibility trust state we logged, so the watcher only emits on a
    // change. Seeded by the startup log line below.
    static var lastTrusted: Bool?
    static var accessibilityTimer: Timer?

    // The startup `trusted=` line is a snapshot: TCC can flip while the daemon
    // runs (the user ticks the box in System Settings, or a `brew upgrade`
    // reissues the adhoc signature and drops the grant). AXIsProcessTrusted() is
    // live at every point of use, but a stale one-time log misleads anyone
    // reading it — so poll and log the transitions, giving the log a truthful
    // running account of the grant instead of a frozen boot-time value.
    static func watchAccessibility() {
        accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            let now = AXIsProcessTrusted()
            if now != lastTrusted {
                lastTrusted = now
                NSLog("pounce daemon accessibility trusted=\(now) (changed while running)")
            }
        }
    }

    static func run() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let state = DaemonState()
        let ui = PounceUI(state: state)
        ui.window.orderOut(nil)
        // Warm the SwiftUI render pipeline off the hot path so the first ⌘Space
        // doesn't pay NSHostingView's initial layout/draw on the keystroke.
        DispatchQueue.main.async { ui.warmRender() }

        AppScanner.shared.warm()
        EmojiStore.shared.warm()   // filter the dataset to OS-renderable glyphs off the main thread

        // Warm the command registry so the first ⌘Space doesn't pay the initial
        // scan + header parse. Kept on the main queue — refresh() is only ever
        // touched from the main thread (here and in presentLauncher), so the
        // registry needs no locking.
        let registry = CommandRegistry()
        DispatchQueue.main.async { registry.refresh() }

        let settings = Settings.load()

        // Currency rates for the quick-answer engine: hydrate from the disk
        // cache now, refresh from the network when stale, re-check every 6h.
        // Keystrokes only ever read the warmed in-memory table.
        if settings.quickAnswers.currency {
            CurrencyRates.shared.warm()
            Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
                CurrencyRates.shared.warm()
            }
        }

        // The in-process launcher: what ⌘Space triggers. No shell, no client, no
        // socket — build the launcher from the cached registry + warm app list and
        // present the already-built window straight away. Toggling: a second press
        // while it's up dismisses it (Raycast-style).
        // Flips true the first time the hotkey actually delivers a press. The
        // startup log says the key was *registered*; this says it's *received* —
        // the two diverge exactly when a system shortcut (Spotlight ⌘Space) or a
        // third-party launcher swallows the key, the failure that leaves the
        // present log empty despite the user mashing ⌘Space. Logged once.
        var hotkeyReceived = false
        let presentLauncher: () -> Void = {
            if !hotkeyReceived {
                hotkeyReceived = true
                NSLog("pounce daemon: hotkey received its first press — the in-process launcher path is live")
            }
            if state.isVisible { state.cancel(); return }
            let t0 = DispatchTime.now()
            let settings = Settings.load()   // re-read so config edits apply live
            Theme.current = settings.palette
            state.reset()
            state.metrics = settings.metrics
            registry.refresh()
            let lines = registry.entries.map { $0.registryLine }
            state.load(lines: lines, placeholder: "Search apps & actions...",
                       icon: "magnifyingglass", launcher: true, maxEmpty: 7)
            let tBuild = DispatchTime.now()   // registry + app scan + frecency + sort
            // Launcher selections that aren't native app launches arrive as
            // "run\t<id>"; spawn that command script ourselves, the way
            // pounce-palette used to exec it. App launches come back with an empty
            // string (handled natively in PounceUI) and are ignored here.
            ui.resultSink = { result in
                guard result.hasPrefix("run\t") else { return }
                let id = String(result.dropFirst(4))
                if let path = registry.scriptPath(for: id) { CommandSpawner.run(scriptPath: path) }
            }
            ui.present()
            // Press→present latency on the in-process fast path, broken into
            // phases so a summon-lag report localizes the cost instead of guessing:
            //   build   — synchronous registry refresh + app scan + sort
            //   sync    — build + present()'s synchronous layout/activate
            //   visible — build + sync + the deferred reveal tick (resize + fade
            //             in). This last runloop turn is NOT counted by the first
            //             two, yet it's where SwiftUI paints and the compositor
            //             shows the window — so on a machine where `sync` is small
            //             but the summon still feels slow, `visible` is the tell.
            // All three carry the "launcher present" substring so one grep catches
            // them. If these lines appear on the user's hotkey they're on the fast
            // daemon path (not an external binder spawning pounce-palette).
            let ms = { (t: DispatchTime) in
                Int((Double(DispatchTime.now().uptimeNanoseconds &- t.uptimeNanoseconds) / 1_000_000).rounded())
            }
            let buildMs = ms(t0) - ms(tBuild)
            let syncMs = ms(t0)
            let count = state.items.count
            DispatchQueue.main.async {
                NSLog("pounce daemon: launcher present — build \(buildMs)ms, sync \(syncMs)ms, visible \(ms(t0))ms (\(count) items)")
            }
        }

        if settings.hotkey.enabled {
            if let keyCode = HotKeyParser.keyCode(for: settings.hotkey.key) {
                let modifiers = HotKeyParser.modifierMask(for: settings.hotkey.modifiers)
                let manager = HotKeyManager(onFire: presentLauncher)
                if manager.register(keyCode: keyCode, modifiers: modifiers) {
                    hotKey = manager
                    let combo = "\(settings.hotkey.modifiers.joined(separator: "+"))+\(settings.hotkey.key)"
                    NSLog("pounce daemon: hotkey \(combo) registered")
                    // Registration succeeding doesn't mean we'll get the key: if
                    // macOS still owns the same combo (Spotlight ⌘Space is the
                    // classic case), the system wins and pounce never receives a
                    // press. Name the conflict so the fix is obvious instead of
                    // the summon just silently doing nothing.
                    if let conflict = HotKeyConflict.systemConflict(keyName: settings.hotkey.key,
                                                                    modifierNames: settings.hotkey.modifiers) {
                        NSLog("pounce daemon: WARNING — \(combo) is also bound to \(conflict); macOS routes the key there, so pounce likely never receives it and the palette won't open. Disable that shortcut in System Settings → Keyboard → Keyboard Shortcuts, then restart pounce.")
                    }
                } else {
                    NSLog("pounce daemon: could not register hotkey \(settings.hotkey.modifiers.joined(separator: "+"))+\(settings.hotkey.key) (already taken?); falling back to socket launch")
                }
            } else {
                NSLog("pounce daemon: unknown hotkey key '\(settings.hotkey.key)'; falling back to socket launch")
            }
        }

        // The MRU window switcher (default ⌘Tab, see Switcher.swift). Unlike the
        // palette hotkey (Carbon, no permissions), taking ⌘Tab needs an event
        // tap, which macOS gates behind Accessibility — without the grant the
        // stock switcher is left untouched, so enabling this can never brick
        // window switching.
        if settings.windows.enabled {
            let combo = "\(settings.windows.modifiers.joined(separator: "+"))+\(settings.windows.key)"
            if !AXIsProcessTrusted() {
                NSLog("pounce daemon: windows.enabled is set but Accessibility is not granted; window switcher off, stock \(combo) untouched (grant via `pounce --request-accessibility`)")
            } else if let switcher = WindowSwitcher(settings: settings.windows) {
                windowSwitcher = switcher
                NSLog("pounce daemon: window switcher armed on \(combo)")
            } else {
                NSLog("pounce daemon: window switcher event tap failed to install; stock \(combo) untouched")
            }
        }

        // Clipboard history watcher: poll the pasteboard while the daemon lives.
        if settings.clipboard.enabled {
            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                ClipboardStore.shared.poll()
            }
        }

        let cleanupAndExit: @convention(c) (Int32) -> Void = { _ in
            unlink(SocketConfig.path); _exit(0)
        }
        signal(SIGTERM, cleanupAndExit)
        signal(SIGINT, cleanupAndExit)

        DispatchQueue.global(qos: .userInitiated).async {
            startSocketServer(state: state, ui: ui)
        }

        NSLog("pounce daemon started, listening on \(SocketConfig.path)")
        // Snapshot at boot; watchAccessibility() then logs any later transition
        // so the grant's true running state is always in the log, not just the
        // value that happened to hold the instant the daemon launched.
        lastTrusted = AXIsProcessTrusted()
        NSLog("pounce daemon accessibility trusted=\(lastTrusted!) (startup snapshot)")
        watchAccessibility()
        app.run()
    }

    static func startSocketServer(state: DaemonState, ui: PounceUI) {
        unlink(SocketConfig.path)
        try? FileManager.default.createDirectory(atPath: SocketConfig.dir,
                                                 withIntermediateDirectories: true)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { NSLog("pounce daemon: failed to create socket"); return }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            SocketConfig.path.withCString { cstr in
                _ = memcpy(ptr, cstr, min(strlen(cstr) + 1, MemoryLayout.size(ofValue: ptr.pointee)))
            }
        }
        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        guard withUnsafePointer(to: &addr, { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, addrLen) }
        }) == 0 else { NSLog("pounce daemon: failed to bind socket"); close(fd); return }

        guard listen(fd, 5) == 0 else { NSLog("pounce daemon: failed to listen"); close(fd); return }

        while true {
            var clientAddr = sockaddr_un()
            var clientLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(fd, $0, &clientLen) }
            }
            guard clientFD >= 0 else { continue }
            handleClient(clientFD: clientFD, state: state, ui: ui)
        }
    }

    static func handleClient(clientFD: Int32, state: DaemonState, ui: PounceUI) {
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(clientFD, &buf, buf.count)
            if n <= 0 { break }
            data.append(contentsOf: buf[0..<n])
        }
        guard let payload = String(data: data, encoding: .utf8), !payload.isEmpty else {
            close(clientFD); return
        }

        // Focus ops arrive as their own one-line protocol ("FOCUS\t<op>") and
        // run HERE, under the daemon's own TCC identity — the whole point:
        // `pounce focus` spawned by the bar pill or a terminal is attributed
        // to THAT app and holds no grants (Focus.swift). No UI, no main-thread
        // hop; reply one line and hang up.
        if payload.hasPrefix("FOCUS\t") {
            let op = payload.dropFirst("FOCUS\t".count).trimmingCharacters(in: .whitespacesAndNewlines)
            let r = FocusMode.perform(op)
            let reply = r.code == 0 ? (r.out.isEmpty ? "ok" : r.out) : "err\t\(r.code)\t\(r.err)"
            let replyData = (reply + "\n").data(using: .utf8)!
            replyData.withUnsafeBytes { ptr in _ = write(clientFD, ptr.baseAddress!, replyData.count) }
            close(clientFD)
            return
        }

        // Transform-selection ops arrive as "TRANSFORM\t<shell filter>" and,
        // like FOCUS, run HERE under the daemon's own TCC identity (only the
        // signed daemon holds the Accessibility grant that lets ⌘C/⌘V post).
        // No UI, no main-thread hop — every step in perform() is thread-safe;
        // reply one line and hang up. The palette window is already hidden and
        // focus handed back to the source app by the time this fires.
        if payload.hasPrefix("TRANSFORM\t") {
            let filter = String(payload.dropFirst("TRANSFORM\t".count)).trimmingCharacters(in: .newlines)
            let r = TransformMode.perform(filter: filter)
            let reply = r.code == 0 ? "ok" : "err\t\(r.code)\t\(r.err)"
            let replyData = (reply + "\n").data(using: .utf8)!
            replyData.withUnsafeBytes { ptr in _ = write(clientFD, ptr.baseAddress!, replyData.count) }
            close(clientFD)
            return
        }

        var lines = payload.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }

        var inv = Invocation()
        var itemLines: [String] = lines
        if let first = lines.first, first.hasPrefix("CONFIG\t") {
            let p = first.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            if p.count > 1 && !p[1].isEmpty { inv.placeholder = p[1] }
            if p.count > 2 && !p[2].isEmpty { inv.icon = p[2] }
            if p.count > 3 && p[3] == "launcher" { inv.launcher = true }
            if p.count > 3 && p[3] == "clipboard" { inv.clipboard = true }
            if p.count > 3 && p[3] == "emoji" { inv.emoji = true }
            if p.count > 3 && p[3] == "screenshots" { inv.screenshots = true }
            if p.count > 3 && p[3] == "camera" { inv.camera = true }
            if p.count > 3 && p[3] == "filesearch" { inv.fileSearch = true }
            if p.count > 3 && p[3] == "cheatsheet" { inv.cheatsheet = true }
            if p.count > 4, let m = Int(p[4]) { inv.maxEmpty = m }
            if p.count > 5 && !p[5].isEmpty { inv.cheatsheetPath = p[5] }
            itemLines = Array(lines.dropFirst())
        }

        let semaphore = DispatchSemaphore(value: 0)
        var result = ""
        let settings = Settings.load()   // re-read per request so edits apply live
        let metrics = settings.metrics

        DispatchQueue.main.async {
            Theme.current = settings.palette
            state.reset()
            state.metrics = metrics
            if inv.clipboard {
                state.loadClipboard(placeholder: inv.placeholder)
            } else if inv.emoji {
                state.loadEmoji(placeholder: inv.placeholder)
            } else if inv.screenshots {
                state.loadScreenshots(placeholder: inv.placeholder)
            } else if inv.camera {
                state.loadCamera(placeholder: inv.placeholder)
            } else if inv.fileSearch {
                state.loadFileSearch(placeholder: inv.placeholder)
            } else if inv.cheatsheet {
                state.loadCheatsheet(path: inv.cheatsheetPath, placeholder: inv.placeholder)
            } else {
                state.load(lines: itemLines, placeholder: inv.placeholder, icon: inv.icon,
                           launcher: inv.launcher, maxEmpty: inv.maxEmpty)
            }
            ui.resultSink = { r in result = r; semaphore.signal() }
            ui.present()
        }

        semaphore.wait()

        if !result.isEmpty {
            let resultData = (result + "\n").data(using: .utf8)!
            resultData.withUnsafeBytes { ptr in _ = write(clientFD, ptr.baseAddress!, resultData.count) }
        }
        close(clientFD)
    }
}

// MARK: - Client Mode

enum ClientMode {
    static func parseArgs() -> Invocation {
        var inv = Invocation()
        var args = Array(CommandLine.arguments.dropFirst())
        while !args.isEmpty {
            let arg = args.removeFirst()
            switch arg {
            case "-p", "--placeholder": if !args.isEmpty { inv.placeholder = args.removeFirst() }
            case "-i", "--icon":        if !args.isEmpty { inv.icon = args.removeFirst() }
            case "--launcher":          inv.launcher = true
            case "--clipboard":         inv.clipboard = true
            case "--emoji":             inv.emoji = true
            case "--screenshots":       inv.screenshots = true
            case "--camera":            inv.camera = true
            case "--find-files":        inv.fileSearch = true
            case "--cheatsheet":
                inv.cheatsheet = true
                // The JSON path is optional (defaults in Invocation) — don't
                // swallow a following flag as the path.
                if let next = args.first, !next.hasPrefix("--") { inv.cheatsheetPath = args.removeFirst() }
            case "--max-empty":         if !args.isEmpty { inv.maxEmpty = Int(args.removeFirst()) }
            default: break
            }
        }
        return inv
    }

    static func run() {
        var stdinLines: [String] = []
        if isatty(FileHandle.standardInput.fileDescriptor) == 0 {
            while let line = readLine() { stdinLines.append(line) }
        }
        let inv = parseArgs()

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { runDirect(lines: stdinLines, inv: inv); return }

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
        if !connected { close(fd); runDirect(lines: stdinLines, inv: inv); return }

        let mode = inv.launcher ? "launcher"
            : (inv.clipboard ? "clipboard"
            : (inv.emoji ? "emoji"
            : (inv.screenshots ? "screenshots"
            : (inv.camera ? "camera"
            : (inv.fileSearch ? "filesearch"
            : (inv.cheatsheet ? "cheatsheet" : ""))))))
        let maxEmpty = inv.maxEmpty.map(String.init) ?? ""
        var payload = "CONFIG\t\(inv.placeholder ?? "")\t\(inv.icon ?? "")\t\(mode)\t\(maxEmpty)\t\(inv.cheatsheetPath)\n"
        for line in stdinLines { payload += line + "\n" }

        if let data = payload.data(using: .utf8) {
            data.withUnsafeBytes { ptr in _ = write(fd, ptr.baseAddress!, data.count) }
        }
        shutdown(fd, SHUT_WR)

        var resultData = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            resultData.append(contentsOf: buf[0..<n])
        }
        close(fd)

        if let result = String(data: resultData, encoding: .utf8)?.trimmingCharacters(in: .newlines),
           !result.isEmpty {
            print(result); exit(0)
        } else {
            exit(1)
        }
    }

    // Fallback when the daemon is not running.
    static func runDirect(lines: [String], inv: Invocation) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let state = DaemonState()
        let ui = PounceUI(state: state)
        let settings = Settings.load()
        state.metrics = settings.metrics
        Theme.current = settings.palette
        if inv.clipboard {
            state.loadClipboard(placeholder: inv.placeholder)
        } else if inv.emoji {
            state.loadEmoji(placeholder: inv.placeholder)
        } else if inv.screenshots {
            state.loadScreenshots(placeholder: inv.placeholder)
        } else if inv.camera {
            state.loadCamera(placeholder: inv.placeholder)
        } else if inv.fileSearch {
            state.loadFileSearch(placeholder: inv.placeholder)
        } else if inv.cheatsheet {
            state.loadCheatsheet(path: inv.cheatsheetPath, placeholder: inv.placeholder)
        } else {
            state.load(lines: lines, placeholder: inv.placeholder, icon: inv.icon,
                       launcher: inv.launcher, maxEmpty: inv.maxEmpty)
        }

        ui.resultSink = { result in
            if result.isEmpty { exit(1) }
            print(result); NSApp.terminate(nil)
        }
        DispatchQueue.main.async { ui.present() }
        app.run()
    }
}
