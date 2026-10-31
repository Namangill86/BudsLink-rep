import SwiftUI

/// Every row is driven by data the earbuds actually returned. When something isn't available the screen says
/// exactly why (no BLE link, service missing, no reply, reply not understood) instead of a generic "not supported".
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
                } footer: {
                    Text("Lists every service the earbuds expose plus an event log. Review it before sharing.")
                }
            }
            .navigationTitle("Earbuds")
            .onAppear { hub.screenAppeared() }
            .onDisappear { hub.screenDisappeared() }
        }
    }

    // MARK: Connection (three separate facts)

    private var canRetry: Bool {
        if hub.controlReady { return false }
        switch hub.ble.connection {
        case .bluetoothOff, .unauthorized, .unsupported: return false
        default: return true
        }
    }

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
            LabeledContent("Audio", value: hub.audioDescription)
            LabeledContent("Bluetooth LE link", value: hub.bleLinkDescription)
            LabeledContent("BLE control", value: hub.controlDescription)

            if hub.isConnected, let reason = hub.controlDiagnosis {
                Text(reason).font(.footnote).foregroundStyle(.secondary)
            }
            if !hub.bleLinked, !hub.ble.candidates.isEmpty {
                ForEach(hub.ble.candidates) { c in
                    Button("Use \(c.name) for battery and controls") { hub.ble.select(c) }
                }
            }
            if canRetry {
                Button("Retry") { hub.retryControl() }
            }
            if !hub.bleLinked {
                Button("Search for earbuds again") { hub.ble.rescan() }
            }
            if let message = hub.ble.errorMessage {
                Text(message).font(.footnote).foregroundStyle(.orange)
            }
        } header: {
            Text("Connection")
        }
    }

    // MARK: Battery

    @ViewBuilder private var standardBatteryRows: some View {
        if hub.ble.batteryAvailability == .supported {
            ForEach(hub.ble.batteries) { b in
                LabeledContent(b.role.title) {
                    HStack(spacing: 4) {
                        if b.charging == true { Image(systemName: "bolt.fill").foregroundStyle(.green) }
                        Text(b.percent.map { "\($0)%" } ?? "…")
                    }
                }
            }
        }
    }

    private func controlBatteryRow(_ title: String, _ value: OPOBatteryMonitor.Value?) -> some View {
        LabeledContent(title) {
            HStack(spacing: 4) {
                if value?.charging == true { Image(systemName: "bolt.fill").foregroundStyle(.green) }
                Text(value.map { "\($0.percent)%" } ?? "Not available")
            }
        }
    }

    @ViewBuilder private var batterySection: some View {
        Section("Battery") {
            switch hub.battery.status {
            case .ready:
                controlBatteryRow("Left Earbud", hub.battery.left)
                controlBatteryRow("Right Earbud", hub.battery.right)
                controlBatteryRow("Charging Case", hub.battery.caseValue)
                Text("Read from the earbuds' control channel. The reply layout for this model is community-documented and not yet confirmed on your unit, so compare these once with HeyMelody.")
                    .font(.footnote).foregroundStyle(.secondary)
            case .idle, .loading:
                Label("Loading…", systemImage: "hourglass").foregroundStyle(.secondary)
            case .failed(let message):
                Text(message).foregroundStyle(.orange)
                standardBatteryRows
            case .unavailable(let reason):
                if hub.ble.batteryAvailability == .supported {
                    standardBatteryRows
                } else {
                    Text("Not available").foregroundStyle(.secondary)
                    Text(reason).font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Noise control

    private var isChangingNoise: Bool {
        if case .changing = hub.noise.status { return true }
        return false
    }

    @ViewBuilder private var noiseControls: some View {
        Picker("Mode", selection: Binding<OPONoiseMode?>(
            get: { hub.noise.mode },
            set: { if let mode = $0 { hub.noise.set(mode) } }
        )) {
            ForEach(OPONoiseMode.allCases) { mode in Text(mode.shortLabel).tag(Optional(mode)) }
        }
        .pickerStyle(.segmented)
        .disabled(isChangingNoise)

        if case .changing(let target) = hub.noise.status {
            Label("Changing to \(target.shortLabel)…", systemImage: "hourglass").foregroundStyle(.secondary)
        } else if let mode = hub.noise.mode {
            Text(mode.activeLabel)
        } else {
            Text("The earbuds haven't reported their current mode.").foregroundStyle(.secondary)
        }
        if case .failed(let message) = hub.noise.status {
            Text(message).foregroundStyle(.orange)
        }
        Text("ANC levels (Mild, Moderate, Max, Smart) are not offered: no verified command values exist for this model, so none are sent.")
            .font(.footnote).foregroundStyle(.secondary)
    }

    @ViewBuilder private var noiseSection: some View {
        Section("Noise Control") {
            switch hub.noise.status {
            case .unavailable(let reason):
                Text("Noise control is unavailable.").foregroundStyle(.secondary)
                Text(reason).font(.footnote).foregroundStyle(.secondary)
            case .idle, .reading:
                Label("Reading current mode…", systemImage: "hourglass").foregroundStyle(.secondary)
            case .ready, .changing, .failed:
                noiseControls
            }
        }
    }

    // MARK: Device information

    @ViewBuilder private var deviceSection: some View {
        Section("Device") {
            if let name = hub.bleDeviceName { LabeledContent("Name", value: name) }

            switch hub.info.status {
            case .ready:
                if let firmware = hub.info.firmware {
                    LabeledContent("Firmware", value: firmware)
                } else {
                    Text("The earbuds replied, but no firmware version was recognised in the reply.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(hub.info.strings, id: \.self) { text in
                    LabeledContent("Reply text", value: text)
                }
            case .idle, .loading:
                Label("Reading firmware…", systemImage: "hourglass").foregroundStyle(.secondary)
            case .failed(let message):
                Text(message).font(.footnote).foregroundStyle(.secondary)
            case .unavailable:
                EmptyView()
            }

            ForEach(BLEEarbudSession.infoOrder, id: \.self) { label in
                if let value = hub.ble.deviceInfo[label] { LabeledContent(label, value: value) }
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
