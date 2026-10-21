import AppIntents
import Charts
import SwiftUI
import WidgetKit

// The pieces every widget surface is built from. They live here, not in the
// widget extension, so the app can draw them too (the debug widget gallery
// renders each size without a device).

/// The app's faces: Archivo for words and the big numeral, Geist Mono for
/// figures. Falls back to the system font if a face didn't register.
enum WidgetFont {
    static func numeral(_ size: CGFloat) -> Font { .custom("Archivo-Bold", size: size) }
    static func label(_ size: CGFloat) -> Font { .custom("Archivo-SemiBold", size: size) }
    static func body(_ size: CGFloat) -> Font { .custom("Archivo-Medium", size: size) }
    static func mono(_ size: CGFloat) -> Font { .custom("GeistMono-Medium", size: size) }
}

/// Temperature bands, in °C, as the app draws them on its charts.
enum WidgetTemperatureBands {
    static let comfortC: ClosedRange<Double> = 30...34
    static let elevatedC = 38.0
}

/// What a surface needs to draw: the snapshot, what time it is, and which
/// measurement the sole shows.
struct WidgetContext {
    var snapshot: ThermyxWidgetSnapshot?
    var now: Date = .now
    var soleView: ThermyxSoleView = .temperature
    /// A Live Activity iOS has marked stale.
    var stale = false

    var live: Bool { !stale && (snapshot?.isLive(at: now) ?? false) }

    func soleContent(isLeft: Bool) -> WidgetSole.Content {
        guard live, let s = snapshot else { return .empty }
        switch soleView {
        case .temperature: return .temperature(isLeft ? s.leftC : s.rightC)
        case .pressure: return .load(isLeft ? s.leftLoad : s.rightLoad)
        case .gait: return .steadiness(isLeft ? s.leftSteady : s.rightSteady)
        }
    }

    /// "93.3°", "47%", "88%".
    func soleValue(isLeft: Bool) -> String {
        guard live, let s = snapshot else { return "—" }
        switch soleView {
        case .temperature: return s.temperature(isLeft ? s.leftC : s.rightC)
        case .pressure: return (isLeft ? s.leftLoad : s.rightLoad).map { "\(Int(($0 * 100).rounded()))%" } ?? "—"
        case .gait: return (isLeft ? s.leftSteady : s.rightSteady).map { "\(Int(($0 * 100).rounded()))%" } ?? "—"
        }
    }
}

// MARK: - Sole

/// One foot's outline, filled the way Home's maps fill it: the temperature
/// ramp, the arch sensor's load as a glow where the sensor sits, or the
/// steadiness scale. Only what the insole measures is drawn.
struct WidgetSole: View {
    enum Content: Equatable {
        case temperature(Double?)
        case load(Double?)
        case steadiness(Double?)
        case empty
    }

    let isLeft: Bool
    var content: Content
    /// For Lock Screen widgets, which iOS tints one colour: warmth reads as
    /// brightness instead of hue.
    var monochrome = false

    private struct Outline: Shape {
        let isLeft: Bool
        func path(in rect: CGRect) -> Path { ThermyxFootShape.path(isLeft: isLeft, in: rect) }
    }

    var body: some View {
        GeometryReader { geo in
            let rect = CGRect(origin: .zero, size: geo.size).insetBy(dx: 1, dy: 1)
            ZStack {
                Outline(isLeft: isLeft).fill(base)
                glow(in: rect)
                    .mask(Outline(isLeft: isLeft))
                Outline(isLeft: isLeft)
                    .stroke(Color.white.opacity(monochrome ? 0.9 : 0.3), lineWidth: max(0.8, geo.size.width / 38))
            }
        }
        .aspectRatio(ThermyxFootShape.aspect, contentMode: .fit)
        .accessibilityHidden(true)
    }

    private var base: Color {
        switch content {
        case .temperature(let c?):
            return monochrome ? Color.white.opacity(0.22 + 0.78 * min(max(FootScale.thermalPosition(c), 0), 1)) : FootScale.thermalColor(c)
        case .steadiness(let v?):
            return monochrome ? Color.white.opacity(0.22 + 0.78 * min(max(v, 0), 1)) : ChartValueScale.steadiness.color(at: v * 100)
        case .load:
            return monochrome ? Color.white.opacity(0.1) : FootScale.unsensed
        case .temperature(nil), .steadiness(nil), .empty:
            return monochrome ? Color.white.opacity(0.08) : FootScale.unsensed.opacity(0.7)
        }
    }

    /// The arch sensor's glow, where the one sensor sits.
    @ViewBuilder
    private func glow(in rect: CGRect) -> some View {
        if case .load(let level?) = content, level > 0.02 {
            let box = ThermyxFootShape.fitted(in: rect)
            let c = ThermyxFootShape.point(m: ThermyxFootShape.archSite.m, v: ThermyxFootShape.archSite.v, isLeft: isLeft, in: rect)
            let r = box.width * (0.3 + 0.12 * min(level, 1))
            let color = monochrome ? Color.white : FootScale.loadColor(min(1, level))
            Ellipse()
                .fill(RadialGradient(colors: [color, color.opacity(0.55), color.opacity(0)],
                                     center: .center, startRadius: 0, endRadius: r * 1.3))
                .frame(width: r * 2.6, height: r * 3.4)
                .position(c)
        } else {
            Color.clear
        }
    }
}

/// Left and right, side by side, each showing the chosen measurement.
struct WidgetSolePair: View {
    let context: WidgetContext
    var height: CGFloat
    var monochrome = false
    /// The value under each sole.
    var showsValues = false

    var body: some View {
        HStack(alignment: .top, spacing: max(3, height * 0.07)) {
            ForEach([true, false], id: \.self) { isLeft in
                VStack(spacing: 3) {
                    WidgetSole(isLeft: isLeft, content: context.soleContent(isLeft: isLeft), monochrome: monochrome)
                        .frame(height: height)
                    if showsValues {
                        Text(context.soleValue(isLeft: isLeft))
                            .font(WidgetFont.mono(max(9, height * 0.13)))
                            .monospacedDigit()
                            .foregroundStyle(ThermyxWidgetInk.muted)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                }
                .frame(width: height * ThermyxFootShape.aspect + (showsValues ? height * 0.2 : 0))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(context.soleView.label). Left \(context.soleValue(isLeft: true)), right \(context.soleValue(isLeft: false)).")
    }
}

/// A sole pair that, on a Home Screen widget, steps through Temperature,
/// Pressure and Gait when tapped, and says which it's showing.
struct WidgetSoleButton: View {
    let context: WidgetContext
    var height: CGFloat
    var showsValues = false
    var showsCaption = true

    var body: some View {
        Button(intent: CycleSoleViewIntent()) {
            VStack(spacing: 4) {
                WidgetSolePair(context: context, height: height, showsValues: showsValues)
                if showsCaption {
                    HStack(spacing: 3) {
                        Text(context.soleView.shortLabel)
                        Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 7, weight: .bold))
                    }
                    .font(WidgetFont.body(9))
                    .foregroundStyle(ThermyxWidgetInk.faint)
                    .lineLimit(1)
                    .fixedSize()
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint("Shows the next measurement.")
    }
}

// MARK: - Trend chart

/// The foot temperature over the last half hour, drawn as the app draws its
/// temperature chart: the line takes the colour of the temperature it's at
/// (blue cool, ember hot), over a faint comfort band and a dashed "elevated"
/// line, with the area fading under it.
struct WidgetTrendChart: View {
    enum Style { case full, compact, mono }

    let temps: [Float]
    var fahrenheit = false
    var style: Style = .full
    /// Right-hand temperature labels, grid lines and the time labels.
    var showsAxes = false

    private var values: [Double] { temps.map(Double.init) }
    private static let scale = ChartValueScale.footTemperatureCelsius

    /// Frames the data with a little headroom, and always the comfort band:
    /// the app's rule (never anchored to zero, at least four degrees).
    static func domain(_ values: [Double]) -> ClosedRange<Double> {
        let all = values + [WidgetTemperatureBands.comfortC.lowerBound, WidgetTemperatureBands.comfortC.upperBound]
        guard let lo = all.min(), let hi = all.max() else { return 0...1 }
        let span = max(hi - lo, 4)
        let pad = span * 0.18
        return (lo - pad)...(hi + pad)
    }

    var body: some View {
        if values.count < 3 {
            Text("Building the trend…")
                .font(WidgetFont.body(10))
                .foregroundStyle(ThermyxWidgetInk.faint)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 3) {
                chart
                if showsAxes {
                    HStack {
                        Text("\(ThermyxWidgetSnapshot.windowMinutes) min ago")
                        Spacer()
                        Text("now")
                    }
                    .font(WidgetFont.mono(9))
                    .foregroundStyle(ThermyxWidgetInk.faint)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Foot temperature over the last \(ThermyxWidgetSnapshot.windowMinutes) minutes")
            .accessibilityValue(summary)
        }
    }

    private var chart: some View {
        let v = values
        let domain = Self.domain(v)
        let lo = v.min() ?? 0, hi = v.max() ?? 1
        let peakIndex = v.indices.max { v[$0] < v[$1] } ?? 0
        let n = v.count
        let mono = style == .mono
        let lineGradient = Self.scale.gradient(from: lo, to: hi)
        let areaGradient = Self.scale.gradient(from: domain.lowerBound, to: hi) { t in 0.02 + 0.34 * t * t }
        return Chart {
            if !mono {
                RectangleMark(yStart: .value("Comfort low", WidgetTemperatureBands.comfortC.lowerBound),
                              yEnd: .value("Comfort high", WidgetTemperatureBands.comfortC.upperBound))
                    .foregroundStyle(ThermyxWidgetInk.signal.opacity(0.13))
                if domain.contains(WidgetTemperatureBands.elevatedC) {
                    RuleMark(y: .value("Elevated", WidgetTemperatureBands.elevatedC))
                        .foregroundStyle(ThermyxWidgetInk.ember.opacity(0.7))
                        .lineStyle(StrokeStyle(lineWidth: 0.8, dash: [3, 3]))
                }
            }
            ForEach(0..<n, id: \.self) { i in
                if !mono {
                    AreaMark(x: .value("t", i), yStart: .value("floor", domain.lowerBound), yEnd: .value("°C", v[i]),
                             series: .value("series", "area"))
                        .foregroundStyle(areaGradient)
                        .interpolationMethod(.monotone)
                }
                LineMark(x: .value("t", i), y: .value("°C", v[i]), series: .value("series", "line"))
                    .foregroundStyle(mono ? AnyShapeStyle(Color.white) : AnyShapeStyle(lineGradient))
                    .lineStyle(StrokeStyle(lineWidth: style == .full ? 2.4 : (mono ? 1.8 : 2), lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)
            }
            // The latest reading, haloed.
            if !mono {
                PointMark(x: .value("t", n - 1), y: .value("°C", v[n - 1]))
                    .foregroundStyle(Self.scale.color(at: v[n - 1]).opacity(0.3))
                    .symbolSize(style == .full ? 200 : 110)
                PointMark(x: .value("t", n - 1), y: .value("°C", v[n - 1]))
                    .foregroundStyle(Self.scale.color(at: v[n - 1]))
                    .symbolSize(style == .full ? 46 : 28)
            }
            // The peak, labelled, on the full chart.
            if showsAxes, peakIndex != n - 1 {
                PointMark(x: .value("t", peakIndex), y: .value("°C", v[peakIndex]))
                    .foregroundStyle(Self.scale.color(at: v[peakIndex]))
                    .symbolSize(30)
                    .annotation(position: .top, spacing: 2) {
                        Text(String(format: "%.1f°", fahrenheit ? v[peakIndex] * 9 / 5 + 32 : v[peakIndex]))
                            .font(WidgetFont.mono(9))
                            .foregroundStyle(Self.scale.color(at: v[peakIndex]))
                    }
            }
        }
        .chartYScale(domain: domain)
        .chartXScale(domain: 0...(n - 1), range: .plotDimension(startPadding: 2, endPadding: 9))
        .chartXAxis(.hidden)
        .chartYAxis {
            if showsAxes {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine().foregroundStyle(ThermyxWidgetInk.hairline)
                    AxisValueLabel {
                        if let c = value.as(Double.self) {
                            Text("\(Int((fahrenheit ? c * 9 / 5 + 32 : c).rounded()))°")
                                .font(WidgetFont.mono(9))
                                .foregroundStyle(ThermyxWidgetInk.faint)
                        }
                    }
                }
            }
        }
        .chartLegend(.hidden)
        .widgetAccentable(mono)
    }

    private var summary: String {
        guard let lo = temps.min(), let hi = temps.max(), let last = temps.last else { return "No data" }
        func t(_ c: Float) -> String { String(format: "%.1f", fahrenheit ? Double(c) * 9 / 5 + 32 : Double(c)) }
        return "Now \(t(last)), low \(t(lo)), high \(t(hi))"
    }
}

// MARK: - Battery

/// A battery drawn to scale: the fill is the charge, ice normally, amber at
/// 10% and red at 5%.
struct WidgetBatteryGlyph: View {
    let percent: Int?
    var width: CGFloat = 22
    var height: CGFloat = 11

    var body: some View {
        let fraction = CGFloat(min(max(percent ?? 0, 0), 100)) / 100
        HStack(spacing: 1) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: height * 0.3, style: .continuous)
                    .strokeBorder(ThermyxWidgetInk.muted.opacity(percent == nil ? 0.4 : 0.8), lineWidth: 1)
                RoundedRectangle(cornerRadius: height * 0.18, style: .continuous)
                    .fill(ThermyxWidgetInk.battery(percent))
                    .frame(width: max(percent == nil ? 0 : 2, (width - 4) * fraction))
                    .padding(2)
            }
            .frame(width: width, height: height)
            RoundedRectangle(cornerRadius: 1)
                .fill(ThermyxWidgetInk.muted.opacity(0.8))
                .frame(width: 2, height: height * 0.4)
        }
        .accessibilityHidden(true)
    }
}

/// "L ▭ 61%   R ▭ 55%".
struct WidgetBatteryRow: View {
    let snapshot: ThermyxWidgetSnapshot?
    var size: CGFloat = 11

    var body: some View {
        let entries: [(String, Int?)] = [("L", snapshot?.batteryLeft), ("R", snapshot?.batteryRight)].filter { $0.1 != nil }
        HStack(spacing: size * 0.7) {
            if entries.isEmpty {
                Text("Battery —").foregroundStyle(ThermyxWidgetInk.faint)
            }
            ForEach(entries, id: \.0) { side, percent in
                HStack(spacing: 3) {
                    Text(side).foregroundStyle(ThermyxWidgetInk.muted)
                    WidgetBatteryGlyph(percent: percent, width: size * 1.7, height: size * 0.9)
                    Text("\(percent ?? 0)%")
                        .foregroundStyle((percent ?? 100) <= ThermyxWidgetSnapshot.batteryLow ? ThermyxWidgetInk.battery(percent) : ThermyxWidgetInk.text)
                        .monospacedDigit()
                }
            }
        }
        .font(WidgetFont.mono(size))
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entries.isEmpty ? "No battery reading"
                            : entries.map { "\($0.0 == "L" ? "Left" : "Right") insole \($0.1 ?? 0) percent" }.joined(separator: ", "))
    }
}

/// "Left insole 8% · charge soon", amber at 10% and red at 5%.
struct WidgetBatteryWarning: View {
    let snapshot: ThermyxWidgetSnapshot
    /// "Left 8% · charge", for narrow spots.
    var compact = false

    var body: some View {
        if let low = snapshot.lowBattery {
            HStack(spacing: 5) {
                Image(systemName: snapshot.batteryIsCritical ? "battery.0percent" : "battery.25percent")
                    .font(.system(size: 11, weight: .semibold))
                Text(compact
                     ? "\(low.side) \(low.percent)% · charge"
                     : "\(low.side) insole \(low.percent)% · \(snapshot.batteryIsCritical ? "charge now" : "charge soon")")
                    .font(WidgetFont.body(11))
                    .lineLimit(1)
            }
            .foregroundStyle(snapshot.batteryIsCritical ? ThermyxWidgetInk.red : ThermyxWidgetInk.amber)
        }
    }
}

// MARK: - Text pieces

/// "Thermyx · Auto" with the mode dot.
struct WidgetHeader: View {
    let context: WidgetContext

    var body: some View {
        HStack(spacing: 5) {
            if let s = context.snapshot { ThermyxModeDot(mode: s.mode, size: 8) }
            Text(context.snapshot.map { "Thermyx · \($0.mode.label)" } ?? "Thermyx")
                .font(WidgetFont.label(11))
                .foregroundStyle(ThermyxWidgetInk.muted)
            if let s = context.snapshot, s.isDemo {
                // The demo can't tick while iOS has the app suspended.
                let paused = context.now.timeIntervalSince(s.updated) > 90
                Text(paused ? "Simulated · paused" : "Simulated").font(WidgetFont.label(10)).foregroundStyle(ThermyxWidgetInk.amber)
            }
        }
        .lineLimit(1)
    }
}

/// The warmer foot's temperature, big, with its unit small beside it.
struct WidgetNumeral: View {
    let context: WidgetContext
    var size: CGFloat = 40

    var body: some View {
        let s = context.snapshot
        let live = context.live
        HStack(alignment: .top, spacing: 1) {
            Text(live ? (s?.footC.map { String(format: "%.1f", s?.convert($0) ?? $0) } ?? "—") : "—")
                .font(WidgetFont.numeral(size))
                .tracking(-size * 0.045)
                .monospacedDigit()
                .foregroundStyle(live ? ThermyxWidgetInk.text : ThermyxWidgetInk.faint)
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if live {
                Text("°\(s?.unitSymbol ?? "C")")
                    .font(WidgetFont.body(size * 0.34))
                    .foregroundStyle(ThermyxWidgetInk.muted)
                    .padding(.top, size * 0.08)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(live ? "Warmer foot \(s?.temperature(s?.footC) ?? "no reading")" : "No reading")
    }
}

/// The risk level, or the concern behind it.
struct WidgetLevelLine: View {
    let snapshot: ThermyxWidgetSnapshot
    var showsConcern = true
    var lines = 2

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Circle().fill(ThermyxWidgetInk.color(snapshot.level)).frame(width: 6, height: 6)
            Text(showsConcern ? (snapshot.shortConcern ?? snapshot.level.label) : snapshot.level.label)
                .font(WidgetFont.body(11))
                .foregroundStyle(snapshot.level.isConcern ? ThermyxWidgetInk.color(snapshot.level) : ThermyxWidgetInk.muted)
                .lineLimit(lines)
        }
    }
}

/// What shows when the insoles aren't connected.
struct WidgetNotLive: View {
    let snapshot: ThermyxWidgetSnapshot?

    /// "7 min. ago": rounded, so it doesn't count seconds nobody asked for.
    static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: .now)
    }

    var body: some View {
        Group {
            if let snapshot {
                Text("Not connected · \(Self.relative(snapshot.updated))")
            } else {
                Text("Open Thermyx to connect your insoles.")
            }
        }
        .font(WidgetFont.body(11))
        .foregroundStyle(ThermyxWidgetInk.faint)
        .lineLimit(2)
    }
}

// MARK: - Buttons

/// Auto, Cool, Heat, Off as four buttons, the current one filled. Heat shows
/// a lock at High risk and above, as in the app. A tap leaves the request for
/// the app; until it confirms, the requested mode carries an outline.
struct WidgetModeButtons: View {
    let context: WidgetContext
    var height: CGFloat = 30

    var body: some View {
        let live = context.live
        let current = context.snapshot?.mode
        let pending = ThermyxModeInbox.pending(now: context.now)
        HStack(spacing: 6) {
            ForEach(ThermyxWidgetMode.allCases) { mode in
                let locked = mode == .heat && (context.snapshot?.heatLocked ?? false)
                let selected = live && mode == current && (pending == nil || pending == current)
                let sending = live && pending == mode && pending != current
                Button(intent: SetThermalModeIntent(mode: mode)) {
                    HStack(spacing: 5) {
                        if locked {
                            Image(systemName: "lock.fill").font(.system(size: 9, weight: .bold))
                        } else {
                            ThermyxModeDot(mode: mode, size: 8)
                        }
                        Text(mode.label)
                            .font(WidgetFont.label(12))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(selected ? ThermyxWidgetInk.onPrimary : (locked ? ThermyxWidgetInk.faint : ThermyxWidgetInk.text))
                    .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
                    .background(selected ? ThermyxWidgetInk.text : ThermyxWidgetInk.well,
                                in: RoundedRectangle(cornerRadius: height * 0.36, style: .continuous))
                    .overlay {
                        if sending {
                            RoundedRectangle(cornerRadius: height * 0.36, style: .continuous)
                                .strokeBorder(ThermyxWidgetInk.ice, lineWidth: 1.5)
                        }
                    }
                    .opacity(live ? (locked ? 0.45 : 1) : 0.4)
                }
                .buttonStyle(.plain)
                .disabled(!live || locked)
                .accessibilityLabel(locked ? "Heat, locked while your risk level is elevated" : mode.label)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}

/// Temperature, Pressure and Gait as a switch, for the large widget.
struct WidgetSoleSwitch: View {
    let context: WidgetContext
    var height: CGFloat = 26

    var body: some View {
        HStack(spacing: 4) {
            ForEach(ThermyxSoleView.allCases) { view in
                let selected = view == context.soleView
                Button(intent: SetSoleViewIntent(view: view)) {
                    Text(view.label)
                        .font(WidgetFont.label(11))
                        .foregroundStyle(selected ? ThermyxWidgetInk.text : ThermyxWidgetInk.faint)
                        .frame(maxWidth: .infinity, minHeight: height)
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(selected ? ThermyxWidgetInk.ice : .clear).frame(height: 2)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(ThermyxWidgetInk.hairline).frame(height: 1) }
    }
}
