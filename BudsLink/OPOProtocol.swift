import CoreBluetooth
import Foundation

// MARK: - What this file is, and what it is NOT
//
// The OPO ("OPOv1") protocol is the vendor protocol the OnePlus / OPPO / realme companion app uses.
// It is NOT published by the manufacturer. Everything below comes from community reverse engineering of
// the OnePlus Nord Buds 3 Pro over BLE GATT (a CoreBluetooth write-up and CLI), cross-checked against
// other OPOv1 projects. That means:
//   - Framing, the HELLO/REGISTER/ANC packets and the ANC mode bytes are documented for this model.
//   - The REGISTER token is device-specific in that write-up. Whether YOUR unit accepts it is unverified.
//   - The battery and device-info reply LAYOUTS are not confirmed. They are decoded defensively and the
//     raw bytes are always logged, so a wrong guess shows up as "could not be decoded", never as a fake value.
//   - ANC intensity levels (Mild / Moderate / Max / Smart): no verified command bytes exist for this model,
//     so none are sent.

// MARK: - UUIDs

enum OPO {
    static let service = CBUUID(string: "0000079A-D102-11E1-9B23-00025B00A5A5")
    static let writeCharacteristic = CBUUID(string: "0100079A-D102-11E1-9B23-00025B00A5A5")
    static let notifyCharacteristic = CBUUID(string: "0200079A-D102-11E1-9B23-00025B00A5A5")

    /// The vendor "telemetry / firmware" service. Replies can arrive on its notify characteristics, so we
    /// SUBSCRIBE to them. We never WRITE to it (it also carries firmware-update traffic).
    static func isTelemetryService(_ uuid: CBUUID) -> Bool {
        uuid.uuidString.uppercased().hasPrefix("FE2C")
    }
}

enum OPOCredentials {
    /// REGISTER token published for a Nord Buds 3 Pro. Unverified for other units. Never logged.
    static let registerToken: [UInt8] = [0xB5, 0x50, 0xA0, 0x69]
}

// MARK: - Noise modes

enum OPONoiseMode: String, CaseIterable, Identifiable {
    case noiseCancellation, transparency, off

    var id: String { rawValue }

    var shortLabel: String {
        switch self {
        case .noiseCancellation: return "ANC"
        case .transparency:      return "Transparency"
        case .off:               return "Off"
        }
    }

    var activeLabel: String {
        switch self {
        case .noiseCancellation: return "Noise Cancellation Active"
        case .transparency:      return "Transparency Active"
        case .off:               return "Noise Control Off"
        }
    }
}

// MARK: - Device profile (what is known per model)

struct OPODeviceProfile {
    let id: String
    let namePatterns: [String]           // lowercase substrings of the BLE name
    let ancOn: UInt8
    let transparency: UInt8
    let ancOff: UInt8
    /// Indices into the battery reply BODY (bytes after the 7-byte header). Layout NOT confirmed on hardware.
    let batteryLeft: Int
    let batteryRight: Int
    let batteryCase: Int
    let supportsAncLevels: Bool

    static let nordBuds3Pro = OPODeviceProfile(
        id: "nord-buds-3-pro",
        namePatterns: ["nord buds 3 pro"],
        ancOn: 0x01, transparency: 0x02, ancOff: 0x04,
        batteryLeft: 5, batteryRight: 7, batteryCase: 8,
        supportsAncLevels: false)

    static let all: [OPODeviceProfile] = [nordBuds3Pro]

    /// Identifies the model from the earbuds' own BLE name. Unknown models get no profile, so no command is ever sent.
    static func match(bleName: String?) -> OPODeviceProfile? {
        guard let name = bleName?.lowercased(), !name.isEmpty else { return nil }
        return all.first { profile in profile.namePatterns.contains { name.contains($0) } }
    }

    func byte(for mode: OPONoiseMode) -> UInt8 {
        switch mode {
        case .noiseCancellation: return ancOn
        case .transparency:      return transparency
        case .off:               return ancOff
        }
    }

    func mode(for byte: UInt8) -> OPONoiseMode? {
        if byte == ancOn { return .noiseCancellation }
        if byte == transparency { return .transparency }
        if byte == ancOff { return .off }
        return nil
    }
}

// MARK: - Packets

struct OPOPacket: Equatable {
    let cat: UInt8
    let sub: UInt8
    let seq: UInt8
    let body: [UInt8]

    /// AA | LEN | 00 00 | CAT | SUB | SEQ | BODY...   (LEN = number of bytes after the LEN byte; no checksum)
    var wireBytes: [UInt8] {
        [0xAA, UInt8(truncatingIfNeeded: 5 + body.count), 0x00, 0x00, cat, sub, seq] + body
    }

    /// Header-only description that is safe to show anywhere (no payload).
    var summary: String {
        String(format: "cat=%02X sub=%02X seq=%02X body=%d bytes", cat, sub, seq, body.count)
    }
}

struct OPOInbound {
    let raw: Data
    let packet: OPOPacket?       // nil when the bytes were not a recognisable AA-framed packet
    let source: String           // short label of the characteristic it arrived on
}

enum OPOCommand {
    /// Exact bytes from the write-up. Its length byte says 7 but one extra trailing byte (0x12) follows,
    /// so it is kept verbatim instead of being rebuilt.
    static let hello: [UInt8] = [0xAA, 0x07, 0x00, 0x00, 0x00, 0x01, 0x23, 0x00, 0x00, 0x12]

    static func register(seq: UInt8 = 0x41) -> OPOPacket {
        OPOPacket(cat: 0x00, sub: 0x85, seq: seq, body: [0x05, 0x00, 0x00] + OPOCredentials.registerToken)
    }
    static func ancQuery(seq: UInt8) -> OPOPacket {
        OPOPacket(cat: 0x04, sub: 0x82, seq: seq, body: [0x02, 0x00, 0x00, 0xF2])
    }
    static func ancSet(mode: UInt8, seq: UInt8) -> OPOPacket {
        OPOPacket(cat: 0x04, sub: 0x04, seq: seq, body: [0x03, 0x00, 0x01, 0x01, mode])
    }
    static func batteryQuery(seq: UInt8) -> OPOPacket {
        OPOPacket(cat: 0x06, sub: 0x01, seq: seq, body: [0x00, 0x00])
    }
    static func deviceInfoQuery(seq: UInt8) -> OPOPacket {
        OPOPacket(cat: 0x03, sub: 0x01, seq: seq, body: [0x00, 0x00])
    }
}

// MARK: - Frame reassembly (notifications can split or merge frames)

struct OPOFrameReader {
    private var buffer: [UInt8] = []

    mutating func append(_ data: Data) -> [OPOPacket] {
        buffer.append(contentsOf: data)
        if buffer.count > 4096 { buffer.removeAll() }
        var out: [OPOPacket] = []

        while true {
            guard let start = buffer.firstIndex(of: 0xAA) else { buffer.removeAll(); break }
            if start > 0 { buffer.removeFirst(start) }
            guard buffer.count >= 2 else { break }

            // Length is a base-128 varint (a single byte for any value below 128).
            var length = 0
            var shift = 0
            var lengthBytes = 0
            var complete = false
            var i = 1
            while i < buffer.count && i <= 3 {
                let b = Int(buffer[i])
                length |= (b & 0x7F) << shift
                lengthBytes += 1
                if b & 0x80 == 0 { complete = true; break }
                shift += 7
                i += 1
            }
            if !complete {
                if lengthBytes >= 3 { buffer.removeFirst(); continue }   // malformed length: resync
                break                                                      // need more bytes
            }

            let total = 1 + lengthBytes + length
            if length < 5 || total > 1024 { buffer.removeFirst(); continue }   // implausible: resync
            if buffer.count < total { break }

            let frame = Array(buffer[0..<total])
            buffer.removeFirst(total)
            let o = 1 + lengthBytes                       // index of the first pad byte
            out.append(OPOPacket(cat: frame[o + 2], sub: frame[o + 3], seq: frame[o + 4],
                                 body: Array(frame[(o + 5)...])))
        }
        return out
    }
}

// MARK: - Parsers (defensive: return nil rather than guess)

enum OPOParsers {
    struct Level: Equatable {
        let percent: Int
        let charging: Bool?
    }

    /// Mode byte is taken as the last byte of an ANC-category packet. Unconfirmed layout, so callers only
    /// trust it for a reply to their own QUERY and cross-check the result against what they asked for.
    static func ancMode(_ p: OPOPacket, profile: OPODeviceProfile) -> OPONoiseMode? {
        guard p.cat == 0x04, let last = p.body.last else { return nil }
        return profile.mode(for: last)
    }

    static func level(fromRaw raw: UInt8) -> Level? {
        let v = Int(raw)
        if v <= 100 { return Level(percent: v, charging: nil) }
        if (v & 0x7F) <= 100 { return Level(percent: v & 0x7F, charging: true) }   // top bit = charging (other OPO models)
        return nil
    }

    static func battery(_ p: OPOPacket, profile: OPODeviceProfile) -> (left: Level?, right: Level?, caseLevel: Level?)? {
        guard p.cat == 0x06 else { return nil }
        let needed = max(profile.batteryLeft, profile.batteryRight, profile.batteryCase)
        guard p.body.count > needed else { return nil }
        let l = level(fromRaw: p.body[profile.batteryLeft])
        let r = level(fromRaw: p.body[profile.batteryRight])
        let c = level(fromRaw: p.body[profile.batteryCase])
        if l == nil && r == nil && c == nil { return nil }
        return (l, r, c)
    }

    static func asciiRuns(_ bytes: [UInt8], minLength: Int = 4) -> [String] {
        var runs: [String] = []
        var current = ""
        for b in bytes {
            if b >= 0x20 && b <= 0x7E {
                current.append(Character(UnicodeScalar(b)))
            } else {
                if current.count >= minLength { runs.append(current) }
                current = ""
            }
        }
        if current.count >= minLength { runs.append(current) }
        return runs
    }

    static func firmwareVersion(in runs: [String]) -> String? {
        runs.first { $0.range(of: #"^\d+(\.\d+){2,}$"#, options: .regularExpression) != nil }
    }
}

// MARK: - Hex + in-app diagnostic log

extension Sequence where Element == UInt8 {
    var hex: String { map { String(format: "%02X", $0) }.joined(separator: " ") }
}

/// In-memory log shown in the Bluetooth Report (release builds have no Xcode console).
/// Never records the REGISTER token or peripheral identifiers. All calls happen on the main thread.
final class OPOLog {
    static let shared = OPOLog()
    private(set) var lines: [String] = []
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    func add(_ tag: String, _ message: String) {
        let line = "\(formatter.string(from: Date())) [\(tag)] \(message)"
        lines.append(line)
        if lines.count > 300 { lines.removeFirst(lines.count - 300) }
        #if DEBUG
        print(line)
        #endif
    }

    var text: String { lines.joined(separator: "\n") }
}

// MARK: - Self-check against the published byte sequences

enum OPOSelfCheck {
    /// Returns a list of mismatches (empty = the builders reproduce the documented packets exactly).
    static func run() -> [String] {
        var failures: [String] = []
        func expect(_ name: String, _ got: [UInt8], _ want: [UInt8]) {
            if got != want {
                // The REGISTER packet contains the token, so its bytes are never written to the log.
                failures.append(name == "REGISTER" ? "REGISTER: bytes differ (not shown)" : "\(name): got \(got.hex) want \(want.hex)")
            }
        }
        expect("REGISTER", OPOCommand.register(seq: 0x41).wireBytes,
               [0xAA, 0x0C, 0x00, 0x00, 0x00, 0x85, 0x41, 0x05, 0x00, 0x00, 0xB5, 0x50, 0xA0, 0x69])
        expect("ANC QUERY", OPOCommand.ancQuery(seq: 0x44).wireBytes,
               [0xAA, 0x09, 0x00, 0x00, 0x04, 0x82, 0x44, 0x02, 0x00, 0x00, 0xF2])
        expect("ANC SET ANC", OPOCommand.ancSet(mode: 0x01, seq: 0x42).wireBytes,
               [0xAA, 0x0A, 0x00, 0x00, 0x04, 0x04, 0x42, 0x03, 0x00, 0x01, 0x01, 0x01])
        expect("ANC SET TRANSPARENCY", OPOCommand.ancSet(mode: 0x02, seq: 0x42).wireBytes,
               [0xAA, 0x0A, 0x00, 0x00, 0x04, 0x04, 0x42, 0x03, 0x00, 0x01, 0x01, 0x02])
        expect("ANC SET OFF", OPOCommand.ancSet(mode: 0x04, seq: 0x42).wireBytes,
               [0xAA, 0x0A, 0x00, 0x00, 0x04, 0x04, 0x42, 0x03, 0x00, 0x01, 0x01, 0x04])
        expect("BATTERY QUERY", OPOCommand.batteryQuery(seq: 0x25).wireBytes,
               [0xAA, 0x07, 0x00, 0x00, 0x06, 0x01, 0x25, 0x00, 0x00])

        // A frame split across two notifications, followed by a second frame in the same chunk.
        var reader = OPOFrameReader()
        let a = OPOCommand.ancQuery(seq: 0x44).wireBytes
        let b = OPOCommand.batteryQuery(seq: 0x25).wireBytes
        let first = reader.append(Data(a.prefix(4)))
        let second = reader.append(Data(Array(a.dropFirst(4)) + b))
        if !first.isEmpty { failures.append("frame reader emitted a partial frame") }
        if second.count != 2 || second[0].cat != 0x04 || second[1].cat != 0x06 {
            failures.append("frame reader did not reassemble split/merged frames")
        }
        return failures
    }
}
