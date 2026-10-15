import Charts
import SwiftUI

/// Type in the website's faces, falling back to the system font if a face
/// didn't register.
enum WidgetFont {
    static func serif(_ size: CGFloat) -> Font { .custom("InstrumentSerif-Regular", size: size) }
    static func label(_ size: CGFloat) -> Font { .custom("Archivo-SemiBold", size: size) }
    static func body(_ size: CGFloat) -> Font { .custom("Archivo-Medium", size: size) }
}

/// "THERMYX · AUTO" with the mode dot.
struct WidgetEyebrow: View {
    let snapshot: ThermyxWidgetSnapshot?

    var body: some View {
        HStack(spacing: 5) {
            if let snapshot { ThermyxModeDot(mode: snapshot.mode, size: 8) }
            Text(snapshot.map { "THERMYX · \($0.mode.label.uppercased())" } ?? "THERMYX")
                .font(WidgetFont.label(10))
                .tracking(1.2)
                .foregroundStyle(ThermyxWidgetInk.muted)
            if snapshot?.isDemo == true {
                Text("DEMO").font(WidgetFont.label(9)).foregroundStyle(ThermyxWidgetInk.amber)
            }
        }
        .lineLimit(1)
    }
}

/// The level, or the concern behind it.
struct LevelLine: View {
    let snapshot: ThermyxWidgetSnapshot
    var showsConcern = true

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Circle().fill(ThermyxWidgetInk.color(snapshot.level)).frame(width: 6, height: 6)
            Text(showsConcern ? (snapshot.concern ?? snapshot.level.label) : snapshot.level.label)
                .font(WidgetFont.body(11))
                .foregroundStyle(snapshot.level.isConcern ? ThermyxWidgetInk.color(snapshot.level) : ThermyxWidgetInk.muted)
                .lineLimit(2)
        }
    }
}

/// The rate of change with its direction.
struct RateLine: View {
    let snapshot: ThermyxWidgetSnapshot

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: snapshot.rateSymbol).font(.system(size: 9, weight: .bold))
            Text(snapshot.rateText).font(WidgetFont.body(11)).monospacedDigit()
        }
        .foregroundStyle(ThermyxWidgetInk.ice)
        .lineLimit(1)
    }
}

/// A small line chart of one curve. Rates get a zero line.
struct Sparkline: View {
    let values: [Float]
    var color: Color = ThermyxWidgetInk.ember
    var zeroLine = false

    var body: some View {
        if values.count < 2 {
            Text("Building…")
                .font(WidgetFont.body(10))
                .foregroundStyle(ThermyxWidgetInk.faint)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Chart {
                if zeroLine {
                    RuleMark(y: .value("Zero", 0))
                        .foregroundStyle(ThermyxWidgetInk.faint)
                        .lineStyle(StrokeStyle(lineWidth: 0.5, dash: [2, 2]))
                }
                ForEach(Array(values.enumerated()), id: \.offset) { i, v in
                    AreaMark(x: .value("t", i), y: .value("v", v))
                        .foregroundStyle(LinearGradient(colors: [color.opacity(0.28), color.opacity(0)],
                                                        startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("t", i), y: .value("v", v))
                        .foregroundStyle(color)
                        .lineStyle(StrokeStyle(lineWidth: 1.6, lineCap: .round))
                        .interpolationMethod(.monotone)
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartYScale(domain: domain)
            .widgetAccentable()
        }
    }

    /// Padded so a flat line sits in the middle, and AreaMark fills from the
    /// bottom of the domain rather than from zero.
    private var domain: ClosedRange<Float> {
        var lo = values.min() ?? 0, hi = values.max() ?? 1
        if zeroLine { lo = min(lo, 0); hi = max(hi, 0) }
        let pad = max((hi - lo) * 0.15, 0.05)
        return (lo - pad)...(hi + pad)
    }
}

/// A labelled chart: "T(t)" or "dT/dt".
struct LabelledCurve: View {
    let label: String
    let values: [Float]
    let color: Color
    var zeroLine = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10, design: .serif).italic())
                .foregroundStyle(ThermyxWidgetInk.faint)
            Sparkline(values: values, color: color, zeroLine: zeroLine)
        }
    }
}

/// What shows when the insoles aren't connected.
struct NotLiveLine: View {
    let snapshot: ThermyxWidgetSnapshot?

    var body: some View {
        Group {
            if let snapshot {
                (Text("Not connected · ") + Text(snapshot.updated, style: .relative) + Text(" ago"))
            } else {
                Text("Open Thermyx to connect your insoles.")
            }
        }
        .font(WidgetFont.body(11))
        .foregroundStyle(ThermyxWidgetInk.faint)
        .lineLimit(2)
    }
}
