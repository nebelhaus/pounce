import SwiftUI
import AppKit

// MARK: - Camera View

// Quick camera peek (à la Raycast): a live, mirrored preview filling the window,
// with an action bar at the bottom. ↵ closes; ⇧↵ opens a dropdown listing every
// available camera — ↑↓ to highlight, ↵ to switch (the choice is remembered).
// There is no search field in this mode, so a local key monitor stands in for
// the launcher's text-field key handling (Esc included).
struct CameraView: View {
    @ObservedObject var state: DaemonState
    @ObservedObject var camera = CameraController.shared
    @State private var pickerOpen = false
    @State private var pickerIndex = 0
    @State private var keyMonitor: Any?

    var activeName: String? {
        camera.devices.first { $0.id == camera.activeID }?.name
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottomTrailing) {
                previewArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if pickerOpen {
                    CameraPickerPanel(
                        devices: camera.devices,
                        activeID: camera.activeID,
                        selectedIndex: pickerIndex,
                        onPick: { i in pick(i) }
                    )
                    .padding(12)
                }
            }
            .frame(height: CameraLayout.previewHeight)
            .clipped()

            Divider().background(Theme.surface1.opacity(0.3))

            actionBar
                .frame(height: CameraLayout.barHeight)
        }
        .frame(width: CameraLayout.width, height: CameraLayout.height)
        .background(Theme.base.opacity(0.55))
        .onAppear { installKeyMonitor() }
        .onDisappear { removeKeyMonitor() }
    }

    @ViewBuilder
    var previewArea: some View {
        switch camera.status {
        case .running:
            CameraPreview()
        case .unauthorized:
            statusMessage("Camera access denied",
                          detail: "Grant it in System Settings → Privacy & Security → Camera")
        case .noCamera:
            statusMessage("No camera found", detail: nil)
        case .idle, .requesting:
            statusMessage("Starting camera…", detail: nil)
        }
    }

    func statusMessage(_ title: String, detail: String?) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "video.slash")
                .font(.system(size: 28, weight: .medium))
                .foregroundColor(Theme.subtext0)
            Text(title)
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundColor(Theme.subtext)
            if let detail = detail {
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.subtext0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.35))
    }

    var actionBar: some View {
        HStack(spacing: 0) {
            if let name = activeName, camera.status == .running {
                HStack(spacing: 7) {
                    Image(systemName: "web.camera")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Theme.subtext0)
                    Text(name)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundColor(Theme.subtext0)
                        .lineLimit(1)
                }
            }
            Spacer()

            if camera.status == .unauthorized {
                barAction(label: "Open Settings", key: "↵") { submit(shift: false) }
            } else {
                if camera.devices.count > 1 || pickerOpen {
                    barAction(label: pickerOpen ? "Hide Cameras" : "Switch Camera", key: "⇧↵") {
                        submit(shift: true)
                    }
                    Rectangle()
                        .fill(Theme.surface1.opacity(0.6))
                        .frame(width: 1, height: 16)
                        .padding(.horizontal, 14)
                }
                barAction(label: pickerOpen ? "Select" : "Close", key: "↵") { submit(shift: false) }
            }
        }
        .padding(.horizontal, 18)
    }

    func barAction(label: String, key: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 7) {
            Text(label)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundColor(Theme.subtext)
            KeyCap(key)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
    }

    // MARK: Actions

    func submit(shift: Bool) {
        if pickerOpen {
            if shift { pickerOpen = false } else { pick(pickerIndex) }
            return
        }
        if shift {
            camera.refreshDevices()
            guard !camera.devices.isEmpty else { return }
            pickerIndex = camera.devices.firstIndex { $0.id == camera.activeID } ?? 0
            pickerOpen = true
            return
        }
        if camera.status == .unauthorized {
            let pane = "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera"
            if let url = URL(string: pane) { NSWorkspace.shared.open(url) }
        }
        state.cancel()
    }

    func pick(_ index: Int) {
        if index < camera.devices.count { camera.select(id: camera.devices[index].id) }
        pickerOpen = false
    }

    // MARK: Keys

    // No text field in this mode, so nothing routes keys for us — catch them
    // app-locally while the camera view is up. Returning nil swallows the event.
    func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard state.displayMode == .camera, state.isVisible else { return event }
            switch event.keyCode {
            case 53:   // esc
                if pickerOpen { pickerOpen = false } else { state.cancel() }
                return nil
            case 36, 76:   // return / keypad enter
                submit(shift: event.modifierFlags.contains(.shift))
                return nil
            case 125:  // down
                guard pickerOpen else { return event }
                pickerIndex = min(pickerIndex + 1, camera.devices.count - 1)
                return nil
            case 126:  // up
                guard pickerOpen else { return event }
                pickerIndex = max(pickerIndex - 1, 0)
                return nil
            default:
                return event
            }
        }
    }

    func removeKeyMonitor() {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
    }
}

// MARK: - Camera Picker Panel

// The ⇧↵ dropdown: a small floating list of every available camera, anchored
// above the action bar. ↑↓ moves the highlight, ↵ (or a click) switches; the
// active camera carries a checkmark.
struct CameraPickerPanel: View {
    let devices: [CameraDevice]
    let activeID: String?
    let selectedIndex: Int
    let onPick: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(devices.enumerated()), id: \.element.id) { i, device in
                HStack(spacing: 8) {
                    Image(systemName: "web.camera")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(i == selectedIndex ? Theme.mauve : Theme.subtext)
                    Text(device.name)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundColor(Theme.text)
                        .lineLimit(1)
                    Spacer(minLength: 12)
                    if device.id == activeID {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Theme.mauve)
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
                .frame(minWidth: 220, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(i == selectedIndex ? Theme.mauve.opacity(0.20) : Color.clear)
                )
                .contentShape(Rectangle())
                .onTapGesture { onPick(i) }
            }
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Theme.surface0.opacity(0.97))
                .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Theme.surface1.opacity(0.6), lineWidth: 1)
        )
    }
}
