import SwiftUI

enum NoiseMode: String, CaseIterable {
    case off = "Off", anc = "ANC", transparency = "Transparency"
    var icon: String { self == .transparency ? "👂" : "🔇" }
}

/// A driver speaks the earbuds' REAL control channel. Add one only after its protocol is verified.
protocol NoiseControlDriver {
    var supportedModes: [NoiseMode] { get }
    func setMode(_ m: NoiseMode) async throws
    func readMode() async throws -> NoiseMode
}

enum DriverRegistry {
    /// No verified drivers ship yet, so no device is reported as supported (never guess commands).
    static func driver(forServices services: [String]) -> NoiseControlDriver? { nil }
}

@MainActor final class NoiseControlManager: ObservableObject {
    @Published var mode: NoiseMode?
    @Published var switching: NoiseMode?
    @Published var error: String?
    private var driver: NoiseControlDriver?

    var isSupported: Bool { driver != nil }
    var supportedModes: [NoiseMode] { driver?.supportedModes ?? [] }

    func detect(gatt: [String]) {
        driver = DriverRegistry.driver(forServices: gatt.filter { $0.hasPrefix("Service") })
        if let d = driver { Task { mode = try? await d.readMode() } } else { mode = nil }
    }

    /// The UI changes only after the earbuds confirm the new mode.
    func set(_ m: NoiseMode) async {
        guard let d = driver else { return }
        switching = m; error = nil
        do { try await d.setMode(m); mode = try await d.readMode() }
        catch { self.error = "The earbuds didn't confirm the change." }
        switching = nil
    }
}

struct NoiseControlCard: View {
    @EnvironmentObject var noise: NoiseControlManager
    @EnvironmentObject var bt: BluetoothManager
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Noise Control").font(.headline)
            if noise.isSupported {
                HStack {
                    ForEach(noise.supportedModes, id: \.self) { m in
                        Button { Task { await noise.set(m) } } label: {
                            Text("\(m.icon) \(m.rawValue)").font(.footnote).frame(maxWidth: .infinity).padding(8)
                                .background(noise.mode == m ? Color.accentColor : Color.secondary.opacity(0.2), in: Capsule())
                                .foregroundStyle(noise.mode == m ? Color.white : Color.primary)
                        }.disabled(noise.switching != nil)
                    }
                }.animation(.easeInOut, value: noise.mode)
                if noise.switching != nil { ProgressView() }
                if let e = noise.error { Text(e).font(.footnote).foregroundStyle(.orange) }
            } else {
                Text("Not supported by this device").foregroundStyle(.secondary)
                Text("No verified noise-control channel is available to iOS apps for these earbuds. Use the buds' touch control (about 1-second press) to switch modes.")
                    .font(.footnote).foregroundStyle(.secondary)
                DisclosureGroup("Bluetooth report (read-only)") {
                    let text = bt.gattDump.isEmpty ? "No BLE data yet. Connect the buds, then tap Scan." : bt.gattDump.joined(separator: "\n")
                    Text(text).font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                    ShareLink(item: text)
                }
            }
        }.padding().background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
    }
}
