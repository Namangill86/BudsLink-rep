import Combine
import Foundation

// None of these classes touch CoreBluetooth. They build packets, hand them to OPOSession, and show only
// what the earbuds report back. No value is ever defaulted, assumed, or set before the device confirms it.

// MARK: - Noise control

final class OPONoiseControl: ObservableObject {

    enum Status: Equatable {
        case unavailable(String)
        case idle
        case reading
        case ready
        case changing(OPONoiseMode)
        case failed(String)
    }

    @Published private(set) var status: Status = .unavailable("BLE control session not established")
    /// The mode the EARBUDS last reported. Never set from a button tap.
    @Published private(set) var mode: OPONoiseMode?

    private let session: OPOSession
    private var bag = Set<AnyCancellable>()
    private var timer: Timer?

    init(session: OPOSession) {
        self.session = session
        // receive(on:) delivers after the new state is stored (a @Published sink fires before the change lands).
        session.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.sessionChanged() }
            .store(in: &bag)
    }

    private func sessionChanged() {
        switch session.state {
        case .ready:
            if case .unavailable = status { status = .idle }
            refresh()
        case .starting:
            status = .unavailable("Starting BLE control session…")
            mode = nil
        case .unavailable(let reason):
            status = .unavailable(reason)
            mode = nil
        case .failed(let reason):
            status = .unavailable(reason)
            mode = nil
        }
    }

    /// Poll while the Earbuds screen is visible so changes made with the buds' touch controls show up.
    func startWatching() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in self?.refresh() }
        refresh()
    }

    func stopWatching() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        guard session.state == .ready, let profile = session.profile else { return }
        if case .changing = status { return }
        if mode == nil { status = .reading }
        let seq = session.nextSeq()
        OPOLog.shared.add("ANC", "Querying current mode")
        session.request(OPOCommand.ancQuery(seq: seq), name: "ANC QUERY",
                        match: Self.queryReply(seq: seq)) { [weak self] result in
            self?.handleQuery(result, profile: profile, expected: nil)
        }
    }

    func set(_ target: OPONoiseMode) {
        guard session.state == .ready, let profile = session.profile else {
            status = .failed("Unable to change noise control. BLE control session failed.")
            return
        }
        if case .changing = status { return }
        status = .changing(target)
        OPOLog.shared.add("ANC", "Requesting \(target.shortLabel)")
        let seq = session.nextSeq()
        session.request(OPOCommand.ancSet(mode: profile.byte(for: target), seq: seq), name: "ANC SET \(target.shortLabel)",
                        match: { $0.packet?.cat == 0x04 }) { [weak self] ack in
            guard let self = self else { return }
            // The acknowledgement format is not confirmed, so it is never trusted on its own.
            // Success is decided only by reading the state back from the earbuds.
            switch ack {
            case .success: OPOLog.shared.add("ANC", "Command acknowledged; verifying by reading the mode back")
            case .failure(let e): OPOLog.shared.add("ANC", "No acknowledgement (\(e.message)); verifying by reading the mode back")
            }
            self.verify(target: target, profile: profile)
        }
    }

    private func verify(target: OPONoiseMode, profile: OPODeviceProfile) {
        let seq = session.nextSeq()
        session.request(OPOCommand.ancQuery(seq: seq), name: "ANC VERIFY",
                        match: Self.queryReply(seq: seq)) { [weak self] result in
            self?.handleQuery(result, profile: profile, expected: target)
        }
    }

    private static func queryReply(seq: UInt8) -> (OPOInbound) -> Bool {
        return { inbound in
            guard let p = inbound.packet else { return false }
            return p.cat == 0x04 && (p.seq == seq || p.sub == 0x82)
        }
    }

    private func handleQuery(_ result: Result<OPOInbound, OPOError>, profile: OPODeviceProfile, expected: OPONoiseMode?) {
        switch result {
        case .failure(let e):
            OPOLog.shared.add("ANC", "Query failed: \(e.message)")
            status = .failed(expected == nil
                ? "Unable to read noise control: \(e.message)."
                : "Unable to change noise control. BLE control session failed.")
        case .success(let inbound):
            guard let packet = inbound.packet, let reported = OPOParsers.ancMode(packet, profile: profile) else {
                OPOLog.shared.add("ANC", "Reply could not be decoded: \(inbound.raw.hex)")
                status = .failed(expected == nil
                    ? "The earbuds replied, but their noise-control state could not be decoded. See the Bluetooth Report."
                    : "The command was sent, but the earbuds' reply could not be verified, so the display was left unchanged.")
                return
            }
            mode = reported
            OPOLog.shared.add("ANC", "Current mode = \(reported.shortLabel)")
            if let expected = expected, expected != reported {
                status = .failed("The earbuds reported \(reported.shortLabel) instead of \(expected.shortLabel).")
            } else {
                status = .ready
            }
        }
    }
}

// MARK: - Battery

final class OPOBatteryMonitor: ObservableObject {

    enum Status: Equatable {
        case unavailable(String)
        case idle
        case loading
        case ready
        case failed(String)
    }

    struct Value: Equatable {
        let percent: Int
        let charging: Bool?
    }

    @Published private(set) var status: Status = .unavailable("BLE control session not established")
    @Published private(set) var left: Value?
    @Published private(set) var right: Value?
    @Published private(set) var caseValue: Value?
    @Published private(set) var lastUpdated: Date?

    private let session: OPOSession
    private var bag = Set<AnyCancellable>()
    private var timer: Timer?

    init(session: OPOSession) {
        self.session = session
        session.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.sessionChanged() }
            .store(in: &bag)
        // Replies and unsolicited updates (for example when a bud goes in or out of the case) both land here.
        session.inbound
            .receive(on: DispatchQueue.main)
            .sink { [weak self] item in self?.consume(item) }
            .store(in: &bag)
    }

    private func sessionChanged() {
        switch session.state {
        case .ready:
            if case .unavailable = status { status = .idle }
            refresh()
        case .starting:
            status = .unavailable("Starting BLE control session…")
        case .unavailable(let reason), .failed(let reason):
            status = .unavailable(reason)
            left = nil; right = nil; caseValue = nil
        }
    }

    func startWatching() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refresh() }
        refresh()
    }

    func stopWatching() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        guard session.state == .ready, let profile = session.profile else { return }
        if left == nil && right == nil && caseValue == nil { status = .loading }
        let seq = session.nextSeq()
        let needed = max(profile.batteryLeft, profile.batteryRight, profile.batteryCase)
        OPOLog.shared.add("BATTERY", "Querying battery")
        session.request(OPOCommand.batteryQuery(seq: seq), name: "BATTERY QUERY",
                        match: { inbound in
                            guard let p = inbound.packet else { return false }
                            return p.cat == 0x06 && p.body.count > needed
                        }) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let e):
                OPOLog.shared.add("BATTERY", "Query failed: \(e.message)")
                self.status = .failed("BLE communication failed (\(e.message)).")
            case .success(let inbound):
                if !self.consume(inbound) {
                    self.status = .failed("The earbuds replied, but the battery data could not be decoded. See the Bluetooth Report.")
                }
            }
        }
    }

    @discardableResult
    private func consume(_ item: OPOInbound) -> Bool {
        guard let profile = session.profile, let packet = item.packet,
              let parsed = OPOParsers.battery(packet, profile: profile) else { return false }
        left = parsed.left.map { Value(percent: $0.percent, charging: $0.charging) }
        right = parsed.right.map { Value(percent: $0.percent, charging: $0.charging) }
        caseValue = parsed.caseLevel.map { Value(percent: $0.percent, charging: $0.charging) }
        lastUpdated = Date()
        status = .ready
        OPOLog.shared.add("BATTERY", "Left = \(left.map { "\($0.percent)%" } ?? "n/a"), Right = \(right.map { "\($0.percent)%" } ?? "n/a"), Case = \(caseValue.map { "\($0.percent)%" } ?? "n/a")")
        return true
    }
}

// MARK: - Device information

final class OPODeviceInfoManager: ObservableObject {

    enum Status: Equatable {
        case unavailable(String)
        case idle
        case loading
        case ready
        case failed(String)
    }

    @Published private(set) var status: Status = .unavailable("BLE control session not established")
    @Published private(set) var firmware: String?
    /// Printable text found in the device-info reply, shown as-is. The reply layout is not confirmed.
    @Published private(set) var strings: [String] = []

    private let session: OPOSession
    private var bag = Set<AnyCancellable>()

    init(session: OPOSession) {
        self.session = session
        session.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.sessionChanged() }
            .store(in: &bag)
        session.inbound
            .receive(on: DispatchQueue.main)
            .sink { [weak self] item in self?.consume(item) }
            .store(in: &bag)
    }

    private func sessionChanged() {
        switch session.state {
        case .ready:
            if case .unavailable = status { status = .idle }
            refresh()
        case .starting:
            status = .unavailable("Starting BLE control session…")
        case .unavailable(let reason), .failed(let reason):
            status = .unavailable(reason)
            firmware = nil
            strings = []
        }
    }

    func refresh() {
        guard session.state == .ready else { return }
        status = .loading
        let seq = session.nextSeq()
        OPOLog.shared.add("INFO", "Querying device information")
        session.request(OPOCommand.deviceInfoQuery(seq: seq), name: "DEVICE INFO QUERY",
                        match: { $0.packet?.cat == 0x03 }) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let e):
                OPOLog.shared.add("INFO", "Query failed: \(e.message)")
                self.status = .failed("Device information is not available (\(e.message)).")
            case .success(let inbound):
                if !self.consume(inbound) {
                    self.status = .failed("The earbuds replied to the device-information request, but it contained no readable firmware text.")
                }
            }
        }
    }

    @discardableResult
    private func consume(_ item: OPOInbound) -> Bool {
        guard let packet = item.packet, packet.cat == 0x03 else { return false }
        let runs = OPOParsers.asciiRuns(packet.body)
        guard !runs.isEmpty else { return false }
        strings = runs
        firmware = OPOParsers.firmwareVersion(in: runs)
        status = .ready
        OPOLog.shared.add("INFO", "Decoded text: \(runs.joined(separator: " | "))")
        return true
    }
}
