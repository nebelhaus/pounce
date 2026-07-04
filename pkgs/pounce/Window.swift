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
            let size = hosting.fittingSize
            let target = NSSize(width: state.targetWidth, height: size.height)
            window.setContentSize(target)
            positionFresh(size: target)
            hosting.frame = window.contentView?.bounds ?? .zero
        }
        // Non-fresh (window already up, e.g. swapping in step 2 after the skeleton):
        // leave the current size and let the deferred resizeToFit tween to the new
        // content height, so the step transition animates instead of snapping.

        window.alphaValue = 1
        state.isVisible = true

        window.makeKeyAndOrderFront(nil)
        if fresh { NSApp.activate(ignoringOtherApps: true) }
        if let tf = state.textField { window.makeFirstResponder(tf) }

        // Fit to the freshly-loaded content once SwiftUI has laid it out. Animate
        // the step transition (non-fresh); keep the first-appear correction instant.
        DispatchQueue.main.async { [weak self] in self?.resizeToFit(animated: !fresh) }
    }

    // Match the window height to the SwiftUI content, anchoring the top edge so
    // the list grows/shrinks downward as the query filters it.
    // animated=true gives a slight eased height/width tween — used for the step
    // transitions (step 1 → skeleton → step 2). Typing-driven resizes pass false
    // so filtering stays instant/snappy.
    func resizeToFit(animated: Bool = false) {
        guard window.isVisible else { return }
        hosting.layoutSubtreeIfNeeded()
        let h = hosting.fittingSize.height
        let w = state.targetWidth
        guard h > 1,
              abs(h - window.frame.height) > 0.5 || abs(w - window.frame.width) > 0.5 else { return }
        let oldTop = window.frame.maxY
        var f = window.frame
        f.size.height = h
        f.size.width = w
        f.origin.y = oldTop - h          // anchor the top edge; grow/shrink downward
        if let vf = (window.screen ?? NSScreen.main)?.visibleFrame {
            f.origin.x = vf.midX - w / 2  // keep centered if the width changed
        }
        if animated {
            // Pin the content to its FINAL height at the current top edge before
            // tweening. With the .minYMargin autoresizing mask the content then
            // stays put (top-anchored) while the window reveals/covers from the
            // bottom — no vertical slide.
            let contentH = window.contentView?.bounds.height ?? window.frame.height
            hosting.frame = NSRect(x: 0, y: contentH - h, width: w, height: h)
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.09
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                ctx.allowsImplicitAnimation = true
                window.animator().setFrame(f, display: true)
            }, completionHandler: { [weak self] in
                // When the window WIDTH changes (e.g. the 720/600 launcher swapping
                // into an 820 two-pane view), the .width autoresizing mask inflates
                // hosting by the same delta, leaving it wider than the content view —
                // NSHostingView then centres the fixed-width content and it drifts
                // right. Snap the frame back to the final bounds so it stays flush.
                guard let self = self else { return }
                self.hosting.frame = self.window.contentView?.bounds ?? .zero
            })
        } else {
            // Commit the frame + hosting bounds atomically with implicit animation
            // off, so the blur material can't animate/flicker through the resize.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            window.setFrame(f, display: true)
            hosting.frame = window.contentView?.bounds ?? .zero
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
            if commit.pasteAfter { restoreFocusAndPaste() }
        case .linger:
            state.isVisible = false
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

    // Hand focus back to the app that was frontmost before pounce appeared, then
    // synthesize ⌘V once it's active. The small delay lets the activation settle
    // so the keystroke lands in the target app rather than the just-hidden window.
    private func restoreFocusAndPaste() {
        guard let app = capturedApp else { return }
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
        })
    }
}
