import AVFoundation
import SwiftUI

// MARK: - Camera Controller

// One camera the picker can switch to.
struct CameraDevice: Identifiable {
    let id: String     // AVCaptureDevice.uniqueID
    let name: String
}

// Owns the AVFoundation capture session for the camera peek. A singleton so the
// session (and the TCC grant prompt) belongs to the daemon process, not to a
// per-request view. All session mutations run on a serial queue —
// startRunning/stopRunning block for a noticeable moment and must stay off the
// main thread; published state is flipped back on main.
final class CameraController: ObservableObject {
    static let shared = CameraController()

    enum Status { case idle, requesting, unauthorized, noCamera, running }
    @Published var status: Status = .idle
    @Published var devices: [CameraDevice] = []
    @Published var activeID: String?

    // The preview layer lives here (not in the view) so mirroring can be
    // re-applied after every device swap — swapping the input recreates the
    // layer's connection, which would otherwise silently drop the mirror.
    let session = AVCaptureSession()
    let previewLayer: AVCaptureVideoPreviewLayer

    private let queue = DispatchQueue(label: "pounce.camera")
    private var currentInput: AVCaptureDeviceInput?
    private static let lastDeviceKey = "camera.lastDeviceID"

    private init() {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
    }

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            beginSession()
        case .notDetermined:
            status = .requesting
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self = self, self.status == .requesting else { return }
                    if granted { self.beginSession() } else { self.status = .unauthorized }
                }
            }
        default:
            status = .unauthorized
        }
    }

    func stop() {
        guard status != .idle else { return }
        status = .idle
        queue.async {
            if self.session.isRunning { self.session.stopRunning() }
            self.session.beginConfiguration()
            if let input = self.currentInput { self.session.removeInput(input) }
            self.currentInput = nil
            self.session.commitConfiguration()
        }
    }

    // Re-enumerate cameras (e.g. when the picker opens, to catch a camera
    // plugged in since the window appeared).
    func refreshDevices() {
        devices = Self.discover().map { CameraDevice(id: $0.uniqueID, name: $0.localizedName) }
    }

    func select(id: String) {
        guard id != activeID,
              let device = Self.discover().first(where: { $0.uniqueID == id }) else { return }
        activeID = id
        UserDefaults.standard.set(id, forKey: Self.lastDeviceKey)
        queue.async { self.configure(device: device) }
    }

    private func beginSession() {
        let found = Self.discover()
        devices = found.map { CameraDevice(id: $0.uniqueID, name: $0.localizedName) }
        guard !found.isEmpty else { status = .noCamera; return }

        // Prefer the camera picked last time (explicit ⇧↵ choice), else the first.
        let lastID = UserDefaults.standard.string(forKey: Self.lastDeviceKey)
        let device = found.first { $0.uniqueID == lastID } ?? found[0]
        activeID = device.uniqueID
        status = .running
        queue.async {
            self.configure(device: device)
            if !self.session.isRunning { self.session.startRunning() }
        }
    }

    // Runs on `queue`.
    private func configure(device: AVCaptureDevice) {
        session.beginConfiguration()
        session.sessionPreset = .high
        if let old = currentInput { session.removeInput(old) }
        currentInput = nil
        if let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
            session.addInput(input)
            currentInput = input
        }
        session.commitConfiguration()

        // A peek is a mirror check — flip the preview like Raycast (and Photo
        // Booth) do. Must re-apply per swap; see previewLayer comment above.
        DispatchQueue.main.async {
            if let c = self.previewLayer.connection, c.isVideoMirroringSupported {
                c.automaticallyAdjustsVideoMirroring = false
                c.isVideoMirrored = true
            }
        }
    }

    private static func discover() -> [AVCaptureDevice] {
        var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
        if #available(macOS 13.0, *) { types += [.continuityCamera, .deskViewCamera] }
        if #available(macOS 14.0, *) { types.append(.external) }
        return AVCaptureDevice.DiscoverySession(
            deviceTypes: types, mediaType: .video, position: .unspecified
        ).devices
    }
}

// MARK: - Preview Layer Host

// Hosts the controller's shared preview layer. Plain layer-backed NSView; the
// layer autoresizes with the view so the SwiftUI frame is the only geometry.
struct CameraPreview: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.black.cgColor
        let layer = CameraController.shared.previewLayer
        layer.frame = v.bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        v.layer?.addSublayer(layer)
        return v
    }

    func updateNSView(_ v: NSView, context: Context) {
        CameraController.shared.previewLayer.frame = v.bounds
    }
}
