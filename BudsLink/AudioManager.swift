import AVFoundation
import CoreMotion

enum HeadMode: String, CaseIterable { case off = "Off", fixed = "Fixed", tracking = "Head tracking" }

/// In-app playback only: 9-band EQ + software spatialization. Not system-wide.
final class AudioManager: ObservableObject {
    static let bands: [Float] = [60, 120, 250, 500, 1000, 2000, 4000, 8000, 16000]
    static let presets: [String: [Float]] = [
        "Balanced": [0,0,0,0,0,0,0,0,0],
        "Bass Boost": [6,5,3,1,0,0,0,0,0],
        "Vocal": [-2,-1,0,3,4,3,1,0,-1],
        "Rock": [4,3,1,-1,-1,1,3,4,4],
        "Classical": [3,2,1,0,0,0,-1,-2,-3],
        "Podcast": [-3,-1,1,3,4,3,1,-1,-3],
    ]

    @Published var preset = "Balanced"
    @Published var gains: [Float] = Array(repeating: 0, count: 9)
    @Published var preamp: Float = 0
    @Published var headMode: HeadMode = .off { didSet { updateMotion() } }
    @Published var yawDegrees: Double = 0          // drives the sound-stage visual

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let eq = AVAudioUnitEQ(numberOfBands: 9)
    private let env = AVAudioEnvironmentNode()
    private let motion = CMMotionManager()

    init() {
        for (i, f) in Self.bands.enumerated() {
            let b = eq.bands[i]; b.filterType = .parametric; b.frequency = f; b.bandwidth = 1; b.bypass = false
        }
        engine.attach(player); engine.attach(eq); engine.attach(env)
        env.renderingAlgorithm = .HRTFHQ
    }

    func applyPreset(_ name: String) {
        guard let g = Self.presets[name] else { return }
        preset = name; gains = g; apply()
    }
    func setGain(_ i: Int, _ v: Float) { gains[i] = v; preset = "Custom"; apply() }
    func apply() {
        for i in 0..<9 { eq.bands[i].gain = gains[i] }
        eq.globalGain = preamp
    }

    /// Plays a local, non-DRM file. Spatialization needs a mono source, so we downmix.
    func play(url: URL) throws {
        try AVAudioSession.sharedInstance().setCategory(.playback)
        try AVAudioSession.sharedInstance().setActive(true)
        let file = try AVAudioFile(forReading: url)
        let mono = AVAudioFormat(standardFormatWithSampleRate: file.processingFormat.sampleRate, channels: 1)!
        engine.connect(player, to: eq, format: file.processingFormat)
        if headMode == .off {
            engine.connect(eq, to: engine.mainMixerNode, format: file.processingFormat)
        } else {
            engine.connect(eq, to: env, format: mono)
            engine.connect(env, to: engine.mainMixerNode, format: nil)
            player.position = AVAudio3DPoint(x: 0, y: 0, z: -2)   // virtual speaker ahead
        }
        apply()
        try engine.start()
        player.scheduleFile(file, at: nil); player.play()
    }

    private func updateMotion() {
        motion.stopDeviceMotionUpdates()
        guard headMode == .tracking, motion.isDeviceMotionAvailable else { yawDegrees = 0; return }
        motion.deviceMotionUpdateInterval = 1.0 / 60
        motion.startDeviceMotionUpdates(to: .main) { [weak self] m, _ in
            guard let self, let m else { return }
            let yaw = m.attitude.yaw * 180 / .pi            // iPhone yaw, NOT earbud yaw
            self.yawDegrees = yaw
            self.env.listenerAngularOrientation = AVAudio3DAngularOrientation(yaw: Float(-yaw), pitch: 0, roll: 0)
        }
    }
}
