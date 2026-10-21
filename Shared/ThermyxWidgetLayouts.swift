import Charts
import SwiftUI
import WidgetKit

// One layout per surface: Home Screen small, medium and large; the Lock
// Screen accessories; the Live Activity banner; and the Dynamic Island.

// MARK: - Home Screen

/// Small: the temperature, the soles (tap to change what they show), a
/// short trend, and both batteries.
struct WidgetSmallLayout: View {
    let context: WidgetContext

    var body: some View {
        let s = context.snapshot
        VStack(alignment: .leading, spacing: 0) {
            WidgetHeader(context: context)
            Spacer(minLength: 3)
            HStack(alignment: .bottom, spacing: 4) {
                VStack(alignment: .leading, spacing: 3) {
                    WidgetNumeral(context: context, size: 36)
                    if context.live, let s {
                        WidgetLevelLine(snapshot: s, showsConcern: false, lines: 1)
                    }
                }
                Spacer(minLength: 0)
                WidgetSoleButton(context: context, height: 50)
            }
            Spacer(minLength: 5)
            if context.live, let s {
                WidgetTrendChart(temps: s.temps, fahrenheit: s.fahrenheit, style: .compact)
                    .frame(height: 22)
            } else {
                WidgetNotLive(snapshot: s)
            }
            Spacer(minLength: 5)
            if context.live, let s, s.lowBattery != nil {
                WidgetBatteryWarning(snapshot: s, compact: true)
            } else {
                WidgetBatteryRow(snapshot: context.live ? s : nil, size: 10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
    }
}

/// Medium, and the Live Activity banner: temperature, level and battery on
/// the left, the soles in the middle, the trend on the right, and the four
/// mode buttons underneath.
struct WidgetMediumLayout: View {
    let context: WidgetContext

    var body: some View {
        let s = context.snapshot
        VStack(spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    WidgetHeader(context: context)
                    WidgetNumeral(context: context, size: 34)
                    if context.live, let s {
                        WidgetLevelLine(snapshot: s, lines: 2)
                    }
                    Spacer(minLength: 2)
                    if context.live, let s, s.lowBattery != nil {
                        WidgetBatteryWarning(snapshot: s, compact: true)
                    } else {
                        WidgetBatteryRow(snapshot: context.live ? s : nil, size: 10)
                    }
                }
                .frame(width: 124, alignment: .leading)
                WidgetSoleButton(context: context, height: 62)
                Group {
                    if context.live, let s {
                        WidgetTrendChart(temps: s.temps, fahrenheit: s.fahrenheit, style: .compact)
                    } else {
                        WidgetNotLive(snapshot: s)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)
            WidgetModeButtons(context: context, height: 30)
        }
        .accessibilityElement(children: .contain)
    }
}

/// Large: the full picture. The temperature and level, both soles with their
/// values, a switch between Temperature, Pressure and Gait, the trend with
/// its axes, the mode buttons and the batteries.
struct WidgetLargeLayout: View {
    let context: WidgetContext

    var body: some View {
        let s = context.snapshot
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                WidgetHeader(context: context)
                Spacer()
                WidgetBatteryRow(snapshot: context.live ? s : nil, size: 10)
            }
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    WidgetNumeral(context: context, size: 56)
                    if context.live, let s {
                        WidgetLevelLine(snapshot: s, lines: 3)
                        WidgetBatteryWarning(snapshot: s)
                    } else {
                        WidgetNotLive(snapshot: s)
                    }
                }
                Spacer(minLength: 0)
                WidgetSolePair(context: context, height: 96, showsValues: true)
            }
            WidgetSoleSwitch(context: context)
            if context.live, let s {
                WidgetTrendChart(temps: s.temps, fahrenheit: s.fahrenheit, style: .full, showsAxes: true)
                    .frame(maxHeight: .infinity)
            } else {
                Spacer(minLength: 0)
            }
            WidgetModeButtons(context: context, height: 34)
        }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Lock Screen

/// Rectangular: the soles (brightness is warmth, since iOS tints these one
/// colour), the temperature, a thin trend, and one line of status.
struct WidgetRectangularLayout: View {
    let context: WidgetContext

    var body: some View {
        let s = context.snapshot
        if context.live, let s {
            HStack(spacing: 8) {
                WidgetSolePair(context: context, height: 50, monochrome: true)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(s.footText)
                            .font(.system(size: 18, weight: .semibold))
                            .widgetAccentable()
                        Text(s.mode.label)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    WidgetTrendChart(temps: s.temps, fahrenheit: s.fahrenheit, style: .mono)
                        .frame(height: 20)
                    Text(status(s))
                        .font(.system(size: 12, weight: s.level.isConcern || s.lowBattery != nil ? .semibold : .regular))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 1) {
                Text("Thermyx").font(.system(size: 15, weight: .semibold)).widgetAccentable()
                Text(s == nil ? "Open to connect" : "Not connected")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    private func status(_ s: ThermyxWidgetSnapshot) -> String {
        if s.level.isConcern, let tiny = s.tinyConcern { return tiny }
        if let low = s.lowBattery { return "\(low.side) \(low.percent)% · charge" }
        let batteries = [s.batteryLeft, s.batteryRight].compactMap { $0.map(String.init) }
        return batteries.isEmpty ? s.level.label : "\(s.level.label) · \(batteries.joined(separator: "/"))%"
    }
}

/// Circular: the temperature on a gauge that fills as the foot warms.
struct WidgetCircularLayout: View {
    let context: WidgetContext

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            if context.live, let s = context.snapshot, let c = s.footC {
                Gauge(value: min(max(FootScale.thermalPosition(c), 0), 1)) {
                    Image(systemName: s.level.isConcern ? "exclamationmark.triangle.fill" : "shoeprints.fill")
                } currentValueLabel: {
                    Text(String(format: "%.0f", s.convert(c)))
                        .font(.system(size: 17, weight: .semibold))
                        .minimumScaleFactor(0.6)
                }
                .gaugeStyle(.accessoryCircular)
                .widgetAccentable()
            } else {
                VStack(spacing: 0) {
                    Image(systemName: "shoeprints.fill").font(.system(size: 16))
                    Text("—").font(.system(size: 11))
                }
            }
        }
    }
}

struct WidgetInlineLayout: View {
    let context: WidgetContext

    var body: some View {
        if context.live, let s = context.snapshot {
            let batteries = [("L", s.batteryLeft), ("R", s.batteryRight)].compactMap { side, p in p.map { "\(side)\($0)%" } }
            Text(([s.footText, s.mode.label] + batteries).joined(separator: " · "))
        } else {
            Text("Thermyx · not connected")
        }
    }
}

// MARK: - Dynamic Island

/// The expanded island, left of the sensor: the temperature and level.
struct IslandLeading: View {
    let context: WidgetContext

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            WidgetHeader(context: context)
            WidgetNumeral(context: context, size: 32)
            if let s = context.snapshot, context.live {
                WidgetLevelLine(snapshot: s, showsConcern: false, lines: 1)
            }
        }
        .padding(.leading, 4)
    }
}

/// The expanded island, right of the sensor: the soles, and both batteries.
struct IslandTrailing: View {
    let context: WidgetContext

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .trailing, spacing: 4) {
                ForEach([("L", context.snapshot?.batteryLeft), ("R", context.snapshot?.batteryRight)], id: \.0) { side, percent in
                    if let percent {
                        HStack(spacing: 3) {
                            Text(side).foregroundStyle(ThermyxWidgetInk.muted)
                            WidgetBatteryGlyph(percent: percent, width: 18, height: 9)
                            Text("\(percent)%")
                                .foregroundStyle((percent) <= ThermyxWidgetSnapshot.batteryLow ? ThermyxWidgetInk.battery(percent) : ThermyxWidgetInk.text)
                                .monospacedDigit()
                        }
                        .font(WidgetFont.mono(9))
                    }
                }
            }
            WidgetSolePair(context: context, height: 48)
        }
        .padding(.trailing, 4)
    }
}

/// The expanded island's bottom: the trend, then the mode buttons.
struct IslandBottom: View {
    let context: WidgetContext

    var body: some View {
        VStack(spacing: 8) {
            if context.live, let s = context.snapshot {
                HStack(alignment: .center, spacing: 10) {
                    WidgetTrendChart(temps: s.temps, fahrenheit: s.fahrenheit, style: .compact)
                        .frame(height: 40)
                    if s.concern != nil || s.lowBattery != nil {
                        VStack(alignment: .leading, spacing: 3) {
                            if s.level.isConcern { WidgetLevelLine(snapshot: s, lines: 2) }
                            WidgetBatteryWarning(snapshot: s, compact: true)
                        }
                        .frame(maxWidth: 118, alignment: .leading)
                    }
                }
            } else {
                WidgetNotLive(snapshot: context.snapshot)
            }
            WidgetModeButtons(context: context, height: 28)
        }
        .padding(.horizontal, 4)
    }
}

/// Compact leading: both soles, tinted by what they're sensing.
struct IslandCompactLeading: View {
    let context: WidgetContext

    var body: some View {
        WidgetSolePair(context: context, height: 19)
            .padding(.leading, 2)
    }
}

/// Compact trailing and minimal: the mode as a dot, with a battery mark when
/// an insole needs charging.
struct IslandModeDot: View {
    let context: WidgetContext
    var showsBattery = true

    var body: some View {
        HStack(spacing: 4) {
            if showsBattery, let s = context.snapshot, s.lowBattery != nil {
                Image(systemName: s.batteryIsCritical ? "battery.0percent" : "battery.25percent")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(s.batteryIsCritical ? ThermyxWidgetInk.red : ThermyxWidgetInk.amber)
            }
            ThermyxModeDot(mode: context.snapshot?.mode ?? .auto, size: 12)
        }
    }
}
