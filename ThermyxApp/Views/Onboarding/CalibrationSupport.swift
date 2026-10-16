import SwiftUI

/// Home: "Calibrate Thermyx" before the first calibration, "Finish
/// calibration" while the outdoor half is still to do.
struct CalibrationPromptCard: View {
    @EnvironmentObject private var viewModel: ThermyxViewModel
    @ObservedObject var baseline: PersonalBaselineStore
    @ObservedObject var settings: ThermyxSettingsStore
    @State private var presenting = false

    /// A model saved by an older build from test data: calibrate again.
    private var retrain: Bool { baseline.model?.isTestData == true }

    private var showsCard: Bool {
        guard viewModel.anyConnected, !viewModel.ble.isDemoMode else { return false }
        return retrain || baseline.model?.outdoorDone != true
    }

    var body: some View {
        if showsCard {
            let finishing = baseline.model != nil && baseline.model?.isTestData != true
            Button { presenting = true } label: {
                HStack(spacing: Thermyx.Space.m) {
                    Image(systemName: "figure.walk.motion")
                        .foregroundStyle(Thermyx.Ink.ice)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(finishing ? "Finish calibration" : (retrain ? "Calibrate with your insoles" : "Calibrate Thermyx"))
                            .font(ThermyxFont.rowTitle)
                            .foregroundStyle(Thermyx.Ink.textPrimary)
                        Text(finishing ? "90 seconds outside to complete your profile."
                             : retrain ? "Your saved norms came from test data, not your feet."
                             : "3 minutes. Learns your normal and sets Auto for you.")
                            .font(ThermyxFont.captionSmall)
                            .foregroundStyle(Thermyx.Ink.textSupporting)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(Thermyx.Ink.textFaint)
                }
                .padding(Thermyx.Space.m)
                .background(Thermyx.Ink.deck, in: RoundedRectangle(cornerRadius: Thermyx.Radius.control, style: .continuous))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .fullScreenCover(isPresented: $presenting) {
                NavigationStack {
                    CalibrationView(viewModel: viewModel, settings: settings, outdoorOnly: finishing)
                }
                .environmentObject(viewModel)
            }
        }
    }
}

/// Settings → Advanced: calibration status, redo, and clear.
struct CalibrationSettingsSection: View {
    @EnvironmentObject private var viewModel: ThermyxViewModel
    @ObservedObject var baseline: PersonalBaselineStore
    @ObservedObject var settings: ThermyxSettingsStore
    @State private var presenting = false

    var body: some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.header) {
            SectionLabel("Calibration")
            ThermyxCard {
                VStack(alignment: .leading, spacing: Thermyx.Space.m) {
                    if let model = baseline.model {
                        Text(model.outdoorDone ? "Calibrated inside and outside" : "Calibrated inside · outside half not done")
                            .font(ThermyxFont.rowTitle)
                            .foregroundStyle(Thermyx.Ink.textPrimary)
                        Text(verbatim: "Trained \(model.trainedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(ThermyxFont.captionSmall)
                            .foregroundStyle(Thermyx.Ink.textSupporting)
                        CalibrationNorms(model: model, unit: settings.temperatureUnit)
                    } else {
                        Text("Not calibrated yet")
                            .font(ThermyxFont.rowTitle)
                            .foregroundStyle(Thermyx.Ink.textPrimary)
                    }
                    HStack(spacing: Thermyx.Space.m) {
                        Button(baseline.model == nil ? "Calibrate" : "Calibrate again") { presenting = true }
                            .buttonStyle(ThermyxSecondaryButtonStyle())
                            .disabled(!viewModel.anyConnected || viewModel.ble.isDemoMode)
                        if baseline.model != nil {
                            Button("Clear") {
                                baseline.clearModel()
                                CalibrationEngine.clearSaved()
                            }
                            .buttonStyle(ThermyxSecondaryButtonStyle(tint: Thermyx.Ink.amber, border: Thermyx.Tint.emberBorder))
                        }
                    }
                    Text("Calibration learns your usual foot temperature inside and out, how fast it changes, your load, cadence and walking steadiness, and sets Auto's target, all on this phone. It can only add caution.")
                        .font(ThermyxFont.captionSmall)
                        .foregroundStyle(Thermyx.Ink.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .fullScreenCover(isPresented: $presenting) {
            NavigationStack { CalibrationView(viewModel: viewModel, settings: settings) }
                .environmentObject(viewModel)
        }
    }
}

/// The learned norms: Auto's target, usual temperatures inside and out, how
/// the temperature moves, walking steadiness, and the activity model.
struct CalibrationNorms: View {
    let model: PersonalThermalModel
    let unit: TemperatureUnit

    var body: some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.s) {
            if let target = model.comfortTargetC {
                row("Auto target", TemperatureFormat.degrees(target, in: unit))
            }
            ForEach(CalibrationActivity.allCases) { activity in
                if let inside = model.footByActivity[activity] {
                    let outside = model.outdoorFootByActivity?[activity]
                    row("Usual · \(activity.label.lowercased())",
                        TemperatureFormat.degrees(inside.mean, in: unit) + " in" + (outside.map { " · " + TemperatureFormat.degrees($0.mean, in: unit) + " out" } ?? ""))
                }
            }
            if let fastest = model.phases?.filter({ $0.ratePerMinute != nil }).max(by: { abs($0.ratePerMinute!) < abs($1.ratePerMinute!) }),
               let rate = fastest.ratePerMinute {
                row("Fastest change", notation: "dT/dt", "\(Self.rate(rate, in: unit)) · \(fastest.activity.label.lowercased()) \(fastest.outdoor ? "out" : "in")")
            }
            let outside = model.phases?.filter(\.outdoor).compactMap(\.accumulatedC) ?? []
            if !outside.isEmpty {
                row("Change outside", notation: "∫ dT/dt dt", Self.signedDelta(outside.reduce(0, +), in: unit, decimals: 2))
            }
            if let air = model.outdoorAirC {
                row("Outside air · local weather", TemperatureFormat.degrees(air, in: unit))
            }
            if let stability = model.walkingStability {
                row("Walking steadiness", "\(Int((stability.mean * 100).rounded()))% · steady above \(Int((stability.steadyFloor * 100).rounded()))%")
            }
            if let load = model.loadByActivity?[.standing] {
                row("Load standing", "\(Int((load.mean * 100).rounded()))%")
            }
            if let accuracy = model.classifierAccuracy {
                row("Activity model accuracy", "\(Int((accuracy * 100).rounded()))%")
            } else {
                Text("Activity detection needs the pressure and motion sensors, so it will switch on once they report.")
                    .font(ThermyxFont.captionSmall)
                    .foregroundStyle(Thermyx.Ink.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// "+0.21°/min". A rate is a difference, so Fahrenheit scales it without
    /// the offset.
    static func rate(_ perMinute: Double, in unit: TemperatureUnit) -> String {
        signedDelta(perMinute, in: unit, decimals: 2) + "/min"
    }

    static func signedDelta(_ celsius: Double, in unit: TemperatureUnit, decimals: Int = 1) -> String {
        let value = unit.convertDelta(celsius)
        let text = String(format: "%.\(decimals)f", abs(value))
        return (Double(text) == 0 ? "" : (value > 0 ? "+" : "−")) + text + "°"
    }

    private func row(_ label: String, notation: String? = nil, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(ThermyxFont.caption).foregroundStyle(Thermyx.Ink.textSupporting)
            if let notation { Text(notation).mathNotation(size: 12) }
            Spacer(minLength: Thermyx.Space.s)
            Text(verbatim: value)
                .font(ThermyxFont.rowTitle)
                .monospacedDigit()
                .foregroundStyle(Thermyx.Ink.textPrimary)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

