import Foundation

/// Single source of truth for what BudsLink can honestly do.
enum Tier: String {
    case hardware = "Earbud hardware"          // controlled on the buds
    case software = "App software"             // done inside BudsLink only
    case limited = "Limited by iOS"
    case appleOnly = "Apple-exclusive"
    case unavailable = "Not exposed to iOS apps"
}

struct Capability: Identifiable {
    let id: String
    let title: String
    let tier: Tier
    let note: String
    var isUsable: Bool { tier == .software || tier == .hardware }
}

enum CapabilityRegistry {
    static let all: [Capability] = [
        .init(id: "anc", title: "ANC / Transparency", tier: .unavailable,
              note: "Controlled via OnePlus's proprietary protocol, not a public Bluetooth interface. Use the buds' touch controls or HeyMelody on Android."),
        .init(id: "battery", title: "Earbud battery", tier: .limited,
              note: "Shown only if the buds expose the standard BLE Battery Service. Case battery is not exposed."),
        .init(id: "touch", title: "Touch-control mapping", tier: .unavailable,
              note: "Stored on the earbuds via the proprietary protocol."),
        .init(id: "eq", title: "Equalizer", tier: .software,
              note: "Applies to audio played inside BudsLink only, not system-wide."),
        .init(id: "immersive", title: "Immersive Audio", tier: .software,
              note: "Software-based. Not Apple Personalized Spatial Audio."),
        .init(id: "headtrack", title: "Head tracking", tier: .limited,
              note: "Uses the iPhone's motion sensors, not the earbuds (no supported earbud sensor feed)."),
        .init(id: "find", title: "Find earbuds", tier: .limited,
              note: "Last-seen time/place and Bluetooth signal strength. Not Apple's Find My network."),
        .init(id: "sidebattery", title: "Left / right / case battery", tier: .unavailable,
              note: "Sent over OnePlus's private protocol. iOS does not pass Classic Bluetooth battery data to apps."),
        .init(id: "livelisten", title: "Live Listen", tier: .software,
              note: "iPhone mic played into your earbuds from inside BudsLink. Not Apple's Live Listen."),
        .init(id: "caseopen", title: "Case-open pop-up", tier: .appleOnly,
              note: "Needs Apple's private advertising. BudsLink shows a pop-up when the buds connect while the app is open."),
        .init(id: "findmy", title: "Find My network", tier: .appleOnly, note: "Requires Apple hardware."),
        .init(id: "autoswitch", title: "Automatic device switching", tier: .appleOnly, note: "Apple H/W-series chips only."),
        .init(id: "translate", title: "Translation assistant", tier: .software,
              note: "In-app alternative; not AirPods Live Translation."),
        .init(id: "camera", title: "Camera remote", tier: .software,
              note: "Works inside BudsLink's camera. Cannot control the native Camera app."),
    ]
    static func get(_ id: String) -> Capability { all.first { $0.id == id }! }
}
