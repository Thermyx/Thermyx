import AppIntents
import SwiftUI
import WidgetKit

// Two more widgets: Readiness ("is today different for me?") and Safety
// (I'm OK, and a way to SOS that always goes through the app's confirm).

// MARK: - Readiness

/// The usual range as a band, with a dot for now.
struct WidgetRangeBar: View {
    let lowC: Double
    let highC: Double
    let nowC: Double?
    var monochrome = false

    var body: some View {
        GeometryReader { proxy in
            let lo = min(lowC, nowC ?? lowC) - 1, hi = max(highC, nowC ?? highC) + 1
            let w = proxy.size.width
            let x: (Double) -> CGFloat = { c in w * CGFloat((c - lo) / max(hi - lo, 0.1)) }
            ZStack(alignment: .leading) {
                Capsule().fill(monochrome ? Color.primary.opacity(0.2) : ThermyxWidgetInk.hairline).frame(height: 5)
                Capsule()
                    .fill(monochrome ? Color.primary.opacity(0.5) : ThermyxWidgetInk.ice.opacity(0.45))
                    .frame(width: max(6, x(highC) - x(lowC)), height: 9)
                    .offset(x: x(lowC))
                if let nowC {
                    Circle()
                        .fill(monochrome ? Color.primary : FootScale.thermalColor(nowC))
                        .frame(width: 12, height: 12)
                        .overlay { Circle().strokeBorder(monochrome ? Color.clear : ThermyxWidgetInk.text, lineWidth: 1.5) }
                        .offset(x: min(max(x(nowC) - 6, 0), w - 12))
                        .widgetAccentable()
                }
            }
            .frame(maxHeight: .infinity)
        }
    }
}

struct WidgetReadinessLayout: View {
    let snapshot: ThermyxWidgetSnapshot?
    let family: WidgetFamily

    private var readiness: ThermyxWidgetSnapshot.Readiness? { snapshot?.readiness }

    private var tint: Color {
        switch readiness?.status {
        case "warmer": return ThermyxWidgetInk.amber
        case "typical", "cooler": return ThermyxWidgetInk.ice
        default: return ThermyxWidgetInk.muted
        }
    }

    var body: some View {
        switch family {
        case .accessoryRectangular: rectangular
        case .systemMedium: medium
        default: small
        }
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Today vs your normal")
                .font(WidgetFont.label(11))
                .foregroundStyle(ThermyxWidgetInk.muted)
                .lineLimit(1)
            Text(readiness?.title ?? "Open Thermyx")
                .font(WidgetFont.numeral(19))
                .foregroundStyle(tint)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
            bar.frame(height: 14)
            caption
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var medium: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Today vs your normal")
                    .font(WidgetFont.label(11))
                    .foregroundStyle(ThermyxWidgetInk.muted)
                Text(readiness?.title ?? "Open Thermyx")
                    .font(WidgetFont.numeral(22))
                    .foregroundStyle(tint)
                    .lineLimit(2)
                Spacer(minLength: 0)
                Text(sentence)
                    .font(WidgetFont.body(11))
                    .foregroundStyle(ThermyxWidgetInk.muted)
                    .lineLimit(3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 8) {
                if let now = readiness?.nowC, let s = snapshot {
                    HStack(alignment: .firstTextBaseline, spacing: 1) {
                        Text(String(format: "%.1f", s.convert(now)))
                            .font(WidgetFont.numeral(30))
                            .foregroundStyle(FootScale.thermalColor(now))
                            .monospacedDigit()
                        Text("°\(s.unitSymbol)").font(WidgetFont.body(12)).foregroundStyle(ThermyxWidgetInk.muted)
                    }
                }
                Spacer(minLength: 0)
                bar.frame(height: 16)
                caption
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(readiness?.title ?? "Thermyx")
                .font(.system(size: 15, weight: .semibold))
                .widgetAccentable()
                .lineLimit(1)
            if let r = readiness, let lo = r.lowC, let hi = r.highC {
                WidgetRangeBar(lowC: lo, highC: hi, nowC: r.nowC, monochrome: true).frame(height: 12)
                Text("\(r.activity ?? "Usual") · usual \(degrees(lo))–\(degrees(hi))")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text("Wear your insoles to learn your normal").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var bar: some View {
        if let r = readiness, let lo = r.lowC, let hi = r.highC {
            WidgetRangeBar(lowC: lo, highC: hi, nowC: r.nowC)
        } else {
            Capsule().fill(ThermyxWidgetInk.hairline).frame(height: 5).frame(maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var caption: some View {
        if let r = readiness, let lo = r.lowC, let hi = r.highC {
            Text("\(r.activity ?? "Usual") · usual \(degrees(lo))–\(degrees(hi))")
                .font(WidgetFont.mono(10))
                .foregroundStyle(ThermyxWidgetInk.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        } else {
            Text("Still learning your normal")
                .font(WidgetFont.body(10))
                .foregroundStyle(ThermyxWidgetInk.faint)
                .lineLimit(1)
        }
    }

    private var sentence: String {
        switch readiness?.status {
        case "typical": return "Your feet look like they usually do\(readiness?.activity.map { " while \($0.lowercased())" } ?? "")."
        case "warmer": return "Your warmer foot is above its usual range. Take breaks and drink water."
        case "cooler": return "Your warmer foot is below its usual range."
        default: return "Thermyx needs a calibration or a few hours of calm wear."
        }
    }

    private func degrees(_ c: Double) -> String {
        guard let s = snapshot else { return String(format: "%.0f°", c) }
        return String(format: "%.0f°", s.convert(c))
    }
}

// MARK: - Safety

struct WidgetSafetyLayout: View {
    let snapshot: ThermyxWidgetSnapshot?
    let family: WidgetFamily
    var now: Date = .now

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "shield.lefthalf.filled").font(.system(size: 11, weight: .bold))
                Text("Safety").font(WidgetFont.label(11))
                Spacer(minLength: 0)
                if let level = snapshot?.level, level.isConcern {
                    Text(level.label)
                        .font(WidgetFont.label(11))
                        .foregroundStyle(ThermyxWidgetInk.color(level))
                }
            }
            .foregroundStyle(ThermyxWidgetInk.muted)

            if family == .systemMedium {
                HStack(spacing: 10) {
                    okButton
                    sosButton
                }
                .frame(maxHeight: .infinity)
            } else {
                okButton.frame(maxHeight: .infinity)
                sosButton.frame(height: 40)
            }

            Text(footer)
                .font(WidgetFont.body(10))
                .foregroundStyle(ThermyxWidgetInk.faint)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var okButton: some View {
        Button(intent: CheckInIntent()) {
            VStack(spacing: 4) {
                Image(systemName: "hand.thumbsup.fill").font(.system(size: family == .systemMedium ? 22 : 18, weight: .semibold))
                Text("I'm OK").font(WidgetFont.label(family == .systemMedium ? 16 : 14))
            }
            .foregroundStyle(ThermyxWidgetInk.onPrimary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ThermyxWidgetInk.text, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Tell my circle I'm OK")
    }

    /// Opens the app's hold-to-call screen: a widget can't hold to confirm,
    /// so it never calls or sends on its own.
    private var sosButton: some View {
        Link(destination: URL(string: "thermyx://sos")!) {
            HStack(spacing: 6) {
                if family == .systemMedium {
                    Image(systemName: "phone.fill").font(.system(size: 16, weight: .bold))
                    Text("SOS").font(WidgetFont.label(18))
                } else {
                    Image(systemName: "sos").font(.system(size: 14, weight: .heavy))
                }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ThermyxWidgetInk.red, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .accessibilityLabel("SOS: opens Thermyx to call 911")
    }

    private var footer: String {
        if let at = snapshot?.lastCheckIn, now.timeIntervalSince(at) < 12 * 3600 {
            return "Checked in \(at.formatted(date: .omitted, time: .shortened))"
        }
        if let n = snapshot?.circleSize, n > 0 { return "Reaches \(n) contact\(n == 1 ? "" : "s")" }
        return "Set up your circle in Thermyx"
    }
}
