import AppKit
import ApplicationServices

// MARK: - Transform selection (text actions)

// `pounce --transform '<shell filter>'` — the "act on the selection" primitive.
// Copies the frontmost app's current selection (synthetic ⌘C), pipes the text
// through the given shell filter, and pastes the result back (synthetic ⌘V),
// replacing the selection in place. Every text action — Capitalize, lowercase,
// Title Case, trim, sort-lines — is then just a one-line command script that
// execs this with a different filter (see pkgs/pounce-commands/commands).
//
// Why it forwards to the daemon (same reasoning as Focus.swift): posting the
// ⌘C/⌘V CGEvents is gated by Accessibility, and TCC attributes a grant to the
// RESPONSIBLE process. A command script spawned from the palette runs the
// Nix/Homebrew `pounce` binary, whose code identity is NOT the signed daemon
// copy that actually holds the grant — so it would post nothing. Handing the
// op to the resident daemon over the socket runs it under the daemon's own
// trusted identity, exactly like `pounce focus`.
enum TransformMode {
    // Everything perform() can report, kept exit-free so the daemon can run the
    // same code from its socket handler without exit() killing it.
    struct Outcome: Error {
        let code: Int32
        var err = ""   // human hint, printed to stderr by the CLI
    }

    // CLI entry: run locally only when THIS context already holds the grant
    // (rare — usually only the signed daemon does), otherwise forward to the
    // daemon. If no daemon answers, fall through to the local attempt so the
    // grant-missing error and exit code still surface.
    static func run(filter: String) -> Never {
        if AXIsProcessTrusted() { finish(perform(filter: filter)) }
        if let reply = askDaemon(filter) {
            if reply.hasPrefix("err\t") {
                let parts = reply.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                finish(Outcome(code: parts.count > 1 ? Int32(parts[1]) ?? 1 : 1,
                               err: parts.count > 2 ? parts[2] : ""))
            }
            finish(Outcome(code: 0))
        }
        finish(perform(filter: filter))
    }

    static func finish(_ r: Outcome) -> Never {
        if !r.err.isEmpty { warn(r.err) }
        exit(r.code)
    }

    // The exit-free core — shared verbatim by the CLI and the daemon's
    // TRANSFORM socket handler (Entry.swift). Runs off the main thread on the
    // daemon path (like FocusMode.perform); every step here is thread-safe.
    //
    // Exit codes are the contract the command scripts rely on:
    //   0  replaced the selection
    //   1  nothing selected, or the filter produced nothing / failed
    //   3  no Accessibility grant anywhere — refuse to press blind
    static func perform(filter: String) -> Outcome {
        guard AXIsProcessTrusted() else {
            return Outcome(code: 3, err: "no Accessibility grant for this context — grant the signed Pounce.app once (pounce --request-accessibility) and keep its daemon running; it acts on behalf of any caller")
        }

        let pb = NSPasteboard.general
        let before = pb.changeCount

        // Let the app pounce just handed focus back to settle before we press
        // ⌘C, then poll the change count — an empty selection copies nothing,
        // so a count that never moves means "no text selected" (and we must NOT
        // paste stale clipboard back).
        usleep(80_000)
        Paste.sendCommandC()
        var copied = false
        for _ in 0..<60 {          // up to ~0.6s for the app to answer ⌘C
            usleep(10_000)
            if pb.changeCount != before { copied = true; break }
        }
        guard copied, let text = pb.string(forType: .string), !text.isEmpty else {
            return Outcome(code: 1, err: "no text selected")
        }

        let transformed: String
        switch runFilter(filter, input: text) {
        case .success(let out): transformed = out
        case .failure(let o): return o
        }
        guard !transformed.isEmpty else {
            return Outcome(code: 1, err: "filter produced no output")
        }

        Pasteboard.copyString(transformed)
        usleep(30_000)             // let the pasteboard write land before ⌘V
        Paste.sendCommandV()
        return Outcome(code: 0)
    }

    // Pipe `input` through `/bin/sh -c "<filter>"`, returning its stdout. A
    // filter is a plain shell command (`tr '[:lower:]' '[:upper:]'`), keeping
    // text actions in shell scripts, true to pounce's "every command is a file"
    // ethos. Stdin is written off-thread so a filter that streams a large
    // result can't deadlock on a full pipe buffer.
    private static func runFilter(_ filter: String, input: String) -> Result<String, Outcome> {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", filter]
        let inPipe = Pipe(), outPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch {
            return .failure(Outcome(code: 1, err: "could not run filter '\(filter)'"))
        }
        let data = Data(input.utf8)
        DispatchQueue.global().async {
            inPipe.fileHandleForWriting.write(data)
            try? inPipe.fileHandleForWriting.close()
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            return .failure(Outcome(code: 1, err: "filter exited \(proc.terminationStatus)"))
        }
        var out = String(data: outData, encoding: .utf8) ?? ""
        if out.hasSuffix("\n") { out.removeLast() }   // filters commonly add a trailing newline
        return .success(out)
    }

    // One round-trip to the resident daemon: "TRANSFORM\t<filter>\n" in, one
    // reply line out ("ok" or "err\t<code>\t<hint>"). nil when no daemon
    // answers — the caller falls back to the local attempt. Mirrors
    // FocusMode.askDaemon.
    static func askDaemon(_ filter: String) -> String? {
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

        let payload = "TRANSFORM\t\(filter)\n".data(using: .utf8)!
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
        FileHandle.standardError.write(Data(("pounce transform: " + message + "\n").utf8))
    }
}
