import SwiftUI
import AppKit
import ApplicationServices

// MARK: - Entry Point

@main
enum Main {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--version") {
            // pounceVersion comes from Version.generated.swift (see build.sh).
            print("pounce \(pounceVersion)")
        } else if let i = args.firstIndex(of: "--copy-file"), i + 1 < args.count {
            CopyFileMode.run(path: args[i + 1])
        } else if args.contains("--check-accessibility") {
            // Silent trust check for scripted verification. AXIsProcessTrusted
            // reflects THIS binary's code identity, so run it from the signed copy
            // to confirm the daemon's identity holds the grant.
            print(AXIsProcessTrusted() ? "true" : "false")
        } else if args.contains("--request-accessibility") {
            // One-shot bootstrap: fire the system "add to Accessibility" prompt.
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            print(AXIsProcessTrustedWithOptions(opts) ? "true" : "false")
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
    var maxEmpty: Int?
}

// MARK: - Daemon Mode

enum DaemonMode {
    static func run() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let state = DaemonState()
        let ui = PounceUI(state: state)
        ui.window.orderOut(nil)

        AppScanner.shared.warm()
        EmojiStore.shared.warm()   // filter the dataset to OS-renderable glyphs off the main thread

        // Clipboard history watcher: poll the pasteboard while the daemon lives.
        if Settings.load().clipboard.enabled {
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
        NSLog("pounce daemon accessibility trusted=\(AXIsProcessTrusted())")
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
            if p.count > 4, let m = Int(p[4]) { inv.maxEmpty = m }
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
            : (inv.camera ? "camera" : ""))))
        let maxEmpty = inv.maxEmpty.map(String.init) ?? ""
        var payload = "CONFIG\t\(inv.placeholder ?? "")\t\(inv.icon ?? "")\t\(mode)\t\(maxEmpty)\n"
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
