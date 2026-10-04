import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var viewModel: ThermyxViewModel
    @ObservedObject var roles: ThermyxRoleStore
    @ObservedObject var settings: ThermyxSettingsStore

    @State private var showingWhy = false
    @State private var showingConnect = false
    @State private var showingPairing: Bool = {
        #if DEBUG
        return ThermyxPreviewHarness.opensProfileSheet
        #else
        return false
        #endif
    }()

    private var reading: BilateralReading { viewModel.reading }
    private var assessment: ThermyxRiskAssessment { viewModel.assessment }
    private var unit: TemperatureUnit { settings.temperatureUnit }

    /// The hero number is the **hotter** foot, not the average of the pair.
    /// An average would hide exactly the case that matters — one foot running
    /// hot while the other is fine.
    private var heroTemperatureC: Double? { reading.peakFootTemperatureC }

    var body: some View {
        VStack(spacing: 0) {
            header
            if heroTemperatureC != nil {
                live
            } else {
                // No insole live: the test board's main sensor, if any.
                SensorHomeSwitch(board: viewModel.board, ble: viewModel.ble) { empty }
            }
        }
        .background(Thermyx.Ink.midnight)
        .thermyxTopScrim()
        .sheet(isPresented: $showingPairing) {
            DeviceProfileSheet(roles: roles, settings: settings)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingConnect) {
            NavigationStack { ConnectDeviceView(ble: viewModel.ble) }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingWhy) {
            RiskExplanationSheet(settings: settings)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Thermyx.Space.s) {
            Button {
                showingPairing = true
            } label: {
                HStack(spacing: Thermyx.Space.s) {
                    Image("ThermyxBadge")
                        .resizable().scaledToFit()
                        .frame(width: 48, height: 48)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(deviceLabel)
                            .narrowLabel(ThermyxFont.zoneLabel, tracking: 2.2,
                                         color: viewModel.anyConnected ? Thermyx.Ink.ice : Thermyx.Ink.amber)
                            .lineLimit(1)
                        Text(profileLabel)
                            .font(ThermyxFont.rowTitle)
                            .tracking(ThermyxTracking.cardTitle)
                            .foregroundStyle(Thermyx.Ink.textPrimary)
                            .lineLimit(1)
                    }
                }
                .frame(minHeight: Thermyx.minimumTapTarget, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(deviceLabel). Open device and profile settings.")

            Spacer(minLength: Thermyx.Space.xs)

            ThermyxSegmentedControl(
                options: TemperatureUnit.allCases,
                label: \.shortLabel,
                selection: $settings.temperatureUnit,
                font: ThermyxFont.rowTitleRegular,
                tracking: 0,
                uppercase: false,
                accessibilityPrefix: "Show temperatures in "
            )
            .fixedSize()
        }
        .padding(.horizontal, Thermyx.Space.screen)
        .padding(.top, Thermyx.Space.s)
        .padding(.bottom, Thermyx.Space.s)
    }

    /// Says which insoles are on and what the weaker battery is — the number
    /// that decides whether you need to charge.
    private var deviceLabel: String {
        let feet = viewModel.connectedFeet
        guard !feet.isEmpty else { return "Offline" }
        let which = feet.count == 2 ? "Both insoles" : "\(feet[0].label) only"
        guard let battery = reading.batteryPercent else { return which }
        return "\(which) · \(battery)%"
    }

    private var profileLabel: String {
        roles.profileName.isEmpty ? "Thermyx" : "\(roles.profileName)'s Thermyx"
    }

    // MARK: - Live

    private var live: some View {
        VStack(spacing: 0) {
            hero
            riskBand
                .padding(.horizontal, Thermyx.Space.screen)
                .padding(.top, Thermyx.Space.m)

            BilateralSoleView(unit: unit) { foot in
                viewModel.scanFor(foot)
                showingPairing = true
            }
            .padding(.horizontal, Thermyx.Space.screen)
            .padding(.vertical, Thermyx.Space.xs)
            .frame(maxHeight: .infinity)

            metricRow
                .padding(.horizontal, Thermyx.Space.screen)
                .padding(.bottom, Thermyx.Space.m)
        }
    }

    @ViewBuilder
    private var hero: some View {
        if let heroTemperatureC {
            HStack(alignment: .bottom, spacing: Thermyx.Space.m) {
                HStack(alignment: .top, spacing: 4) {
                    Text(TemperatureFormat.value(heroTemperatureC, in: unit))
                        .font(ThermyxFont.heroNumeral)
                        .tracking(ThermyxTracking.heroNumeral)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(unit.symbol)
                        .font(ThermyxFont.heroDegree)
                        .padding(.top, 6)
                }
                .foregroundStyle(ThermyxTemperatureScale.tint(for: heroTemperatureC))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(heroLabel)
                .accessibilityValue(TemperatureFormat.full(heroTemperatureC, in: unit))

                VStack(alignment: .leading, spacing: 3) {
                    Text(heroLabel)
                        .narrowLabel(ThermyxFont.zoneLabel, tracking: 2, color: Thermyx.Ink.textSupporting)
                    trendChip
                }
                .padding(.bottom, 6)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, Thermyx.Space.screen)
        }
    }

    /// Names the foot when only one is hot, so the headline number is never
    /// ambiguous about what it describes.
    private var heroLabel: String {
        guard viewModel.bothConnected else {
            return viewModel.connectedFeet.first.map { "\($0.label) foot" } ?? "Foot"
        }
        guard let hotter = reading.hotterFoot else { return "Both feet" }
        return "\(hotter.label) foot · warmer"
    }

    @ViewBuilder
    private var trendChip: some View {
        if let trend = viewModel.history.footTrend(over: 20 * 60, current: heroTemperatureC) {
            HStack(spacing: 5) {
                Image(systemName: trend.isRising ? "arrow.up" : "arrow.down")
                    .font(.system(size: 11, weight: .black))
                Text("\(TemperatureFormat.delta(trend.delta, in: unit)) / 20min")
                    .narrowLabel(ThermyxFont.statusPill, tracking: 0.6,
                                 color: trend.isRising ? Thermyx.Ink.ember : Thermyx.Ink.ice)
            }
            .foregroundStyle(trend.isRising ? Thermyx.Ink.ember : Thermyx.Ink.ice)
            .accessibilityElement(children: .combine)
        } else {
            Text("Building trend")
                .narrowLabel(ThermyxFont.statusPill, tracking: 0.6, color: Thermyx.Ink.textFaint)
        }
    }

    private var riskBand: some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.xs) {
            riskRow
            if settings.aiSuggestionsEnabled,
               let suggestion = ThermyxSuggestion.nextStep(for: assessment, reading: reading) {
                Text("Next: \(suggestion)")
                    .font(ThermyxFont.captionSmall)
                    .foregroundStyle(Thermyx.Ink.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 16)
                    .accessibilityLabel("Guidance: \(suggestion)")
            }
            if assessment.level.severity >= ThermyxRiskLevel.caution.severity {
                WhyButton(tint: assessment.level.tint) { showingWhy = true }
                    .padding(.leading, 16)
            }
        }
        .padding(.horizontal, Thermyx.Space.l)
        .padding(.vertical, 11)
        .background(assessment.level.fill, in: RoundedRectangle(cornerRadius: Thermyx.Radius.control, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Thermyx.Radius.control, style: .continuous)
                .strokeBorder(assessment.level.border, lineWidth: Thermyx.Stroke.hairline)
        }
    }

    private var riskRow: some View {
        HStack(spacing: Thermyx.Space.s) {
            Circle()
                .fill(assessment.level.tint)
                .frame(width: 8, height: 8)
            Text(assessment.level.rawValue)
                .narrowLabel(ThermyxFont.statusPillLarge, tracking: ThermyxTracking.sectionLabel, color: assessment.level.tint)
            Text(assessment.reasons.first ?? assessment.level.shortGuidance)
                .font(ThermyxFont.caption)
                .foregroundStyle(Thermyx.Ink.textSecondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Risk level \(assessment.level.rawValue)")
    }

    /// With both insoles on, the third tile becomes left-right balance —
    /// the signal a single insole could never give.
    private var metricRow: some View {
        HStack(spacing: Thermyx.Space.xs) {
            MetricTile(
                label: "Ambient",
                value: reading.ambientTemperatureC.map { TemperatureFormat.degrees($0, in: unit) },
                accessibilityValue: reading.ambientTemperatureC.map { TemperatureFormat.full($0, in: unit) }
            )
            MetricTile(
                label: "Steadiness",
                value: reading.gaitStability.map { "\(Int(($0 * 100).rounded()))%" },
                tint: Thermyx.Ink.ice
            )
            if viewModel.bothConnected {
                MetricTile(
                    label: "L–R gap",
                    value: asymmetryText,
                    tint: asymmetryTint,
                    accessibilityValue: asymmetryAccessibility
                )
            } else {
                MetricTile(
                    label: "Forefoot load",
                    value: reading.pressureBalance.map { "\(Int(($0 * 100).rounded()))%" }
                )
            }
        }
    }

    private var asymmetryText: String? {
        guard let index = reading.asymmetryIndex else { return nil }
        return "\(Int((index * 100).rounded()))%"
    }

    private var asymmetryTint: Color {
        guard let index = reading.asymmetryIndex else { return Thermyx.Ink.textPrimary }
        return index > 0.5 ? Thermyx.Ink.amber : Thermyx.Ink.textPrimary
    }

    private var asymmetryAccessibility: String {
        guard let index = reading.asymmetryIndex else { return "No reading" }
        if let favoured = reading.favouredFoot {
            return "\(Int((index * 100).rounded())) percent difference, heavier on the \(favoured.label.lowercased())"
        }
        return "\(Int((index * 100).rounded())) percent difference between feet"
    }

    // MARK: - Empty
    //
    // No insole, no numbers. This behaviour predates the redesign and is the
    // one thing the redesign must not lose.

    private var empty: some View {
        VStack(spacing: Thermyx.Space.xl) {
            Spacer(minLength: 0)

            BilateralSoleView(unit: unit) { foot in
                viewModel.scanFor(foot)
                showingPairing = true
            }
            .padding(.horizontal, Thermyx.Space.screen)

            VStack(spacing: Thermyx.Space.m) {
                Text("No sensor connected")
                    .font(ThermyxFont.featureHeadline)
                    .tracking(-0.8)
                    .foregroundStyle(Thermyx.Ink.textPrimary)
                    .multilineTextAlignment(.center)

                Text("Thermyx shows no estimated readings. Connect a sensor or pair a left or right insole — or both — and live readings start here.")
                    .font(ThermyxFont.body)
                    .foregroundStyle(Thermyx.Ink.textSupporting)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: Thermyx.Space.m) {
                Button("Connect a device") {
                    showingConnect = true
                }
                .buttonStyle(ThermyxPrimaryButtonStyle())
                .fixedSize(horizontal: true, vertical: false)

                Button {
                    showingPairing = true
                } label: {
                    Text("Pair insoles")
                        .narrowLabel(ThermyxFont.statusPill, tracking: ThermyxTracking.statusPill, color: Thermyx.Ink.ice)
                        .frame(minHeight: Thermyx.minimumTapTarget)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }

            if let error = viewModel.ble.errorMessage {
                Text(error)
                    .font(ThermyxFont.captionSmall)
                    .foregroundStyle(Thermyx.Ink.amber)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, Thermyx.Space.wide)
    }
}
