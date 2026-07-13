import CoreBluetooth

// TCC bootstrap for the bluetooth command (mirrors --request-accessibility).
// blueutil's classic IOBluetooth calls are denied SILENTLY when the caller
// lacks the Bluetooth grant — no prompt, and the app never appears in
// Privacy & Security → Bluetooth. Instantiating a CBCentralManager is the
// sanctioned way to make macOS raise the prompt. TCC attributes the request
// to the responsible process, so spawned under the daemon this registers the
// grant on the signed Pounce.app — exactly like the camera peek does for
// NSCameraUsageDescription.
enum BluetoothGrant {
    static func check() -> Bool { CBCentralManager.authorization == .allowedAlways }

    static func request() -> Never {
        if CBCentralManager.authorization == .allowedAlways { print("true"); exit(0) }
        let semaphore = DispatchSemaphore(value: 0)
        let delegate = Delegate { semaphore.signal() }
        let manager = CBCentralManager(delegate: delegate, queue: DispatchQueue.global())
        // Wait for the user's answer; a dismissed dialog may never fire the
        // callback, so give up (denied) after a minute.
        _ = semaphore.wait(timeout: .now() + 60)
        withExtendedLifetime((manager, delegate)) {}
        let granted = CBCentralManager.authorization == .allowedAlways
        print(granted ? "true" : "false")
        exit(granted ? 0 : 1)
    }

    private final class Delegate: NSObject, CBCentralManagerDelegate {
        let onDetermined: () -> Void
        init(onDetermined: @escaping () -> Void) { self.onDetermined = onDetermined }
        func centralManagerDidUpdateState(_ central: CBCentralManager) {
            if CBCentralManager.authorization != .notDetermined { onDetermined() }
        }
    }
}
