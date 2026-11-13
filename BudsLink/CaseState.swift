import SwiftUI
import Combine

// MARK: - Case state

enum CaseState: Equatable {
    case unknown
    case closed
    case open

    var title: String {
        switch self {
        case .unknown: return "Unknown"
        case .closed:  return "Closed"
        case .open:    return "Open"
        }
    }
}

/// How the app knows. These are kept apart so the UI never presents a guess as a fact.
enum CaseEvidence: String {
    /// The earbuds themselves reported the lid state. NOT available yet (see OPOCaseSignalDecoder).
    case reported
    /// Derived from the earbuds becoming unreachable, then reachable again.
    case inferred

    var summary: String {
        switch self {
        case .reported: return "reported by the earbuds"
        case .inferred: return "inferred from reconnection"
        }
    }
}

// MARK: - Trigger rule (pure, no UI, no Bluetooth)

/// Fires EXACTLY ONCE per closed -> open cycle.
///   - unknown -> open never fires (we cannot know it was closed, e.g. the app launched with the buds already out)
///   - open -> open never fires (the case simply stays open)
///   - a cooldown stops rapid flapping from producing several popups
struct CaseTransitionDetector {
    private(set) var lastDefinite: CaseState = .unknown
    private var lastTrigger = Date.distantPast
    let cooldown: TimeInterval

    init(cooldown: TimeInterval) {
        self.cooldown = cooldown
    }

    /// Returns true when this input is a new closed -> open transition that should show the popup.
    mutating func ingest(_ state: CaseState, now: Date) -> Bool {
        switch state {
        case .unknown:
            return false
        case .closed:
            lastDefinite = .closed
            return false
        case .open:
            let wasClosed = (lastDefinite == .closed)
            lastDefinite = .open
            guard wasClosed else { return false }
            guard now.timeIntervalSince(lastTrigger) >= cooldown else { return false }
            lastTrigger = now
            return true
        }
    }
}

// MARK: - INTEGRATION POINT: a real "case opened" signal

/// INTEGRATION POINT.
///
/// No verified message that reports the charging-case LID state is known for the OnePlus Nord Buds 3 Pro, so this
/// returns nil for every frame. It is wired up: every notification from the earbuds' control channel passes through
/// here, so the moment a lid frame is decoded the popup switches from "inferred" to "reported" by itself.
///
/// To implement it for real:
///   1. Open the Bluetooth Report, tap "Run BLE diagnostic", then open and close the charging case a few times.
///   2. Find the "OPO RX …" log lines that appear only when the lid moves (they show the raw bytes).
///   3. Decode that frame here and return `.open` / `.closed`.
/// Until then nothing here claims to know the lid state.
enum OPOCaseSignalDecoder {
    static func decode(_ inbound: OPOInbound) -> CaseState? {
        return nil
    }
}

// MARK: - Single source of truth + popup scheduling

final class CaseAnimationManager: ObservableObject {

    /// Popup stays on screen about this long, then dismisses itself.
    static let displayDuration: TimeInterval = 5.0
    /// The earbuds must stay unreachable this long before the case counts as "closed" (ignores brief dropouts).
    static let closeDebounce: TimeInterval = 3.0

    @Published private(set) var caseState: CaseState = .unknown
    @Published private(set) var evidence: CaseEvidence?
    @Published private(set) var isPopupVisible = false
    @Published private(set) var popupEvidence: CaseEvidence = .inferred
    @Published private(set) var isPreview = false
    @Published private(set) var popupID = UUID()

    @Published var popupEnabled: Bool {
        didSet { UserDefaults.standard.set(popupEnabled, forKey: Keys.enabled) }
    }
    @Published var inferredTriggerEnabled: Bool {
        didSet { UserDefaults.standard.set(inferredTriggerEnabled, forKey: Keys.inferred) }
    }

    private enum Keys {
        static let enabled = "BudsLink.casePopupEnabled"
        static let inferred = "BudsLink.casePopupInferredTrigger"
    }

    private var detector = CaseTransitionDetector(cooldown: 6)
    private var hasReportedSignal = false
    private var dismissWork: DispatchWorkItem?
    private var closeWork: DispatchWorkItem?
    private var bag = Set<AnyCancellable>()
    private var bound = false

    init() {
        let defaults = UserDefaults.standard
        popupEnabled = defaults.object(forKey: Keys.enabled) as? Bool ?? true
        inferredTriggerEnabled = defaults.object(forKey: Keys.inferred) as? Bool ?? true
    }

    // MARK: Inputs

    /// Connects the manager to the live Bluetooth state. Safe to call more than once.
    func bind(route: AudioRouteObserver, ble: BLEEarbudSession) {
        guard !bound else { return }
        bound = true

        // Inferred signal: reachable = audio route is Bluetooth OR a BLE link exists. Both are real evidence.
        Publishers.CombineLatest(route.$route, ble.$bleLinked)
            .map { currentRoute, linked in currentRoute != nil || linked }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] reachable in self?.reachabilityChanged(reachable) }
            .store(in: &bag)

        // Real signal (integration point): every control-channel frame is offered to the decoder.
        ble.opo.inbound
            .receive(on: DispatchQueue.main)
            .sink { [weak self] item in self?.consumeReported(item) }
            .store(in: &bag)
    }

    private func reachabilityChanged(_ reachable: Bool) {
        closeWork?.cancel()
        if reachable {
            update(.open, evidence: .inferred)
        } else {
            let work = DispatchWorkItem { [weak self] in self?.update(.closed, evidence: .inferred) }
            closeWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.closeDebounce, execute: work)
        }
    }

    private func consumeReported(_ item: OPOInbound) {
        guard let state = OPOCaseSignalDecoder.decode(item) else { return }
        hasReportedSignal = true
        update(state, evidence: .reported)
    }

    /// The ONLY place the case state changes. Everything else (UI, popup) reads it.
    func update(_ state: CaseState, evidence newEvidence: CaseEvidence) {
        // Once a real signal exists, inferred guesses are ignored entirely.
        if newEvidence == .inferred && hasReportedSignal { return }

        if caseState != state {
            OPOLog.shared.add("CASE", "Case state \(caseState.title) -> \(state.title) (\(newEvidence.summary))")
        }
        caseState = state
        evidence = newEvidence

        guard detector.ingest(state, now: Date()) else { return }
        OPOLog.shared.add("CASE", "Closed -> open detected (\(newEvidence.summary))")

        guard popupEnabled else {
            OPOLog.shared.add("CASE", "Popup is switched off; not shown")
            return
        }
        if newEvidence == .inferred && !inferredTriggerEnabled {
            OPOLog.shared.add("CASE", "Inferred triggers are switched off; not shown")
            return
        }
        present(newEvidence, preview: false)
    }

    // MARK: Popup lifecycle

    /// Test the animation without waiting for a case event. The popup says "Preview" and shows real current values.
    func preview() {
        present(evidence ?? .inferred, preview: true)
    }

    func dismiss() {
        dismissWork?.cancel()
        dismissWork = nil
        guard isPopupVisible else { return }
        withAnimation(.easeIn(duration: 0.35)) { isPopupVisible = false }
    }

    private func present(_ shownEvidence: CaseEvidence, preview: Bool) {
        dismissWork?.cancel()
        popupEvidence = shownEvidence
        isPreview = preview
        popupID = UUID()       // a fresh identity restarts the opening animation for every event
        withAnimation(.spring(response: 0.55, dampingFraction: 0.82)) { isPopupVisible = true }

        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.displayDuration, execute: work)
    }
}
