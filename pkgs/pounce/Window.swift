import SwiftUI
import AppKit

// MARK: - Window

class PounceWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - PounceUI (window controller shared by daemon + direct mode)

final class PounceUI {
    // A resizable rounded-rect mask: a solid rounded square with cap insets so it
    // stretches to any window size without distorting the corners.
    static func roundedMask(radius: CGFloat) -> NSImage {
        let d = radius * 2 + 1
        let image = NSImage(size: NSSize(width: d, height: d), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    let window: PounceWindow
    let hosting: NSHostingView<ContentView>
    let state: DaemonState

    private var lingerItem: DispatchWorkItem?
    private var spinnerItem: DispatchWorkItem?
    var resultSink: ((String) -> Void)?

    // The app that was frontmost when the window first appeared — captured before
    // we steal focus, preserved across submenu swaps, and reactivated on an
    // auto-paste commit. Cleared when the window fully hides.
    private var capturedApp: NSRunningApplication?

    init(state: DaemonState) {
        self.state = state
        self.hosting = NSHostingView(rootView: ContentView(state: state))

        window = PounceWindow(
            contentRect: NSRect(x: 0, y: 0, width: LayoutMetrics.standard.width, height: 400),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = false
        window.level = .floating
        window.hasShadow = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 16
        blur.layer?.masksToBounds = true
        blur.layer?.borderWidth = 1
        blur.layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor
        // layer.cornerRadius alone doesn't clip the vibrancy material or shape the
        // window shadow — a resizable rounded maskImage does both, killing the
        // square corner that pokes out behind the rounded panel.
        blur.maskImage = PounceUI.roundedMask(radius: 16)
        // Pin the content to the TOP edge (fixed height, flexible bottom margin)
        // so an animated window resize reveals/covers from the bottom instead of
        // letting NSHostingView re-center the content and slide it vertically.
        hosting.autoresizingMask = [.width, .minYMargin]
        blur.addSubview(hosting)
        window.contentView = blur

        state.onCommit = { [weak self] commit in self?.handleCommit(commit) }
        state.onResize = { [weak self] in
            // Resize in the SAME runloop turn as the content change. Forcing
            // layout makes fittingSize current immediately, so the window and the
            // SwiftUI content never composite at mismatched sizes — that one-frame
            // mismatch (small content inside the still-tall window/blur) is the
            // flash you see when the query filters the list, worst on 0→1 letters.
            guard let self = self else { return }
            self.hosting.layoutSubtreeIfNeeded()
            self.resizeToFit()
        }

        NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            guard let self = self, self.state.isVisible else { return }
            self.state.cancel()
        }
    }

    // MARK: Presentation

    func present() {
        cancelLinger()
        state.isLoading = false   // new content replaces any in-flight spinner
        let fresh = !window.isVisible

        if fresh {
            // Record who had focus before we steal it, so an auto-paste commit can
            // hand focus back and ⌘V into the right app. Skip our own process so a
            // stale activation can't capture pounce itself.
            let front = NSWorkspace.shared.frontmostApplication
            if front?.processIdentifier != NSRunningApplication.current.processIdentifier {
                capturedApp = front
            }

            // First appear: size + position instantly (nothing to animate from).
            // Force layout first so fittingSize reflects the content the caller
            // JUST reset/loaded, not whatever taller view (e.g. clipboard
            // history) was rendered last time the window was up. Without this the
            // window opens at the stale height for one frame before the deferred
            // resizeToFit snaps it down — the flash you see going from a big
            // window (clipboard) back to the empty launcher bar.
            hosting.layoutSubtreeIfNeeded()
            let size = hosting.fittingSize
            let target = NSSize(width: state.targetWidth, height: size.height)
            window.setContentSize(target)
            positionFresh(size: target)
            hosting.frame = window.contentView?.bounds ?? .zero
        }
        // Non-fresh (window already up, e.g. swapping step 2 into the live window):
        // leave the current size; the deferred resizeToFit snaps it to the new mode.

        // Hold the incoming content dark until the deferred pass has sized it and
        // SwiftUI has painted it, then reveal it fully-formed in one step. present()
        // runs synchronously right after state.reset()/load(), but SwiftUI hasn't
        // reconciled the displayMode swap yet, so any size read now can still report
        // the PREVIOUS view. Showing content before the async correction lands is
        // what flashed — either the stale oversized W×H (fresh open) or the new grid
        // mid-resize/mid-reconcile (step swap). FRESH gates the whole WINDOW (it has
        // to reposition too); a non-fresh step swap gates just the CONTENT so the
        // panel chrome stays put underneath.
        window.alphaValue = fresh ? 0 : 1
        if !fresh { hosting.alphaValue = 0 }
        state.isVisible = true

        window.makeKeyAndOrderFront(nil)
        // Re-activate on a submenu step swap too, not only on a fresh open. A
        // two-step command presents its next step into the already-visible window
        // (fresh == false) via a nested `pounce` invocation, but the app can lose
        // frontmost between steps (the prior step's client process exits and macOS
        // hands activation back to whatever was behind us) — leaving the window
        // ordered-front yet not key, so keystrokes go to the app behind. Guarding
        // on !NSApp.isActive restores focus on a swap without churning activation
        // when we're already frontmost (e.g. a per-keystroke content refresh).
        if fresh || !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
        if let tf = state.textField { window.makeFirstResponder(tf) }

        // One runloop tick later SwiftUI has reconciled the new mode: size to it and
        // unveil crisply, in a single step (no frame tween → no shear; no crossfade
        // → no low-contrast header lagging the grid). resizeToFit reveals the
        // content; a fresh open also lifts the window veil once it's positioned.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.resizeToFit()
            if fresh { self.window.alphaValue = 1 }
        }
    }

    // Match the window height to the SwiftUI content, anchoring the top edge so
    // the list grows/shrinks downward as the query filters it. Always a crisp,
    // instant snap — both typing-driven filtering AND mode swaps (launcher →
    // emoji/clipboard). We never tween the frame: an animated setFrame runs an
    // implicit animation on the content layer that scales/shears the just-rendered
    // grid mid-flight — the "sheared panel" jank — and morphing geometry between
    // two unrelated layouts is the wrong metaphor anyway. A step swap instead hides
    // its content in present() and this reveals it, so the change is one clean cut.
    func resizeToFit() {
        guard window.isVisible else { return }
        hosting.layoutSubtreeIfNeeded()
        let h = hosting.fittingSize.height
        let w = state.targetWidth
        if h > 1, abs(h - window.frame.height) > 0.5 || abs(w - window.frame.width) > 0.5 {
            let oldTop = window.frame.maxY
            var f = window.frame
            f.size.height = h
            f.size.width = w
            f.origin.y = oldTop - h          // anchor the top edge; grow/shrink downward
            if let vf = (window.screen ?? NSScreen.main)?.visibleFrame {
                f.origin.x = vf.midX - w / 2  // keep centered if the width changed
            }
            // Commit the frame + hosting bounds atomically with implicit animation
            // off, so nothing (blur material, content layer) tweens/flickers through
            // the resize.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            window.setFrame(f, display: true)
            hosting.frame = window.contentView?.bounds ?? .zero
            CATransaction.commit()
        }
        // Content is now sized and laid out — unveil it in one step (a no-op unless
        // a step swap hid it in present()). Instant, never a fade: a crossfade would
        // expose the low-contrast search header lagging the emoji grid for a frame.
        if hosting.alphaValue != 1 {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hosting.alphaValue = 1
            CATransaction.commit()
        }
    }

    private func positionFresh(size: NSSize) {
        guard let vf = (NSScreen.main ?? window.screen)?.visibleFrame else { window.center(); return }
        let x = vf.midX - size.width / 2
        let topInset = vf.height * state.metrics.topInsetFraction
        let y = vf.maxY - topInset - size.height
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: Commit handling

    private func handleCommit(_ commit: Commit) {
        // Whether WE still own focus at the moment of dismissal. Esc/↵ arrive
        // while the window is key; a click into another app arrives via
        // didResignKey AFTER that app took focus — there, handing focus back
        // would undo the user's click.
        let wasKey = window.isKeyWindow

        // Every way out of the camera peek (↵, Esc, click-away) commits through
        // here — release the camera the moment the window goes, not at the next
        // request's reset().
        if state.displayMode == .camera { CameraController.shared.stop() }

        if let app = commit.appLaunch {
            let url = URL(fileURLWithPath: app.path)
            if app.reveal {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } else {
                let cfg = NSWorkspace.OpenConfiguration()
                cfg.activates = true
                NSWorkspace.shared.openApplication(at: url, configuration: cfg)
            }
        }

        resultSink?(commit.clientString ?? "")

        switch commit.disposition {
        case .hideNow:
            state.isVisible = false
            hideNow()
            if commit.pasteAfter {
                restoreFocusAndPaste()
            } else if commit.appLaunch == nil {
                refocusCaptured(wasKey: wasKey)
            } else {
                capturedApp = nil   // the launched app takes focus
            }
        case .linger:
            state.isVisible = false
            // Hand focus back right away, before the fade: if the committed
            // command goes on to open/activate something, that later
            // activation simply wins.
            refocusCaptured(wasKey: wasKey)
            startLinger()
        case .loading:
            // Keep the window up (and key, so click-away still cancels) until the
            // two-step command's step 2 calls present() and swaps the content in.
            startLoading()
        }
    }

    // MARK: Hide / linger / loading

    func hideNow() {
        cancelLinger()
        window.orderOut(nil)
    }

    // Raycast-style focus restore: on dismissal (Esc, ↵ on a copy-style
    // action) hand focus back to the app pounce stole it from. wasKey=false
    // means the user dismissed by clicking into another app — that app owns
    // focus now, leave it alone.
    private func refocusCaptured(wasKey: Bool) {
        defer { capturedApp = nil }
        guard wasKey, let app = capturedApp, !app.isTerminated else { return }
        app.activate(options: [.activateIgnoringOtherApps])
    }

    // Hand focus back to the app that was frontmost before pounce appeared, then
    // synthesize ⌘V once it's active. The small delay lets the activation settle
    // so the keystroke lands in the target app rather than the just-hidden window.
    private func restoreFocusAndPaste() {
        guard let app = capturedApp else { capturedApp = nil; return }
        capturedApp = nil
        app.activate(options: [.activateIgnoringOtherApps])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            Paste.sendCommandV()
        }
    }

    private func startLinger() {
        cancelLinger()
        let work = DispatchWorkItem { [weak self] in self?.fadeOut() }
        lingerItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    // Show the skeleton after a short grace period (so fast sub-commands swap
    // with no flash), and fall back to fading out if step 2 never arrives. We do
    // NOT resize here — the skeleton fills the window at its current (step 1)
    // height, so there's no arbitrary intermediary height; the single animated
    // resize happens only when step 2's real content lands.
    private func startLoading() {
        cancelLinger()
        let show = DispatchWorkItem { [weak self] in self?.state.isLoading = true }
        spinnerItem = show
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: show)

        let fallback = DispatchWorkItem { [weak self] in
            self?.state.isLoading = false
            self?.fadeOut()
        }
        lingerItem = fallback
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.0, execute: fallback)
    }

    private func cancelLinger() {
        lingerItem?.cancel()
        lingerItem = nil
        spinnerItem?.cancel()
        spinnerItem = nil
    }

    private func fadeOut() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.window.orderOut(nil)
            self?.window.alphaValue = 1
            self?.capturedApp = nil
        })
    }
}
