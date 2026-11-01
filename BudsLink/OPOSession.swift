import Combine
import CoreBluetooth
import Foundation

/// Implemented by BLEEarbudSession. The ONLY thing OPOSession can do to the hardware is call this, and the
/// implementation writes (without response) to the single discovered OPO write characteristic, nothing else.
protocol OPOTransport: AnyObject {
    /// false = could not write right now (link down, or the BLE write queue is full)
    func opoWrite(_ data: Data) -> Bool
}

enum OPOError: Error, Equatable {
    case timeout, writeFailed, disconnected, sessionNotReady

    var message: String {
        switch self {
        case .timeout:         return "no reply from the earbuds"
        case .writeFailed:     return "Bluetooth could not send the command"
        case .disconnected:    return "the earbuds disconnected"
        case .sessionNotReady: return "BLE control session is not ready"
        }
    }
}

/// Owns the OPO control session: HELLO, REGISTER, then paced request/response commands.
/// Being connected over BLE does NOT mean the session is ready. `state` says which it is.
final class OPOSession: ObservableObject {

    enum State: Equatable {
        case unavailable(String)    // no BLE link / service missing / model has no profile. String = exact reason
        case starting(String)       // handshake in progress (current step)
        case ready                  // HELLO + REGISTER were answered
        case failed(String)         // handshake failed after retries. String = diagnosis
    }

    @Published private(set) var state: State = .unavailable("Waiting for the Bluetooth LE link")
    private(set) var profile: OPODeviceProfile?
    let inbound = PassthroughSubject<OPOInbound, Never>()
    weak var transport: OPOTransport?

    // Pacing taken from the published timing notes: commands sent too quickly are dropped silently.
    private let registerGap: TimeInterval = 1.5
    private let commandGap: TimeInterval = 1.0
    private let maxAutoAttempts = 3

    private struct Request {
        let name: String
        let wire: Data
        let logLine: String          // what is written to the log (never contains the token)
        let seq: UInt8
        let match: (OPOInbound) -> Bool
        let timeout: TimeInterval
        var retriesLeft: Int
        let minGap: TimeInterval
        let duringHandshake: Bool
        let completion: (Result<OPOInbound, OPOError>) -> Void
    }

    private var queue: [Request] = []
    private var inFlight: Request?
    private var timeoutWork: DispatchWorkItem?
    private var lastWrite = Date.distantPast
    private var seqCounter: UInt8 = 0x44
    private var readers: [String: OPOFrameReader] = [:]
    private var generation = 0          // bumps on every reset so stale timers do nothing
    private var attempts = 0

    init() {
        let problems = OPOSelfCheck.run()
        if problems.isEmpty {
            OPOLog.shared.add("OPO", "Self-check passed: packet builders match the published byte sequences")
        } else {
            OPOLog.shared.add("OPO", "SELF-CHECK FAILED: \(problems.joined(separator: " | "))")
        }
    }

    // MARK: Lifecycle

    func nextSeq() -> UInt8 {
        seqCounter = seqCounter &+ 2
        return seqCounter
    }

    /// Called when the BLE link goes away or capability discovery decided the session cannot exist.
    func markUnavailable(_ reason: String) {
        generation += 1
        timeoutWork?.cancel()
        timeoutWork = nil
        readers = [:]
        let pending = queue
        let running = inFlight
        queue = []
        inFlight = nil
        profile = nil
        lastProfile = nil
        if state != .unavailable(reason) {
            OPOLog.shared.add("OPO", "Unavailable: \(reason)")
            state = .unavailable(reason)
        }
        running?.completion(.failure(.disconnected))
        pending.forEach { $0.completion(.failure(.disconnected)) }
    }

    func resetForNewConnection() {
        attempts = 0
    }

    func markStarting(_ step: String) {
        state = .starting(step)
    }

    func retry() {
        guard let profile = profile ?? lastProfile else {
            OPOLog.shared.add("OPO", "Retry ignored: no profile (service or model not supported)")
            return
        }
        attempts = 0
        begin(profile: profile)
    }

    private var lastProfile: OPODeviceProfile?

    /// Starts HELLO then REGISTER. Both are answered-or-retried; nothing else is sent until both succeed.
    func begin(profile: OPODeviceProfile) {
        guard transport != nil else { markUnavailable("No Bluetooth transport"); return }
        generation += 1
        timeoutWork?.cancel()
        queue = []
        inFlight = nil
        readers = [:]
        self.profile = profile
        lastProfile = profile
        attempts += 1
        state = .starting("Sending HELLO")
        OPOLog.shared.add("OPO", "Handshake started (attempt \(attempts) of \(maxAutoAttempts))")
        OPOLog.shared.add("OPO", "Sending HELLO")
        let gen = generation

        enqueue(name: "HELLO", wire: Data(OPOCommand.hello), logLine: "HELLO \(OPOCommand.hello.hex)",
                seq: 0x23, match: { _ in true }, timeout: 3, retries: 2, minGap: 0, handshake: true) { [weak self] result in
            guard let self = self, gen == self.generation else { return }
            switch result {
            case .failure(let e):
                self.handshakeFailed("HELLO got no answer (\(e.message))")
            case .success:
                OPOLog.shared.add("OPO", "Handshake response received (HELLO)")
                self.state = .starting("Registering session")
                OPOLog.shared.add("OPO", "Registering session")
                let reg = OPOCommand.register()
                self.enqueue(name: "REGISTER", wire: Data(reg.wireBytes),
                             logLine: "REGISTER \(String(format: "cat=%02X sub=%02X seq=%02X", reg.cat, reg.sub, reg.seq)) [token redacted]",
                             seq: reg.seq, match: { _ in true }, timeout: 3, retries: 2,
                             minGap: self.registerGap, handshake: true) { [weak self] regResult in
                    guard let self = self, gen == self.generation else { return }
                    switch regResult {
                    case .failure(let e):
                        self.handshakeFailed("REGISTER got no answer (\(e.message))")
                    case .success:
                        // An answer proves the control channel is alive. The first real command (ANC query)
                        // is what proves the registration was accepted, and its failure is reported there.
                        OPOLog.shared.add("OPO", "Handshake response received (REGISTER); session ready")
                        self.state = .ready
                        self.pump()
                    }
                }
            }
        }
    }

    private func handshakeFailed(_ detail: String) {
        OPOLog.shared.add("OPO ERROR", "Handshake failed: \(detail)")
        if attempts < maxAutoAttempts, let profile = lastProfile {
            let delay = Double(attempts) * 3
            state = .starting("Retrying in \(Int(delay)) s")
            let gen = generation
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self = self, gen == self.generation else { return }
                self.begin(profile: profile)
            }
        } else {
            state = .failed("\(detail). The earbuds' control channel did not answer. Another controller (for example HeyMelody on a phone that is connected to the earbuds) may be using it, or this unit did not accept the registration. Tap Retry after closing other controllers.")
        }
    }

    // MARK: Requests

    /// Queue a command. It is written only when the session is ready, spaced from the previous write,
    /// retried on timeout, and completed exactly once (reply, timeout, or disconnect).
    func request(_ packet: OPOPacket, name: String, timeout: TimeInterval = 3, retries: Int = 1,
                 match: @escaping (OPOInbound) -> Bool,
                 completion: @escaping (Result<OPOInbound, OPOError>) -> Void) {
        guard state == .ready else { completion(.failure(.sessionNotReady)); return }
        OPOLog.shared.add("OPO", "Queued \(name)")
        enqueue(name: name, wire: Data(packet.wireBytes), logLine: "\(name) \(packet.wireBytes.hex)",
                seq: packet.seq, match: match, timeout: timeout, retries: retries,
                minGap: commandGap, handshake: false, completion: completion)
    }

    private func enqueue(name: String, wire: Data, logLine: String, seq: UInt8,
                         match: @escaping (OPOInbound) -> Bool, timeout: TimeInterval, retries: Int,
                         minGap: TimeInterval, handshake: Bool,
                         completion: @escaping (Result<OPOInbound, OPOError>) -> Void) {
        queue.append(Request(name: name, wire: wire, logLine: logLine, seq: seq, match: match,
                             timeout: timeout, retriesLeft: retries, minGap: minGap,
                             duringHandshake: handshake, completion: completion))
        pump()
    }

    private func pump() {
        guard inFlight == nil else { return }
        guard let index = queue.firstIndex(where: { $0.duringHandshake || state == .ready }) else { return }
        let request = queue.remove(at: index)
        inFlight = request
        let wait = max(0, request.minGap - Date().timeIntervalSince(lastWrite))
        let gen = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            self?.write(generation: gen, tries: 0)
        }
    }

    private func write(generation gen: Int, tries: Int) {
        guard gen == generation, let request = inFlight else { return }
        guard let transport = transport else { finish(.failure(.disconnected)); return }
        if transport.opoWrite(request.wire) {
            lastWrite = Date()
            OPOLog.shared.add("OPO", "TX \(request.logLine)")
            armTimeout(generation: gen, seconds: request.timeout)
        } else if tries < 8 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.write(generation: gen, tries: tries + 1)
            }
        } else {
            finish(.failure(.writeFailed))
        }
    }

    private func armTimeout(generation gen: Int, seconds: TimeInterval) {
        timeoutWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.timedOut(generation: gen) }
        timeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func timedOut(generation gen: Int) {
        guard gen == generation, var request = inFlight else { return }
        if request.retriesLeft > 0 {
            request.retriesLeft -= 1
            inFlight = request
            OPOLog.shared.add("OPO", "Timeout waiting for \(request.name); retrying")
            write(generation: gen, tries: 0)
        } else {
            OPOLog.shared.add("OPO ERROR", "Handshake/command timeout waiting for \(request.name); giving up")
            finish(.failure(.timeout))
        }
    }

    private func finish(_ result: Result<OPOInbound, OPOError>) {
        timeoutWork?.cancel()
        timeoutWork = nil
        guard let request = inFlight else { return }
        inFlight = nil
        request.completion(result)
        pump()
    }

    // MARK: Inbound

    /// Every notification from the OPO / telemetry characteristics arrives here.
    func handleInbound(_ data: Data, source: String) {
        OPOLog.shared.add("OPO", "RX \(source) \(data.hex)")
        var reader = readers[source] ?? OPOFrameReader()
        let packets = reader.append(data)
        readers[source] = reader
        if packets.isEmpty {
            deliver(OPOInbound(raw: data, packet: nil, source: source))
        } else {
            for packet in packets {
                deliver(OPOInbound(raw: data, packet: packet, source: source))
            }
        }
    }

    private func deliver(_ item: OPOInbound) {
        inbound.send(item)
        if let request = inFlight, request.match(item) {
            finish(.success(item))
        }
    }
}
