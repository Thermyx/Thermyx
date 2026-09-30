import SwiftUI
import UIKit

/// The watcher needs one answer: is this person okay, and do I act?
/// Status first, the instruction second, the numbers third.
struct TrustedWatchView: View {
    @ObservedObject var roles: ThermyxRoleStore
    @ObservedObject var member: TrustedMemberViewModel
    @ObservedObject var settings: ThermyxSettingsStore

    private var unit: TemperatureUnit { settings.temperatureUnit }
    private var event: ThermyxAlertEvent? { member.displayedEvent(deviceID: settings.deviceID) }
    private var pair: BilateralReading? { member.displayedBilateral }

    private var assessment: ThermyxRiskAssessment {
        guard let event else { return .unavailable }
        return ThermyxRiskAssessment(
            level: ThermyxRiskLevel(rawValue: event.level) ?? .unavailable,
            reasons: event.reasons
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Thermyx.Space.l) {
                    header

                    if let event {
                        silenceWarning
                        riskCard(event: event)
                        if let mapsURL = event.location?.mapsURL, !member.isShowingSample {
                            Link(destination: mapsURL) {
                                Label("Open their location in Maps", systemImage: "mappin.and.ellipse")
                            }
                            .buttonStyle(ThermyxSecondaryButtonStyle(tint: Thermyx.Ink.ice, border: Thermyx.Tint.liveBorder))
                        }
                        actionCard
                        if let pair, pair.hasAny { soleRow(pair) }
                        metricGrid(event.readings, pair: pair)
                    } else {
                        Spacer(minLength: Thermyx.Space.xxl)
                        ThermyxEmptyState(
                            title: member.isConnected ? "No status shared yet" : "Not connected",
                            message: member.isConnected
                                ? "This phone is connected to the shared backend. Their status will appear here as soon as their insole sends one."
                                : "Check the backend address and device ID under Settings. Nothing is shown until real status arrives.",
                            systemImage: "antenna.radiowaves.left.and.right"
                        )
                        samplePrompt
                        Spacer(minLength: Thermyx.Space.xxl)
                    }

                    if let error = member.lastError, !member.isShowingSample {
                        Text(error)
                            .font(ThermyxFont.captionSmall)
                            .foregroundStyle(Thermyx.Ink.amber)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, Thermyx.Space.screen)
                .padding(.bottom, Thermyx.Space.xxl)
                .frame(maxHeight: .infinity)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
            .background(Thermyx.Ink.midnight)
            .thermyxTopScrim()
            .trustedSampleBanner(member: member, watchedName: roles.watchedUserName)
        }
    }

    private var header: some View {
        HStack(spacing: Thermyx.Space.m) {
            Circle()
                .fill(Thermyx.Ink.elevated)
                .frame(width: 42, height: 42)
                .overlay {
                    Text(roles.watchedUserName.thermyxInitials)
                        .font(ThermyxFont.rowTitle)
                        .foregroundStyle(Thermyx.Ink.ice)
                }

            VStack(alignment: .leading, spacing: 1) {
                Text("Trusted circle")
                    .narrowLabel(ThermyxFont.zoneLabel, tracking: 2.4, color: Thermyx.Ink.ice)
                Text(roles.watchedUserName)
                    .font(ThermyxFont.cardTitle)
                    .tracking(-0.3)
                    .foregroundStyle(Thermyx.Ink.textPrimary)
            }

            Spacer(minLength: Thermyx.Space.xs)

            if member.isShowingSample {
                StatusPill("Sample", tint: Thermyx.Ink.amber, fill: Thermyx.Tint.amberFill, border: Thermyx.Tint.amberBorder, showsDot: false)
            } else if member.isConnected {
                StatusPill.live()
            } else {
                StatusPill.offline()
            }
        }
        .padding(.top, Thermyx.Space.m)
    }

    /// Shown when the wearer's phone has gone quiet. Their app posts at least
    /// once a minute while an insole is connected, so silence is itself news.
    private var silenceWarning: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            if let silence = member.silence(now: context.date), silence >= TrustedMemberViewModel.silenceWarning {
                ThermyxCard(fill: Thermyx.Tint.amberFill, border: Thermyx.Tint.amberBorder) {
                    VStack(alignment: .leading, spacing: Thermyx.Space.xs) {
                        SectionLabel("No update for \(Int(silence / 60)) min", color: Thermyx.Ink.amber)
                        Text("Their phone, signal, or insoles may be off. The status below is the last one received, not a live one. Check in with them.")
                            .font(ThermyxFont.caption)
                            .foregroundStyle(Thermyx.Ink.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func riskCard(event: ThermyxAlertEvent) -> some View {
        let level = assessment.level
        return VStack(alignment: .leading, spacing: Thermyx.Space.s) {
            HStack(spacing: Thermyx.Space.s) {
                Image(systemName: level.severity >= 1 ? "exclamationmark.triangle.fill" : "checkmark.shield.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(level.tint)
                Text(level.rawValue)
                    .narrowLabel(ThermyxFont.riskHeadline, tracking: ThermyxTracking.riskHeadline, color: level.tint)
            }

            Text(assessment.reasons.joined(separator: " ").isEmpty ? level.explanation : assessment.reasons.joined(separator: " "))
                .font(ThermyxFont.bodyLarge)
                .lineSpacing(3)
                .foregroundStyle(Thermyx.Ink.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Updated \(event.timestamp.formatted(date: .omitted, time: .shortened))")
                .narrowLabel(ThermyxFont.statusPill, tracking: ThermyxTracking.statusPill, color: Thermyx.Ink.textMuted)
        }
        .padding(Thermyx.Space.hero)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(level.fill, in: RoundedRectangle(cornerRadius: Thermyx.Radius.readout, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Thermyx.Radius.readout, style: .continuous)
                .strokeBorder(level.border, lineWidth: Thermyx.Stroke.hairline)
        }
        .accessibilityElement(children: .combine)
    }

    private var actionCard: some View {
        ThermyxCard(padding: Thermyx.Space.xxl) {
            VStack(alignment: .leading, spacing: Thermyx.Space.s) {
                SectionLabel("What to do", color: Thermyx.Ink.ice)

                Text(guidance)
                    .font(ThermyxFont.bodyLarge)
                    .lineSpacing(3)
                    .foregroundStyle(Thermyx.Ink.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: Thermyx.Space.xs) {
                    Button("Message") { open(scheme: "sms") }
                        .buttonStyle(ThermyxPrimaryButtonStyle())
                    Button("Call") { open(scheme: "tel") }
                        .buttonStyle(ThermyxSecondaryButtonStyle())
                }
                .padding(.top, 2)
                .disabled(contactNumber == nil || member.isShowingSample)
                .opacity(contactNumber == nil || member.isShowingSample ? 0.5 : 1)

                if member.isShowingSample {
                    Text("Disabled while you're reading the sample.")
                        .font(ThermyxFont.captionSmall)
                        .foregroundStyle(Thermyx.Ink.textFaint)
                } else if contactNumber == nil {
                    Text("Add their number under Settings to message or call from here.")
                        .font(ThermyxFont.captionSmall)
                        .foregroundStyle(Thermyx.Ink.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var samplePrompt: some View {
        ThermyxCard(fill: Thermyx.Tint.signalFill, border: Thermyx.Tint.signalBorder) {
            VStack(alignment: .leading, spacing: Thermyx.Space.s) {
                SectionLabel("New to this?", color: Thermyx.Ink.ice)
                Text("Read through a worked example of a shift — what a caution looks like, where the instruction appears, and which buttons matter — while nothing is wrong.")
                    .font(ThermyxFont.caption)
                    .foregroundStyle(Thermyx.Ink.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Show me a sample shift") {
                    withAnimation { member.isShowingSample = true }
                }
                .buttonStyle(ThermyxPrimaryButtonStyle())
                .padding(.top, 2)
            }
        }
    }

    private var guidance: String {
        switch assessment.level {
        case .critical, .high:
            return "Check in now. If they report dizziness or stop responding, call them and then call 911."
        case .caution:
            return "Check in by message. If they report dizziness or stop responding, call them and then call 911."
        default:
            return "Stay available and check in if they report discomfort."
        }
    }

    private var contactNumber: String? {
        let number = roles.watchedUserPhone.trimmingCharacters(in: .whitespacesAndNewlines)
        return number.isEmpty ? nil : number
    }

    private func open(scheme: String) {
        guard !member.isShowingSample, let number = contactNumber else { return }
        let digits = number.filter { $0.isNumber || $0 == "+" }
        guard let url = URL(string: "\(scheme)://\(digits)"), UIApplication.shared.canOpenURL(url) else { return }
        UIApplication.shared.open(url)
    }

    /// Both soles, read-only. A watcher cannot scan for someone else's
    /// insole, so a foot that is not reporting simply says so.
    private func soleRow(_ pair: BilateralReading) -> some View {
        ThermyxCard {
            VStack(alignment: .leading, spacing: Thermyx.Space.s) {
                SectionLabel("Both feet")
                HStack(alignment: .top, spacing: Thermyx.Space.xl) {
                    ForEach(Foot.allCases) { foot in
                        VStack(spacing: 6) {
                            SoleView(foot: foot, reading: pair[foot], unit: unit)
                                .frame(height: 150)
                            Text(pair[foot] == nil ? "\(foot.label) · not reporting" : foot.label)
                                .narrowLabel(ThermyxFont.axisLabel, tracking: ThermyxTracking.axisLabel,
                                             color: pair[foot] == nil ? Thermyx.Ink.textFaint : Thermyx.Ink.textSupporting)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }

                if let gap = pair.temperatureAsymmetryC, let hotter = pair.hotterFoot {
                    Text("\(hotter.label) foot is \(TemperatureFormat.delta(gap, in: unit)) warmer right now.")
                        .font(ThermyxFont.caption)
                        .foregroundStyle(Thermyx.Ink.amber)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func metricGrid(_ readings: ThermyxAlertEvent.AlertReadings, pair: BilateralReading?) -> some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: Thermyx.Space.s), GridItem(.flexible(), spacing: Thermyx.Space.s)],
            spacing: Thermyx.Space.s
        ) {
            MetricTile(
                label: "Foot temperature",
                value: readings.footTemperatureC.map { TemperatureFormat.degrees($0, in: unit) },
                tint: readings.footTemperatureC.map(ThermyxTemperatureScale.tint) ?? Thermyx.Ink.textPrimary,
                numeralFont: ThermyxFont.zoneNumeral
            )
            MetricTile(
                label: "Ambient",
                value: readings.ambientTemperatureC.map { TemperatureFormat.degrees($0, in: unit) },
                numeralFont: ThermyxFont.zoneNumeral
            )
            MetricTile(
                label: "Movement",
                value: readings.gaitStability.map { "\(Int(($0 * 100).rounded()))%" },
                tint: Thermyx.Ink.ice,
                numeralFont: ThermyxFont.zoneNumeral
            )
            MetricTile(
                label: "Insole battery",
                value: readings.batteryPercent.map { "\($0)%" },
                numeralFont: ThermyxFont.zoneNumeral
            )
            if let index = pair?.asymmetryIndex {
                MetricTile(
                    label: "L / R difference",
                    value: "\(Int((index * 100).rounded()))%",
                    tint: index > 0.5 ? Thermyx.Ink.amber : Thermyx.Ink.textPrimary,
                    numeralFont: ThermyxFont.zoneNumeral
                )
            }
        }
    }
}

// MARK: - Sample banner

/// Marks every trusted screen while the worked example is showing, and gives
/// one-tap exit. A watcher must never be able to mistake the sample for the
/// person they are responsible for.
struct TrustedSampleBanner: ViewModifier {
    @ObservedObject var member: TrustedMemberViewModel
    let watchedName: String

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .top, spacing: 0) {
            if member.isShowingSample {
                HStack(spacing: Thermyx.Space.s) {
                    Image(systemName: "eye.fill")
                        .font(.system(size: 12, weight: .bold))
                    Text("Sample shift · not \(watchedName)'s data")
                        .narrowLabel(ThermyxFont.axisLabel, tracking: ThermyxTracking.axisLabel, color: Thermyx.Ink.onEmber)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: Thermyx.Space.xs)
                    Button("Exit") {
                        withAnimation { member.isShowingSample = false }
                    }
                    .font(ThermyxFont.rowTitle)
                    .foregroundStyle(Thermyx.Ink.onEmber)
                }
                .foregroundStyle(Thermyx.Ink.onEmber)
                .padding(.horizontal, Thermyx.Space.screen)
                .padding(.vertical, Thermyx.Space.s)
                .frame(maxWidth: .infinity)
                .background(Thermyx.Ink.amber)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Showing a sample shift. This is not \(watchedName)'s data.")
            }
        }
    }
}

extension View {
    func trustedSampleBanner(member: TrustedMemberViewModel, watchedName: String) -> some View {
        modifier(TrustedSampleBanner(member: member, watchedName: watchedName))
    }
}

extension String {
    /// Up to two initials from a display name.
    var thermyxInitials: String {
        let letters = split(separator: " ").prefix(2).compactMap { $0.first.map(String.init) }.joined().uppercased()
        return letters.isEmpty ? "?" : letters
    }
}
