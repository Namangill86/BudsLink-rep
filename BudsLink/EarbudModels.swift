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
