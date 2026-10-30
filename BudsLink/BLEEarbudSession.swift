import CoreBluetooth
import Combine
import Foundation

/// Discovers, connects to, and interrogates the earbuds' BLE (GATT) side.
///
/// Pipeline:  find peripheral -> connect -> discover ALL services/characteristics ->
///            decide capabilities from what is really there -> read/subscribe -> publish.
///
/// Nothing here is hardcoded to a device model: the peripheral is matched against the NAME OF THE
/// CURRENT SYSTEM AUDIO ROUTE (real evidence), or chosen by the user from real scan results.
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
    @Published private(set) var noiseAvailability: FeatureAvailability = .checking
    @Published private(set) var noiseModes: [NoiseMode] = []
    @Published private(set) var currentNoiseMode: NoiseMode?
    @Published private(set) var rssi: Int?
    @Published private(set) var lastSeen: Date?
    @Published private(set) var errorMessage: String?

    static let infoOrder = ["Manufacturer", "Model", "Firmware", "Hardware", "Software", "Serial"]

    // MARK: UUIDs (Bluetooth SIG assigned numbers)
    private static let batteryService = CBUUID(string: "180F")
    private static let deviceInfoService = CBUUID(string: "180A")
    private static let batteryLevel = CBUUID(string: "2A19")
    private static let batteryPowerState = CBUUID(string: "2A1A")
    private static let userDescription = CBUUID(string: "2901")        // Characteristic User Description
    private static let presentationFormat = CBUUID(string: "2904")     // Characteristic Presentation Format
    private static let infoLabels: [CBUUID: String] = [
        CBUUID(string: "2A29"): "Manufacturer", CBUUID(string: "2A24"): "Model",
        CBUUID(string: "2A26"): "Firmware",     CBUUID(string: "2A27"): "Hardware",
        CBUUID(string: "2A28"): "Software",     CBUUID(string: "2A25"): "Serial"
    ]
    private static let savedKey = "BudsLink.lastPeripheralID"

    // MARK: Private state
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var known: [UUID: CBPeripheral] = [:]          // CoreBluetooth needs strong references
    private var targetName: String?
    private var wantConnection = false
    private var scanStop: DispatchWorkItem?
    private var rssiTimer: Timer?
    private var pendingServices = 0
    private var provider: NoiseControlProvider?

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
        wantConnection = true
        locate()
    }

    func select(_ candidate: Candidate) {
        guard let p = known[candidate.id] else { return }
        connect(p)
    }

    func setNoiseMode(_ mode: NoiseMode) {
        provider?.set(mode)        // no optimistic update: UI follows what the device reports
    }

    // MARK: Finding the peripheral

    private func nameMatches(_ other: String?) -> Bool {
        guard let t = targetName?.lowercased(), !t.isEmpty,
              let o = other?.lowercased(), !o.isEmpty else { return false }
        return t == o || t.contains(o) || o.contains(t)
    }

    private func locate() {
        guard wantConnection, central.state == .poweredOn else { return }
        if let p = peripheral, p.state == .connected || p.state == .connecting { return }

        // 1. Remembered device: connect() stays pending and fires when the earbuds come back,
        //    so reconnects work without restarting the app.
        if let id = UserDefaults.standard.string(forKey: Self.savedKey).flatMap(UUID.init(uuidString:)),
           let saved = central.retrievePeripherals(withIdentifiers: [id]).first,
           targetName == nil || nameMatches(saved.name) {
            connect(saved, pending: true)
            return
        }

        // 2. Peripherals the system already holds a BLE link to.
        let systemConnected = central.retrieveConnectedPeripherals(
            withServices: [Self.batteryService, Self.deviceInfoService])
        for p in systemConnected { known[p.identifier] = p }
        if let match = systemConnected.first(where: { nameMatches($0.name) }) {
            connect(match)
            return
        }

        // 3. Scan, but only when we have a real audio-route name to look for.
        guard targetName != nil else { connection = .idle; return }
        connection = .searching
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        scanStop?.cancel()
        let stop = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.central.stopScan()
            if self.connection == .searching { self.connection = .idle }
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
        provider = nil
        noiseModes = []
        currentNoiseMode = nil
        rssi = nil
        discoveryComplete = false
        pendingServices = 0
        batteryAvailability = .checking
        noiseAvailability = .checking
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
        attachNoiseControl()
    }

    private func attachNoiseControl() {
        guard let p = peripheral else { return }
        let all = p.services ?? []
        for providerType in NoiseControlRegistry.providers() where providerType.matches(services: all) {
            let instance = providerType.init(peripheral: p, services: all)
            instance.onModeChange = { [weak self] mode in self?.currentNoiseMode = mode }
            provider = instance
            noiseModes = instance.supportedModes
            noiseAvailability = .supported
            instance.start()
            return
        }
        noiseAvailability = .notExposed
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

    func reportText(audioRoute: String?) -> String {
        var l: [String] = []
        l.append("BudsLink Bluetooth report")
        l.append("Generated: \(Date().formatted())")
        l.append("iOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        l.append("Audio route: \(audioRoute ?? "none")")
        l.append("BLE link: \(String(describing: connection))")
        if let rssi = rssi { l.append("RSSI: \(rssi) dBm") }
        l.append("Discovery complete: \(discoveryComplete)")
        l.append("Battery: \(String(describing: batteryAvailability))")
        for b in batteries {
            l.append("  \(b.role.title): \(b.percent.map { "\($0)%" } ?? "no value yet")"
                     + (b.charging == true ? " (charging)" : ""))
        }
        l.append("Noise control: \(String(describing: noiseAvailability))")
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
        return l.joined(separator: "\n")
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
        if nameMatches(name) {
            connect(p)
        } else if let name, !name.isEmpty, !candidates.contains(where: { $0.id == p.identifier }),
                  candidates.count < 20 {
            candidates.append(Candidate(id: p.identifier, name: name))
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        guard p.identifier == peripheral?.identifier else { return }
        UserDefaults.standard.set(p.identifier.uuidString, forKey: Self.savedKey)
        clearDeviceData()
        connection = .connected(p.name ?? targetName ?? "Earbuds")
        lastSeen = Date()
        p.discoverServices(nil)       // nil: discover everything, then decide capabilities from the result
        p.readRSSI()
        startRSSITimer()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        guard p.identifier == peripheral?.identifier else { return }
        clearDeviceData()
        guard wantConnection else { connection = .idle; return }
        connection = .waiting(p.name ?? targetName ?? "Earbuds")
        central.connect(p, options: nil)   // stays pending; fires when the earbuds return
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        errorMessage = error?.localizedDescription ?? "Couldn't connect to the earbuds."
        connection = .idle
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.locate() }
    }
}

// MARK: - CBPeripheralDelegate

extension BLEEarbudSession: CBPeripheralDelegate {

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            batteryAvailability = .failed(error.localizedDescription)
            noiseAvailability = .failed(error.localizedDescription)
            return
        }
        let list = p.services ?? []
        pendingServices = list.count
        if list.isEmpty { finishDiscovery(); return }
        list.forEach { p.discoverCharacteristics(nil, for: $0) }
    }

    func peripheral(_ p: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        clearDeviceData()
        p.discoverServices(nil)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        defer {
            pendingServices -= 1
            if pendingServices <= 0 && !discoveryComplete { finishDiscovery() }
        }
        if let error { errorMessage = error.localizedDescription; return }

        let chars = service.characteristics ?? []
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
        if let error {
            errorMessage = "Read failed (\(c.uuid.uuidString)): \(error.localizedDescription)"
            return
        }
        lastSeen = Date()
        if provider?.handle(update: c) == true { return }
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
        guard error == nil, let owner else { return }
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
        if let error { errorMessage = "Notify failed (\(c.uuid.uuidString)): \(error.localizedDescription)" }
    }

    func peripheral(_ p: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        guard error == nil, RSSI.intValue != 127 else { return }      // 127 means "not available"
        rssi = RSSI.intValue
        lastSeen = Date()
    }
}
