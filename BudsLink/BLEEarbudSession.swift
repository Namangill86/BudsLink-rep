import CoreBluetooth
import Combine
import Foundation

/// The single authoritative BLE layer: finds, connects to, and interrogates the earbuds' GATT side.
///
/// Pipeline:  find peripheral -> connect -> discover ALL services/characteristics (logged) ->
///            decide capabilities from what is really there -> subscribe -> start the OPO control session.
///
/// The peripheral is found by (a) services it exposes, (b) a known device profile name, or (c) the name of the
/// current audio route. Nothing is assumed from a successful connection: whether control works is reported
/// separately by `opo.state`.
///
/// LIVE LISTEN SAFETY: no AVAudioSession / AVAudioEngine calls anywhere in this file.
final class BLEEarbudSession: NSObject, ObservableObject {

    enum Connection: Equatable {
        case bluetoothOff, unauthorized, unsupported
        case idle
        case searching
        case connecting(String)
        case waiting(String)        // connect request pending; the earbuds are not reachable right now
        case connected(String)      // didConnect has fired: a real GATT link exists
    }

    struct Candidate: Identifiable, Equatable {
        let id: UUID
        let name: String
    }

    // MARK: Published state (all mutated on the main queue)
    @Published private(set) var connection: Connection = .idle
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
    private static let maxConnectAttempts = 4

    // MARK: Private state
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var known: [UUID: CBPeripheral] = [:]          // CoreBluetooth needs strong references
    private var targetName: String?
    private var wantConnection = false
    private var scanStop: DispatchWorkItem?
    private var rssiTimer: Timer?
    private var pendingServices = 0
    private var connectAttempts = 0

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
        central = CBCentralManager(delegate: self, queue: .main,
                                   options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }

    /// Call whenever the audio route changes. `name` is the Bluetooth route's name, or nil.
    func start(matchingAudioRouteNamed name: String?) {
        targetName = name
        wantConnection = true
        guard central.state == .poweredOn else { return }
        locate()
    }

    /// User-initiated: forget the saved device and search again.
    func rescan() {
        UserDefaults.standard.removeObject(forKey: Self.savedKey)
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        peripheral = nil
        clearDeviceData()
        connectAttempts = 0
        wantConnection = true
        locate()
    }

    func select(_ candidate: Candidate) {
        guard let p = known[candidate.id] else { return }
        connectAttempts = 0
        connect(p)
    }

    /// User-initiated "Retry" for the control session: re-runs discovery on a live link, or searches again.
    func retryControl() {
        connectAttempts = 0
        errorMessage = nil
        if case .connected = connection, let p = peripheral {
            OPOLog.shared.add("BLE", "Retry requested: discovering services again")
            clearDeviceData()
            p.discoverServices(nil)
        } else {
            wantConnection = true
            locate()
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

    private func locate() {
        guard wantConnection, central.state == .poweredOn else { return }
        if let p = peripheral, p.state == .connected || p.state == .connecting { return }

        // 1. Remembered device: connect() stays pending and fires when the earbuds come back,
        //    so reconnects work without restarting the app.
        if let id = UserDefaults.standard.string(forKey: Self.savedKey).flatMap(UUID.init(uuidString:)),
           let saved = central.retrievePeripherals(withIdentifiers: [id]).first,
           targetName == nil || nameMatches(saved.name) || isKnownDevice(saved.name) {
            OPOLog.shared.add("BLE", "Reconnecting to the remembered earbuds")
            connect(saved, pending: true)
            return
        }

        // 2. Peripherals the system already holds a BLE link to, found by the services they expose.
        let probes = [OPO.service, Self.batteryService, Self.deviceInfoService]
        let systemConnected = central.retrieveConnectedPeripherals(withServices: probes)
        for p in systemConnected { known[p.identifier] = p }
        let connectedNames = systemConnected.map { $0.name ?? "unnamed" }.joined(separator: ", ")
        OPOLog.shared.add("BLE", "System-connected peripherals with known services: \(connectedNames)")
        if let match = systemConnected.first(where: { nameMatches($0.name) || isKnownDevice($0.name) }) {
            OPOLog.shared.add("BLE", "Found: " + (match.name ?? "earbuds"))
            connect(match)
            return
        }

        // 3. Scan, but only when there is a real audio route (or a known model) to look for.
        guard targetName != nil else { connection = .idle; return }
        OPOLog.shared.add("BLE", "Scanning...")
        connection = .searching
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        scanStop?.cancel()
        let stop = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.central.stopScan()
            if self.connection == .searching {
                OPOLog.shared.add("BLE", "Scan ended without finding the earbuds")
                self.connection = .idle
            }
        }
        scanStop = stop
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: stop)
    }

    private func connect(_ p: CBPeripheral, pending: Bool = false) {
        central.stopScan()
        scanStop?.cancel()
        peripheral = p
        known[p.identifier] = p
        p.delegate = self
        errorMessage = nil
        let name = p.name ?? targetName ?? "Earbuds"
        connection = pending ? .waiting(name) : .connecting(name)
        OPOLog.shared.add("BLE", pending ? "Waiting for \(name) to reconnect" : "Connecting to \(name)")
        central.connect(p, options: nil)
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
        discoveryComplete = true
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
        OPOLog.shared.add("BLE", "Services: \(uuidList)")

        guard all.contains(where: { $0.uuid == OPO.service }) else {
            opo.markUnavailable("The earbuds' OPO control service (0000079A-D102-11E1-9B23-00025B00A5A5) was not found on this BLE connection. Services found: \(uuidList). Possible reasons: this connection only offers it over Classic Bluetooth (RFCOMM), which iOS apps cannot open without Apple's MFi program, or iOS does not expose it for this connection. The earbuds can still support ANC; this app just cannot reach the control channel.")
            return
        }
        guard let profile = OPODeviceProfile.match(bleName: p.name) else {
            opo.markUnavailable("The OPO control service is present, but \"\(p.name ?? "unnamed")\" has no verified command profile, so no commands are sent. The Bluetooth Report lists everything found.")
            return
        }
        guard let writeChar = opoWriteChar, writeChar.properties.contains(.writeWithoutResponse) else {
            opo.markUnavailable("The OPO service is present, but its write characteristic (0100079A…) is missing or does not allow write-without-response, which the protocol requires.")
            return
        }
        guard !opoCriticalNotify.isEmpty else {
            opo.markUnavailable("The OPO service is present, but it has no notification characteristic, so replies could not be received and no commands are sent.")
            return
        }
        OPOLog.shared.add("BLE", "OPO service verified; write characteristic supports write-without-response")
        opoProfile = profile
        opo.markStarting("Subscribing to notifications")
        maybeStartOPO()
    }

    private func maybeStartOPO() {
        guard let profile = opoProfile, pendingNotify.isEmpty, !opoStartScheduled else { return }
        opoStartScheduled = true
        OPOLog.shared.add("BLE", "Subscribed to notifications")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self, self.opoStartScheduled, case .connected = self.connection else { return }
            self.opo.begin(profile: profile)
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

    var opoStateDescription: String {
        switch opo.state {
        case .unavailable(let reason): return "unavailable: \(reason)"
        case .starting(let step):      return "starting: \(step)"
        case .ready:                   return "ready"
        case .failed(let reason):      return "failed: \(reason)"
        }
    }

    func reportText(audioRoute: String?) -> String {
        var l: [String] = []
        l.append("BudsLink Bluetooth report")
        l.append("Generated: \(Date().formatted())")
        l.append("iOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        l.append("Audio route: \(audioRoute ?? "none")")
        l.append("BLE link: \(String(describing: connection))")
        if let rssi = rssi { l.append("RSSI: \(rssi) dBm") }
        l.append("Discovery complete: \(discoveryComplete)")
        l.append("OPO control session: \(opoStateDescription)")
        l.append("Standard battery service: \(String(describing: batteryAvailability))")
        for (k, v) in deviceInfo.sorted(by: { $0.key < $1.key }) { l.append("\(k): \(v)") }
        l.append("")
        l.append("GATT services (\(services.count)):")
        for s in services {
            l.append("[\(s.uuid)] \(s.name ?? "Unknown service")")
            for c in s.characteristics {
                l.append("    \(c.uuid)  \(c.name ?? "Unknown")  (\(c.properties.joined(separator: ", ")))")
            }
        }
        if let errorMessage = errorMessage { l.append(""); l.append("Last error: \(errorMessage)") }
        l.append("")
        l.append("Event log (the REGISTER token is never recorded; review before sharing):")
        l.append(OPOLog.shared.text)
        return l.joined(separator: "\n")
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
            if wantConnection { locate() } else { connection = .idle }
        case .poweredOff:
            peripheral = nil
            known = [:]
            clearDeviceData()
            connection = .bluetoothOff
        case .unauthorized:
            connection = .unauthorized
        case .unsupported:
            connection = .unsupported
        default:
            break      // .unknown / .resetting: wait for the next update
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? p.name
        known[p.identifier] = p
        if nameMatches(name) || isKnownDevice(name) {
            OPOLog.shared.add("BLE", "Found: " + (name ?? "earbuds"))
            connect(p)
        } else if let name = name, !name.isEmpty, !candidates.contains(where: { $0.id == p.identifier }),
                  candidates.count < 20 {
            candidates.append(Candidate(id: p.identifier, name: name))
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        guard p.identifier == peripheral?.identifier else { return }
        UserDefaults.standard.set(p.identifier.uuidString, forKey: Self.savedKey)
        connectAttempts = 0
        clearDeviceData()
        opo.resetForNewConnection()
        connection = .connected(p.name ?? targetName ?? "Earbuds")
        lastSeen = Date()
        let shownName = p.name ?? "earbuds"
        OPOLog.shared.add("BLE", "Peripheral connected: " + shownName)
        OPOLog.shared.add("BLE", "Discovering services...")
        opo.markUnavailable("Discovering services…")
        p.discoverServices(nil)       // nil: discover everything, then decide capabilities from the result
        p.readRSSI()
        startRSSITimer()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        guard p.identifier == peripheral?.identifier else { return }
        let detail = error.map { ": " + $0.localizedDescription } ?? ""
        OPOLog.shared.add("BLE", "Disconnected" + detail)
        clearDeviceData()
        opo.markUnavailable("The earbuds disconnected from BLE (case closed, out of range, or another app took the connection).")
        guard wantConnection else { connection = .idle; return }
        connection = .waiting(p.name ?? targetName ?? "Earbuds")
        central.connect(p, options: nil)   // stays pending; fires when the earbuds return (not a retry loop)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        connectAttempts += 1
        let reason = error?.localizedDescription ?? "Couldn't connect to the earbuds."
        OPOLog.shared.add("BLE", "Connect failed (\(connectAttempts) of \(Self.maxConnectAttempts)): \(reason)")
        errorMessage = reason
        connection = .idle
        guard connectAttempts < Self.maxConnectAttempts else {
            errorMessage = "\(reason) Gave up after \(Self.maxConnectAttempts) tries. Tap Retry."
            return
        }
        let delay = Double(connectAttempts) * 2
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.locate() }
    }
}

// MARK: - CBPeripheralDelegate

extension BLEEarbudSession: CBPeripheralDelegate {

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            OPOLog.shared.add("BLE", "Service discovery failed: \(error.localizedDescription)")
            batteryAvailability = .failed(error.localizedDescription)
            opo.markUnavailable("Service discovery failed: \(error.localizedDescription). Close other apps that control the earbuds and tap Retry.")
            return
        }
        let list = p.services ?? []
        pendingServices = list.count
        if list.isEmpty { finishDiscovery(); return }
        OPOLog.shared.add("BLE", "Discovering characteristics...")
        list.forEach { p.discoverCharacteristics(nil, for: $0) }
    }

    func peripheral(_ p: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        OPOLog.shared.add("BLE", "Services changed; discovering again")
        clearDeviceData()
        p.discoverServices(nil)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        defer {
            pendingServices -= 1
            if pendingServices <= 0 && !discoveryComplete { finishDiscovery() }
        }
        if let error = error { errorMessage = error.localizedDescription; return }

        let chars = service.characteristics ?? []
        for c in chars {
            OPOLog.shared.add("BLE", "Service \(service.uuid.uuidString) characteristic \(c.uuid.uuidString) [\(GATTNames.properties(of: c).joined(separator: ","))]")
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
            OPOLog.shared.add("BLE", "Read/notify failed on \(String(c.uuid.uuidString.prefix(8))): \(error.localizedDescription)")
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

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        let id = ObjectIdentifier(c)
        guard opoInboundChars[id] != nil else {
            if let error = error { errorMessage = "Notify failed (\(c.uuid.uuidString)): \(error.localizedDescription)" }
            return
        }
        pendingNotify.remove(id)
        if let error = error {
            OPOLog.shared.add("BLE", "Subscribe failed on \(String(c.uuid.uuidString.prefix(8))): \(error.localizedDescription)")
            if opoCriticalNotify.contains(id) {
                opoProfile = nil
                opo.markUnavailable("Could not subscribe to the earbuds' reply channel (\(c.uuid.uuidString)): \(error.localizedDescription). Replies could not be received, so no commands are sent.")
            }
            return
        }
        maybeStartOPO()
    }

    func peripheral(_ p: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        guard error == nil, RSSI.intValue != 127 else { return }      // 127 means "not available"
        rssi = RSSI.intValue
        lastSeen = Date()
    }
}
