import SwiftUI

// MARK: - "Why am I seeing this?"

/// A small link under a risk level that opens the explanation.
struct WhyButton: View {
    var tint: Color = Thermyx.Ink.ice
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Why am I seeing this?", systemImage: "questionmark.circle")
                .font(ThermyxFont.captionSmall.weight(.semibold))
                .foregroundStyle(tint)
                .frame(minHeight: Thermyx.minimumTapTarget, alignment: .leading)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Shows which readings set this level and how much to trust them.")
    }
}

/// Explains the current level from the live readings: which foot, which
/// signals counted and against what rule, how fresh the data is, how much to
/// trust it, and what to do next. It refreshes every second while open.
struct RiskExplanationSheet: View {
    @EnvironmentObject private var viewModel: ThermyxViewModel
    @ObservedObject var settings: ThermyxSettingsStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let explanation = viewModel.explanation(unit: settings.temperatureUnit, now: context.date)
                ScrollView {
                    VStack(alignment: .leading, spacing: Thermyx.Space.xl) {
                        header(explanation)
                        signals(explanation)
                        DeviceHealthStrip(now: context.date)
                        confidence(explanation)
                        baseline
                        nextStep(explanation)
                        Text("Thermyx is a wellness prototype, not a medical device. If you feel unwell, stop and get help whatever the level says.")
                            .font(ThermyxFont.captionSmall)
                            .foregroundStyle(Thermyx.Ink.textFaint)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(Thermyx.Space.screen)
                }
                .scrollIndicators(.hidden)
            }
            .background(Thermyx.Ink.midnight)
            .navigationTitle("Why am I seeing this?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func header(_ e: RiskExplanation) -> some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.xs) {
            HStack(spacing: Thermyx.Space.s) {
                Circle().fill(e.level.tint).frame(width: 10, height: 10)
                Text(e.level.rawValue)
                    .font(ThermyxFont.riskHeadline)
                    .foregroundStyle(e.level.tint)
            }
            Text(summary(e))
                .font(ThermyxFont.body)
                .foregroundStyle(Thermyx.Ink.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func summary(_ e: RiskExplanation) -> String {
        let count = e.contributing.count
        switch e.level {
        case .unavailable:
            return "No insole is sending readings, so there is nothing to assess yet."
        case .normal:
            return "None of the signals below has crossed its rule."
        default:
            let foot = e.foot.map { " Mostly the \($0.label.lowercased()) foot." } ?? ""
            return "\(count) \(count == 1 ? "signal has" : "signals have") crossed \(count == 1 ? "its rule" : "their rules").\(foot)"
        }
    }

    private func signals(_ e: RiskExplanation) -> some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.s) {
            SectionLabel("Signals")
            ThermyxCard(padding: Thermyx.Space.l) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(e.signals.enumerated()), id: \.element.id) { index, signal in
                        if index > 0 { Divider().overlay(Thermyx.Ink.divider) }
                        SignalRow(signal: signal)
                    }
                }
            }
            Text("Levels: one signal is Caution, two are High, three are Critical. The burn-protection limit is High on its own. Left–right gaps raise Caution only, and only after holding for 2 minutes.")
                .font(ThermyxFont.captionSmall)
                .foregroundStyle(Thermyx.Ink.textFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func confidence(_ e: RiskExplanation) -> some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.s) {
            SectionLabel("How much to trust this")
            ThermyxCard(padding: Thermyx.Space.l) {
                VStack(alignment: .leading, spacing: Thermyx.Space.xs) {
                    Text("\(e.confidence.rawValue) confidence")
                        .font(ThermyxFont.rowTitle)
                        .foregroundStyle(confidenceTint(e.confidence))
                    ForEach(e.confidenceReasons, id: \.self) { reason in
                        Text(reason)
                            .font(ThermyxFont.caption)
                            .foregroundStyle(Thermyx.Ink.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var baseline: some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.s) {
            SectionLabel("Personal baseline")
            Text("Still learning. Your own normal can only make Thermyx more cautious — it never lowers a level the fixed rules set.")
                .font(ThermyxFont.caption)
                .foregroundStyle(Thermyx.Ink.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func nextStep(_ e: RiskExplanation) -> some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.s) {
            SectionLabel("What to do")
            Text(e.nextStep)
                .font(ThermyxFont.body)
                .foregroundStyle(Thermyx.Ink.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func confidenceTint(_ c: RiskExplanation.Confidence) -> Color {
        switch c {
        case .high: return Thermyx.Ink.ice
        case .medium: return Thermyx.Ink.amber
        case .low: return Thermyx.Ink.ember
        }
    }
}

private struct SignalRow: View {
    let signal: RiskExplanation.Signal

    var body: some View {
        HStack(alignment: .top, spacing: Thermyx.Space.s) {
            Image(systemName: signal.contributes ? "exclamationmark.circle.fill" : "checkmark.circle")
                .foregroundStyle(signal.contributes ? Thermyx.Ink.ember : Thermyx.Ink.textFaint)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(signal.title)
                    .font(ThermyxFont.rowTitleRegular)
                    .foregroundStyle(Thermyx.Ink.textPrimary)
                Text(signal.rule)
                    .font(ThermyxFont.captionSmall)
                    .foregroundStyle(Thermyx.Ink.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Thermyx.Space.xs)
            Text(signal.value ?? "Not measured")
                .font(signal.value == nil ? ThermyxFont.captionSmall : ThermyxFont.rowNumeral)
                .monospacedDigit()
                .foregroundStyle(signal.contributes ? Thermyx.Ink.ember : Thermyx.Ink.textSecondary)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, Thermyx.Space.s)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(signal.title), \(signal.value ?? "not measured"). \(signal.contributes ? "Counts toward this level." : "Not counting.") \(signal.rule).")
    }
}

// MARK: - Device health

/// Per foot: whether data is live, stale, or off; battery; how old the
/// newest reading is; and the Bluetooth signal. Shown wherever the wearer
/// needs to judge whether the numbers above can be trusted.
struct DeviceHealthStrip: View {
    @EnvironmentObject private var viewModel: ThermyxViewModel
    var now: Date = .now

    enum Status: Equatable {
        case live, stale, off

        var label: String {
            switch self {
            case .live: return "Live"
            case .stale: return "Stale"
            case .off: return "Off"
            }
        }
    }

    /// A reading older than this is shown as stale.
    static let staleAfter: TimeInterval = 3

    static func state(connected: Bool, age: TimeInterval?) -> Status {
        guard connected, let age else { return .off }
        return age > staleAfter ? .stale : .live
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.s) {
            SectionLabel("Insoles")
            HStack(spacing: Thermyx.Space.xs) {
                ForEach(Foot.allCases) { foot in
                    tile(foot)
                }
            }
        }
    }

    private func tile(_ foot: Foot) -> some View {
        let entry = viewModel.reading[foot]
        let age = entry.map { max(0, now.timeIntervalSince($0.timestamp)) }
        let state = Self.state(connected: viewModel.isConnected(foot), age: age)
        let rssi = viewModel.ble.rssi[foot]
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(tint(state)).frame(width: 7, height: 7)
                Text("\(foot.label) · \(state.label)")
                    .narrowLabel(ThermyxFont.statusPill, tracking: 0.8, color: tint(state))
            }
            Text(detail(state: state, age: age, battery: entry?.batteryPercent, rssi: rssi))
                .font(ThermyxFont.captionSmall)
                .foregroundStyle(Thermyx.Ink.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Thermyx.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Thermyx.Ink.deck, in: RoundedRectangle(cornerRadius: Thermyx.Radius.control, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Thermyx.Radius.control, style: .continuous)
                .strokeBorder(Thermyx.Ink.hairline, lineWidth: Thermyx.Stroke.hairline)
        }
        .accessibilityElement(children: .combine)
    }

    private func detail(state: Status, age: TimeInterval?, battery: Int?, rssi: Int?) -> String {
        guard state != .off else { return "Not connected" }
        var parts: [String] = []
        if let age { parts.append(age < 1 ? "Just now" : "\(Int(age)) s ago") }
        parts.append(battery.map { "Battery \($0)%" } ?? "Battery —")
        if let rssi { parts.append("Signal \(Self.signalWord(rssi))") }
        return parts.joined(separator: " · ")
    }

    static func signalWord(_ rssi: Int) -> String {
        rssi > -70 ? "good" : rssi >= -85 ? "fair" : "weak"
    }

    private func tint(_ state: Status) -> Color {
        switch state {
        case .live: return Thermyx.Ink.ice
        case .stale: return Thermyx.Ink.amber
        case .off: return Thermyx.Ink.textFaint
        }
    }
}
