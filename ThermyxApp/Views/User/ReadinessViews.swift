import SwiftUI

// Insights: what's normal for this wearer, and what has helped them recover.

/// "Is today different for me?": the wearer's own usual temperatures by
/// activity, how today's foot compares, their usual weight on each foot,
/// their comfort target, and whether recoveries are getting quicker.
struct ReadinessCard: View {
    @EnvironmentObject private var viewModel: ThermyxViewModel
    @ObservedObject var settings: ThermyxSettingsStore

    private var unit: TemperatureUnit { settings.temperatureUnit }

    private var profile: ReadinessProfile {
        ReadinessProfile.build(
            reading: viewModel.reading,
            activity: viewModel.baseline.activity,
            model: viewModel.baseline.isEnabled ? viewModel.baseline.model : nil,
            hours: viewModel.history.hourSamples,
            recoveries: viewModel.recovery.records,
            comfortTargetC: settings.targetTemperatureC
        )
    }

    var body: some View {
        let profile = profile
        ThermyxCard {
            VStack(alignment: .leading, spacing: Thermyx.Space.l) {
                HStack(alignment: .firstTextBaseline) {
                    SectionLabel("Today vs your normal")
                    Spacer(minLength: Thermyx.Space.xs)
                    StatusPill(profile.status.title, tint: tint(profile.status), fill: fill(profile.status), border: border(profile.status))
                }

                Text(headline(profile))
                    .font(ThermyxFont.bodyLarge)
                    .lineSpacing(3)
                    .foregroundStyle(Thermyx.Ink.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(profile.notes, id: \.self) { note in
                    Label(note, systemImage: "arrow.left.arrow.right")
                        .font(ThermyxFont.caption)
                        .foregroundStyle(Thermyx.Ink.amber)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !profile.ranges.isEmpty { ranges(profile) }
                facts(profile)

                Text(footnote(profile))
                    .font(ThermyxFont.captionSmall)
                    .foregroundStyle(Thermyx.Ink.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: Words

    private func headline(_ p: ReadinessProfile) -> String {
        let doing = p.activity?.label.lowercased()
        switch p.status {
        case .learning:
            return viewModel.anyConnected
                ? "Thermyx is still learning what's normal for your feet. It needs a calibration, or about \(ReadinessProfile.minimumHours) hours of calm wear for each thing you do."
                : "Connect your insoles to see how today compares with your normal."
        case .typical:
            let resting = p.isResting
            return "Your feet look like they usually do while you're \(doing ?? "active"). \(resting ? "A good time to head out." : "Nothing stands out today.")"
        case .warmer:
            return "Your warmer foot is running above what's usual for you while \(doing ?? "active"). Take breaks, drink water, and keep an eye on it."
        case .cooler:
            return "Your warmer foot is running cooler than usual for you while \(doing ?? "active"). If your feet feel cold, warm them gradually."
        }
    }

    private func footnote(_ p: ReadinessProfile) -> String {
        let source = p.ranges.contains(where: \.fromHistory) ? "your last \(ReadinessProfile.historyDays) days of calm wear" : "your calibration"
        return "Built from \(source), on this phone. It describes your usual, not your health, and never changes your risk level."
    }

    // MARK: Ranges

    private func ranges(_ p: ReadinessProfile) -> some View {
        let lows = p.ranges.map(\.lowC) + [p.nowC].compactMap { $0 }
        let highs = p.ranges.map(\.highC) + [p.nowC].compactMap { $0 }
        let domain = (lows.min()! - 1)...(highs.max()! + 1)
        return VStack(alignment: .leading, spacing: Thermyx.Space.s) {
            Text("Usual temperature at the insole")
                .font(ThermyxFont.captionSmall)
                .foregroundStyle(Thermyx.Ink.textMuted)
            ForEach(p.ranges) { range in
                let current = range.activity == p.activity
                HStack(spacing: Thermyx.Space.m) {
                    Text(range.activity.label)
                        .font(current ? ThermyxFont.rowTitle : ThermyxFont.bodySmall)
                        .foregroundStyle(current ? Thermyx.Ink.textPrimary : Thermyx.Ink.textSecondary)
                        .frame(width: 74, alignment: .leading)
                    UsualRangeBar(lowC: range.lowC, highC: range.highC, nowC: current ? p.nowC : nil, domain: domain)
                        .frame(height: 22)
                    Text("\(TemperatureFormat.value(range.lowC, in: unit, decimals: 0))–\(TemperatureFormat.degrees(range.highC, in: unit, decimals: 0))")
                        .font(ThermyxFont.monoCaption)
                        .monospacedDigit()
                        .foregroundStyle(Thermyx.Ink.textMuted)
                        .frame(width: 66, alignment: .trailing)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(range.activity.label)")
                .accessibilityValue("Usually \(TemperatureFormat.full(range.lowC, in: unit)) to \(TemperatureFormat.full(range.highC, in: unit))\(current && p.nowC != nil ? ", now \(TemperatureFormat.full(p.nowC!, in: unit))" : "")")
            }
        }
    }

    // MARK: Facts

    private func facts(_ p: ReadinessProfile) -> some View {
        VStack(spacing: 0) {
            ThermyxDivider()
            fact("scalemass", "Weight on your feet", leanText(p.usualLean))
            ThermyxDivider()
            fact("target", "Comfort target", p.comfortTargetC.map { TemperatureFormat.degrees($0, in: unit, decimals: 0) } ?? "Not set")
            ThermyxDivider()
            fact("arrow.down.right.circle", "Recent recoveries", recoveryText(p.recoveryTrend))
        }
    }

    private func fact(_ symbol: String, _ label: String, _ value: String) -> some View {
        HStack(spacing: Thermyx.Space.m) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(Thermyx.Ink.textMuted)
                .frame(width: 22)
                .accessibilityHidden(true)
            Text(label)
                .font(ThermyxFont.bodySmall)
                .foregroundStyle(Thermyx.Ink.textSecondary)
            Spacer(minLength: Thermyx.Space.xs)
            Text(value)
                .font(ThermyxFont.rowTitleRegular)
                .foregroundStyle(Thermyx.Ink.textPrimary)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, Thermyx.Space.m)
        .accessibilityElement(children: .combine)
    }

    private func leanText(_ lean: Double?) -> String {
        guard let lean else { return "Still learning" }
        if abs(lean) < 0.05 { return "Usually even" }
        return "Leans \(lean > 0 ? "left" : "right") by \(Int((abs(lean) * 100).rounded())) points"
    }

    private func recoveryText(_ t: ReadinessProfile.RecoveryTrend) -> String {
        switch t {
        case .notEnough: return "Not enough yet"
        case .faster: return "Getting quicker"
        case .slower: return "Taking longer"
        case .steady: return "About the same"
        }
    }

    // MARK: Tints

    private func tint(_ s: ReadinessProfile.Status) -> Color {
        switch s {
        case .learning: return Thermyx.Ink.textSecondary
        case .typical: return Thermyx.Ink.ice
        case .warmer: return Thermyx.Ink.amber
        case .cooler: return Thermyx.Ink.ice
        }
    }

    private func fill(_ s: ReadinessProfile.Status) -> Color {
        switch s {
        case .learning: return Thermyx.Tint.neutralFill
        case .typical, .cooler: return Thermyx.Tint.liveFill
        case .warmer: return Thermyx.Tint.amberFill
        }
    }

    private func border(_ s: ReadinessProfile.Status) -> Color {
        switch s {
        case .learning: return Thermyx.Tint.neutralBorder
        case .typical, .cooler: return Thermyx.Tint.liveBorder
        case .warmer: return Thermyx.Tint.amberBorder
        }
    }
}

/// A usual range as a band on a shared scale, with a dot where the foot is
/// now.
struct UsualRangeBar: View {
    let lowC: Double
    let highC: Double
    let nowC: Double?
    let domain: ClosedRange<Double>

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let x: (Double) -> CGFloat = { c in w * CGFloat((c - domain.lowerBound) / (domain.upperBound - domain.lowerBound)) }
            ZStack(alignment: .leading) {
                Capsule().fill(Thermyx.Ink.elevated).frame(height: 6)
                Capsule()
                    .fill(Thermyx.Ink.ice.opacity(0.35))
                    .overlay { Capsule().strokeBorder(Thermyx.Ink.ice.opacity(0.6), lineWidth: 1) }
                    .frame(width: max(8, x(highC) - x(lowC)), height: 10)
                    .offset(x: x(lowC))
                if let nowC {
                    Circle()
                        .fill(FootScale.thermalColor(nowC))
                        .frame(width: 14, height: 14)
                        .overlay { Circle().strokeBorder(Thermyx.Ink.textPrimary, lineWidth: 2) }
                        .offset(x: min(max(x(nowC) - 7, 0), w - 14))
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Safety plan

/// What has helped, from the wearer's own recoveries, in their own words
/// and Thermyx's measurements.
struct SafetyPlanCard: View {
    @EnvironmentObject private var viewModel: ThermyxViewModel
    @ObservedObject var settings: ThermyxSettingsStore
    @State private var logging: ThermyxRiskEvent?

    private var plan: SafetyPlan { SafetyPlan.build(viewModel.recovery.records) }

    /// The latest event that's over, within a week, with no recovery on it.
    private var loggable: ThermyxRiskEvent? {
        let now = Date.now
        return viewModel.history.events
            .filter { e in
                e.endedAt != nil && now.timeIntervalSince(e.timestamp) < 7 * 86_400
                    && (e.riskLevel?.severity ?? 0) >= ThermyxRiskLevel.caution.severity
                    && !viewModel.recovery.records.contains { abs($0.startedAt.timeIntervalSince(e.timestamp)) < 1800 }
            }
            .max { $0.timestamp < $1.timestamp }
    }

    var body: some View {
        let plan = plan
        ThermyxCard {
            VStack(alignment: .leading, spacing: Thermyx.Space.l) {
                HStack(alignment: .firstTextBaseline) {
                    SectionLabel("Your safety plan")
                    Spacer(minLength: Thermyx.Space.xs)
                    Text("\(viewModel.recovery.records.count) recover\(viewModel.recovery.records.count == 1 ? "y" : "ies")")
                        .font(ThermyxFont.monoCaption)
                        .foregroundStyle(Thermyx.Ink.textFaint)
                }

                if plan.findings.isEmpty { learning(plan) } else {
                    VStack(alignment: .leading, spacing: Thermyx.Space.m) {
                        ForEach(plan.findings) { finding in
                            HStack(alignment: .top, spacing: Thermyx.Space.m) {
                                Image(systemName: finding.action.symbol)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(Thermyx.Ink.ice)
                                    .frame(width: 32, height: 32)
                                    .background(Thermyx.Tint.liveFill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                                    .accessibilityHidden(true)
                                Text(finding.text)
                                    .font(ThermyxFont.bodySmall)
                                    .lineSpacing(2)
                                    .foregroundStyle(Thermyx.Ink.textPrimary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }

                if let event = loggable {
                    Button { logging = event } label: {
                        Label("Log what you did after \(event.level) at \(event.timestamp.formatted(date: .omitted, time: .shortened))", systemImage: "square.and.pencil")
                            .multilineTextAlignment(.leading)
                    }
                    .buttonStyle(ThermyxSecondaryButtonStyle(tint: Thermyx.Ink.ice, border: Thermyx.Tint.liveBorder))
                }

                recent

                Text("Patterns in your own recoveries, not medical advice, and not proof that one thing causes another.")
                    .font(ThermyxFont.captionSmall)
                    .foregroundStyle(Thermyx.Ink.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .sheet(item: $logging) { event in
            RecoveryLogSheet(event: event)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .accessibilityElement(children: .contain)
    }

    private func learning(_ plan: SafetyPlan) -> some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.s) {
            HStack(spacing: 6) {
                ForEach(0..<plan.needed, id: \.self) { i in
                    Capsule()
                        .fill(i < plan.measured ? Thermyx.Ink.ice : Thermyx.Ink.elevated)
                        .frame(height: 6)
                }
            }
            .accessibilityHidden(true)
            Text(plan.isReady
                 ? "Nothing stands out yet. Thermyx looks for a step that was followed by clearly faster cooling, and hasn't found one."
                 : "\(plan.measured) of \(plan.needed) recoveries measured. Next time you're at Caution or above, run a recovery test, or log what you did afterwards. Thermyx then compares what was followed by faster cooling.")
                .font(ThermyxFont.bodySmall)
                .foregroundStyle(Thermyx.Ink.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The last few recoveries, newest first.
    @ViewBuilder
    private var recent: some View {
        let records = viewModel.recovery.records.sorted { $0.startedAt > $1.startedAt }.prefix(3)
        if !records.isEmpty {
            VStack(spacing: 0) {
                ThermyxDivider()
                ForEach(Array(records)) { record in
                    HStack(alignment: .firstTextBaseline, spacing: Thermyx.Space.m) {
                        Text(record.startedAt.formatted(.dateTime.month(.abbreviated).day()))
                            .font(ThermyxFont.monoCaption)
                            .foregroundStyle(Thermyx.Ink.textMuted)
                            .frame(width: 52, alignment: .leading)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(record.outcome.title)
                                .font(ThermyxFont.rowTitleRegular)
                                .foregroundStyle(outcomeTint(record.outcome))
                            Text(record.actions.isEmpty ? "Nothing logged" : record.actions.map(\.label).joined(separator: " · "))
                                .font(ThermyxFont.captionSmall)
                                .foregroundStyle(Thermyx.Ink.textMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, Thermyx.Space.s)
                    .contextMenu {
                        Button("Delete", role: .destructive) { viewModel.recovery.remove(record.id) }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func outcomeTint(_ o: RecoveryOutcome) -> Color {
        switch o {
        case .recovered: return Thermyx.Ink.ice
        case .improving: return Thermyx.Ink.amber
        case .notImproving: return Thermyx.Ink.ember
        case .inconclusive: return Thermyx.Ink.textSecondary
        }
    }
}
