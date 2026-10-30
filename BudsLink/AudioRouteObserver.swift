import AVFoundation
import Combine
import UIKit

/// Read-only view of the system audio route.
///
/// This is the same kind of evidence iOS itself uses to say "headphones are connected"
/// (A2DP / HFP / LE Audio output). CoreBluetooth alone cannot see Classic Bluetooth
/// audio links, which is why a BLE-only check reports "Disconnected" for earbuds that
/// are playing audio perfectly well.
///
/// LIVE LISTEN SAFETY: this class only READS `currentRoute`. It never calls
/// setCategory / setActive / setPreferredInput, never touches AVAudioEngine, and never
/// requests the microphone, so it cannot interfere with LiveListenManager or AudioManager.
final class AudioRouteObserver: ObservableObject {

    struct BluetoothRoute: Equatable {
        enum Kind: String { case a2dp = "A2DP", hfp = "HFP", le = "LE Audio" }
        let name: String
        let kind: Kind
        let uid: String
    }

    @Published private(set) var route: BluetoothRoute?

    private var tokens: [NSObjectProtocol] = []

    init() {
        refresh()
        let names: [Notification.Name] = [
            AVAudioSession.routeChangeNotification,
            AVAudioSession.mediaServicesWereResetNotification,
            UIApplication.didBecomeActiveNotification
        ]
        tokens = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refresh()
            }
        }
    }

    deinit {
        tokens.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func refresh() {
        let current = AVAudioSession.sharedInstance().currentRoute
        let found: [BluetoothRoute] = (current.outputs + current.inputs).compactMap { port in
            switch port.portType {
            case .bluetoothA2DP: return BluetoothRoute(name: port.portName, kind: .a2dp, uid: port.uid)
            case .bluetoothHFP:  return BluetoothRoute(name: port.portName, kind: .hfp, uid: port.uid)
            case .bluetoothLE:   return BluetoothRoute(name: port.portName, kind: .le, uid: port.uid)
            default:             return nil
            }
        }
        // Prefer the music route (A2DP) for naming; Live Listen's HFP route reports the same device.
        let best = found.first(where: { $0.kind == .a2dp }) ?? found.first
        if best != route { route = best }
    }
}
