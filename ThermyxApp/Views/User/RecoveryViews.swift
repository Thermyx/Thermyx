import SwiftUI

/// The Thermal Recovery Test: the steps, a short hold while Thermyx measures
/// whether the foot is cooling, and the result.
struct RecoverySheet: View {
    @EnvironmentObject private var viewModel: ThermyxViewModel
    @ObservedObject var coach: RecoveryCoach
    @ObservedObject var settings: ThermyxSettingsStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var chosen: Set<RecoveryAction> = []
    @State private var choseOnce = false
    @State private var showingCannotCall = false

    private var unit: TemperatureUnit { settings.temperatureUnit }
    private var plan: SafetyPlan { SafetyPlan.build(viewModel.recovery.records) }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView {
                VStack(alignment: .leading, spacing: Thermyx.Space.xl) {
                    if let session = coach.session {
                        switch session.phase {
                        case .steps: steps(session)
                        case .holding: holding(session)
                        case .result(let result): resultView(session, result)
                        }
                    }
                }
                .padding(.horizontal, Thermyx.Space.screen)
                .padding(.bottom, Thermyx.Space.xxl)
                .animation(reduceMotion ? nil : SiteMotion.settle, value: coach.session?.phase)
            }
            .scrollIndicators(.hidden)
        }
        .background(Thermyx.Ink.midnight.ignoresSafeArea())
        .alert("This device can't place calls", isPresented: $showingCannotCall) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Dial 911 from a phone.")
        }
    }

    private var topBar: some View {
        HStack {
            Text("Recovery test")
                .font(ThermyxFont.sectionTitle)
                .foregroundStyle(Thermyx.Ink.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button {
                coach.close()
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Thermyx.Ink.textPrimary)
                    .frame(width: 44, height: 44)
                    .background(Thermyx.Ink.elevated, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, Thermyx.Space.screen)
        .padding(.top, Thermyx.Space.l)
        .padding(.bottom, Thermyx.Space.s)
    }

    // MARK: Steps

    private func steps(_ session: RecoverySession) -> some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.xl) {
            VStack(alignment: .leading, spacing: Thermyx.Space.xs) {
                Text("Let's cool this down")
                    .font(ThermyxFont.display)
                    .tracking(-0.4)
                    .foregroundStyle(Thermyx.Ink.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Do what you can from this list, then hold still for \(spoken(session.holdSeconds)). Thermyx measures whether your feet are cooling.")
                    .font(ThermyxFont.bodySmall)
                    .foregroundStyle(Thermyx.Ink.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if session.startLevel == .critical { criticalBanner }

            VStack(spacing: 0) {
                ForEach(Array(RecoveryStep.allCases.enumerated()), id: \.element.id) { index, step in
                    stepRow(step, session: session, isLast: index == RecoveryStep.allCases.count - 1)
                }
            }

            VStack(alignment: .leading, spacing: Thermyx.Space.xs) {
                Button("Start the \(minutes(session.holdSeconds)) hold") { coach.beginHold() }
                    .buttonStyle(ThermyxPrimaryButtonStyle())
                    .disabled(!session.canStartHold)
                    .opacity(session.canStartHold ? 1 : 0.5)
                if !session.canStartHold {
                    Text("Tick \"Stop and sit down\" to start.")
                        .font(ThermyxFont.captionSmall)
                        .foregroundStyle(Thermyx.Ink.textFaint)
                }
            }
            disclaimer
        }
    }

    private func stepRow(_ step: RecoveryStep, session: RecoverySession, isLast: Bool) -> some View {
        let done = session.done.contains(step)
        let helped = !plan.helped.isDisjoint(with: Set(step.actions))
        return VStack(alignment: .leading, spacing: Thermyx.Space.xs) {
            Button { coach.toggle(step) } label: {
                HStack(alignment: .top, spacing: Thermyx.Space.m) {
                    Image(systemName: done ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 24, weight: .regular))
                        .foregroundStyle(done ? Thermyx.Ink.ice : Thermyx.Ink.textFaint)
                        .frame(width: 28)
                        .contentTransition(.symbolEffect(.replace))
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: Thermyx.Space.xs) {
                            Text(step.title)
                                .font(ThermyxFont.rowTitle)
                                .foregroundStyle(Thermyx.Ink.textPrimary)
                            if helped {
                                Text("Helped you before")
                                    .font(ThermyxFont.captionSmall)
                                    .foregroundStyle(Thermyx.Ink.ice)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(Thermyx.Tint.liveFill, in: Capsule())
                            }
                        }
                        Text(step.detail)
                            .font(ThermyxFont.bodySmall)
                            .foregroundStyle(Thermyx.Ink.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .sensoryFeedback(.selection, trigger: done)
            .accessibilityElement(children: .combine)
            .accessibilityValue(done ? "Done" : "Not done")
            .accessibilityHint("Double tap to mark it \(done ? "not done" : "done").")

            if step == .coolDown, viewModel.isControlAvailable {
                let onCool = viewModel.thermalSetting == .cool
                Button {
                    if !onCool { viewModel.select(.cool) }
                    coach.switchedToCool()
                } label: {
                    Label(onCool ? "Insoles are on Cool" : "Switch the insoles to Cool", systemImage: "snowflake")
                        .font(ThermyxFont.controlLabel)
                        .foregroundStyle(Thermyx.Ink.ice)
                        .padding(.horizontal, Thermyx.Space.l)
                        .frame(minHeight: Thermyx.minimumTapTarget)
                        .background(Thermyx.Tint.liveFill, in: Capsule())
                        .overlay { Capsule().strokeBorder(Thermyx.Tint.liveBorder, lineWidth: 1) }
                }
                .buttonStyle(.plain)
                .padding(.leading, 28 + Thermyx.Space.m)
            }
        }
        .padding(.vertical, Thermyx.Space.m)
        .overlay(alignment: .bottom) { if !isLast { ThermyxDivider().padding(.leading, 28 + Thermyx.Space.m) } }
    }

    // MARK: Holding

    private func holding(_ session: RecoverySession) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = context.date
            let remaining = session.remaining(now: now)
            VStack(spacing: Thermyx.Space.xl) {
                if session.startLevel == .critical || session.isGettingWorse { urgentBanner(session) }

                ZStack {
                    Circle().stroke(Thermyx.Ink.hairline, lineWidth: 10)
                    Circle()
                        .trim(from: 0, to: session.progress(now: now))
                        .stroke(Thermyx.Ink.ice, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(reduceMotion ? nil : .linear(duration: 1), value: session.progress(now: now))
                    VStack(spacing: 2) {
                        Text(clock(remaining))
                            .font(ThermyxFont.displayLarge)
                            .monospacedDigit()
                            .foregroundStyle(Thermyx.Ink.textPrimary)
                        Text("Hold still")
                            .font(ThermyxFont.caption)
                            .foregroundStyle(Thermyx.Ink.textMuted)
                    }
                }
                .frame(width: 220, height: 220)
                .padding(.top, Thermyx.Space.l)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Time left")
                .accessibilityValue(clock(remaining))

                liveReadout(session)

                Button("Finish now") { coach.finish() }
                    .buttonStyle(ThermyxSecondaryButtonStyle())
                    .disabled(session.samples.count < 8)
                disclaimer
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// The foot now, and how far it's come since the hold began.
    private func liveReadout(_ session: RecoverySession) -> some View {
        let first = session.samples.first?.footC
        let now = viewModel.reading.peakFootTemperatureC ?? session.samples.last?.footC
        let change = (now != nil && first != nil) ? now! - first! : nil
        let still = session.samples.last?.still
        return ThermyxCard {
            HStack(alignment: .center, spacing: Thermyx.Space.xl) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Warmer foot")
                        .font(ThermyxFont.captionSmall)
                        .foregroundStyle(Thermyx.Ink.textMuted)
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(now.map { TemperatureFormat.value($0, in: unit) } ?? "—")
                            .font(ThermyxFont.statNumeral)
                            .monospacedDigit()
                            .foregroundStyle(now.map(FootScale.thermalColor) ?? Thermyx.Ink.textFaint)
                            .contentTransition(.numericText())
                        Text(unit.symbol)
                            .font(ThermyxFont.caption)
                            .foregroundStyle(Thermyx.Ink.textMuted)
                    }
                    if let change, abs(change) >= 0.1 {
                        Label("\(change < 0 ? "Cooled" : "Warmed") \(TemperatureFormat.delta(change, in: unit))", systemImage: change < 0 ? "arrow.down.right" : "arrow.up.right")
                            .font(ThermyxFont.caption)
                            .foregroundStyle(change < 0 ? Thermyx.Ink.ice : Thermyx.Ink.ember)
                    } else {
                        Text("Steady so far")
                            .font(ThermyxFont.caption)
                            .foregroundStyle(Thermyx.Ink.textMuted)
                    }
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 4) {
                    Image(systemName: still == false ? "figure.walk.motion" : "figure.seated.side")
                        .font(.system(size: 22, weight: .regular))
                        .foregroundStyle(still == false ? Thermyx.Ink.amber : Thermyx.Ink.ice)
                    Text(still == false ? "Keep still" : "Holding still")
                        .font(ThermyxFont.captionSmall)
                        .foregroundStyle(still == false ? Thermyx.Ink.amber : Thermyx.Ink.textMuted)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Result

    private func resultView(_ session: RecoverySession, _ result: RecoveryResult) -> some View {
        let tint = tint(result.outcome)
        return VStack(alignment: .leading, spacing: Thermyx.Space.xl) {
            VStack(alignment: .leading, spacing: Thermyx.Space.s) {
                Image(systemName: symbol(result.outcome))
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(tint)
                Text(result.outcome.title)
                    .font(ThermyxFont.display)
                    .tracking(-0.4)
                    .foregroundStyle(tint)
                Text(result.advice(level: session.startLevel))
                    .font(ThermyxFont.bodyLarge)
                    .lineSpacing(3)
                    .foregroundStyle(Thermyx.Ink.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: Thermyx.Space.s) {
                tile("Temperature", result.dropC.map { ($0 >= 0 ? "−" : "+") + TemperatureFormat.delta($0, in: unit) },
                     tint: (result.dropC ?? 0) >= RecoveryEvaluator.improvesAtC ? Thermyx.Ink.ice : Thermyx.Ink.textPrimary)
                tile("Stillness", result.stillFraction.map { "\(Int(($0 * 100).rounded()))%" },
                     tint: (result.stillFraction ?? 1) >= RecoveryEvaluator.minimumStill ? Thermyx.Ink.textPrimary : Thermyx.Ink.amber)
                tile("Weight", result.loadEvened.map { $0 ? "Evener" : "Less even" } ?? "No change",
                     tint: result.loadEvened == false ? Thermyx.Ink.amber : Thermyx.Ink.textPrimary)
            }
            Text("Cooling by \(TemperatureFormat.delta(RecoveryEvaluator.improvesAtC, in: unit)) or more over the hold counts as improving. Anything less is within the sensor's normal wobble.")
                .font(ThermyxFont.captionSmall)
                .foregroundStyle(Thermyx.Ink.textFaint)
                .fixedSize(horizontal: false, vertical: true)

            if result.outcome == .notImproving || result.outcome == .inconclusive {
                VStack(spacing: Thermyx.Space.s) {
                    Button("Try another \(minutes(session.holdSeconds))") { coach.again() }
                        .buttonStyle(ThermyxPrimaryButtonStyle())
                    if session.startLevel.severity >= ThermyxRiskLevel.high.severity, result.outcome == .notImproving {
                        Button { call() } label: { Label("Call 911", systemImage: "phone.fill") }
                            .buttonStyle(ThermyxPrimaryButtonStyle(fill: Thermyx.Ink.ember, foreground: Thermyx.Ink.onEmber))
                    }
                }
            }

            VStack(alignment: .leading, spacing: Thermyx.Space.s) {
                SectionLabel("What did you do?")
                Text("Tick what applies. Your safety plan learns from this.")
                    .font(ThermyxFont.captionSmall)
                    .foregroundStyle(Thermyx.Ink.textMuted)
                RecoveryActionChips(selection: $chosen)
            }
            .onAppear {
                if !choseOnce { chosen = Set(session.actions); choseOnce = true }
            }

            VStack(spacing: Thermyx.Space.s) {
                Button("Save to my safety plan") {
                    let ordered = RecoveryAction.allCases.filter { chosen.contains($0) }
                    viewModel.recovery.add(session.record(result: result, actions: ordered))
                    coach.close()
                    dismiss()
                }
                .buttonStyle(ThermyxPrimaryButtonStyle(fill: result.outcome == .notImproving ? Thermyx.Ink.elevated : Thermyx.Ink.textPrimary,
                                                       foreground: result.outcome == .notImproving ? Thermyx.Ink.textPrimary : Thermyx.Ink.onPrimary))
                Button("Don't save") {
                    coach.close()
                    dismiss()
                }
                .font(ThermyxFont.controlLabel)
                .foregroundStyle(Thermyx.Ink.textMuted)
                .frame(minHeight: Thermyx.minimumTapTarget)
            }
            disclaimer
        }
    }

    private func tile(_ label: String, _ value: String?, tint: Color) -> some View {
        MetricTile(label: label, value: value, tint: tint, numeralFont: ThermyxFont.metricNumeralCompact)
            .padding(Thermyx.Space.m)
            .background(Thermyx.Ink.deck, in: RoundedRectangle(cornerRadius: Thermyx.Radius.control, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: Thermyx.Radius.control, style: .continuous).strokeBorder(Thermyx.Ink.hairline, lineWidth: 1) }
    }

    // MARK: Pieces

    private var criticalBanner: some View {
        HStack(alignment: .top, spacing: Thermyx.Space.m) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Thermyx.Ink.ember)
            VStack(alignment: .leading, spacing: Thermyx.Space.xs) {
                Text("You're at Critical. Don't wait on this test.")
                    .font(ThermyxFont.rowTitle)
                    .foregroundStyle(Thermyx.Ink.textPrimary)
                Text("If you feel dizzy, confused or unwell, call for help now.")
                    .font(ThermyxFont.bodySmall)
                    .foregroundStyle(Thermyx.Ink.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button { call() } label: { Label("Call 911", systemImage: "phone.fill") }
                    .buttonStyle(ThermyxPrimaryButtonStyle(fill: Thermyx.Ink.ember, foreground: Thermyx.Ink.onEmber))
            }
        }
        .padding(Thermyx.Space.l)
        .background(Thermyx.Tint.cautionFill, in: RoundedRectangle(cornerRadius: Thermyx.Radius.control, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: Thermyx.Radius.control, style: .continuous).strokeBorder(Thermyx.Tint.cautionBorder, lineWidth: 1) }
    }

    private func urgentBanner(_ session: RecoverySession) -> some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.xs) {
            Label(session.isGettingWorse ? "Your foot is warming, not cooling." : "You're at Critical.", systemImage: "exclamationmark.triangle.fill")
                .font(ThermyxFont.rowTitle)
                .foregroundStyle(Thermyx.Ink.ember)
            Text("Don't wait for the timer. If you feel unwell, call for help.")
                .font(ThermyxFont.bodySmall)
                .foregroundStyle(Thermyx.Ink.textSecondary)
            Button { call() } label: { Label("Call 911", systemImage: "phone.fill") }
                .buttonStyle(ThermyxPrimaryButtonStyle(fill: Thermyx.Ink.ember, foreground: Thermyx.Ink.onEmber))
        }
        .padding(Thermyx.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Thermyx.Tint.cautionFill, in: RoundedRectangle(cornerRadius: Thermyx.Radius.control, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: Thermyx.Radius.control, style: .continuous).strokeBorder(Thermyx.Tint.cautionBorder, lineWidth: 1) }
    }

    private var disclaimer: some View {
        Text("These are common comfort and safety steps, not medical advice. Thermyx measures the temperature at your insole, not your body's. If you feel unwell, get help.")
            .font(ThermyxFont.captionSmall)
            .foregroundStyle(Thermyx.Ink.textFaint)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func call() {
        if !EmergencyCall.dial() { showingCannotCall = true }
    }

    private func clock(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded(.up))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private func spoken(_ seconds: TimeInterval) -> String {
        seconds >= 60 && seconds.truncatingRemainder(dividingBy: 60) == 0
            ? "\(Int(seconds / 60)) minute\(seconds == 60 ? "" : "s")" : "\(Int(seconds)) seconds"
    }

    private func minutes(_ seconds: TimeInterval) -> String {
        seconds >= 60 && seconds.truncatingRemainder(dividingBy: 60) == 0 ? "\(Int(seconds / 60))-minute" : "\(Int(seconds))-second"
    }

    private func tint(_ outcome: RecoveryOutcome) -> Color {
        switch outcome {
        case .recovered: return Thermyx.Ink.ice
        case .improving: return Thermyx.Ink.amber
        case .notImproving: return Thermyx.Ink.ember
        case .inconclusive: return Thermyx.Ink.textSecondary
        }
    }

    private func symbol(_ outcome: RecoveryOutcome) -> String {
        switch outcome {
        case .recovered: return "checkmark.seal.fill"
        case .improving: return "arrow.down.right.circle.fill"
        case .notImproving: return "exclamationmark.triangle.fill"
        case .inconclusive: return "questionmark.circle.fill"
        }
    }
}

// MARK: - What you did

/// The six things the wearer can say they did.
struct RecoveryActionChips: View {
    @Binding var selection: Set<RecoveryAction>

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: Thermyx.Space.xs)], alignment: .leading, spacing: Thermyx.Space.xs) {
            ForEach(RecoveryAction.allCases) { action in
                let on = selection.contains(action)
                Button {
                    if on { selection.remove(action) } else { selection.insert(action) }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: on ? "checkmark" : action.symbol)
                            .font(.system(size: 13, weight: .semibold))
                        Text(action.label)
                            .font(ThermyxFont.controlLabel)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                    .foregroundStyle(on ? Thermyx.Ink.onPrimary : Thermyx.Ink.textPrimary)
                    .padding(.horizontal, Thermyx.Space.m)
                    .frame(maxWidth: .infinity, minHeight: Thermyx.minimumTapTarget, alignment: .leading)
                    .background(on ? Thermyx.Ink.textPrimary : Thermyx.Ink.deck, in: Capsule())
                    .overlay { Capsule().strokeBorder(on ? Color.clear : Thermyx.Ink.hairline, lineWidth: 1) }
                }
                .buttonStyle(.plain)
                .sensoryFeedback(.selection, trigger: on)
                .accessibilityValue(on ? "Selected" : "Not selected")
            }
        }
    }
}

// MARK: - Logging afterwards

/// "What did you do?" for an event that's already over.
struct RecoveryLogSheet: View {
    @EnvironmentObject private var viewModel: ThermyxViewModel
    let event: ThermyxRiskEvent
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: Set<RecoveryAction> = []

    var body: some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.xl) {
            VStack(alignment: .leading, spacing: Thermyx.Space.xs) {
                Text("What did you do?")
                    .font(ThermyxFont.sectionTitle)
                    .foregroundStyle(Thermyx.Ink.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text("\(event.level) at \(event.timestamp.formatted(date: .abbreviated, time: .shortened))\(duration)")
                    .font(ThermyxFont.bodySmall)
                    .foregroundStyle(Thermyx.Ink.textMuted)
            }
            RecoveryActionChips(selection: $chosen)
            Text("Thermyx compares how fast your feet cooled with and without each one. It shows a pattern once it has a few to compare.")
                .font(ThermyxFont.captionSmall)
                .foregroundStyle(Thermyx.Ink.textFaint)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Save") {
                viewModel.recovery.add(record())
                dismiss()
            }
            .buttonStyle(ThermyxPrimaryButtonStyle())
        }
        .padding(Thermyx.Space.screen)
        .background(Thermyx.Ink.midnight.ignoresSafeArea())
    }

    private var duration: String {
        event.duration.map { " · held \(DurationFormat.long($0))" } ?? ""
    }

    /// A recovery from the event: how far the foot cooled by the time it
    /// ended, read from the history around then.
    private func record() -> RecoveryRecord {
        var end: Double?
        if let endedAt = event.endedAt {
            let all = viewModel.history.minuteSamples + viewModel.history.hourSamples
            end = all.filter { $0.foot == event.foot && $0.footMeanC != nil }
                .min { abs($0.start.timeIntervalSince(endedAt)) < abs($1.start.timeIntervalSince(endedAt)) }
                .flatMap { abs($0.start.timeIntervalSince(endedAt)) <= 3600 ? $0.footMeanC : nil }
        }
        return RecoveryRecord(
            id: UUID(), startedAt: event.timestamp, startLevel: event.level, startFootC: event.footTemperatureC, endFootC: end,
            seconds: event.duration, outcome: event.endedAt == nil ? .inconclusive : .recovered, stillFraction: nil, loadEvened: nil,
            actions: RecoveryAction.allCases.filter { chosen.contains($0) }, guided: false
        )
    }
}
