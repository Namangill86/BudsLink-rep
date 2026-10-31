import Combine
import Foundation

/// Single source of truth for the earbuds screen. Three DIFFERENT facts are kept apart on purpose:
///
///   Audio connection : the system audio route is a Bluetooth output (A2DP / HFP / LE Audio)
///   BLE link         : a GATT connection to the earbuds exists (CoreBluetooth didConnect)
///   BLE control      : the OPO session is ready (HELLO + REGISTER answered)
///
/// Audio working proves nothing about the other two. Create ONE instance (`@StateObject` in BudsLinkApp).
/// It does not use or modify BluetoothManager, ConnectionMonitor, AudioManager or LiveListenManager.
final class EarbudHub: ObservableObject {

    let route = AudioRouteObserver()
    let ble = BLEEarbudSession()
    let noise: OPONoiseControl
    let battery: OPOBatteryMonitor
    let info: OPODeviceInfoManager

    private var bag = Set<AnyCancellable>()

    init() {
        noise = OPONoiseControl(session: ble.opo)
        battery = OPOBatteryMonitor(session: ble.opo)
        info = OPODeviceInfoManager(session: ble.opo)

        // Forward child changes so views that observe only the hub still refresh.
        Publishers.MergeMany([
            route.objectWillChange, ble.objectWillChange, ble.opo.objectWillChange,
            noise.objectWillChange, battery.objectWillChange, info.objectWillChange
        ])
        .sink { [weak self] _ in self?.objectWillChange.send() }
        .store(in: &bag)

        // Every audio-route change (connect, disconnect, case closing) re-evaluates which BLE peripheral to look for.
        route.$route
            .removeDuplicates()
            .sink { [weak self] newRoute in self?.ble.start(matchingAudioRouteNamed: newRoute?.name) }
            .store(in: &bag)
    }

    /// Call from the screen's onAppear / onDisappear: polling runs only while the screen is visible.
    func screenAppeared() {
        route.refresh()
        ble.start(matchingAudioRouteNamed: route.route?.name)
        noise.startWatching()
        battery.startWatching()
    }

    func screenDisappeared() {
        noise.stopWatching()
        battery.stopWatching()
    }

    func retryControl() { ble.retryControl() }

    // MARK: The three states

    var audioConnected: Bool { route.route != nil }

    var bleLinked: Bool {
        if case .connected = ble.connection { return true }
        return false
    }

    var controlReady: Bool { ble.opo.state == .ready }

    var isConnected: Bool { audioConnected || bleLinked }

    var displayName: String? {
        if let name = route.route?.name { return name }
        if case .connected(let name) = ble.connection { return name }
        return nil
    }

    /// The earbuds' own BLE name (what the earbuds call themselves), or nil when there is no BLE link.
    var bleDeviceName: String? {
        if case .connected(let name) = ble.connection { return name }
        return nil
    }

    var audioDescription: String {
        guard let r = route.route else { return "Not connected" }
        return "Connected (\(r.kind.rawValue))"
    }

    var bleLinkDescription: String {
        switch ble.connection {
        case .bluetoothOff:        return "Bluetooth is off. Turn it on in Control Center."
        case .unauthorized:        return "Bluetooth permission denied. Enable it in Settings > BudsLink."
        case .unsupported:         return "Bluetooth LE is not supported on this device."
        case .idle:                return "Not connected"
        case .searching:           return "Searching…"
        case .connecting(let n):   return "Connecting to \(n)…"
        case .waiting(let n):      return "Waiting for \(n)…"
        case .connected:           return "Connected"
        }
    }

    var controlDescription: String {
        switch ble.opo.state {
        case .unavailable:         return "Not connected"
        case .starting(let step):  return "Starting: \(step)"
        case .ready:               return "Connected"
        case .failed:              return "Failed"
        }
    }

    /// The exact reason BLE control is not available, or nil when it is ready.
    var controlDiagnosis: String? {
        switch ble.opo.state {
        case .ready:                   return nil
        case .starting:                return nil
        case .unavailable(let reason): return reason
        case .failed(let reason):      return reason
        }
    }

    var reportText: String {
        ble.reportText(audioRoute: route.route.map { "\($0.name) (\($0.kind.rawValue))" })
    }
}
