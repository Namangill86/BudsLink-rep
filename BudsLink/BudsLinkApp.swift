import SwiftUI

@main struct BudsLinkApp: App {
    // BluetoothManager is intentionally NOT created any more. It ran its own CBCentralManager that connected on
    // every Bluetooth power-on and from onAppear, in parallel with EarbudHub's, and the two fought over the earbuds.
    // EarbudHub (BLEEarbudSession -> OPOSession) is now the ONE authoritative BLE control layer.
    @StateObject private var audio = AudioManager()
    @StateObject private var monitor = ConnectionMonitor()
    @StateObject private var live = LiveListenManager()
    @StateObject private var noise = NoiseControlManager()   // legacy object, kept so any view that still reads it keeps working
    @StateObject private var hub = EarbudHub()

    var body: some Scene {
        WindowGroup {
            ZStack(alignment: .top) {
                TabView {
                    DashboardView().tabItem { Label("Buds", systemImage: "earbuds") }
                    LiveListenView().tabItem { Label("Live Listen", systemImage: "ear.badge.waveform") }
                    EQView().tabItem { Label("EQ", systemImage: "slider.vertical.3") }
                    FeatureComparisonView().tabItem { Label("Features", systemImage: "checklist") }
                    EarbudStatusView(hub: hub).tabItem { Label("Earbuds", systemImage: "antenna.radiowaves.left.and.right") }
                }
                if monitor.showPopup {
                    ConnectPopup(name: monitor.deviceName ?? "Earbuds")
                        .transition(.move(edge: .top).combined(with: .opacity)).zIndex(1)
                }
            }
            .animation(.spring(response: 0.5, dampingFraction: 0.8), value: monitor.showPopup)
            .environmentObject(audio)
            .environmentObject(monitor).environmentObject(live).environmentObject(noise).environmentObject(hub)
            .onAppear { monitor.onConnect = { hub.connectionDetected() }; hub.connectionDetected() }
        }
    }
}

struct ConnectPopup: View {
    let name: String
    @State private var pulse = false
    @EnvironmentObject var hub: EarbudHub
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "earbuds").font(.largeTitle).scaleEffect(pulse ? 1.12 : 0.95)
                .onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever()) { pulse = true } }
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.headline)
                Text("Connected").font(.subheadline).foregroundStyle(.green)
                Text(hub.batterySummary).font(.caption).foregroundStyle(.secondary)
                if let mode = hub.noise.mode {
                    Text(mode.activeLabel).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding().background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28))
        .padding(.horizontal).padding(.top, 8)
    }
}

struct DashboardView: View {
    @EnvironmentObject var hub: EarbudHub
    @EnvironmentObject var monitor: ConnectionMonitor

    private func panel<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
        .budsCard()
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    VStack(spacing: 6) {
                        Text(monitor.status == .connected ? "🟢 Connected" : "⚪️ Disconnected").font(.headline)
                        Text(monitor.deviceName ?? "No earbuds detected").font(.title2.bold())
                        if let r = hub.ble.rssi { Text("Signal \(r) dBm").foregroundStyle(.secondary) }
                    }
                    .frame(maxWidth: .infinity).padding()
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))

                    ControlStatusPanel(hub: hub).budsCard()
                    panel("Battery") { BatteryPanel(hub: hub) }
                    panel("Noise Control") { NoisePanel(hub: hub) }
                    panel("Device") { DevicePanel(hub: hub) }

                    Text("Last seen: \(hub.ble.lastSeen?.formatted(date: .omitted, time: .shortened) ?? "never"). Not Apple's Find My network.")
                        .font(.footnote).foregroundStyle(.secondary)
                }.padding()
            }.navigationTitle("BudsLink")
                .onAppear { hub.screenAppeared() }
                .onDisappear { hub.screenDisappeared() }
        }
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

/// Legacy view, no longer shown (FeatureComparisonView replaced it). Kept compiling so nothing that referenced it breaks.
struct CompatibilityView: View {
    var body: some View {
        NavigationStack {
            ScrollView { VStack(spacing: 10) { ForEach(CapabilityRegistry.all) { CapabilityRow(cap: $0) } }.padding() }
                .navigationTitle("Feature Comparison")
        }
    }
}
