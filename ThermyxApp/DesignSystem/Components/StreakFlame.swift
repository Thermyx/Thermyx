import SwiftUI

/// The streak's flame. It grows from a small flame on the first day to full
/// size at a week, then keeps changing colour as the streak runs on:
/// orange, then white-hot gold at two weeks, blue at a month, violet at two
/// months, teal at a hundred days. It flickers gently (still with Reduce
/// Motion), and with no streak it's an unlit grey ember.
struct StreakFlame: View {
    let days: Int
    var size: CGFloat = 56

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    struct Palette {
        let outer: [Color]
        let core: [Color]
        let glow: Color
    }

    static func palette(_ days: Int) -> Palette {
        switch days {
        case ..<1:
            return Palette(outer: [Color(hex: 0x3A3F47), Color(hex: 0x23272D)], core: [Color(hex: 0x4A5059), Color(hex: 0x30353C)], glow: .clear)
        case ..<14:
            return Palette(outer: [Color(hex: 0xFFB347), Color(hex: 0xFF6A13), Color(hex: 0xD9360B)],
                           core: [Color(hex: 0xFFF6C7), Color(hex: 0xFFC94A)], glow: Color(hex: 0xFF6A13))
        case ..<30:
            return Palette(outer: [Color(hex: 0xFFF1A8), Color(hex: 0xFFC233), Color(hex: 0xFF8A00)],
                           core: [Color.white, Color(hex: 0xFFF6D6)], glow: Color(hex: 0xFFC233))
        case ..<60:
            return Palette(outer: [Color(hex: 0x9FE7FF), Color(hex: 0x3AA8FF), Color(hex: 0x1F5BFF)],
                           core: [Color.white, Color(hex: 0xC9F1FF)], glow: Color(hex: 0x3AA8FF))
        case ..<100:
            return Palette(outer: [Color(hex: 0xE2B8FF), Color(hex: 0xA45CFF), Color(hex: 0x6B2BE0)],
                           core: [Color.white, Color(hex: 0xF0DDFF)], glow: Color(hex: 0xA45CFF))
        default:
            return Palette(outer: [Color(hex: 0xA8FFE6), Color(hex: 0x2EE6B8), Color(hex: 0x0EA58A)],
                           core: [Color.white, Color(hex: 0xD6FFF4)], glow: Color(hex: 0x2EE6B8))
        }
    }

    /// Small on day one, full size from a week.
    static func scale(_ days: Int) -> CGFloat {
        days <= 0 ? 0.6 : 0.55 + 0.45 * CGFloat(min(days, 7)) / 7
    }

    var body: some View {
        let palette = Self.palette(days)
        let lit = days > 0
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion || !lit)) { context in
            let t = reduceMotion || !lit ? 0 : context.date.timeIntervalSinceReferenceDate
            let sway = CGFloat(sin(t * 2.3) * 0.06 + sin(t * 5.1) * 0.025)
            let breathe = 1 + CGFloat(sin(t * 3.1) * 0.035)
            ZStack(alignment: .bottom) {
                FlameShape(sway: sway)
                    .fill(LinearGradient(colors: palette.outer.reversed(), startPoint: .bottom, endPoint: .top))
                    .overlay {
                        FlameShape(sway: sway * 0.6)
                            .fill(LinearGradient(colors: [.white.opacity(0.35), .clear], startPoint: .topLeading, endPoint: .center))
                            .blendMode(.plusLighter)
                    }
                FlameShape(sway: sway * 1.4)
                    .fill(LinearGradient(colors: palette.core.reversed(), startPoint: .bottom, endPoint: .top))
                    .frame(width: size * 0.5, height: size * 0.56)
                    .offset(y: -size * 0.04)
            }
            .frame(width: size * 0.8, height: size)
            .scaleEffect(x: 1, y: breathe, anchor: .bottom)
            .scaleEffect(Self.scale(days), anchor: .bottom)
            .shadow(color: palette.glow.opacity(lit ? 0.55 : 0), radius: size * 0.18, y: size * 0.04)
            .frame(width: size, height: size, alignment: .bottom)
        }
        .animation(SiteMotion.settle, value: days)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(days > 0 ? "\(days)-day streak" : "No streak yet")
    }
}

/// A rounded teardrop with a curling tip; `sway` leans the tip.
struct FlameShape: Shape {
    var sway: CGFloat

    var animatableData: CGFloat {
        get { sway }
        set { sway = newValue }
    }

    func path(in r: CGRect) -> Path {
        let w = r.width, h = r.height
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * w, y: r.minY + y * h) }
        let tip = 0.52 + sway
        var path = Path()
        path.move(to: p(0.5, 1))
        path.addCurve(to: p(0.06, 0.64), control1: p(0.2, 1), control2: p(0.04, 0.84))
        path.addCurve(to: p(0.3, 0.3), control1: p(0.08, 0.5), control2: p(0.2, 0.42))
        path.addCurve(to: p(tip, 0), control1: p(0.38, 0.2), control2: p(tip - 0.06, 0.1))
        path.addCurve(to: p(0.86, 0.42), control1: p(tip + 0.18, 0.12), control2: p(0.88, 0.26))
        path.addCurve(to: p(0.94, 0.66), control1: p(0.9, 0.5), control2: p(0.96, 0.58))
        path.addCurve(to: p(0.5, 1), control1: p(0.94, 0.86), control2: p(0.78, 1))
        path.closeSubpath()
        return path
    }
}
