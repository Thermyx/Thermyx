import SwiftUI

struct AuroraBackground: View {

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drift = false

    var body: some View {
        ZStack {
            Thermyx.Ink.midnight

            bloom(color: Thermyx.Ink.ember, opacity: 0.30, size: 380)
                .offset(x: 110, y: -170)
                .offset(x: drift ? -40 : 0, y: drift ? 60 : 0)
                .scaleEffect(drift ? 1.25 : 1)
                .opacity(drift ? 1 : 0.85)
                .animation(loop(14), value: drift)

            bloom(color: Thermyx.Ink.signal, opacity: 0.34, size: 400)
                .offset(x: -120, y: 220)
                .offset(x: drift ? 50 : 0, y: drift ? -70 : 0)
                .scaleEffect(drift ? 0.9 : 1.1)
                .opacity(drift ? 0.6 : 0.9)
                .animation(loop(18), value: drift)
        }
        .ignoresSafeArea()
        .onAppear {
            guard !reduceMotion else { return }
            drift = true
        }
        .accessibilityHidden(true)
    }

    private func bloom(color: Color, opacity: Double, size: CGFloat) -> some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [color.opacity(opacity), color.opacity(0)],
                    center: .center,
                    startRadius: 0,
                    endRadius: size * 0.34
                )
            )
            .frame(width: size, height: size)
    }

    private func loop(_ duration: Double) -> Animation? {
        reduceMotion ? nil : .easeInOut(duration: duration).repeatForever(autoreverses: true)
    }
}

/// Concentric rings that expand and fade — behind the insole on step one and
/// around the radar core on step three.
struct ExpandingRings: View {
    var color: Color = Thermyx.Ink.ice
    var alternateColor: Color?
    var baseSize: CGFloat = 200
    var count: Int = 3
    var duration: Double = 4
    var stagger: Double = 1.3

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if reduceMotion {
                // Static concentric rings instead of a pulse.
                ForEach(0..<count, id: \.self) { index in
                    Circle()
                        .strokeBorder(ringColor(index).opacity(0.35), lineWidth: 1.5)
                        .frame(width: baseSize * (0.6 + 0.45 * CGFloat(index)))
                }
            } else {
                ForEach(0..<count, id: \.self) { index in
                    ExpandingRing(
                        color: ringColor(index),
                        size: baseSize,
                        duration: duration,
                        delay: Double(index) * stagger
                    )
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func ringColor(_ index: Int) -> Color {
        guard let alternateColor else { return color }
        return index % 2 == 1 ? alternateColor : color
    }
}

private struct ExpandingRing: View {
    let color: Color
    let size: CGFloat
    let duration: Double
    let delay: Double

    @State private var expanded = false

    var body: some View {
        Circle()
            .strokeBorder(color, lineWidth: 1.5)
            .frame(width: size, height: size)
            .scaleEffect(expanded ? 1.9 : 0.6)
            .opacity(expanded ? 0 : 0.55)
            .onAppear {
                withAnimation(.easeOut(duration: duration).repeatForever(autoreverses: false).delay(delay)) {
                    expanded = true
                }
            }
    }
}

/// Staggered rise-in for the onboarding copy stack. Becomes a plain cross-fade
/// under Reduce Motion.
struct RiseIn: ViewModifier {
    let delay: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: reduceMotion ? 0 : (shown ? 0 : 20))
            .onAppear {
                let curve: Animation = reduceMotion
                    ? .easeOut(duration: 0.3)
                    : .easeOut(duration: 0.7)
                withAnimation(curve.delay(delay)) { shown = true }
            }
    }
}

extension View {
    func riseIn(delay: Double) -> some View {
        modifier(RiseIn(delay: delay))
    }
}
