import AVFoundation
import AudioToolbox

/// In-app "Live Listen": iPhone mic -> earbuds. Nothing is recorded or stored.
final class LiveListenManager: ObservableObject {
    @Published var isOn = false
    @Published var error: String?
    @Published var level: Float = 0
    @Published var gainDB: Float = 0 { didSet { eq.globalGain = gainDB } }       // 0...15 dB
    @Published var voiceBoost = false { didSet { eq.bands[1].bypass = !voiceBoost } }

    private let engine = AVAudioEngine()
    private let eq = AVAudioUnitEQ(numberOfBands: 2)
    private let limiter = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
        componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_PeakLimiter,
        componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))

    init() {
        eq.bands[0].filterType = .highPass; eq.bands[0].frequency = 150; eq.bands[0].bypass = false  // cut rumble
        eq.bands[1].filterType = .parametric; eq.bands[1].frequency = 2500; eq.bands[1].bandwidth = 1
        eq.bands[1].gain = 5; eq.bands[1].bypass = true                                              // speech clarity
        engine.attach(eq); engine.attach(limiter)
        NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            guard let self, self.isOn, AVAudioSession.sharedInstance().bluetoothOutput == nil else { return }
            self.stop(); self.error = "Earbuds disconnected. Live Listen stopped."
        }
    }

    func start() {
        error = nil
        AVAudioApplication.requestRecordPermission { granted in
            DispatchQueue.main.async {
                guard granted else { self.error = "Microphone permission denied. Enable it in Settings > BudsLink."; return }
                self.run()
            }
        }
    }

    private func run() {
        do {
            let s = AVAudioSession.sharedInstance()
            try s.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothA2DP])
            try s.setActive(true)
            if let mic = s.availableInputs?.first(where: { $0.portType == .builtInMic }) { try s.setPreferredInput(mic) }
            guard s.bluetoothOutput != nil else {
                error = "Connect your earbuds first. Without them, audio would play from the phone speaker and cause feedback."
                return
            }
            let input = engine.inputNode
            let fmt = input.outputFormat(forBus: 0)
            engine.connect(input, to: eq, format: fmt)
            engine.connect(eq, to: limiter, format: fmt)
            engine.connect(limiter, to: engine.mainMixerNode, format: fmt)
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buf, _ in
                guard let ch = buf.floatChannelData?[0] else { return }
                let n = Int(buf.frameLength); var sum: Float = 0
                for i in 0..<n { sum += ch[i] * ch[i] }
                let rms = (sum / Float(max(n, 1))).squareRoot()
                DispatchQueue.main.async { self?.level = min(rms * 8, 1) }
            }
            eq.globalGain = gainDB
            try engine.start()
            isOn = true
        } catch { self.error = "Couldn't start Live Listen: \(error.localizedDescription)" }
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
        isOn = false; level = 0
    }
}
