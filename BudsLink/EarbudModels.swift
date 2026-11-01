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
        if p.contains(.read) { out.append("Read") }
        if p.contains(.write) { out.append("Write") }
        if p.contains(.writeWithoutResponse) { out.append("Write Without Response") }
        if p.contains(.notify) { out.append("Notify") }
        if p.contains(.indicate) { out.append("Indicate") }
        return out
    }
}

// MARK: - BLE control state machine

/// The ONE state the UI shows for the BLE control channel. Audio (A2DP) is a separate fact and never part of this.
enum BLEControlState: Equatable {
    case bluetoothOff, unauthorized, unsupported
    case idle
    case scanning
    case discovered(String)
    case connecting(String)
    case connected(String)
    case discoveringServices
    case discoveringCharacteristics
    case subscribing
    case authenticating(String)
    case ready
    case unavailable(String)      // earbuds not reachable right now (case closed, out of range, not advertising)
    case failed(String)           // reached the earbuds but a step failed; the string is the exact reason

    var title: String {
        switch self {
        case .bluetoothOff:                return "Bluetooth is off"
        case .unauthorized:                return "Bluetooth permission denied"
        case .unsupported:                 return "Bluetooth LE not supported"
        case .idle:                        return "Idle"
        case .scanning:                    return "Scanning…"
        case .discovered:                  return "Earbuds found"
        case .connecting:                  return "Connecting…"
        case .connected:                   return "Connected (link up)"
        case .discoveringServices:         return "Discovering services…"
        case .discoveringCharacteristics:  return "Discovering characteristics…"
        case .subscribing:                 return "Subscribing to notifications…"
        case .authenticating:              return "Authenticating…"
        case .ready:                       return "Ready"
        case .unavailable:                 return "Earbuds unavailable"
        case .failed:                      return "Failed"
        }
    }

    /// The exact reason, when there is one.
    var reason: String? {
        switch self {
        case .unavailable(let r), .failed(let r): return r
        case .authenticating(let step):           return step
        case .bluetoothOff:                       return "Turn Bluetooth on in Control Center."
        case .unauthorized:                       return "Allow Bluetooth for BudsLink in Settings > BudsLink."
        case .unsupported:                        return "This device does not support Bluetooth LE."
        default:                                  return nil
        }
    }

    /// A step is in progress (a spinner makes sense).
    var isBusy: Bool {
        switch self {
        case .scanning, .discovered, .connecting, .connected, .discoveringServices,
             .discoveringCharacteristics, .subscribing, .authenticating: return true
        default: return false
        }
    }
}

/// Which stage of the control pipeline was reached. nil = not reached yet.
struct BLEChecklist: Equatable {
    var discovered: Bool?
    var connected: Bool?
    var servicesDiscovered: Bool?
    var opoService: Bool?
    var characteristics: Bool?
    var notifications: Bool?
    var handshake: String?           // nil = not reached, "OK", or "FAILED: reason"

    static func label(_ value: Bool?) -> String {
        switch value {
        case .some(true):  return "YES"
        case .some(false): return "NO"
        case .none:        return "—"
        }
    }

    struct Line: Identifiable {
        let title: String
        let value: String
        var id: String { title }
    }

    var lines: [Line] {
        [
            Line(title: "Peripheral discovered", value: Self.label(discovered)),
            Line(title: "Peripheral connected", value: Self.label(connected)),
            Line(title: "Services discovered", value: Self.label(servicesDiscovered)),
            Line(title: "OPO service discovered", value: Self.label(opoService)),
            Line(title: "Characteristics discovered", value: Self.label(characteristics)),
            Line(title: "Notifications enabled", value: Self.label(notifications)),
            Line(title: "Handshake", value: handshake ?? "—")
        ]
    }
}
