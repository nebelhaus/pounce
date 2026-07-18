import SwiftUI
import AppKit

// MARK: - Switcher State

// The quasimode's render model, mutated by WindowSwitcher (always on the main
// thread — the event tap's run loop). No text field: the panel never becomes
// key, all input arrives through the event tap.
final class SwitcherState: ObservableObject {
    @Published var visible: [WindowInfo] = []
    @Published var selection = 0
    @Published var query = ""
    @Published var workspaces: [CGWindowID: String] = [:]

    var onSelect: ((Int) -> Void)?    // row click → select + commit
    var onResize: (() -> Void)?       // content height changed; panel refits
}

// MARK: - Layout

enum SwitcherLayout {
    static let width: CGFloat = 640
    static let rowHeight: CGFloat = 44
    static let queryHeight: CGFloat = 40
    static let maxVisibleRows = 9
}

// MARK: - Panel

// A non-activating floating panel: it must never steal key focus (the app the
// user is leaving keeps it until the commit lands), which is also why it needs
// no responder chain — the event tap feeds it. Chrome matches the palette
// window (same blur, mask, radius) so the switcher reads as pounce.
final class SwitcherPanel {
    private let panel: NSPanel
    private let hosting: NSHostingView<SwitcherView>
    private let state: SwitcherState

    init(state: SwitcherState) {
        self.state = state
        hosting = NSHostingView(rootView: SwitcherView(state: state))

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: SwitcherLayout.width, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.level = .statusBar   // above the palette's .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 16
        blur.layer?.masksToBounds = true
        blur.layer?.borderWidth = 1
        blur.layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor
        blur.maskImage = PounceUI.roundedMask(radius: 16)
        hosting.autoresizingMask = [.width, .height]
        blur.addSubview(hosting)
        panel.contentView = blur

        state.onResize = { [weak self] in
            guard let self, self.panel.isVisible else { return }
            self.refit()
        }
    }

    func show() {
        refit()
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    // Size to the SwiftUI content and park it slightly above screen center (the
    // stock switcher's neighborhood). Snap, never tween — same reasoning as
    // PounceUI.resizeToFit.
    private func refit() {
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        guard size.height > 1,
              let vf = (NSScreen.main ?? panel.screen)?.visibleFrame else { return }
        let frame = NSRect(
            x: vf.midX - SwitcherLayout.width / 2,
            y: vf.midY - size.height / 2 + vf.height * 0.06,
            width: SwitcherLayout.width,
            height: size.height
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        panel.setFrame(frame, display: true)
        hosting.frame = panel.contentView?.bounds ?? .zero
        CATransaction.commit()
    }
}

// MARK: - View

struct SwitcherView: View {
    @ObservedObject var state: SwitcherState

    var listHeight: CGFloat {
        CGFloat(min(max(state.visible.count, 1), SwitcherLayout.maxVisibleRows))
            * SwitcherLayout.rowHeight
    }

    var body: some View {
        VStack(spacing: 0) {
            // The filter line appears only once the user types — the resting
            // switcher is just the window list.
            if !state.query.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Theme.subtext)
                    Text(state.query)
                        .font(.system(size: 15, weight: .regular, design: .rounded))
                        .foregroundColor(Theme.text)
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .frame(height: SwitcherLayout.queryHeight)

                Divider().background(Theme.surface1.opacity(0.3))
            }

            if state.visible.isEmpty {
                Text("No matching windows")
                    .font(.system(size: 14, design: .rounded))
                    .foregroundColor(Theme.subtext0)
                    .frame(height: SwitcherLayout.rowHeight)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            // Identity is the row POSITION, not the window. The
                            // selection highlight is a function of position
                            // (`i == selection`); keying rows on `w.id` instead
                            // made SwiftUI carry a row's rendered view — highlight
                            // and all — to the window's new slot whenever the list
                            // reordered between opens (the just-focused window
                            // jumps to the top on a rapid second ⌘Tab), stranding
                            // the highlight on the wrong row. Position identity
                            // re-evaluates `isSelected` per slot every time.
                            ForEach(state.visible.indices, id: \.self) { i in
                                let w = state.visible[i]
                                SwitcherRow(window: w,
                                            workspace: state.workspaces[w.id],
                                            isSelected: i == state.selection)
                                    .frame(height: SwitcherLayout.rowHeight)
                                    .onTapGesture { state.onSelect?(i) }
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    .frame(height: listHeight + 12)
                    .onChange(of: state.selection) {
                        if state.visible.indices.contains(state.selection) {
                            proxy.scrollTo(state.selection)
                        }
                    }
                }
            }
        }
        .frame(width: SwitcherLayout.width)
        .fixedSize(horizontal: false, vertical: true)
        .background(Theme.base.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .onChange(of: state.visible.count) { state.onResize?() }
        .onChange(of: state.query.isEmpty) { state.onResize?() }
    }
}

// MARK: - Row

struct SwitcherRow: View {
    let window: WindowInfo
    let workspace: String?
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let path = window.appPath {
                    Image(nsImage: AppIconCache.shared.icon(for: path))
                        .resizable().aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "macwindow")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(isSelected ? Theme.mauve : Theme.subtext)
                }
            }
            .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 1) {
                Text(window.title)
                    .foregroundColor(Theme.text)
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .lineLimit(1)
                if window.title != window.appName {
                    Text(window.appName)
                        .foregroundColor(Theme.subtext0)
                        .font(.system(size: 11, design: .rounded))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            if window.isMinimized {
                Image(systemName: "arrow.down.right.square")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.subtext0)
            }

            // The AeroSpace workspace this window lives on — the cross-workspace
            // reach is what the badge is advertising.
            if let ws = workspace {
                Text(ws)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(Theme.blue)
                    .frame(minWidth: 20, minHeight: 20)
                    .padding(.horizontal, 2)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Theme.blue.opacity(0.15)))
            }
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isSelected ? Theme.mauve.opacity(0.20) : Color.clear)
                .padding(.horizontal, 8)
        )
        .contentShape(Rectangle())
    }
}
