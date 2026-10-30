import SwiftUI

/// Native-style status screen. Every row is driven by real data; when the device does not
/// expose something the screen says so instead of showing a placeholder value.
struct EarbudStatusView: View {
    @ObservedObject var hub: EarbudHub

    var body: some View {
        NavigationStack {
            List {
                connectionSection
                batterySection
                noiseSection
                deviceSection
                Section {
                    NavigationLink("Bluetooth Report") { BluetoothReportView(text: hub.reportText) }
                }
            }
            .navigationTitle("Earbuds")
            .onAppear { hub.start() }
        }
    }

    // MARK: Connection

    private var connectionSection: some View {
        Section {
            HStack(spacing: 12) {
                Circle()
                    .fill(hub.isConnected ? Color.green : Color.secondary)
                    .frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(hub.isConnected ? "Connected" : "Disconnected").font(.headline)
                    if let name = hub.displayName {
                        Text(name).foregroundStyle(.secondary)
                    } else if !hub.isConnected {
                        Text("No earbuds detected").foregroundStyle(.secondary)
                    }
                }
            }
            LabeledContent("Audio output", value: hub.routeDescription)
            LabeledContent("Bluetooth LE", value: hub.bleDescription)

            if !hub.bleConnected, !hub.ble.candidates.isEmpty {
                ForEach(hub.ble.candidates) { c in
                    Button("Use \(c.name) for battery and controls") { hub.ble.select(c) }
                }
            }
            if !hub.bleConnected {
                Button("Search for earbuds again") { hub.ble.rescan() }
            }
            if let message = hub.ble.errorMessage {
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Battery

    @ViewBuilder private var batterySection: some View {
        Section("Battery") {
            switch hub.ble.batteryAvailability {
            case .checking:
                if hub.bleConnected {
                    Label("Reading…", systemImage: "hourglass").foregroundStyle(.secondary)
                } else if hub.isConnected {
                    Text("Waiting for a Bluetooth LE link to the earbuds.").foregroundStyle(.secondary)
                } else {
                    Text("Connect your earbuds to read battery.").foregroundStyle(.secondary)
                }
            case .notExposed:
                Text("Battery information is not exposed by this device.").foregroundStyle(.secondary)
            case .failed(let message):
                Text("Couldn't read battery: \(message)").foregroundStyle(.secondary)
            case .supported:
                ForEach(hub.ble.batteries) { b in
                    LabeledContent(b.role.title) {
                        HStack(spacing: 4) {
                            if b.charging == true { Image(systemName: "bolt.fill").foregroundStyle(.green) }
                            Text(b.percent.map { "\($0)%" } ?? "…")
                        }
                    }
                }
                if hub.ble.batteries.contains(where: { $0.role == .combined }) {
                    Text("These earbuds report a single battery value.").font(.footnote).foregroundStyle(.secondary)
                }
                if hub.ble.batteries.contains(where: { $0.role == .unlabeled }) {
                    Text("The device doesn't say which battery is which, so they are not labeled left, right, or case.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Noise control

    @ViewBuilder private var noiseSection: some View {
        Section("Noise Control") {
            switch hub.ble.noiseAvailability {
            case .checking:
                Text(hub.bleConnected ? "Checking…" : "Connect your earbuds to check.")
                    .foregroundStyle(.secondary)
            case .notExposed:
                Text("Noise Control is not exposed by this device.").foregroundStyle(.secondary)
            case .failed(let message):
                Text("Couldn't check noise control: \(message)").foregroundStyle(.secondary)
            case .supported:
                Picker("Mode", selection: Binding<EarbudNoiseMode?>(
                    get: { hub.ble.currentNoiseMode },
                    set: { if let mode = $0 { hub.ble.setNoiseMode(mode) } }
                )) {
                    ForEach(hub.ble.noiseModes) { mode in Text(mode.rawValue).tag(Optional(mode)) }
                }
                .pickerStyle(.segmented)
                if let mode = hub.ble.currentNoiseMode {
                    Text(mode.activeLabel)
                } else {
                    Text("The earbuds haven't reported their current mode.").foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Device information

    @ViewBuilder private var deviceSection: some View {
        Section("Device") {
            ForEach(BLEEarbudSession.infoOrder, id: \.self) { label in
                if let value = hub.ble.deviceInfo[label] { LabeledContent(label, value: value) }
            }
            if hub.ble.discoveryComplete, hub.ble.deviceInfo.isEmpty {
                Text("Firmware and model are not exposed by this device.").foregroundStyle(.secondary)
            }
            if let rssi = hub.ble.rssi { LabeledContent("Signal", value: "\(rssi) dBm") }
            if let seen = hub.ble.lastSeen {
                LabeledContent("Last seen", value: seen.formatted(.relative(presentation: .named)))
            }
        }
    }
}

struct BluetoothReportView: View {
    let text: String

    var body: some View {
        ScrollView {
            Text(text)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle("Bluetooth Report")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ShareLink(item: text) }
    }
}
