import SwiftUI

@main struct BudsLinkApp: App {
    @StateObject private var bt = BluetoothManager()
    @StateObject private var audio = AudioManager()
    @StateObject private var monitor = ConnectionMonitor()
    @StateObject private var live = LiveListenManager()
    @StateObject private var noise = NoiseControlManager()

    var body: some Scene {
        WindowGroup {
            ZStack(alignment: .top) {
                TabView {
                    DashboardView().tabItem { Label("Buds", systemImage: "earbuds") }
                    LiveListenView().tabItem { Label("Live Listen", systemImage: "ear.badge.waveform") }
                    EQView().tabItem { Label("EQ", systemImage: "slider.vertical.3") }
                    CompatibilityView().tabItem { Label("Features", systemImage: "checklist") }
                }
                if monitor.showPopup {
                    ConnectPopup(name: monitor.deviceName ?? "Earbuds", battery: bt.batteryPercent)
                        .transition(.move(edge: .top).combined(with: .opacity)).zIndex(1)
                }
            }
            .animation(.spring(response: 0.5, dampingFraction: 0.8), value: monitor.showPopup)
            .environmentObject(bt).environmentObject(audio)
            .environmentObject(monitor).environmentObject(live).environmentObject(noise)
            .onAppear { monitor.onConnect = { bt.attachToConnected() }; bt.attachToConnected() }
        }
    }
}

struct ConnectPopup: View {
    let name: String; let battery: Int?
    @State private var pulse = false
    @EnvironmentObject var noise: NoiseControlManager
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "earbuds").font(.largeTitle).scaleEffect(pulse ? 1.12 : 0.95)
                .onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever()) { pulse = true } }
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.headline)
                Text("Connected").font(.subheadline).foregroundStyle(.green)
                Text(battery.map { "Battery \($0)%" } ?? "Battery not reported by earbuds")
                    .font(.caption).foregroundStyle(.secondary)
                if noise.isSupported {
                    HStack { ForEach(noise.supportedModes, id: \.self) { m in
                        Text("\(m.icon) \(m.rawValue)").font(.caption2).padding(6)
                            .background(noise.mode == m ? Color.accentColor : Color.secondary.opacity(0.2), in: Capsule())
                            .foregroundStyle(noise.mode == m ? Color.white : Color.primary) } }
                }
            }
            Spacer()
        }
        .padding().background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28))
        .padding(.horizontal).padding(.top, 8)
    }
}

struct DashboardView: View {
    @EnvironmentObject var bt: BluetoothManager
    @EnvironmentObject var monitor: ConnectionMonitor
    @EnvironmentObject var noise: NoiseControlManager
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    VStack(spacing: 6) {
                        Text(monitor.status == .connected ? "🟢 Connected" : "⚪️ Disconnected").font(.headline)
                        Text(monitor.deviceName ?? "No earbuds detected").font(.title2.bold())
                        if let r = bt.rssi { Text("Signal \(r) dBm").foregroundStyle(.secondary) }
                    }
                    .frame(maxWidth: .infinity).padding()
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
                    BatteryCard()
                    if let e = bt.errorMessage { Text(e).foregroundStyle(.orange).font(.callout) }
                    Button("Scan for battery (BLE)") {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred(); bt.startScan()
                    }.buttonStyle(.borderedProminent)
                    NoiseControlCard()
                    Text("Last seen: \(bt.lastSeen?.formatted(date: .omitted, time: .shortened) ?? "never"). Not Apple's Find My network.")
                        .font(.footnote).foregroundStyle(.secondary)
                }.padding()
            }.navigationTitle("BudsLink")
                .onChange(of: bt.gattDump) { _, new in noise.detect(gatt: new) }
        }
    }
}

struct BatteryCard: View {
    @EnvironmentObject var bt: BluetoothManager
    private func row(_ t: String, _ v: String) -> some View { HStack { Text(t); Spacer(); Text(v).foregroundStyle(.secondary) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            row("Earbuds (single value)", bt.batteryPercent.map { "\($0)%" } ?? "Not available")
            row("Left earbud", "Not exposed")
            row("Right earbud", "Not exposed")
            row("Charging case", "Not exposed")
            Text("iOS doesn't give apps Classic Bluetooth battery data. Only a BLE Battery Service value can be shown, and only if the buds offer one.")
                .font(.footnote).foregroundStyle(.secondary)
        }.padding().background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
    }
}

struct LiveListenView: View {
    @EnvironmentObject var live: LiveListenManager
    @EnvironmentObject var monitor: ConnectionMonitor
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Live Listen", isOn: Binding(get: { live.isOn }, set: { $0 ? live.start() : live.stop() }))
                    ProgressView(value: Double(live.level))
                    if monitor.status != .connected { Text("Connect your earbuds first.").foregroundStyle(.orange) }
                }
                Section("Adjust (start low)") {
                    VStack(alignment: .leading) {
                        Text("Boost +\(Int(live.gainDB)) dB")
                        Slider(value: Binding(get: { Double(live.gainDB) }, set: { live.gainDB = Float($0) }), in: 0...15, step: 1)
                    }
                    Toggle("Voice boost", isOn: $live.voiceBoost)
                }
                if let e = live.error { Text(e).foregroundStyle(.orange) }
                Section {
                    Text("Plays the iPhone microphone into your earbuds. Nothing is recorded or saved. Bluetooth adds about 100-250 ms delay. Keep the volume low to protect your hearing. This is BudsLink's own feature, not Apple's Live Listen.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }.navigationTitle("Live Listen")
        }
    }
}

struct EQView: View {
    @EnvironmentObject var audio: AudioManager
    var body: some View {
        NavigationStack {
            List {
                Picker("Preset", selection: Binding(get: { audio.preset }, set: { audio.applyPreset($0) })) {
                    ForEach(AudioManager.presets.keys.sorted(), id: \.self) { Text($0) }
                }
                ForEach(0..<9, id: \.self) { i in
                    VStack(alignment: .leading) {
                        Text("\(Int(AudioManager.bands[i])) Hz  \(audio.gains[i], specifier: "%.0f") dB")
                        Slider(value: Binding(get: { Double(audio.gains[i]) }, set: { audio.setGain(i, Float($0)) }), in: -12...12, step: 1)
                    }
                }
                Section("Immersive Audio (software-based)") {
                    Picker("Mode", selection: $audio.headMode) { ForEach(HeadMode.allCases, id: \.self) { Text($0.rawValue) } }
                        .pickerStyle(.segmented)
                    Text("Applies to audio played in BudsLink only. Head tracking uses the iPhone's sensors.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }.navigationTitle("Equalizer")
        }
    }
}

struct CapabilityRow: View {
    let cap: Capability
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack { Text(cap.title).bold(); Spacer(); Text(cap.tier.rawValue).font(.caption).padding(4)
                .background(.thinMaterial, in: Capsule()) }
            Text(cap.note).font(.footnote).foregroundStyle(.secondary)
        }.padding().background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

struct CompatibilityView: View {
    var body: some View {
        NavigationStack {
            ScrollView { VStack(spacing: 10) { ForEach(CapabilityRegistry.all) { CapabilityRow(cap: $0) } }.padding() }
                .navigationTitle("Feature Comparison")
        }
    }
}
