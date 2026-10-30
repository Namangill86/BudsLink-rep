import Combine
import Foundation

/// Single source of truth for "are my earbuds connected, and what do they expose?".
///
/// "Connected" is reported only when there is real evidence:
///   - the system audio route is a Bluetooth output (A2DP / HFP / LE Audio), or
///   - a GATT link to the earbuds' peripheral is actually established.
///
/// Create ONE instance (e.g. `@StateObject private var hub = EarbudHub()` in BudsLinkApp).
/// It does not use or modify BluetoothManager, ConnectionMonitor, AudioManager or LiveListenManager.
final class EarbudHub: ObservableObject {

    let route = AudioRouteObserver()
    let ble = BLEEarbudSession()

    private var bag = Set<AnyCancellable>()

    init() {
        // Forward child changes so views that observe only the hub still refresh.
        route.objectWillChange
            .merge(with: ble.objectWillChange)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &bag)

        // Every audio-route change (connect, disconnect, case open/close that drops the link)
        // re-evaluates which BLE peripheral to look for. Emits the current value immediately.
        route.$route
            .removeDuplicates()
            .sink { [weak self] newRoute in self?.ble.start(matchingAudioRouteNamed: newRoute?.name) }
            .store(in: &bag)
    }

    func start() {
        route.refresh()
        ble.start(matchingAudioRouteNamed: route.route?.name)
    }

    var bleConnected: Bool {
        if case .connected = ble.connection { return true }
        return false
    }

    var isConnected: Bool { route.route != nil || bleConnected }

    var displayName: String? {
        if let name = route.route?.name { return name }
        if case .connected(let name) = ble.connection { return name }
        return nil
    }

    var routeDescription: String {
        guard let r = route.route else { return "No Bluetooth audio output" }
        return "\(r.name) (\(r.kind.rawValue))"
    }

    var bleDescription: String {
        switch ble.connection {
        case .bluetoothOff:        return "Bluetooth is off. Turn it on in Control Center."
        case .unauthorized:        return "Bluetooth permission denied. Enable it in Settings > BudsLink."
        case .unsupported:         return "Bluetooth LE is not supported on this device."
        case .idle:                return "Not linked"
        case .searching:           return "Searching…"
        case .connecting(let n):   return "Connecting to \(n)…"
        case .waiting(let n):      return "Waiting for \(n)…"
        case .connected(let n):    return "Linked to \(n)"
        }
    }

    var reportText: String { ble.reportText(audioRoute: route.route.map { "\($0.name) (\($0.kind.rawValue))" }) }
}
