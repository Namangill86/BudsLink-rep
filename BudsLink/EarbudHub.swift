import Combine
import Foundation

/// Single source of truth for every earbud screen (Buds tab, Earbuds tab, popup, Features). Three DIFFERENT facts
/// are kept apart on purpose:
///
///   Audio         : the system audio route is a Bluetooth output (A2DP / HFP / LE Audio)
///   Bluetooth LE  : a GATT connection to the earbuds exists (CoreBluetooth didConnect)
///   BLE control   : the OPO session is ready (HELLO + REGISTER answered)
///
/// Audio working proves nothing about the other two. Create ONE instance (`@StateObject` in BudsLinkApp).
/// It does not use or modify ConnectionMonitor, AudioManager or LiveListenManager.
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

        // Every audio-route change (connect, disconnect, case opening or closing) re-evaluates the BLE side.
        // This also fires once at launch, so BLE starts without any screen having to be opened.
        route.$route
            .removeDuplicates()
            .sink { [weak self] newRoute in self?.ble.start(matchingAudioRouteNamed: newRoute?.name) }
            .store(in: &bag)
    }

    /// Called by ConnectionMonitor.onConnect and by screens.
    func connectionDetected() {
        route.refresh()
        ble.start(matchingAudioRouteNamed: route.route?.name)
    }

    private var visibleScreens = 0

    /// Call from a screen's onAppear / onDisappear. A counter (not a flag) because in a TabView the new tab's
    /// onAppear can fire before the old tab's onDisappear. Polling runs only while at least one screen is visible.
    func screenAppeared() {
        visibleScreens += 1
        connectionDetected()
        noise.startWatching()
        battery.startWatching()
    }

    func screenDisappeared() {
        visibleScreens = max(0, visibleScreens - 1)
        if visibleScreens == 0 {
            noise.stopWatching()
            battery.stopWatching()
        }
    }

    func retryControl() { ble.retryControl() }
    func runDiagnostic() { ble.runDiagnostic() }

    // MARK: The three states

    var audioConnected: Bool { route.route != nil }
    var bleLinked: Bool { ble.bleLinked }
    var controlReady: Bool { ble.control == .ready }
    var isConnected: Bool { audioConnected || bleLinked }

    var displayName: String? {
        if let name = route.route?.name { return name }
        if bleLinked { return ble.peripheralName }
        return nil
    }

    var audioDescription: String {
        guard let r = route.route else { return "Not connected" }
        return "Connected (\(r.kind.rawValue))"
    }

    var bleLinkDescription: String {
        if bleLinked { return "Connected" }
        switch ble.control {
        case .bluetoothOff:                   return "Bluetooth is off"
        case .unauthorized:                   return "Permission denied"
        case .unsupported:                    return "Not supported"
        case .scanning:                       return "Searching…"
        case .discovered, .connecting:        return "Connecting…"
        case .unavailable:                    return "Earbuds unavailable"
        default:                              return "Not connected"
        }
    }

    var controlDescription: String {
        if case .authenticating(let step) = ble.control { return "Authenticating… (\(step))" }
        return ble.control.title
    }

    /// The exact reason BLE control is not ready, or nil while it is progressing normally or ready.
    var controlDiagnosis: String? {
        switch ble.control {
        case .unavailable(let r), .failed(let r): return r
        case .bluetoothOff, .unauthorized, .unsupported: return ble.control.reason
        default: return nil
        }
    }

    var canRetry: Bool {
        switch ble.control {
        case .ready, .bluetoothOff, .unauthorized, .unsupported: return false
        default: return true
        }
    }

    /// One line for the connect pop-up. Only values the earbuds reported; otherwise the honest state.
    var batterySummary: String {
        switch battery.status {
        case .ready:
            var parts: [String] = []
            if let v = battery.left { parts.append("L \(v.percent)%") }
            if let v = battery.right { parts.append("R \(v.percent)%") }
            if let v = battery.caseValue { parts.append("Case \(v.percent)%") }
            return parts.isEmpty ? "Battery: no values reported" : "Battery " + parts.joined(separator: " · ")
        case .idle, .loading:
            return "Battery: loading…"
        case .failed:
            return "Battery: BLE communication failed"
        case .unavailable:
            return "Battery: waiting for BLE control"
        }
    }

    var reportText: String {
        ble.reportText(audioRoute: route.route.map { "\($0.name) (\($0.kind.rawValue))" })
    }
}
