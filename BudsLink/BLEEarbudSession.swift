import CoreBluetooth
import Combine
import Foundation

/// The ONE authoritative CoreBluetooth layer in the app (the original BluetoothManager is retired).
///
///   find peripheral -> connect -> discover ALL services -> discover ALL characteristics (logged) ->
///   verify the OPO service -> subscribe -> hand over to OPOSession (handshake) -> ready
///
/// Every step is a `BLEControlState` the UI shows as it happens, every step has a watchdog (nothing can sit on
/// "Waiting…" forever), and every failure carries its exact reason. Audio (A2DP) is deliberately NOT part of this.
///
/// LIVE LISTEN SAFETY: no AVAudioSession / AVAudioEngine calls anywhere in this file.
final class BLEEarbudSession: NSObject, ObservableObject {

    struct Candidate: Identifiable, Equatable {
        let id: UUID
        let name: String
    }

    // MARK: Published state (all mutated on the main queue)
    @Published private(set) var control: BLEControlState = .idle
    @Published private(set) var bleLinked = false
    @Published private(set) var peripheralName: String?
    @Published private(set) var peripheralShortID: String?
    @Published private(set) var checklist = BLEChecklist()
    @Published private(set) var opoChannelVerified = false
    @Published private(set) var candidates: [Candidate] = []
    @Published private(set) var batteries: [BatteryReading] = []
    @Published private(set) var batteryAvailability: FeatureAvailability = .checking
    @Published private(set) var deviceInfo: [String: String] = [:]
    @Published private(set) var services: [GATTServiceInfo] = []
    @Published private(set) var discoveryComplete = false
    @Published private(set) var rssi: Int?
    @Published private(set) var lastSeen: Date?
    @Published private(set) var errorMessage: String?

    /// The one OPO control session (handshake, commands, replies).
    let opo = OPOSession()

    static let infoOrder = ["Manufacturer", "Model", "Firmware", "Hardware", "Software", "Serial"]

    // MARK: UUIDs (Bluetooth SIG assigned numbers)
    private static let batteryService = CBUUID(string: "180F")
    private static let deviceInfoService = CBUUID(string: "180A")
    private static let batteryLevel = CBUUID(string: "2A19")
    private static let batteryPowerState = CBUUID(string: "2A1A")
    private static let userDescription = CBUUID(string: "2901")
    private static let presentationFormat = CBUUID(string: "2904")
    private static let infoLabels: [CBUUID: String] = [
        CBUUID(string: "2A29"): "Manufacturer", CBUUID(string: "2A24"): "Model",
        CBUUID(string: "2A26"): "Firmware",     CBUUID(string: "2A27"): "Hardware",
        CBUUID(string: "2A28"): "Software",     CBUUID(string: "2A25"): "Serial"
    ]
    private static let savedKey = "BudsLink.lastPeripheralID"
    private static let maxConnectAttempts = 3

    // Watchdog durations (seconds)
    private static let connectTimeout = 12.0
    private static let discoveryTimeout = 10.0
    private static let subscribeTimeout = 8.0
    private static let scanDuration = 25.0

    // MARK: Private state
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var known: [UUID: CBPeripheral] = [:]          // CoreBluetooth needs strong references
    private var targetName: String?
    private var wantConnection = false
    private var connectAttempts = 0
    private var bag = Set<AnyCancellable>()

    private var stageWatch: DispatchWorkItem?
    private var scanWork: DispatchWorkItem?
    private var lastScanEnd = Date.distantPast
    private var rssiTimer: Timer?
    private var pendingServices = 0
    private var seenInScan = Set<UUID>()
    private var scanLogBudget = 0

    // OPO bookkeeping
    private var opoWriteChar: CBCharacteristic?
    private var opoInboundChars: [ObjectIdentifier: String] = [:]   // notify characteristics we listen on -> short label
    private var opoCriticalNotify = Set<ObjectIdentifier>()         // notify characteristics inside the OPO service itself
    private var pendingNotify = Set<ObjectIdentifier>()
    private var opoProfile: OPODeviceProfile?
    private var opoStartScheduled = false

    private struct BatteryChar {
        var percent: Int?
        var service: ObjectIdentifier?
        var userDescription: String?
        var namespace: UInt8?
        var descriptionCode: UInt16?
    }
    private var batteryChars: [ObjectIdentifier: BatteryChar] = [:]
    private var chargingByService: [ObjectIdentifier: Bool] = [:]

    // MARK: Lifecycle

    override init() {
        super.init()
        opo.transport = self
        // The OPO session's progress drives the later stages of the control state.
        opo.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.opoStateChanged() }
            .store(in: &bag)
        central = CBCentralManager(delegate: self, queue: .main,
                                   options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }

    /// Call whenever the audio route changes. `name` is the Bluetooth route's name, or nil.
    func start(matchingAudioRouteNamed name: String?) {
        targetName = name
        wantConnection = true
        guard central.state == .poweredOn else { return }
        begin(force: false)
    }

    /// "Retry": re-runs the pipeline. On a live link it rediscovers services; otherwise it searches again.
    func retryControl() {
        connectAttempts = 0
        errorMessage = nil
        wantConnection = true
        if bleLinked, let p = peripheral {
            OPOLog.shared.add("BLE", "Retry requested on a live link: discovering services again")
            disarm()
            clearDeviceData()
            checklist.servicesDiscovered = nil
            setControl(.discoveringServices)
            arm(Self.discoveryTimeout, "Service discovery")
            p.discoverServices(nil)
        } else {
            checklist = BLEChecklist()
            begin(force: true)
        }
    }

    /// The real diagnostic action: forget the saved device, scan, connect, discover, handshake, then query
    /// battery and noise control (those queries start automatically when the session is ready).
    func runDiagnostic() {
        OPOLog.shared.add("BLE", "=== Diagnostic run started ===")
        UserDefaults.standard.removeObject(forKey: Self.savedKey)
        scanWork?.cancel()
        central.stopScan()
        disarm()
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        peripheral = nil
        bleLinked = false
        clearDeviceData()
        checklist = BLEChecklist()
        connectAttempts = 0
        errorMessage = nil
        wantConnection = true
        setControl(.idle)
        guard central.state == .poweredOn else { return }
        begin(force: true)
    }

    func select(_ candidate: Candidate) {
        guard let p = known[candidate.id] else { return }
        connectAttempts = 0
        checklist.discovered = true
        connect(p)
    }

    // MARK: State helpers

    private func setControl(_ new: BLEControlState) {
        guard new != control else { return }
        control = new
        let extra = new.reason.map { " (" + $0 + ")" } ?? ""
        OPOLog.shared.add("BLE", "State: " + new.title + extra)
    }

    private func arm(_ seconds: TimeInterval, _ what: String) {
        stageWatch?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.stageTimedOut(what) }
        stageWatch = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func disarm() {
        stageWatch?.cancel()
        stageWatch = nil
    }

    private func fail(_ reason: String) {
        disarm()
        OPOLog.shared.add("BLE ERROR", reason)
        setControl(.failed(reason))
    }

    private func stageTimedOut(_ what: String) {
        switch control {
        case .connecting:
            OPOLog.shared.add("BLE ERROR", "Connecting timed out after \(Int(Self.connectTimeout)) s")
            if let p = peripheral { central.cancelPeripheralConnection(p) }
            peripheral = nil
            connectAttempts += 1
            if connectAttempts < Self.maxConnectAttempts {
                setControl(.idle)          // begin() refuses to run while a step is "in progress"
                begin(force: true)
            } else {
                setControl(.failed("Could not open a Bluetooth LE connection to the earbuds after \(Self.maxConnectAttempts) attempts. They may be connected to another controller (for example HeyMelody on a phone), out of range, or in the case. Close other controllers and tap Retry."))
            }
        case .discoveringServices:
            fail("Service discovery did not finish within \(Int(Self.discoveryTimeout)) s. The link is up but the earbuds did not list their services. Tap Retry.")
            checklist.servicesDiscovered = false
        case .discoveringCharacteristics:
            fail("Characteristic discovery did not finish within \(Int(Self.discoveryTimeout)) s. Tap Retry.")
            checklist.characteristics = false
        case .subscribing:
            fail("Subscribing to the earbuds' reply notifications did not finish within \(Int(Self.subscribeTimeout)) s. If iOS showed a Bluetooth pairing request, accept it and tap Retry.")
            checklist.notifications = false
        default:
            break      // the pipeline already moved on
        }
    }

    // MARK: Finding the peripheral

    private func nameMatches(_ other: String?) -> Bool {
        guard let t = targetName?.lowercased(), !t.isEmpty,
              let o = other?.lowercased(), !o.isEmpty else { return false }
        return t == o || t.contains(o) || o.contains(t)
    }

    private func isKnownDevice(_ name: String?) -> Bool {
        OPODeviceProfile.match(bleName: name) != nil
    }

    private func matchesTarget(name: String?, advertisement: [String: Any]?) -> Bool {
        if nameMatches(name) || isKnownDevice(name) { return true }
        if let uuids = advertisement?[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID], uuids.contains(OPO.service) { return true }
        return false
    }

    private func begin(force: Bool) {
        guard wantConnection, central.state == .poweredOn else { return }
        if bleLinked { return }
        switch control {
        case .scanning, .discovered, .connecting, .connected, .discoveringServices,
             .discoveringCharacteristics, .subscribing, .authenticating, .ready:
            return          // already in progress
        default:
            break
        }
        if !force && Date().timeIntervalSince(lastScanEnd) < 10 { return }   // don't thrash on every screen change

        // 1. Peripherals the system already holds a BLE link to, found by the services they expose.
        let probes = [OPO.service, Self.batteryService, Self.deviceInfoService]
        let systemConnected = central.retrieveConnectedPeripherals(withServices: probes)
        for p in systemConnected { known[p.identifier] = p }
        let connectedNames = systemConnected.map { $0.name ?? "unnamed" }.joined(separator: ", ")
        let shownNames = connectedNames.isEmpty ? "none" : connectedNames
        OPOLog.shared.add("BLE", "System-connected peripherals with known services: " + shownNames)
        if let match = systemConnected.first(where: { matchesTarget(name: $0.name, advertisement: nil) }) {
            checklist.discovered = true
            OPOLog.shared.add("BLE", "Found: " + (match.name ?? "earbuds") + " (already linked to the system)")
            connect(match)
            return
        }

        // 2. Look for the earbuds. Only when there is something real to look for.
        var saved: CBPeripheral?
        if let id = UserDefaults.standard.string(forKey: Self.savedKey).flatMap(UUID.init(uuidString:)) {
            saved = central.retrievePeripherals(withIdentifiers: [id]).first
        }
        guard targetName != nil || saved != nil else {
            setControl(.idle)
            return
        }
        startScan()

        // 3. In PARALLEL arm a pending connect to the remembered device. iOS completes it when the earbuds appear
        //    (case reopened, back in range). It must never replace scanning, which is what caused "Waiting…" forever.
        if let saved = saved, targetName == nil || nameMatches(saved.name) || isKnownDevice(saved.name) {
            OPOLog.shared.add("BLE", "Arming a pending connection to the remembered earbuds")
            peripheral = saved
            known[saved.identifier] = saved
            saved.delegate = self
            peripheralName = saved.name ?? targetName
            peripheralShortID = String(saved.identifier.uuidString.prefix(8))
            central.connect(saved, options: nil)
        }
    }

    private func startScan() {
        OPOLog.shared.add("BLE", "Scan started")
        scanLogBudget = 40
        seenInScan = []
        candidates = []
        setControl(.scanning)
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        scanWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.scanFinished() }
        scanWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.scanDuration, execute: work)
    }

    private func scanFinished() {
        central.stopScan()
        lastScanEnd = Date()
        guard control == .scanning else { return }
        checklist.discovered = false
        OPOLog.shared.add("BLE ERROR", "Scan ended without finding the earbuds")
        setControl(.unavailable("The earbuds were not found over Bluetooth LE in \(Int(Self.scanDuration)) seconds. They may be in the case or out of range, may not be advertising while connected for audio, or another controller (for example HeyMelody on a phone) may be holding them. Audio is not affected. Open the case or put the earbuds in your ears and tap Retry; a pending connection stays armed and will resume automatically if they reappear."))
    }

    private func connect(_ p: CBPeripheral) {
        central.stopScan()
        scanWork?.cancel()
        lastScanEnd = Date()
        peripheral = p
        known[p.identifier] = p
        p.delegate = self
        errorMessage = nil
        let name = p.name ?? targetName ?? "Earbuds"
        peripheralName = name
        peripheralShortID = String(p.identifier.uuidString.prefix(8))
        setControl(.connecting(name))
        OPOLog.shared.add("BLE", "Attempting connection to \(name)")
        central.connect(p, options: nil)
        arm(Self.connectTimeout, "Connecting")
    }

    // MARK: State reset

    private func clearDeviceData() {
        stopRSSITimer()
        batteryChars = [:]
        chargingByService = [:]
        batteries = []
        deviceInfo = [:]
        services = []
        rssi = nil
        discoveryComplete = false
        pendingServices = 0
        batteryAvailability = .checking
        opoWriteChar = nil
        opoInboundChars = [:]
        opoCriticalNotify = []
        pendingNotify = []
        opoProfile = nil
        opoStartScheduled = false
        opoChannelVerified = false
        checklist = BLEChecklist(discovered: checklist.discovered, connected: checklist.connected)
        opo.markUnavailable("Waiting for the Bluetooth LE link")
    }

    private func startRSSITimer() {
        rssiTimer?.invalidate()
        rssiTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.peripheral?.readRSSI()
        }
    }

    private func stopRSSITimer() {
        rssiTimer?.invalidate()
        rssiTimer = nil
    }

    // MARK: Capability decisions

    private func finishDiscovery() {
        disarm()
        discoveryComplete = true
        checklist.characteristics = true
        batteryAvailability = batteryChars.isEmpty ? .notExposed : .supported
        publishBatteries()
        configureOPO()
    }

    /// Decides, from what the earbuds really expose, whether the OPO control session can exist.
    private func configureOPO() {
        guard let p = peripheral else { return }
        let all = p.services ?? []
        let uuids = all.map { $0.uuid.uuidString }
        let uuidList = uuids.isEmpty ? "none" : uuids.joined(separator: ", ")
        OPOLog.shared.add("BLE", "Complete service list: \(uuidList)")

        let hasService = all.contains(where: { $0.uuid == OPO.service })
        checklist.opoService = hasService
        guard hasService else {
            let reason = "The earbuds' OPO control service (0000079A-D102-11E1-9B23-00025B00A5A5) was not found on this BLE connection. Services found: \(uuidList). Possible reasons: the earbuds offer it only over Classic Bluetooth (RFCOMM), which iOS apps cannot open without Apple's MFi program; iOS is hiding it on this connection; or this firmware does not expose it over BLE. The earbuds can still support ANC; the full service list is in the Bluetooth Report."
            opo.markUnavailable(reason)
            fail(reason)
            return
        }
        guard let profile = OPODeviceProfile.match(bleName: p.name) else {
            let shownName = p.name ?? "unnamed"
            let reason = "The OPO control service is present, but \"" + shownName + "\" has no verified command profile, so no commands are sent. The Bluetooth Report lists everything found."
            opo.markUnavailable(reason)
            fail(reason)
            return
        }
        guard let writeChar = opoWriteChar, writeChar.properties.contains(.writeWithoutResponse) else {
            let reason = "The OPO service is present, but its write characteristic (0100079A…) is missing or does not allow write-without-response, which the protocol requires."
            OPOLog.shared.add("BLE ERROR", "Required characteristic not found: OPO write characteristic")
            opo.markUnavailable(reason)
            checklist.characteristics = false
            fail(reason)
            return
        }
        guard !opoCriticalNotify.isEmpty else {
            let reason = "The OPO service is present, but it has no notification characteristic, so replies could not be received and no commands are sent."
            OPOLog.shared.add("BLE ERROR", "Required characteristic not found: OPO notify characteristic")
            opo.markUnavailable(reason)
            checklist.characteristics = false
            fail(reason)
            return
        }
        OPOLog.shared.add("BLE", "OPO service verified; write characteristic supports write-without-response")
        opoProfile = profile
        opoChannelVerified = true
        setControl(.subscribing)
        OPOLog.shared.add("BLE", "Subscribing to notifications")
        arm(Self.subscribeTimeout, "Subscribing")
        maybeStartOPO()
    }

    private func maybeStartOPO() {
        guard let profile = opoProfile, pendingNotify.isEmpty, !opoStartScheduled else { return }
        opoStartScheduled = true
        disarm()
        checklist.notifications = true
        OPOLog.shared.add("BLE", "Notifications enabled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self, self.opoStartScheduled, self.bleLinked else { return }
            self.opo.begin(profile: profile)
        }
    }

    /// Later stages of the control state follow the OPO session.
    private func opoStateChanged() {
        guard bleLinked else { return }
        switch opo.state {
        case .starting(let step):
            if case .failed = control { return }
            setControl(.authenticating(step))
        case .ready:
            checklist.handshake = "OK"
            OPOLog.shared.add("OPO", "Protocol ready")
            setControl(.ready)
        case .failed(let reason):
            checklist.handshake = "FAILED: no reply from the earbuds"
            setControl(.failed(reason))
        case .unavailable:
            break
        }
    }

    private func serviceKey(of c: CBCharacteristic) -> ObjectIdentifier? {
        let s: CBService? = c.service      // compiles whether the SDK declares this optional or not
        return s.map { ObjectIdentifier($0) }
    }

    private static func role(of b: BatteryChar, siblings: Int) -> BatteryRole {
        // 1. What the device says about itself (Characteristic User Description).
        let text = (b.userDescription ?? "").lowercased()
        if text.contains("left") { return .left }
        if text.contains("right") { return .right }
        if text.contains("case") { return .chargingCase }
        // 2. Bluetooth SIG GATT namespace descriptors (namespace 0x01): 0x010D = left, 0x010E = right.
        if b.namespace == 0x01, let d = b.descriptionCode {
            if d == 0x010D { return .left }
            if d == 0x010E { return .right }
        }
        // 3. Never guess which bud is which.
        return siblings == 1 ? .combined : .unlabeled
    }

    private func publishBatteries() {
        let count = batteryChars.count
        let list = batteryChars.map { key, b in
            BatteryReading(id: key,
                           role: Self.role(of: b, siblings: count),
                           percent: b.percent,
                           charging: b.service.flatMap { chargingByService[$0] })
        }
        batteries = list.sorted { $0.role < $1.role }
    }

    // MARK: Report

    private func yesNo(_ value: Bool) -> String { value ? "YES" : "NO" }

    func reportText(audioRoute: String?) -> String {
        let oService = OPO.service.uuidString
        let hasOPO = services.contains { $0.uuid.caseInsensitiveCompare(oService) == .orderedSame }
        let hasStdBattery = batteryAvailability == .supported
        let hasStdInfo = services.contains { $0.uuid.caseInsensitiveCompare("180A") == .orderedSame }
        var l: [String] = []
        l.append("BudsLink Bluetooth report")
        l.append("Generated: \(Date().formatted())")
        l.append("iOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        l.append("")
        let nameText = peripheralName ?? "none"
        let idText = peripheralShortID.map { $0 + "… (app-local, shortened)" } ?? "none"
        let rssiText = rssi.map { String($0) + " dBm" } ?? "n/a"
        let audioText = audioRoute ?? "not connected"
        let linkText = bleLinked ? "connected" : "not connected"
        let stateExtra = control.reason.map { " (" + $0 + ")" } ?? ""
        l.append("Peripheral name: " + nameText)
        l.append("Peripheral identifier: " + idText)
        l.append("RSSI: " + rssiText)
        l.append("Audio state: " + audioText)
        l.append("BLE link: " + linkText)
        l.append("BLE control state: " + control.title + stateExtra)
        l.append("")
        let opoReady = opo.state == .ready
        l.append("OPO service detected: " + yesNo(hasOPO))
        l.append("OPO protocol ready: " + yesNo(opoReady))
        l.append("ANC channel detected: " + yesNo(opoChannelVerified) + "  (ANC is controlled through the OPO channel)")
        l.append("Battery channel detected: " + yesNo(hasStdBattery || opoChannelVerified) + "  (standard service: " + yesNo(hasStdBattery) + ", OPO: " + yesNo(opoChannelVerified) + ")")
        l.append("Device info channel detected: " + yesNo(hasStdInfo || opoChannelVerified) + "  (standard service: " + yesNo(hasStdInfo) + ", OPO: " + yesNo(opoChannelVerified) + ")")
        l.append("")
        l.append("Control checklist:")
        for line in checklist.lines { l.append("  " + line.title + ": " + line.value) }
        for (k, v) in deviceInfo.sorted(by: { $0.key < $1.key }) { l.append("\(k): \(v)") }
        l.append("")
        l.append("GATT services (\(services.count)):")
        for s in services {
            l.append("[" + s.uuid + "] " + (s.name ?? "Unknown service"))
            for c in s.characteristics {
                let propText = c.properties.isEmpty ? "no properties" : c.properties.joined(separator: ", ")
                let charName = c.name ?? "Unknown"
                l.append("    " + c.uuid + "  " + charName + "  (" + propText + ")")
            }
        }
        if let errorMessage = errorMessage { l.append(""); l.append("Last error: \(errorMessage)") }
        l.append("")
        l.append("Event log (the REGISTER token is never recorded; review before sharing):")
        l.append(OPOLog.shared.text)
        return l.joined(separator: "\n")
    }

    private func describe(_ ad: [String: Any]) -> String {
        var parts: [String] = []
        if let uuids = ad[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID], !uuids.isEmpty {
            parts.append("services=" + uuids.map { $0.uuidString }.joined(separator: ","))
        }
        if let m = ad[CBAdvertisementDataManufacturerDataKey] as? Data, m.count >= 2 {
            let company = UInt16(m[m.startIndex]) | UInt16(m[m.startIndex + 1]) << 8
            parts.append(String(format: "manufacturer=0x%04X(%d bytes)", company, m.count))
        }
        if let c = ad[CBAdvertisementDataIsConnectable] as? NSNumber {
            parts.append("connectable=\(c.boolValue)")
        }
        return parts.joined(separator: " ")
    }
}

// MARK: - OPOTransport

extension BLEEarbudSession: OPOTransport {
    /// The only write in the whole app: write-without-response to the verified OPO write characteristic.
    func opoWrite(_ data: Data) -> Bool {
        guard let p = peripheral, p.state == .connected, let c = opoWriteChar else { return false }
        guard p.canSendWriteWithoutResponse else { return false }
        p.writeValue(data, for: c, type: .withoutResponse)
        return true
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEEarbudSession: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            OPOLog.shared.add("BLE", "Bluetooth powered on")
            if wantConnection { begin(force: true) } else { setControl(.idle) }
        case .poweredOff:
            OPOLog.shared.add("BLE ERROR", "Bluetooth powered off")
            disarm()
            scanWork?.cancel()
            peripheral = nil
            known = [:]
            bleLinked = false
            clearDeviceData()
            setControl(.bluetoothOff)
        case .unauthorized:
            OPOLog.shared.add("BLE ERROR", "Bluetooth permission denied")
            setControl(.unauthorized)
        case .unsupported:
            setControl(.unsupported)
        default:
            break      // .unknown / .resetting: wait for the next update
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? p.name
        known[p.identifier] = p
        if let name = name, !name.isEmpty, scanLogBudget > 0, seenInScan.insert(p.identifier).inserted {
            scanLogBudget -= 1
            OPOLog.shared.add("BLE", "Discovered peripheral: " + name + " RSSI " + String(RSSI.intValue) + " " + describe(advertisementData))
        }
        if matchesTarget(name: name, advertisement: advertisementData) {
            checklist.discovered = true
            if RSSI.intValue != 127 { rssi = RSSI.intValue }
            OPOLog.shared.add("BLE", "Found: " + (name ?? "earbuds"))
            setControl(.discovered(name ?? "earbuds"))
            connect(p)
        } else if let name = name, !name.isEmpty, !candidates.contains(where: { $0.id == p.identifier }),
                  candidates.count < 20 {
            candidates.append(Candidate(id: p.identifier, name: name))
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        guard p.identifier == peripheral?.identifier else { return }
        disarm()
        scanWork?.cancel()
        central.stopScan()
        UserDefaults.standard.set(p.identifier.uuidString, forKey: Self.savedKey)
        connectAttempts = 0
        clearDeviceData()
        opo.resetForNewConnection()
        bleLinked = true
        checklist.discovered = checklist.discovered ?? true
        checklist.connected = true
        peripheralName = p.name ?? peripheralName ?? targetName
        peripheralShortID = String(p.identifier.uuidString.prefix(8))
        lastSeen = Date()
        let connectedName = peripheralName ?? "earbuds"
        OPOLog.shared.add("BLE", "didConnect: " + connectedName)
        setControl(.discoveringServices)
        OPOLog.shared.add("BLE", "Discovering services")
        opo.markUnavailable("Discovering services…")
        arm(Self.discoveryTimeout, "Service discovery")
        p.discoverServices(nil)       // nil: discover everything, then decide capabilities from the result
        p.readRSSI()
        startRSSITimer()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        guard p.identifier == peripheral?.identifier else { return }
        let detail = error.map { ": " + $0.localizedDescription } ?? ""
        OPOLog.shared.add("BLE", "didDisconnect" + detail)
        disarm()
        bleLinked = false
        checklist.connected = false
        clearDeviceData()
        opo.markUnavailable("The earbuds disconnected from BLE.")
        guard wantConnection else { setControl(.idle); return }
        setControl(.unavailable("The earbuds disconnected from Bluetooth LE (case closed, out of range, removed from your ears, or taken over by another controller). Audio is not affected. A pending connection is armed and resumes automatically when they are available again."))
        central.connect(p, options: nil)   // pending, not a retry loop: iOS completes it when the earbuds return
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        disarm()
        let reason = error?.localizedDescription ?? "unknown error"
        connectAttempts += 1
        OPOLog.shared.add("BLE ERROR", "didFailToConnect (\(connectAttempts) of \(Self.maxConnectAttempts)): \(reason)")
        errorMessage = reason
        peripheral = nil
        guard connectAttempts < Self.maxConnectAttempts else {
            setControl(.failed("Connecting over Bluetooth LE failed \(Self.maxConnectAttempts) times: \(reason). Tap Retry."))
            return
        }
        setControl(.unavailable("Connect attempt failed (\(reason)). Trying again shortly."))
        let delay = Double(connectAttempts) * 2
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.begin(force: true) }
    }
}

// MARK: - CBPeripheralDelegate

extension BLEEarbudSession: CBPeripheralDelegate {

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            checklist.servicesDiscovered = false
            opo.markUnavailable("Service discovery failed: \(error.localizedDescription)")
            fail("Service discovery failed: \(error.localizedDescription). Close other apps that control the earbuds and tap Retry.")
            return
        }
        let list = p.services ?? []
        checklist.servicesDiscovered = true
        for s in list { OPOLog.shared.add("BLE", "Discovered service: \(s.uuid.uuidString)") }
        pendingServices = list.count
        if list.isEmpty { finishDiscovery(); return }
        setControl(.discoveringCharacteristics)
        OPOLog.shared.add("BLE", "Discovering characteristics")
        arm(Self.discoveryTimeout, "Characteristic discovery")
        list.forEach { p.discoverCharacteristics(nil, for: $0) }
    }

    func peripheral(_ p: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        OPOLog.shared.add("BLE", "Services changed; discovering again")
        disarm()
        clearDeviceData()
        setControl(.discoveringServices)
        arm(Self.discoveryTimeout, "Service discovery")
        p.discoverServices(nil)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        defer {
            pendingServices -= 1
            if pendingServices <= 0 && !discoveryComplete && bleLinked { finishDiscovery() }
        }
        if let error = error {
            OPOLog.shared.add("BLE ERROR", "Characteristic discovery failed for \(service.uuid.uuidString): \(error.localizedDescription)")
            errorMessage = error.localizedDescription
            return
        }

        let chars = service.characteristics ?? []
        for c in chars {
            let props = GATTNames.properties(of: c).joined(separator: ", ")
            let shownProps = props.isEmpty ? "none" : props
            OPOLog.shared.add("BLE", "Service " + service.uuid.uuidString + " characteristic " + c.uuid.uuidString + " properties [" + shownProps + "]")
        }
        services.append(GATTServiceInfo(
            id: "\(ObjectIdentifier(service))",
            uuid: service.uuid.uuidString,
            name: GATTNames.services[service.uuid.uuidString],
            characteristics: chars.map {
                GATTCharacteristicInfo(id: "\(ObjectIdentifier($0))",
                                       uuid: $0.uuid.uuidString,
                                       name: GATTNames.characteristics[$0.uuid.uuidString],
                                       properties: GATTNames.properties(of: $0))
            }))

        // OPO control service + vendor telemetry service: SUBSCRIBE to every notify/indicate characteristic
        // (replies can arrive on either service). Only the verified OPO write characteristic is ever written.
        let isOPOService = service.uuid == OPO.service
        if isOPOService || OPO.isTelemetryService(service.uuid) {
            if isOPOService { OPOLog.shared.add("BLE", "OPO service found: \(service.uuid.uuidString)") }
            for c in chars {
                let id = ObjectIdentifier(c)
                if c.properties.contains(.notify) || c.properties.contains(.indicate) {
                    opoInboundChars[id] = String(c.uuid.uuidString.prefix(8))
                    pendingNotify.insert(id)
                    if isOPOService { opoCriticalNotify.insert(id) }
                    OPOLog.shared.add("BLE", "Notify characteristic found: \(String(c.uuid.uuidString.prefix(8)))")
                    p.setNotifyValue(true, for: c)
                }
                if isOPOService && c.uuid == OPO.writeCharacteristic {
                    opoWriteChar = c
                    OPOLog.shared.add("BLE", "Write characteristic found")
                }
            }
        }

        for c in chars {
            switch c.uuid {
            case Self.batteryLevel:
                batteryChars[ObjectIdentifier(c)] = BatteryChar(service: ObjectIdentifier(service))
                p.discoverDescriptors(for: c)
                if c.properties.contains(.read) { p.readValue(for: c) }
                if c.properties.contains(.notify) { p.setNotifyValue(true, for: c) }
            case Self.batteryPowerState:
                if c.properties.contains(.read) { p.readValue(for: c) }
                if c.properties.contains(.notify) { p.setNotifyValue(true, for: c) }
            default:
                if Self.infoLabels[c.uuid] != nil, c.properties.contains(.read) { p.readValue(for: c) }
            }
        }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverDescriptorsFor c: CBCharacteristic, error: Error?) {
        guard error == nil else { return }
        for d in c.descriptors ?? [] where d.uuid == Self.userDescription || d.uuid == Self.presentationFormat {
            p.readValue(for: d)
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        if let error = error {
            OPOLog.shared.add("BLE ERROR", "Read/notify failed on \(String(c.uuid.uuidString.prefix(8))): \(error.localizedDescription)")
            errorMessage = "Read failed (\(c.uuid.uuidString)): \(error.localizedDescription)"
            return
        }
        lastSeen = Date()

        // OPO / vendor notifications go straight to the protocol layer.
        if let label = opoInboundChars[ObjectIdentifier(c)] {
            if let data = c.value { opo.handleInbound(data, source: label) }
            return
        }
        guard let data = c.value else { return }

        switch c.uuid {
        case Self.batteryLevel:
            guard let byte = data.first, byte <= 100 else { return }      // 0...100 per spec; ignore anything else
            batteryChars[ObjectIdentifier(c), default: BatteryChar()].percent = Int(byte)
            publishBatteries()

        case Self.batteryPowerState:
            // GATT Specification Supplement, Battery Power State: bits 4-5 = Charging
            // (0 unknown, 1 not chargeable, 2 not charging, 3 charging).
            guard let b = data.first, let svc = serviceKey(of: c) else { return }
            switch (b >> 4) & 0x3 {
            case 3:  chargingByService[svc] = true
            case 2:  chargingByService[svc] = false
            default: chargingByService[svc] = nil
            }
            publishBatteries()

        default:
            if let label = Self.infoLabels[c.uuid],
               let text = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: CharacterSet.controlCharacters.union(.whitespacesAndNewlines)),
               !text.isEmpty {
                deviceInfo[label] = text
            }
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor d: CBDescriptor, error: Error?) {
        let owner: CBCharacteristic? = d.characteristic
        guard error == nil, let owner = owner else { return }
        let key = ObjectIdentifier(owner)
        guard batteryChars[key] != nil else { return }

        if d.uuid == Self.userDescription, let s = d.value as? String {
            batteryChars[key]?.userDescription = s
        } else if d.uuid == Self.presentationFormat, let data = d.value as? Data, data.count >= 7 {
            let bytes = [UInt8](data)       // format, exponent, unit(2), namespace, description(2) -- little endian
            batteryChars[key]?.namespace = bytes[4]
            batteryChars[key]?.descriptionCode = UInt16(bytes[5]) | UInt16(bytes[6]) << 8
        }
        publishBatteries()
    }

    /// Commands use write-without-response, so this normally never fires; it is here so a failure can never be silent.
    func peripheral(_ p: CBPeripheral, didWriteValueFor c: CBCharacteristic, error: Error?) {
        if let error = error {
            OPOLog.shared.add("BLE ERROR", "Write failed on \(String(c.uuid.uuidString.prefix(8))): \(error.localizedDescription)")
            errorMessage = "Write failed: \(error.localizedDescription)"
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        let id = ObjectIdentifier(c)
        guard opoInboundChars[id] != nil else {
            if let error = error { errorMessage = "Notify failed (\(c.uuid.uuidString)): \(error.localizedDescription)" }
            return
        }
        pendingNotify.remove(id)
        if let error = error {
            OPOLog.shared.add("BLE ERROR", "Subscribe failed on \(String(c.uuid.uuidString.prefix(8))): \(error.localizedDescription)")
            if opoCriticalNotify.contains(id) {
                opoProfile = nil
                checklist.notifications = false
                let nsError = error as NSError
                let needsPairing = nsError.domain == CBATTErrorDomain &&
                    (nsError.code == CBATTError.insufficientAuthentication.rawValue ||
                     nsError.code == CBATTError.insufficientEncryption.rawValue)
                let hint = needsPairing ? " iOS needs to pair with the earbuds over Bluetooth LE: accept the pairing request if one appears, then tap Retry." : ""
                let reason = "Could not subscribe to the earbuds' reply channel (\(c.uuid.uuidString)): \(error.localizedDescription).\(hint) Replies could not be received, so no commands are sent."
                opo.markUnavailable(reason)
                fail(reason)
            }
            return
        }
        OPOLog.shared.add("BLE", "Notification enabled on \(String(c.uuid.uuidString.prefix(8)))")
        maybeStartOPO()
    }

    func peripheral(_ p: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        guard error == nil, RSSI.intValue != 127 else { return }      // 127 means "not available"
        rssi = RSSI.intValue
        lastSeen = Date()
    }
}
