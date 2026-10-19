import SwiftUI

@main struct BudsLinkApp: App {
    @StateObject private var bt = BluetoothManager()
    @StateObject private var audio = AudioManager()
    var body: some Scene {
        WindowGroup {
            TabView {
                DashboardView().tabItem { Label("Buds", systemImage: "earbuds") }
                EQView().tabItem { Label("EQ", systemImage: "slider.vertical.3") }
                CompatibilityView().tabItem { Label("Features", systemImage: "checklist") }
            }
            .environmentObject(bt).environmentObject(audio)
        }
    }
}

struct DashboardView: View {
    @EnvironmentObject var bt: BluetoothManager
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    VStack(spacing: 6) {
                        Text(bt.state == .connected ? "🟢 Connected" : "⚪️ Not connected").font(.headline)
                        Text("OnePlus Buds 3 Pro").font(.title2.bold())
                        Text(bt.batteryPercent.map { "Battery \($0)%" } ?? "Battery: not reported by earbuds")
                            .font(.largeTitle.weight(.semibold)).minimumScaleFactor(0.6)
                        if let r = bt.rssi { Text("Signal \(r) dBm").foregroundStyle(.secondary) }
                    }
                    .frame(maxWidth: .infinity).padding().background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
                    if let e = bt.errorMessage { Text(e).foregroundStyle(.orange).font(.callout) }
                    Button(bt.state == .connected ? "Disconnect" : "Find my Buds") {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        bt.state == .connected ? bt.disconnect() : bt.startScan()
                    }.buttonStyle(.borderedProminent)
                    CapabilityRow(cap: CapabilityRegistry.get("anc"))
                    Text("Not Apple's Find My network. Last seen: \(bt.lastSeen?.formatted(date: .omitted, time: .shortened) ?? "never")")
                        .font(.footnote).foregroundStyle(.secondary)
                }.padding()
            }.navigationTitle("BudsLink")
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
                .navigationTitle("AirPods Feature Comparison")
        }
    }
}
