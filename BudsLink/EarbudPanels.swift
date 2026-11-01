import SwiftUI

// Shared building blocks. The Buds tab wraps them in cards, the Earbuds tab wraps them in List sections, so both
// always show the same facts. Every value comes from data the earbuds returned; when something is unavailable the
// panel says exactly which step is missing instead of a generic "not supported".

extension View {
    /// The Buds tab's existing card look.
    func budsCard() -> some View {
        self.padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
    }
}

private struct FactRow: View {
    let title: String
    let value: String
    var busy = false
    var body: some View {
        HStack {
            Text(title)
            Spacer()
            if busy { ProgressView().controlSize(.small) }
            Text(value).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        }
    }
}

// MARK: - Connection + control checklist

struct ChecklistView: View {
    let checklist: BLEChecklist
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(checklist.lines) { line in
                HStack {
                    Text(line.title).font(.footnote)
                    Spacer()
                    Text(line.value).font(.footnote.monospaced()).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct ControlStatusPanel: View {
    @ObservedObject var hub: EarbudHub

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Circle()
                    .fill(hub.isConnected ? Color.green : Color.secondary)
                    .frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(hub.isConnected ? "Connected" : "Disconnected").font(.headline)
                    if let name = hub.displayName {
                        Text(name).foregroundStyle(.secondary)
                    } else {
                        Text("Earbuds unavailable").foregroundStyle(.secondary)
                    }
                }
            }

            // Three separate facts. Audio working says nothing about the other two.
            FactRow(title: "Audio", value: hub.audioDescription)
            FactRow(title: "Bluetooth LE", value: hub.bleLinkDescription)
            FactRow(title: "BLE Control", value: hub.controlDescription, busy: hub.ble.control.isBusy)

            if let reason = hub.controlDiagnosis {
                Text(reason).font(.footnote).foregroundStyle(.secondary)
            }

            if !hub.controlReady && hub.isConnected {
                DisclosureGroup("Control checklist") {
                    ChecklistView(checklist: hub.ble.checklist).padding(.top, 4)
                }
                .font(.subheadline)
            }

            HStack(spacing: 10) {
                if hub.canRetry {
                    Button("Retry") { hub.retryControl() }.buttonStyle(.bordered)
                }
                Button("Run BLE diagnostic") { hub.runDiagnostic() }.buttonStyle(.bordered)
            }

            if !hub.bleLinked, !hub.ble.candidates.isEmpty {
                ForEach(hub.ble.candidates) { c in
                    Button("Use \(c.name) for control") { hub.ble.select(c) }.buttonStyle(.bordered)
                }
            }
            if let message = hub.ble.errorMessage {
                Text(message).font(.footnote).foregroundStyle(.orange)
            }
        }
    }
}

// MARK: - Battery

struct BatteryPanel: View {
    @ObservedObject var hub: EarbudHub

    private func row(_ title: String, _ value: OPOBatteryMonitor.Value?) -> some View {
        HStack {
            Text(title)
            Spacer()
            if value?.charging == true { Image(systemName: "bolt.fill").foregroundStyle(.green) }
            Text(value.map { "\($0.percent)%" } ?? "Not available").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var standardRows: some View {
        if hub.ble.batteryAvailability == .supported {
            ForEach(hub.ble.batteries) { b in
                HStack {
                    Text(b.role.title)
                    Spacer()
                    if b.charging == true { Image(systemName: "bolt.fill").foregroundStyle(.green) }
                    Text(b.percent.map { "\($0)%" } ?? "…").foregroundStyle(.secondary)
                }
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch hub.battery.status {
            case .ready:
                row("Left", hub.battery.left)
                row("Right", hub.battery.right)
                row("Case", hub.battery.caseValue)
                Text("Read from the earbuds over their control channel. The reply layout for this model is community-documented and not yet confirmed on your unit, so compare these once with HeyMelody.")
                    .font(.footnote).foregroundStyle(.secondary)
            case .idle, .loading:
                Label("Loading…", systemImage: "hourglass").foregroundStyle(.secondary)
            case .failed(let message):
                Text("BLE communication failed").foregroundStyle(.orange)
                Text(message).font(.footnote).foregroundStyle(.secondary)
                standardRows
            case .unavailable(let reason):
                // Standard Battery Service is the fallback; otherwise say exactly what is missing.
                if hub.ble.batteryAvailability == .supported {
                    standardRows
                } else {
                    Text("Not available yet").foregroundStyle(.secondary)
                    Text(reason).font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Noise control

struct NoisePanel: View {
    @ObservedObject var hub: EarbudHub

    private var isChanging: Bool {
        if case .changing = hub.noise.status { return true }
        return false
    }

    @ViewBuilder private var controls: some View {
        Picker("Mode", selection: Binding<OPONoiseMode?>(
            get: { hub.noise.mode },
            set: { if let mode = $0 { hub.noise.set(mode) } }
        )) {
            ForEach(OPONoiseMode.allCases) { mode in Text(mode.shortLabel).tag(Optional(mode)) }
        }
        .pickerStyle(.segmented)
        .disabled(isChanging)

        if case .changing(let target) = hub.noise.status {
            Label("Changing to \(target.shortLabel)…", systemImage: "hourglass").foregroundStyle(.secondary)
        } else if let mode = hub.noise.mode {
            Text(mode.activeLabel)
        } else {
            Text("The earbuds haven't reported their current mode.").foregroundStyle(.secondary)
        }
        if case .failed(let message) = hub.noise.status {
            Text(message).font(.footnote).foregroundStyle(.orange)
        }
        Text("ANC levels (Mild, Moderate, Max, Smart) are not offered: no verified command values exist for this model, so none are sent.")
            .font(.footnote).foregroundStyle(.secondary)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch hub.noise.status {
            case .unavailable(let reason):
                Text("Waiting for BLE control").foregroundStyle(.secondary)
                Text(reason).font(.footnote).foregroundStyle(.secondary)
            case .idle, .reading:
                Label("Reading current mode…", systemImage: "hourglass").foregroundStyle(.secondary)
            case .ready, .changing, .failed:
                controls
            }
        }
    }
}

// MARK: - Device information

struct DevicePanel: View {
    @ObservedObject var hub: EarbudHub

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if hub.bleLinked, let name = hub.ble.peripheralName {
                FactRow(title: "Name", value: name)
            }
            switch hub.info.status {
            case .ready:
                if let firmware = hub.info.firmware {
                    FactRow(title: "Firmware", value: firmware)
                } else {
                    Text("The earbuds replied, but no firmware version was recognised in the reply.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(hub.info.strings, id: \.self) { text in
                    FactRow(title: "Reply text", value: text)
                }
            case .idle, .loading:
                Label("Reading firmware…", systemImage: "hourglass").foregroundStyle(.secondary)
            case .failed(let message):
                Text(message).font(.footnote).foregroundStyle(.secondary)
            case .unavailable:
                Text("Firmware: waiting for BLE control").foregroundStyle(.secondary)
            }
            ForEach(BLEEarbudSession.infoOrder, id: \.self) { label in
                if let value = hub.ble.deviceInfo[label] { FactRow(title: label, value: value) }
            }
            if let rssi = hub.ble.rssi { FactRow(title: "Signal", value: "\(rssi) dBm") }
            if let seen = hub.ble.lastSeen {
                FactRow(title: "Last seen", value: seen.formatted(.relative(presentation: .named)))
            }
        }
    }
}
