import AVFoundation
import UIKit

extension AVAudioSession {
    static let btPorts: [AVAudioSession.Port] = [.bluetoothA2DP, .bluetoothHFP, .bluetoothLE]
    var bluetoothOutput: AVAudioSessionPortDescription? {
        currentRoute.outputs.first { Self.btPorts.contains($0.portType) }
    }
}

enum LinkStatus { case connected, disconnected }

/// Real connection state from iOS's audio route. iOS reports only connected / disconnected.
final class ConnectionMonitor: ObservableObject {
    @Published var status: LinkStatus = .disconnected
    @Published var deviceName: String?
    @Published var showPopup = false
    var onConnect: (() -> Void)?

    init() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.ambient, options: [.mixWithOthers])   // lets us read the route without interrupting music
        try? s.setActive(true)
        NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.refresh(fromChange: true)
        }
        refresh(fromChange: false)
    }

    func refresh(fromChange: Bool) {
        let out = AVAudioSession.sharedInstance().bluetoothOutput
        let wasConnected = status == .connected
        deviceName = out?.portName
        status = out == nil ? .disconnected : .connected
        guard fromChange, !wasConnected, status == .connected else { return }
        onConnect?()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        showPopup = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.showPopup = false }
    }
}
