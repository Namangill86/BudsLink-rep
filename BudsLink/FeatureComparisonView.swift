import SwiftUI

/// Features tab. Rows that depend on the earbuds' vendor BLE channel show two separate statements:
///   - iOS limitation: what Apple's public APIs provide
///   - BudsLink capability: what BudsLink can do over CoreBluetooth and the vendor protocol, and its state right now
/// "iOS has no standard API" is never used as a reason a feature cannot work. All other rows come unchanged from
/// the existing CapabilityRegistry.
struct FeatureComparisonView: View {
    @EnvironmentObject var hub: EarbudHub

    /// Registry rows about battery / noise control are replaced by the live rows below (their text was the misleading part).
    private static func isReplaced(_ title: String) -> Bool {
        let t = title.lowercased()
        if t.contains("battery") || t.contains("noise") || t.contains("transparen") || t.contains("ambient") { return true }
        return t.split(separator: " ").contains { $0 == "anc" }
    }

    private var legacyRows: [Capability] {
        CapabilityRegistry.all.filter { !Self.isReplaced($0.title) }
    }

    private var stateNow: String {
        if hub.controlReady { return "BLE control is ready." }
        var text = "BLE control: " + hub.controlDescription + "."
        if let reason = hub.controlDiagnosis { text += " " + reason }
        return text
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    SplitFeatureRow(
                        title: "Left / right / case battery",
                        ios: "Apple's public APIs give apps no battery data for Classic Bluetooth earbuds. The standard BLE Battery Service is optional.",
                        budslink: "Supported when the earbuds' proprietary BLE control session is available. The values are read from the earbuds over the OPO protocol.",
                        now: hub.batterySummary + ". " + stateNow)
                    SplitFeatureRow(
                        title: "Noise control (ANC / Transparency / Off)",
                        ios: "No public Apple API controls noise modes on third-party earbuds.",
                        budslink: "Supported for compatible OnePlus earbuds when vendor BLE control is available. Every change is confirmed by reading the mode back from the earbuds before the screen updates.",
                        now: (hub.noise.mode.map { "The earbuds report " + $0.shortLabel + ". " } ?? "") + stateNow)
                    SplitFeatureRow(
                        title: "ANC levels (Mild / Moderate / Max / Smart)",
                        ios: "No public Apple API.",
                        budslink: "Not offered yet: the command values for these levels are not verified for this model, and BudsLink does not send unverified commands to your earbuds.",
                        now: "Capturing them needs the Bluetooth Report from a real session.")
                    SplitFeatureRow(
                        title: "Device and firmware information",
                        ios: "Apple's public APIs only expose the standard Device Information service, and only if the earbuds offer it.",
                        budslink: "Read from the earbuds' vendor protocol when available, with the standard service as a fallback.",
                        now: stateNow)

                    ForEach(legacyRows) { CapabilityRow(cap: $0) }
                }
                .padding()
            }
            .navigationTitle("Feature Comparison")
        }
    }
}

private struct SplitFeatureRow: View {
    let title: String
    let ios: String
    let budslink: String
    let now: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).bold()
            VStack(alignment: .leading, spacing: 2) {
                Text("iOS limitation").font(.caption.bold()).foregroundStyle(.secondary)
                Text(ios).font(.footnote)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("BudsLink capability").font(.caption.bold()).foregroundStyle(.secondary)
                Text(budslink).font(.footnote)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Right now").font(.caption.bold()).foregroundStyle(.secondary)
                Text(now).font(.footnote)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}
