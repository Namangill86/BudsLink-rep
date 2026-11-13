import SwiftUI

// MARK: - Data the popup shows (all of it comes from the live hub; nothing here is a placeholder value)

struct CasePopupInfo: Equatable {
    var deviceName: String
    var audioText: String
    var audioConnected: Bool
    var controlText: String
    var controlReady: Bool
    /// nil = the earbuds have not reported this value (yet). The ring then shows a dash, never an invented number.
    var left: Int?
    var right: Int?
    var caseLevel: Int?
    var leftCharging: Bool?
    var rightCharging: Bool?
    var caseCharging: Bool?
}

extension EarbudHub {
    /// Live snapshot for the popup. Battery values come from the same managers as the rest of the app
    /// (OPO battery first, the standard BLE Battery Service as fallback).
    var casePopupInfo: CasePopupInfo {
        func standard(_ role: BatteryRole) -> BatteryReading? {
            ble.batteries.first { $0.role == role }
        }
        return CasePopupInfo(
            deviceName: displayName ?? "Earbuds",
            audioText: audioDescription,
            audioConnected: audioConnected,
            controlText: controlDescription,
            controlReady: controlReady,
            left: battery.left?.percent ?? standard(.left)?.percent,
            right: battery.right?.percent ?? standard(.right)?.percent,
            caseLevel: battery.caseValue?.percent ?? standard(.chargingCase)?.percent,
            leftCharging: battery.left?.charging ?? standard(.left)?.charging,
            rightCharging: battery.right?.charging ?? standard(.right)?.charging,
            caseCharging: battery.caseValue?.charging ?? standard(.chargingCase)?.charging)
    }
}

// MARK: - The popup

struct CaseOpenPopupView: View {
    let info: CasePopupInfo
    let evidence: CaseEvidence
    let isPreview: Bool
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var caseShown = false
    @State private var lidAngle: Double = 0
    @State private var budsUp = false
    @State private var gaugesOn = false
    @State private var glow = false

    /// "Charging case opened" is only claimed when the earbuds themselves reported it.
    private var title: String { evidence == .reported ? "Charging case opened" : "Earbuds ready" }
    private var subtitle: String {
        evidence == .reported ? "Reported by the earbuds" : "Case opened or earbuds reconnected"
    }

    private var statusColor: Color {
        if info.controlReady { return .green }
        return info.audioConnected ? .blue : .gray
    }

    var body: some View {
        VStack(spacing: 14) {
            header

            CaseIllustration(lidAngle: lidAngle, budsUp: budsUp, ledColor: statusColor)
                .scaleEffect(caseShown ? 1 : 0.85)
                .opacity(caseShown ? 1 : 0)
                .frame(height: 128)

            VStack(spacing: 5) {
                Text(info.deviceName)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                statusLine(color: info.audioConnected ? .green : .gray, text: "Audio · " + info.audioText)
                statusLine(color: info.controlReady ? .green : .orange, text: "BLE control · " + info.controlText)
            }

            HStack(spacing: 10) {
                BatteryRing(title: "Left", value: info.left, charging: info.leftCharging, on: gaugesOn)
                BatteryRing(title: "Right", value: info.right, charging: info.rightCharging, on: gaugesOn)
                BatteryRing(title: "Case", value: info.caseLevel, charging: info.caseCharging, on: gaugesOn)
            }
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 18)
        .frame(maxWidth: 380)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 32, style: .continuous))
        .background { glowLayer }
        .overlay(
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
        .shadow(color: .black.opacity(0.22), radius: 24, x: 0, y: 12)
        .padding(.horizontal, 16)
        .contentShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
        .onTapGesture(perform: onDismiss)
        .task { await runTimeline() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Double tap to dismiss")
    }

    // MARK: Pieces

    private var header: some View {
        VStack(spacing: 2) {
            HStack(spacing: 6) {
                Text(title).font(.headline)
                if isPreview {
                    Text("PREVIEW")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.orange.opacity(0.25)))
                        .foregroundStyle(.orange)
                }
            }
            Text(subtitle).font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func statusLine(color: Color, text: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }

    private var glowLayer: some View {
        Circle()
            .fill(statusColor.opacity(0.45))
            .frame(width: 230, height: 230)
            .blur(radius: 50)
            .scaleEffect(glow ? 1.12 : 0.85)
            .opacity(caseShown ? 1 : 0)
            .allowsHitTesting(false)
    }

    private var accessibilitySummary: String {
        func part(_ name: String, _ value: Int?) -> String {
            guard let value = value else { return name + " not reported" }
            return name + " " + String(value) + " percent"
        }
        return title + ". " + info.deviceName + ". "
            + part("Left", info.left) + ", " + part("Right", info.right) + ", " + part("Case", info.caseLevel) + "."
    }

    // MARK: Animation timeline
    // case appears closed -> lid opens (spring) -> earbuds rise (bouncy spring) -> battery rings fill to the real values

    @MainActor private func runTimeline() async {
        if reduceMotion {
            caseShown = true
            lidAngle = 105
            budsUp = true
            gaugesOn = true
            return
        }
        try? await Task.sleep(nanoseconds: 120_000_000)
        guard !Task.isCancelled else { return }
        withAnimation(.spring(response: 0.55, dampingFraction: 0.8)) { caseShown = true }
        withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) { glow = true }

        try? await Task.sleep(nanoseconds: 380_000_000)
        guard !Task.isCancelled else { return }
        withAnimation(.spring(response: 0.9, dampingFraction: 0.68)) { lidAngle = 105 }

        try? await Task.sleep(nanoseconds: 330_000_000)
        guard !Task.isCancelled else { return }
        withAnimation(.spring(response: 0.6, dampingFraction: 0.62)) { budsUp = true }

        try? await Task.sleep(nanoseconds: 380_000_000)
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.9)) { gaugesOn = true }
    }
}

// MARK: - Case illustration (original artwork, drawn with SwiftUI shapes)

private struct CaseIllustration: View {
    let lidAngle: Double
    let budsUp: Bool
    let ledColor: Color

    private let width: CGFloat = 150
    private var lidProgress: Double { min(1, max(0, lidAngle / 105)) }

    var body: some View {
        ZStack {
            // Interior, visible once the lid is open
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(LinearGradient(colors: [Color.black.opacity(0.55), Color.black.opacity(0.25)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: width - 20, height: 34)
                .offset(y: -10)
                .opacity(lidProgress)

            // Earbuds rise out of the case (drawn behind the front panel so they look inside it)
            HStack(spacing: 26) {
                EarbudShape(mirrored: false).rotationEffect(.degrees(-10))
                EarbudShape(mirrored: true).rotationEffect(.degrees(10))
            }
            .offset(y: budsUp ? -16 : 20)
            .scaleEffect(budsUp ? 1 : 0.85)
            .opacity(budsUp ? 1 : 0)

            // Front of the case with its status LED
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.96), Color(white: 0.80)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: width, height: 62)
                .overlay {
                    Circle()
                        .fill(ledColor)
                        .frame(width: 7, height: 7)
                        .shadow(color: ledColor, radius: 4)
                        .offset(y: 6)
                }
                .shadow(color: .black.opacity(0.18), radius: 6, x: 0, y: 4)
                .offset(y: 24)

            // Lid, hinged along its bottom edge
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.99), Color(white: 0.86)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: width, height: 56)
                .brightness(-0.28 * lidProgress)
                .rotation3DEffect(.degrees(-lidAngle), axis: (x: 1, y: 0, z: 0), anchor: .bottom, perspective: 0.5)
                .offset(y: -32)
        }
        .frame(width: width + 40, height: 130)
    }
}

private struct EarbudShape: View {
    let mirrored: Bool

    var body: some View {
        ZStack(alignment: .top) {
            Capsule()
                .fill(LinearGradient(colors: [Color.white, Color(white: 0.82)], startPoint: .top, endPoint: .bottom))
                .frame(width: 9, height: 30)
                .offset(x: mirrored ? -6 : 6, y: 14)
            Capsule()
                .fill(LinearGradient(colors: [Color.white, Color(white: 0.84)], startPoint: .top, endPoint: .bottom))
                .frame(width: 24, height: 30)
        }
        .frame(width: 28, height: 48)
        .shadow(color: .black.opacity(0.2), radius: 3, x: 0, y: 2)
    }
}

// MARK: - Battery ring (fills to the real value)

private struct BatteryRing: View {
    let title: String
    let value: Int?
    let charging: Bool?
    let on: Bool

    @State private var pulse = false

    private var fraction: Double {
        guard on, let v = value else { return 0 }
        return Double(min(max(v, 0), 100)) / 100
    }

    private var tint: Color {
        guard let v = value else { return .gray }
        if charging == true { return .green }
        if v >= 50 { return .green }
        return v >= 20 ? .orange : .red
    }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.12), lineWidth: 6)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(tint, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.9), value: fraction)

                if let v = value {
                    HStack(spacing: 1) {
                        if charging == true {
                            Image(systemName: "bolt.fill").font(.system(size: 9)).foregroundStyle(.green)
                        }
                        Text("\(v)%")
                            .font(.system(.footnote, design: .rounded).weight(.bold))
                            .contentTransition(.numericText())
                            .animation(.easeOut(duration: 0.6), value: v)
                    }
                    .opacity(on ? 1 : 0)
                    .animation(.easeOut(duration: 0.5), value: on)
                } else {
                    // Not reported (yet): a quiet pulsing dash, never an invented number.
                    Text("—")
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .foregroundStyle(.secondary)
                        .opacity(pulse ? 0.3 : 1)
                        .onAppear {
                            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
                        }
                }
            }
            .frame(width: 58, height: 58)

            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
