import SwiftUI

// The website's visual language, native: topographic contours on black,
// Instrument Serif headlines that resolve out of a blur, glass surfaces and
// pill buttons that answer the finger on touch-down.

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
                Rectangle()
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

// MARK: - Headline

/// A display headline whose words resolve out of a blur one after another,
/// like React Bits "Blur Text". Words wrapped in `*asterisks*` are set in
/// Instrument Serif Italic. Under Reduce Motion the whole line fades in.
struct RevealHeadline: View {
    let text: String
    var font: Font = ThermyxFont.display
    var italicFont: Font = ThermyxFont.displayItalic
    var tracking: CGFloat = ThermyxTracking.display
    var color: Color = Thermyx.Site.text
    var alignment: HorizontalAlignment = .leading
    var delay: Double = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    private struct Word: Identifiable {
        let id: Int
        let text: String
        let italic: Bool
        let lineBreak: Bool
    }

    private var words: [Word] {
        var result: [Word] = []
        var italic = false
        for (lineIndex, line) in text.components(separatedBy: "\n").enumerated() {
            for (index, raw) in line.split(separator: " ").enumerated() {
                var word = String(raw)
                let opens = word.hasPrefix("*")
                if opens { italic = true; word.removeFirst() }
                let closes = word.hasSuffix("*")
                if closes { word.removeLast() }
                result.append(Word(id: result.count, text: word, italic: italic, lineBreak: lineIndex > 0 && index == 0))
                if closes { italic = false }
            }
        }
        return result
    }

    var body: some View {
        WordFlow(alignment: alignment, spacing: 0.26) {
            ForEach(words) { word in
                Text(word.text)
                    .font(word.italic ? italicFont : font)
                    .tracking(tracking)
                    .foregroundStyle(color)
                    .layoutValue(key: LineBreakBefore.self, value: word.lineBreak)
                    .blur(radius: shown || reduceMotion ? 0 : 10)
                    .opacity(shown ? 1 : 0)
                    .offset(y: shown || reduceMotion ? 0 : 10)
                    .animation(
                        reduceMotion ? SiteMotion.fade.delay(delay) : .spring(response: 0.7, dampingFraction: 1).delay(delay + Double(word.id) * 0.07),
                        value: shown
                    )
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text.replacingOccurrences(of: "*", with: "").replacingOccurrences(of: "\n", with: " "))
        .accessibilityAddTraits(.isHeader)
        .onAppear { shown = true }
    }
}

private struct LineBreakBefore: LayoutValueKey {
    static let defaultValue = false
}

/// Lays words out left to right and wraps them, honouring explicit breaks.
/// `spacing` is a fraction of the line height, so it scales with the font.
private struct WordFlow: Layout {
    var alignment: HorizontalAlignment
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let lines = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = lines.map(\.width).max() ?? 0
        let height = lines.reduce(0) { $0 + $1.height }
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in arrange(width: bounds.width, subviews: subviews) {
            var x: CGFloat
            switch alignment {
            case .center: x = bounds.minX + (bounds.width - line.width) / 2
            case .trailing: x = bounds.maxX - line.width
            default: x = bounds.minX
            }
            for item in line.items {
                subviews[item.index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(item.size))
                x += item.size.width + item.gap
            }
            y += line.height
        }
    }

    private struct Line {
        var items: [(index: Int, size: CGSize, gap: CGFloat)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Line] {
        var lines: [Line] = [Line()]
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            let gap = size.height * spacing
            let forced = subview[LineBreakBefore.self]
            let needed = lines[lines.count - 1].items.isEmpty ? size.width : lines[lines.count - 1].width + gap + size.width
            if (forced || needed > width), !lines[lines.count - 1].items.isEmpty {
                lines.append(Line())
            }
            var line = lines[lines.count - 1]
            if let last = line.items.indices.last {
                line.items[last].gap = gap
                line.width += gap
            }
            line.items.append((index, size, 0))
            line.width += size.width
            // Display serifs have tall ascenders; tighten the line a touch.
            line.height = max(line.height, size.height * 0.94)
            lines[lines.count - 1] = line
        }
        return lines.filter { !$0.items.isEmpty }
    }
}

// MARK: - Buttons

/// The website's primary action: a signal-blue pill with ink text. Presses
/// in on touch-down and dims while disabled.
struct SitePrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(ThermyxFont.buttonLabel)
            .foregroundStyle(isEnabled ? Thermyx.Ink.onSignal : Thermyx.Site.textFaint)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 56)
            .padding(.horizontal, Thermyx.Space.xl)
            .background(isEnabled ? Thermyx.Ink.signal : Thermyx.Site.raised, in: Capsule())
            .overlay { Capsule().strokeBorder(isEnabled ? .clear : Thermyx.Site.hairline, lineWidth: 1) }
            .shadow(color: Thermyx.Ink.signal.opacity(isEnabled ? 0.35 : 0), radius: 18, y: 6)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(SiteMotion.press, value: configuration.isPressed)
            .animation(SiteMotion.settle, value: isEnabled)
            .contentShape(Capsule())
    }
}

/// The quiet action: a glass pill with a hairline.
struct SiteSecondaryButtonStyle: ButtonStyle {
    var tint: Color = Thermyx.Site.text

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(ThermyxFont.controlLabel)
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 52)
            .padding(.horizontal, Thermyx.Space.xl)
            .background(Thermyx.Site.glass, in: Capsule())
            .overlay { Capsule().strokeBorder(Thermyx.Site.hairlineStrong, lineWidth: 1) }
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(SiteMotion.press, value: configuration.isPressed)
            .contentShape(Capsule())
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
