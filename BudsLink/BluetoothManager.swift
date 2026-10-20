import CoreBluetooth
import Combine

enum LinkState: Equatable {
    case unavailable, unauthorized, idle, scanning, connecting, connected
}

/// BLE-only. Classic audio streaming is handled by iOS and is invisible to apps.
final class BluetoothManager: NSObject, ObservableObject {
    @Published var state: LinkState = .idle
    @Published var batteryPercent: Int?          // nil = "Not reported"
    @Published var rssi: Int?
    @Published var lastSeen: Date?
    @Published var errorMessage: String?
    @Published var gattDump: [String] = []      // read-only report of what the buds expose over BLE

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var rssiTimer: Timer?
    private let batteryService = CBUUID(string: "180F")
    private let batteryLevel = CBUUID(string: "2A19")

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func startScan() {
        guard central.state == .poweredOn else { return }
        state = .scanning
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func disconnect() {
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        rssiTimer?.invalidate()
    }

    /// Catches earbuds already connected to iOS that expose the BLE Battery Service.
    func attachToConnected() {
        guard central.state == .poweredOn, peripheral == nil else { return }
        for p in central.retrieveConnectedPeripherals(withServices: [batteryService]) where isTarget(p.name) {
            peripheral = p; p.delegate = self; state = .connecting; central.connect(p)
        }
    }

    private func isTarget(_ name: String?) -> Bool {
        guard let n = name?.lowercased() else { return false }
        return n.contains("buds pro 3") || n.contains("buds 3 pro") || n.contains("oneplus buds 3")
    }
}

extension BluetoothManager: CBCentralManagerDelegate, CBPeripheralDelegate {
    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        switch c.state {
        case .poweredOn: state = .idle; errorMessage = nil; attachToConnected()
        case .unauthorized:
            state = .unauthorized
            errorMessage = "Bluetooth permission denied. Enable it in Settings > BudsLink."
        default:
            state = .unavailable
            errorMessage = "Bluetooth is off or unavailable. Turn it on in Control Center."
        }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = p.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
        guard isTarget(name) else { return }
        c.stopScan(); peripheral = p; p.delegate = self
        state = .connecting; c.connect(p)
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        state = .connected; lastSeen = Date()
        gattDump = []; p.discoverServices(nil)
        rssiTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in p.readRSSI() }
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        state = .idle; rssiTimer?.invalidate(); lastSeen = Date()
        errorMessage = "Earbuds disconnected."
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        for s in p.services ?? [] {
            gattDump.append("Service \(s.uuid.uuidString)")
            p.discoverCharacteristics(nil, for: s)
        }
        // No battery service -> batteryPercent stays nil and the UI says "Not reported".
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for ch in s.characteristics ?? [] { gattDump.append("  Char \(ch.uuid.uuidString) props=\(ch.properties.rawValue)") }
        for ch in s.characteristics ?? [] where ch.uuid == batteryLevel {
            p.readValue(for: ch); p.setNotifyValue(true, for: ch)
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        if ch.uuid == batteryLevel, let b = ch.value?.first { batteryPercent = Int(b); UserDefaults.standard.set(Int(b), forKey: "lastBattery"); lastSeen = Date() }
    }

    func peripheral(_ p: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        rssi = RSSI.intValue; lastSeen = Date()
    }
}
