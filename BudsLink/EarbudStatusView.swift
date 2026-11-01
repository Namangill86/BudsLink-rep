import SwiftUI

/// The Earbuds tab. It renders the same panels as the Buds tab, so the two can never disagree.
struct EarbudStatusView: View {
    @ObservedObject var hub: EarbudHub

    var body: some View {
        NavigationStack {
            List {
                Section("Connection") { ControlStatusPanel(hub: hub) }
                Section("Battery") { BatteryPanel(hub: hub) }
                Section("Noise Control") { NoisePanel(hub: hub) }
                Section("Device") { DevicePanel(hub: hub) }
                Section {
                    NavigationLink("Bluetooth Report") { BluetoothReportView(hub: hub) }
                } footer: {
                    Text("Every service and characteristic the earbuds expose, which control steps succeeded, and an event log. Review it before sharing.")
                }
            }
            .navigationTitle("Earbuds")
            .onAppear { hub.screenAppeared() }
            .onDisappear { hub.screenDisappeared() }
        }
    }
}

/// Live diagnostic screen: updates while a diagnostic run is in progress.
struct BluetoothReportView: View {
    @ObservedObject var hub: EarbudHub

    var body: some View {
        ScrollView {
            Text(hub.reportText)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle("Bluetooth Report")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Run diagnostic") { hub.runDiagnostic() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: hub.reportText)
            }
        }
    }
}
