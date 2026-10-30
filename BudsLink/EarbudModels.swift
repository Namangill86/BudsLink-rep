import CoreBluetooth

// MARK: - Battery

enum BatteryRole: Int, Comparable {
    case left, right, chargingCase, combined, unlabeled

    var title: String {
        switch self {
        case .left:         return "Left Earbud"
        case .right:        return "Right Earbud"
        case .chargingCase: return "Charging Case"
        case .combined:     return "Earbuds"
        case .unlabeled:    return "Battery (unlabeled)"
        }
    }

    static func < (a: BatteryRole, b: BatteryRole) -> Bool { a.rawValue < b.rawValue }
}

struct BatteryReading: Identifiable, Equatable {
    let id: ObjectIdentifier
    var role: BatteryRole
    /// nil until a value has really been read from the device. Never defaulted or invented.
    var percent: Int?
    /// nil unless the device reports Battery Power State (0x2A1A) for this battery.
    var charging: Bool?
}

// MARK: - Feature availability

enum FeatureAvailability: Equatable {
    case checking            // discovery has not finished yet
    case supported           // the device really exposes it
    case notExposed          // discovery finished and the device does not expose it
    case failed(String)      // discovery itself failed, so we can't say either way
}

// MARK: - Noise control

enum NoiseMode: String, CaseIterable, Identifiable {
    case noiseCancellation = "Noise Cancellation"
    case off = "Off"
    case transparency = "Transparency"

    var id: String { rawValue }

    var activeLabel: String {
        switch self {
        case .noiseCancellation: return "Noise Cancellation Active"
        case .transparency:      return "Transparency Active"
        case .off:               return "Noise Control Off"
        }
    }
}

/// A vendor-specific, *documented* BLE noise-control interface.
///
/// There is no Bluetooth SIG standard for ANC / Transparency, and iOS has no public API for it,
/// so every implementation is specific to one manufacturer's GATT layout. Add a conformance only
/// when you have the vendor's documentation, or have confirmed the service/characteristic UUIDs
/// in the app's Bluetooth Report on the real earbuds. Do NOT guess UUIDs.
protocol NoiseControlProvider: AnyObject {
    /// True only when the discovered GATT layout is exactly the interface this provider implements.
    static func matches(services: [CBService]) -> Bool
    init(peripheral: CBPeripheral, services: [CBService])

    var supportedModes: [NoiseMode] { get }
    /// Called with the mode the DEVICE reports (read-back or notification), never with an assumed one.
    var onModeChange: ((NoiseMode?) -> Void)? { get set }

    /// Subscribe and/or read the current state.
    func start()
    /// Write the requested mode. The UI only changes when the device reports the new mode back.
    func set(_ mode: NoiseMode)
    /// Offer every characteristic update; return true if it was consumed.
    func handle(update characteristic: CBCharacteristic) -> Bool
}

enum NoiseControlRegistry {
    /// Intentionally empty: no vendor interface is registered, so the app will truthfully report
    /// "Noise Control is not exposed by this device." Register real providers here.
    static func providers() -> [any NoiseControlProvider.Type] { [] }
}

// MARK: - GATT report types

struct GATTCharacteristicInfo: Identifiable {
    let id: String
    let uuid: String
    let name: String?
    let properties: [String]
}

struct GATTServiceInfo: Identifiable {
    let id: String
    let uuid: String
    let name: String?
    let characteristics: [GATTCharacteristicInfo]
}

enum GATTNames {
    static let services: [String: String] = [
        "1800": "Generic Access", "1801": "Generic Attribute",
        "180A": "Device Information", "180F": "Battery"
    ]
    static let characteristics: [String: String] = [
        "2A00": "Device Name", "2A01": "Appearance",
        "2A19": "Battery Level", "2A1A": "Battery Power State",
        "2A24": "Model Number", "2A25": "Serial Number", "2A26": "Firmware Revision",
        "2A27": "Hardware Revision", "2A28": "Software Revision", "2A29": "Manufacturer Name"
    ]

    static func properties(of c: CBCharacteristic) -> [String] {
        let p = c.properties
        var out: [String] = []
        if p.contains(.read) { out.append("read") }
        if p.contains(.write) { out.append("write") }
        if p.contains(.writeWithoutResponse) { out.append("writeNoResp") }
        if p.contains(.notify) { out.append("notify") }
        if p.contains(.indicate) { out.append("indicate") }
        return out
    }
}
