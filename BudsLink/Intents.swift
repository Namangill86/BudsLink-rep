import AppIntents

struct ShowBatteryIntent: AppIntent {
    static var title: LocalizedStringResource = "Show earbuds battery"
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let pct = UserDefaults.standard.object(forKey: "lastBattery") as? Int
        return .result(dialog: pct.map { "Your earbuds are at \($0) percent." } ??
                       "Battery isn't reported by these earbuds over Bluetooth.")
    }
}

struct SetAudioProfileIntent: AppIntent {
    static var title: LocalizedStringResource = "Activate BudsLink audio profile"
    @Parameter(title: "Profile") var profile: String
    func perform() async throws -> some IntentResult & ProvidesDialog {
        UserDefaults.standard.set(profile, forKey: "pendingProfile")
        return .result(dialog: "\(profile) profile will apply to BudsLink playback.")
    }
}

/// Honest stub: Siri can run it, but it explains the limitation.
struct SetANCIntent: AppIntent {
    static var title: LocalizedStringResource = "Turn on ANC"
    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: "ANC control isn't available through iOS's Bluetooth interfaces for these earbuds.")
    }
}

struct BudsLinkShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ShowBatteryIntent(), phrases: ["Show my earbuds battery in \(.applicationName)"],
                    shortTitle: "Battery", systemImageName: "battery.100")
        AppShortcut(intent: SetANCIntent(), phrases: ["Turn on ANC in \(.applicationName)"],
                    shortTitle: "ANC", systemImageName: "ear")
    }
}
