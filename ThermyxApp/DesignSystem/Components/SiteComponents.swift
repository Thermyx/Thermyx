import SwiftUI

// The website's visual language, native: topographic contours on black,
// glass surfaces, and buttons that answer the finger on touch-down.

// MARK: - Motion

enum SiteMotion {
    /// Critically damped: settles without overshoot. The default for
    /// anything that isn't thrown.
    static let settle = Animation.spring(response: 0.38, dampingFraction: 1)
    /// Press feedback, fast enough to feel attached to the finger.
    static let press = Animation.spring(response: 0.22, dampingFraction: 1)
    /// Under Reduce Motion: a short cross-fade instead of movement.
    static let fade = Animation.easeOut(duration: 0.2)
}

// MARK: - Topography

/// The website's animated topographic contours (React Bits "Topography").
/// Frozen at one moment under Reduce Motion, as on the site.
struct TopographyBackground: View {
    var opacity: Double = 0.25
    /// An optional rise in the field, as (u, v) from the bottom left, in
    /// units of the geometric mean of the view's sides.
    var bump: CGPoint?
    var bumpStrength: Double = 0.4

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale

    private static let speed = 0.35
    private static let morphSpeed = 0.05
    private static let seeds: [[Double]] = [[1, -2, 3, -4], [9, -8, 7, -6], [5, 2, 5, -5], [-1, -3, 8, 9]]
    private static let stillTime = 12.0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { context in
            // Wall-clock time, so the field carries on seamlessly if the view
            // is rebuilt.
            let t = reduceMotion ? Self.stillTime : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 86_400)
            GeometryReader { proxy in
                // Filled black first: until the shader has compiled (the
                // first launch after install), the effect is skipped and the
                // rectangle draws as it is. Unfilled, that's a white sheet.
                Rectangle()
                    .fill(Thermyx.Site.bg)
                    .colorEffect(shader(size: proxy.size, time: t))
            }
        }
        .background(Thermyx.Site.bg)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func shader(size: CGSize, time: Double) -> Shader {
        let controls = Self.seeds.map { row -> Shader.Argument in
            let k = row.map { seed in 3 * sin(time * Self.speed * sin(seed * Self.morphSpeed) + seed) }
            return .float4(k[0], k[1], k[2], k[3])
        }
        let bumpArgument: Shader.Argument = bump.map { .float4($0.x, $0.y, 0.3, bumpStrength) } ?? .float4(0, 0, 0.3, 0)
        return ShaderLibrary.topography(
            .float2(size), .float(time.truncatingRemainder(dividingBy: 1000)), .float(opacity), .float(1 / max(displayScale, 1)),
            controls[0], controls[1], controls[2], controls[3], bumpArgument
        )
    }
}

// MARK: - Buttons

/// The primary action: a white slab with near-black type, as in the v2
/// design. Presses in on touch-down and dims while disabled.
struct SitePrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(ThermyxFont.buttonLabel)
            .foregroundStyle(isEnabled ? Thermyx.Ink.onPrimary : Thermyx.Site.textFaint)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 56)
            .padding(.horizontal, Thermyx.Space.xl)
            .background(isEnabled ? Thermyx.Ink.textPrimary : Thermyx.Site.raised,
                        in: RoundedRectangle(cornerRadius: Thermyx.Radius.action, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.88 : 1)
            .animation(SiteMotion.press, value: configuration.isPressed)
            .animation(SiteMotion.settle, value: isEnabled)
            .contentShape(RoundedRectangle(cornerRadius: Thermyx.Radius.action, style: .continuous))
    }
}

/// The quiet action: a hairline-bordered slab.
struct SiteSecondaryButtonStyle: ButtonStyle {
    var tint: Color = Thermyx.Site.text

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(ThermyxFont.controlLabel)
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 52)
            .padding(.horizontal, Thermyx.Space.xl)
            .overlay {
                RoundedRectangle(cornerRadius: Thermyx.Radius.action, style: .continuous)
                    .strokeBorder(Thermyx.Site.hairlineStrong, lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(SiteMotion.press, value: configuration.isPressed)
            .contentShape(RoundedRectangle(cornerRadius: Thermyx.Radius.action, style: .continuous))
    }
}

/// A text button for low-emphasis choices ("Do this later").
struct SiteTextButtonStyle: ButtonStyle {
    var tint: Color = Thermyx.Site.textMuted

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(ThermyxFont.controlLabel)
            .foregroundStyle(tint)
            .frame(minHeight: Thermyx.minimumTapTarget)
            .padding(.horizontal, Thermyx.Space.m)
            .opacity(configuration.isPressed ? 0.55 : 1)
            .animation(SiteMotion.press, value: configuration.isPressed)
            .contentShape(Rectangle())
    }
}

// MARK: - Surfaces

/// Glass over the topography: a material, a dark wash and a hairline. Solid
/// under Reduce Transparency.
struct SiteGlass: ViewModifier {
    var radius: CGFloat = Thermyx.Radius.list
    var highlighted = false

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background {
                if reduceTransparency {
                    shape.fill(Thermyx.Site.surface)
                } else {
                    shape.fill(.ultraThinMaterial).overlay(shape.fill(Thermyx.Site.glass))
                }
            }
            .overlay {
                shape.strokeBorder(highlighted ? Thermyx.Ink.signal.opacity(0.8) : Thermyx.Site.hairlineStrong,
                                   lineWidth: highlighted ? 1.5 : 1)
            }
            .environment(\.colorScheme, .dark)
    }
}

extension View {
    func siteGlass(radius: CGFloat = Thermyx.Radius.list, highlighted: Bool = false) -> some View {
        modifier(SiteGlass(radius: radius, highlighted: highlighted))
    }
}

/// A small tracked caps label, the website's "label stretch" voice. Used in
/// place of pill badges.
struct SiteEyebrow: View {
    let text: String
    var color: Color = Thermyx.Site.textFaint

    init(_ text: String, color: Color = Thermyx.Site.textFaint) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .narrowLabel(ThermyxFont.sectionLabel, tracking: ThermyxTracking.sectionLabel, color: color)
            .accessibilityAddTraits(.isHeader)
    }
}
