import Charts
import SwiftUI

/// The week at a glance: the streak, each day's wear coloured by how hot it
/// got, and this week against last, figure by figure.
struct WeeklyReportView: View {
    @EnvironmentObject private var viewModel: ThermyxViewModel
    @ObservedObject var settings: ThermyxSettingsStore

    private var unit: TemperatureUnit { settings.temperatureUnit }

    var body: some View {
        let days = ThermyxDailySummary.days(hourSamples: viewModel.history.hourSamples, events: viewModel.history.events)
        let report = ThermyxWeeklyReport.make(days: days)
        ThermyxDetailScreen(title: "This week", caption: rangeCaption(report), backTitle: "Insights") {
            streak(report)
            dailyBars(report)
            comparison(report)
            highlights(report)
            Text("A day counts once you've worn the insoles for 10 minutes. Steps come from Apple Health when it's allowed, otherwise from the insoles.")
                .font(ThermyxFont.captionSmall)
                .foregroundStyle(Thermyx.Ink.textFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func rangeCaption(_ report: ThermyxWeeklyReport) -> String {
        guard let first = report.days.first?.day, let last = report.days.last?.day else { return "" }
        return "\(first.formatted(.dateTime.month(.abbreviated).day()))–\(last.formatted(.dateTime.day()))"
    }

    // MARK: Streak

    private func streak(_ report: ThermyxWeeklyReport) -> some View {
        HStack(alignment: .center, spacing: Thermyx.Space.l) {
            VStack(spacing: 2) {
                StreakFlame(days: report.streak, size: 64)
                Text("\(report.streak) \(report.streak == 1 ? "day" : "days")")
                    .font(ThermyxFont.captionSmall)
                    .monospacedDigit()
                    .foregroundStyle(Thermyx.Ink.textMuted)
            }
            .frame(width: 72)
            VStack(alignment: .leading, spacing: 4) {
                Text(report.streak > 1 ? "\(report.streak) days in a row" : report.streak == 1 ? "Worn today" : "No streak yet")
                    .font(ThermyxFont.cardTitle)
                    .foregroundStyle(Thermyx.Ink.textPrimary)
                Text(streakLine(report))
                    .font(ThermyxFont.caption)
                    .foregroundStyle(Thermyx.Ink.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Thermyx.Space.row)
        .overlay(alignment: .top) { ThermyxDivider() }
        .accessibilityElement(children: .combine)
    }

    private func streakLine(_ report: ThermyxWeeklyReport) -> String {
        let wornToday = report.days.last.map { $0.wornSeconds >= ThermyxWeeklyReport.minimumWear } ?? false
        if report.streak > 0, !wornToday { return "Wear your insoles today to keep it going." }
        if report.streak > 0 { return "\(report.daysWorn) of the last 7 days worn." }
        return "Wear your insoles for 10 minutes today to start one."
    }

    // MARK: Days

    private func dailyBars(_ report: ThermyxWeeklyReport) -> some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.header) {
            SectionLabel("Time worn each day") {
                Text(DurationFormat.long(report.current.wornSeconds)).monospacedDigit().foregroundStyle(Thermyx.Ink.textMuted)
            }
            Chart(report.days) { day in
                BarMark(
                    x: .value("Day", day.day, unit: .day),
                    y: .value("Hours", day.wornSeconds / 3600),
                    width: .ratio(0.62)
                )
                .foregroundStyle(day.peakFootC.map(FootScale.thermalColor) ?? Thermyx.Tint.track)
                .cornerRadius(4)
                .annotation(position: .top, spacing: 3) {
                    if day.wornSeconds >= ThermyxWeeklyReport.minimumWear {
                        Text(String(format: "%.1f", day.wornSeconds / 3600))
                            .font(ThermyxFont.monoSmall)
                            .foregroundStyle(Thermyx.Ink.textMuted)
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) { value in
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text(date.formatted(.dateTime.weekday(.narrow)))
                                .font(ThermyxFont.axisLabel)
                                .foregroundStyle(Calendar.current.isDateInToday(date) ? Thermyx.Ink.textPrimary : Thermyx.Ink.textFaint)
                        }
                    }
                }
            }
            .chartYAxis(.hidden)
            .frame(height: 140)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Hours worn each day this week")
            .accessibilityValue(report.days.map { "\($0.day.formatted(.dateTime.weekday(.wide))) \(DurationFormat.long($0.wornSeconds))" }.joined(separator: ", "))
            HStack(spacing: Thermyx.Space.s) {
                ChartScaleKey(scale: .footTemperature(unit),
                              low: unit.convert(FootScale.thermalRangeC.lowerBound),
                              high: unit.convert(FootScale.thermalRangeC.upperBound),
                              lowLabel: TemperatureFormat.degrees(FootScale.thermalRangeC.lowerBound, in: unit, decimals: 0),
                              highLabel: TemperatureFormat.degrees(FootScale.thermalRangeC.upperBound, in: unit, decimals: 0))
                Text("colour is the day's peak")
                    .font(ThermyxFont.captionSmall)
                    .foregroundStyle(Thermyx.Ink.textFaint)
            }
        }
        .padding(.top, Thermyx.Space.row)
        .overlay(alignment: .top) { ThermyxDivider() }
    }

    // MARK: Compared with last week

    /// Which way is better for a figure, so the change can be coloured.
    private enum Better { case more, less, neither }

    private func comparison(_ report: ThermyxWeeklyReport) -> some View {
        let now = report.current, before = report.previous
        return VStack(alignment: .leading, spacing: Thermyx.Space.header) {
            SectionLabel("Compared with last week")
            VStack(spacing: 0) {
                row("Days worn", "\(now.daysWorn)", "\(before.daysWorn)", Double(now.daysWorn), Double(before.daysWorn), .more, integer: true)
                row("Time worn", DurationFormat.long(now.wornSeconds), DurationFormat.long(before.wornSeconds),
                    now.wornSeconds, before.wornSeconds, .more)
                row("Steps", now.steps.map { Int($0).formatted() } ?? "—", before.steps.map { Int($0).formatted() } ?? "—",
                    now.steps, before.steps, .more)
                row("Hours warm or hot", "\(now.hotHours)", "\(before.hotHours)", Double(now.hotHours), Double(before.hotHours), .less, integer: true)
                row("Cooling", DurationFormat.long(now.coolingSeconds), DurationFormat.long(before.coolingSeconds),
                    now.coolingSeconds, before.coolingSeconds, .neither)
                row("Heating", DurationFormat.long(now.heatingSeconds), DurationFormat.long(before.heatingSeconds),
                    now.heatingSeconds, before.heatingSeconds, .neither)
                row("Steadiness", now.steadiness.map { "\(Int(($0 * 100).rounded()))%" } ?? "—",
                    before.steadiness.map { "\(Int(($0 * 100).rounded()))%" } ?? "—",
                    now.steadiness.map { $0 * 100 }, before.steadiness.map { $0 * 100 }, .more, integer: true, points: true)
                row("Safety events", "\(now.events)", "\(before.events)", Double(now.events), Double(before.events), .less, integer: true)
            }
            .overlay(alignment: .top) { ThermyxDivider() }
        }
        .padding(.top, Thermyx.Space.row)
    }

    private func row(_ title: String, _ now: String, _ before: String, _ a: Double?, _ b: Double?, _ better: Better,
                     integer: Bool = false, points: Bool = false) -> some View {
        HStack(spacing: Thermyx.Space.m) {
            Text(title)
                .font(ThermyxFont.body)
                .foregroundStyle(Thermyx.Ink.textPrimary)
            Spacer(minLength: Thermyx.Space.xs)
            Text(before)
                .font(ThermyxFont.monoCaption)
                .foregroundStyle(Thermyx.Ink.textFaint)
                .frame(minWidth: 56, alignment: .trailing)
            Image(systemName: "arrow.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Thermyx.Ink.textFaint)
            Text(now)
                .font(.custom(ThermyxFont.Family.monoMedium, size: 15, relativeTo: .body))
                .foregroundStyle(Thermyx.Ink.textPrimary)
                .frame(minWidth: 64, alignment: .trailing)
            change(a, b, better, points: points)
                .frame(width: 54, alignment: .trailing)
        }
        .monospacedDigit()
        .padding(.vertical, Thermyx.Space.s)
        .overlay(alignment: .bottom) { ThermyxDivider() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue("\(now) this week, \(before) last week")
    }

    @ViewBuilder
    private func change(_ a: Double?, _ b: Double?, _ better: Better, points: Bool) -> some View {
        if let a, let b, a == 0, b == 0 {
            Text("same")
                .font(ThermyxFont.monoSmall)
                .foregroundStyle(Thermyx.Ink.textFaint)
        } else if let a, let b, b > 0 || points {
            let delta = points ? a - b : (a - b) / b * 100
            let up = delta > 0.5, down = delta < -0.5
            let good = better == .more ? up : better == .less ? down : false
            let bad = better == .more ? down : better == .less ? up : false
            Text(up || down ? "\(up ? "+" : "−")\(Int(abs(delta).rounded()))\(points ? "" : "%")" : "same")
                .font(ThermyxFont.monoSmall)
                .foregroundStyle(good ? Thermyx.Ink.ice : bad ? Thermyx.Ink.amber : Thermyx.Ink.textFaint)
        } else {
            Text("new")
                .font(ThermyxFont.monoSmall)
                .foregroundStyle(Thermyx.Ink.textFaint)
        }
    }

    // MARK: Highlights

    @ViewBuilder
    private func highlights(_ report: ThermyxWeeklyReport) -> some View {
        let worn = report.days.filter { $0.wornSeconds >= ThermyxWeeklyReport.minimumWear }
        if !worn.isEmpty {
            VStack(alignment: .leading, spacing: Thermyx.Space.header) {
                SectionLabel("Highlights")
                VStack(alignment: .leading, spacing: Thermyx.Space.s) {
                    if let hottest = worn.filter({ $0.peakFootC != nil }).max(by: { $0.peakFootC! < $1.peakFootC! }), let peak = hottest.peakFootC {
                        highlight("thermometer.high", tint: FootScale.thermalColor(peak),
                                  "Warmest day: \(hottest.day.formatted(.dateTime.weekday(.wide))), peaking at \(TemperatureFormat.degrees(peak, in: unit)).")
                    }
                    if let most = worn.filter({ $0.steps != nil }).max(by: { $0.steps! < $1.steps! }), let steps = most.steps {
                        highlight("figure.walk", tint: Thermyx.Ink.ice,
                                  "Most steps: \(most.day.formatted(.dateTime.weekday(.wide))), \(Int(steps).formatted()).")
                    }
                    if let longest = worn.max(by: { $0.wornSeconds < $1.wornSeconds }) {
                        highlight("clock", tint: Thermyx.Ink.textMuted,
                                  "Longest day: \(longest.day.formatted(.dateTime.weekday(.wide))), \(DurationFormat.long(longest.wornSeconds)).")
                    }
                }
            }
            .padding(.top, Thermyx.Space.row)
        }
    }

    private func highlight(_ symbol: String, tint: Color, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Thermyx.Space.m) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 20)
                .accessibilityHidden(true)
            Text(text)
                .font(ThermyxFont.bodySmall)
                .foregroundStyle(Thermyx.Ink.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
