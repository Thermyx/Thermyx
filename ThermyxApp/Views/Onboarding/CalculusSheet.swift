import Charts
import SwiftUI

/// Shows the work behind calibration's rate of change and accumulated
/// change: the formulas, the three curves, and for any second the actual
/// numbers that went into them. Worked in °C, as the model is.
struct CalculusSheet: View {
    let title: String
    let samples: [CalibrationSample]
    let unit: TemperatureUnit

    @Environment(\.dismiss) private var dismiss
    @State private var selected: Int?

    private var steps: [CalculusStep] { ThermalCalculus.steps(samples) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: Thermyx.Space.header) {
                        SiteEyebrow(title)
                        Text("The math")
                            .font(ThermyxFont.display)
                            .tracking(ThermyxTracking.display)
                            .foregroundStyle(Thermyx.Site.text)
                        Text("Every second, Thermyx fits a line to the last 10 seconds of foot temperature to get its slope, then adds those slopes up over time.")
                            .font(ThermyxFont.body)
                            .foregroundStyle(Thermyx.Site.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    formulas
                    let steps = self.steps
                    if steps.count < 3 {
                        Text("The math appears once three seconds of readings are in.")
                            .font(ThermyxFont.body)
                            .foregroundStyle(Thermyx.Site.textFaint)
                    } else {
                        let index = min(selected ?? steps.count - 1, steps.count - 1)
                        curves(steps, selected: index)
                        picker(steps, selected: index)
                        WorkedStep(step: steps[index], previous: index > 0 ? steps[index - 1] : nil, unit: unit)
                    }
                }
                .padding(Thermyx.Space.wide)
            }
            .scrollIndicators(.hidden)
            .background(Thermyx.Site.bg.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .preferredColorScheme(.dark)
        .presentationBackground(Thermyx.Site.bg)
    }

    // MARK: Formulas

    private var formulas: some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.l) {
            formula(name: "Rate of change", notation: "dT/dt",
                    body: "dT/dt ≈ Σ (tᵢ − t̄)(Tᵢ − T̄)  ⁄  Σ (tᵢ − t̄)²",
                    note: "The least-squares slope through the readings of the last 10 s, in °C per second, × 60 for per minute. A fitted line, so one noisy reading can't swing it.")
            Rectangle().fill(Thermyx.Site.hairline).frame(height: 1)
            formula(name: "Accumulated change", notation: "∫ dT/dt dt",
                    body: "ΔT = ∫ (dT/dt) dt  ≈  Σₖ ½ (rₖ₋₁ + rₖ)(tₖ − tₖ₋₁)",
                    note: "The trapezoid rule: each second adds the area under the rate curve between two readings. Summed, it's how far the temperature has moved.")
        }
        .padding(Thermyx.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .siteGlass(radius: Thermyx.Radius.list)
    }

    private func formula(name: String, notation: String, body: String, note: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(name).font(ThermyxFont.rowTitle).foregroundStyle(Thermyx.Site.text)
                Text(notation).mathNotation(size: 14)
            }
            Text(body)
                .font(.system(size: 16, design: .serif).italic())
                .foregroundStyle(Thermyx.Ink.ice)
                .fixedSize(horizontal: false, vertical: true)
            Text(note)
                .font(ThermyxFont.captionSmall)
                .foregroundStyle(Thermyx.Site.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Curves

    private func curves(_ steps: [CalculusStep], selected: Int) -> some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.m) {
            curve("Foot temperature  T(t)", unitLabel: "°C", scale: .footTemperature(.celsius), steps: steps, selected: selected) { $0.c }
            curve("Rate  dT/dt", unitLabel: "°C/min", scale: .change(unitSize: 1), steps: steps, selected: selected) { $0.ratePerMinute }
            curve("Accumulated  ∫ dT/dt dt", unitLabel: "°C", scale: .change(unitSize: 0.6), steps: steps, selected: selected) { $0.accumulated }
        }
    }

    private func curve(_ label: String, unitLabel: String, scale: ChartValueScale, steps: [CalculusStep], selected: Int,
                       value: @escaping (CalculusStep) -> Double?) -> some View {
        let values = steps.compactMap(value)
        let low = values.min() ?? 0, high = values.max() ?? 0
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).mathNotation(size: 13)
                Spacer()
                Text(value(steps[selected]).map { String(format: "%.3f %@", $0, unitLabel) } ?? "—")
                    .font(ThermyxFont.captionSmall)
                    .monospacedDigit()
                    .foregroundStyle(value(steps[selected]).map(scale.color(at:)) ?? Thermyx.Site.text)
            }
            Chart {
                ForEach(steps) { s in
                    if let v = value(s) {
                        LineMark(x: .value("t", s.t), y: .value(label, v))
                            .foregroundStyle(scale.gradient(from: low, to: high))
                            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                            .interpolationMethod(.monotone)
                    }
                }
                RuleMark(x: .value("t", steps[selected].t))
                    .foregroundStyle(Thermyx.Ink.textPrimary.opacity(0.5))
            }
            .chartYScale(domain: .automatic(includesZero: false))
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { v in
                    AxisValueLabel { if let t = v.as(Double.self) { Text("\(Int(t)) s").font(ThermyxFont.captionSmall).foregroundStyle(Thermyx.Site.textFaint) } }
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { v in
                    AxisGridLine().foregroundStyle(Thermyx.Site.hairline)
                    AxisValueLabel { if let y = v.as(Double.self) { Text(String(format: "%.2f", y)).font(ThermyxFont.captionSmall).foregroundStyle(Thermyx.Site.textFaint) } }
                }
            }
            .frame(height: 96)
        }
        .padding(Thermyx.Space.m)
        .siteGlass(radius: Thermyx.Radius.compact)
    }

    private func picker(_ steps: [CalculusStep], selected: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SiteEyebrow("Pick a moment · t = \(Int(steps[selected].t)) s")
            Slider(value: Binding(get: { Double(selected) }, set: { self.selected = Int($0.rounded()) }),
                   in: 0...Double(steps.count - 1), step: 1)
                .tint(Thermyx.Ink.ember)
                .accessibilityLabel("Moment")
                .accessibilityValue("\(Int(steps[selected].t)) seconds")
        }
    }
}

/// The numbers for one second, plugged into the formulas.
private struct WorkedStep: View {
    let step: CalculusStep
    let previous: CalculusStep?
    let unit: TemperatureUnit

    var body: some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.m) {
            SiteEyebrow("Worked out at t = \(Int(step.t)) s", color: Thermyx.Ink.ice)
            line("Reading", "T(\(Int(step.t))) = \(f(step.c, 2)) °C")
            VStack(alignment: .leading, spacing: 4) {
                Text("Window: the \(step.window.count) readings from t = \(Int(step.window.first?.t ?? 0)) to \(Int(step.t)) s")
                    .font(ThermyxFont.captionSmall)
                    .foregroundStyle(Thermyx.Site.textMuted)
                Text(step.window.map { "(\(Int($0.t)), \(f($0.c, 2)))" }.joined(separator: "  "))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Thermyx.Site.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let rate = step.ratePerMinute {
                line("Means", "t̄ = \(f(step.tBar, 2)) s,   T̄ = \(f(step.cBar, 3)) °C")
                line("Numerator", "Σ (tᵢ − t̄)(Tᵢ − T̄) = \(f(step.covariance, 4))")
                line("Denominator", "Σ (tᵢ − t̄)² = \(f(step.spread, 2))")
                line("Slope", "\(f(step.covariance, 4)) ⁄ \(f(step.spread, 2)) = \(f(rate / 60, 5)) °C/s")
                line("dT/dt", "× 60 = \(f(rate, 3)) °C/min" + (unit == .fahrenheit ? "  (\(f(rate * 9 / 5, 3)) °F/min)" : ""))
                if let area = step.area, let prev = previous?.ratePerMinute {
                    line("Trapezoid", "½ (\(f(prev / 60, 5)) + \(f(rate / 60, 5))) × \(f(step.t - (previous?.t ?? step.t), 0)) s = \(f(area, 5)) °C")
                } else {
                    line("Trapezoid", "First rate: the integral starts here at 0.")
                }
                if let total = step.accumulated {
                    line("∫ so far", "\(f(total, 4)) °C" + (unit == .fahrenheit ? "  (\(f(total * 9 / 5, 4)) °F)" : ""))
                }
            } else {
                Text("A slope needs three readings; this second doesn't have them yet.")
                    .font(ThermyxFont.caption)
                    .foregroundStyle(Thermyx.Site.textFaint)
            }
        }
        .padding(Thermyx.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .siteGlass(radius: Thermyx.Radius.list)
    }

    private func line(_ label: String, _ math: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .narrowLabel(ThermyxFont.zoneLabel, tracking: ThermyxTracking.zoneLabel, color: Thermyx.Site.textFaint)
            Text(math)
                .font(.system(size: 15, design: .serif).italic())
                .monospacedDigit()
                .foregroundStyle(Thermyx.Site.text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func f(_ x: Double, _ decimals: Int) -> String { String(format: "%.\(decimals)f", x) }
}
