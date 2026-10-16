import SwiftUI

// MARK: - Card container

/// A section. In v2 most sections are not boxed: they sit on the background
/// under a hairline, which is what `ThermyxCard` draws by default. Passing a
/// tinted fill or a coloured border (an alert, a highlighted state) still
/// gives a rounded panel, because that colour is the message.
struct ThermyxCard<Content: View>: View {
    var padding: CGFloat = Thermyx.Space.xl
    var radius: CGFloat = Thermyx.Radius.section
    var fill: Color = Thermyx.Ink.deck
    var border: Color = Thermyx.Ink.hairline
    var borderWidth: CGFloat = Thermyx.Stroke.hairline
    @ViewBuilder var content: Content

    private var isPanel: Bool { fill != Thermyx.Ink.deck || border != Thermyx.Ink.hairline }

    var body: some View {
        if isPanel {
            content
                .padding(padding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(fill == Thermyx.Ink.deck ? Color.clear : fill,
                            in: RoundedRectangle(cornerRadius: radius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(border, lineWidth: borderWidth)
                }
        } else {
            content
                .padding(.vertical, max(padding - 2, Thermyx.Space.m))
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .top) { ThermyxDivider() }
        }
    }
}

// MARK: - Section label

/// "What happens at each level", "Trusted circle": 17 pt semibold, sentence
/// case. A colour other than the default tints the title (an Apple Health
/// prompt, a warning).
struct SectionLabel: View {
    let text: String
    var color: Color = Thermyx.Ink.textSupporting
    var trailing: AnyView?

    init(_ text: String, color: Color = Thermyx.Ink.textSupporting) {
        self.text = text
        self.color = color
        self.trailing = nil
    }

    init<T: View>(_ text: String, color: Color = Thermyx.Ink.textSupporting, @ViewBuilder trailing: () -> T) {
        self.text = text
        self.color = color
        self.trailing = AnyView(trailing())
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(text)
                .font(ThermyxFont.sectionTitle)
                .foregroundStyle(color == Thermyx.Ink.textSupporting ? Thermyx.Ink.textPrimary : color)
            if let trailing {
                Spacer(minLength: Thermyx.Space.xs)
                trailing
                    .font(ThermyxFont.bodySmall)
            }
        }
        .accessibilityAddTraits(.isHeader)
    }
}

/// The "Apple Health" section label with Apple's Health logo in its own
/// colours, in place of the plain text-only label.
struct AppleHealthLabel: View {
    var color: Color = Thermyx.Ink.textSupporting

    var body: some View {
        HStack(spacing: Thermyx.Space.xs) {
            AppleHealthIcon(size: 22)
            SectionLabel("Apple Health", color: color)
        }
    }
}

/// Apple Health's app icon, from the asset in the project, in its own
/// colours: the white tile with the heart, as it appears on the Home
/// Screen. Never recoloured or redrawn.
struct AppleHealthIcon: View {
    var size: CGFloat = 40

    var body: some View {
        Image("AppleHealth")
            .renderingMode(.original)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
            .accessibilityHidden(true)
    }
}

// MARK: - Status pill

/// A dot and a short label — "Live", "Offline", "On".
struct StatusPill: View {
    let text: String
    let tint: Color
    var fill: Color
    var border: Color
    var showsDot: Bool = true
    var isPulsing: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    init(_ text: String, tint: Color, fill: Color, border: Color, showsDot: Bool = true, isPulsing: Bool = false) {
        self.text = text
        self.tint = tint
        self.fill = fill
        self.border = border
        self.showsDot = showsDot
        self.isPulsing = isPulsing
    }

    var body: some View {
        HStack(spacing: 6) {
            if showsDot {
                Circle()
                    .fill(tint)
                    .frame(width: 6, height: 6)
                    .opacity(isPulsing && !reduceMotion ? (pulse ? 1 : 0.45) : 1)
                    .onAppear {
                        guard isPulsing, !reduceMotion else { return }
                        withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                            pulse = true
                        }
                    }
            }
            Text(text)
                .font(ThermyxFont.statusPill)
                .foregroundStyle(tint)
        }
        .accessibilityElement(children: .combine)
    }

    static func live() -> StatusPill {
        StatusPill("Live", tint: Thermyx.Ink.ice, fill: Thermyx.Tint.liveFill, border: Thermyx.Tint.liveBorder, isPulsing: true)
    }

    static func offline() -> StatusPill {
        StatusPill("Offline", tint: Thermyx.Ink.amber, fill: Thermyx.Tint.cautionFill, border: Thermyx.Tint.emberBorder)
    }
}

// MARK: - Metric tile

/// A label over a numeral. Used in the Home metric row and the watcher grid.
struct MetricTile: View {
    let label: String
    /// `nil` renders the empty dash — never a stand-in number.
    let value: String?
    var tint: Color = Thermyx.Ink.textPrimary
    var numeralFont: Font = ThermyxFont.metricNumeralCompact
    var accessibilityValue: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(ThermyxFont.captionSmall)
                .foregroundStyle(Thermyx.Ink.textMuted)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(value ?? "—")
                .font(numeralFont)
                .monospacedDigit()
                .foregroundStyle(value == nil ? Thermyx.Ink.textFaint : tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(accessibilityValue ?? value ?? "No reading")
    }
}

// MARK: - Segmented control

/// A segmented control in a dark well: °C/°F, Day/Week/Month.
struct ThermyxSegmentedControl<Value: Hashable>: View {
    let options: [Value]
    let label: (Value) -> String
    @Binding var selection: Value
    var font: Font = ThermyxFont.statusPill
    var tracking: CGFloat = 1.4
    var uppercase: Bool = true
    var accessibilityPrefix: String = ""

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.self) { option in
                let isSelected = option == selection
                Button {
                    selection = option
                } label: {
                    Text(label(option))
                        .font(ThermyxFont.controlLabel)
                        .foregroundStyle(isSelected ? Thermyx.Ink.onPrimary : Thermyx.Ink.textMuted)
                        .padding(.horizontal, 14)
                        .frame(minWidth: 44)
                        .frame(maxHeight: .infinity)
                        .background(isSelected ? Thermyx.Ink.textPrimary : .clear,
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(accessibilityPrefix)\(label(option))")
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(4)
        .frame(height: 44)
        .background(Thermyx.Tint.neutralFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .animation(SiteMotion.press, value: selection)
    }
}

// MARK: - Rows

/// A tappable row: an optional symbol, a title, optional detail, a chevron,
/// and a hairline under it.
struct ThermyxNavigationRow: View {
    let title: String
    var detail: String?
    var systemImage: String?
    var iconTint: Color = Thermyx.Ink.ice
    var iconFill: Color = Thermyx.Tint.iceWash
    var iconSize: CGFloat = 42
    var emphasized: Bool = false

    var body: some View {
        HStack(spacing: Thermyx.Space.m) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(iconTint)
                    .frame(width: 28)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(emphasized ? ThermyxFont.rowTitle : ThermyxFont.rowTitleRegular)
                    .foregroundStyle(Thermyx.Ink.textPrimary)
                    .multilineTextAlignment(.leading)
                if let detail {
                    Text(detail)
                        .font(ThermyxFont.captionSmall)
                        .foregroundStyle(Thermyx.Ink.textMuted)
                        .multilineTextAlignment(.leading)
                }
            }
            Spacer(minLength: Thermyx.Space.xs)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(emphasized ? Thermyx.Ink.ice : Thermyx.Ink.textFaint)
        }
        .padding(.vertical, 14)
        .frame(minHeight: Thermyx.minimumTapTarget)
        .overlay(alignment: .bottom) { ThermyxDivider() }
        .contentShape(.rect)
    }
}

/// A label/value row inside a grouped card, separated by dividers.
struct ThermyxValueRow: View {
    let label: String
    let value: String
    var valueFont: Font = ThermyxFont.body
    var valueTracking: CGFloat = 0
    var monospaced: Bool = false

    var body: some View {
        HStack(spacing: Thermyx.Space.m) {
            Text(label)
                .font(ThermyxFont.body)
                .foregroundStyle(Thermyx.Ink.textPrimary)
            Spacer(minLength: Thermyx.Space.xs)
            Group {
                if monospaced {
                    Text(value).monospacedDigit()
                } else {
                    Text(value)
                }
            }
            .font(valueFont)
            .tracking(valueTracking)
            .foregroundStyle(Thermyx.Ink.textMuted)
            .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 14)
        .accessibilityElement(children: .combine)
    }
}

/// Rows between hairlines, flush with the screen's gutter.
struct ThermyxGroupedCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .overlay(alignment: .top) { ThermyxDivider() }
            .overlay(alignment: .bottom) { ThermyxDivider() }
    }
}

struct ThermyxDivider: View {
    var body: some View {
        Rectangle()
            .fill(Thermyx.Ink.divider)
            .frame(height: 1)
    }
}

// MARK: - Buttons

/// The primary action: a white, 56 pt, 16-radius slab with near-black type.
/// Pass a fill for a coloured action (Ember for an emergency).
struct ThermyxPrimaryButtonStyle: ButtonStyle {
    var fill: Color = Thermyx.Ink.textPrimary
    var foreground: Color = Thermyx.Ink.onPrimary

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(ThermyxFont.buttonLabel)
            .foregroundStyle(isEnabled ? foreground : Thermyx.Ink.textFaint)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 56)
            .padding(.horizontal, Thermyx.Space.xl)
            .background(isEnabled ? fill : Thermyx.Tint.neutralFill,
                        in: RoundedRectangle(cornerRadius: Thermyx.Radius.action, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(SiteMotion.press, value: configuration.isPressed)
            .contentShape(RoundedRectangle(cornerRadius: Thermyx.Radius.action, style: .continuous))
    }
}

/// The outlined secondary action: same slab, hairline border, no fill.
struct ThermyxSecondaryButtonStyle: ButtonStyle {
    var tint: Color = Thermyx.Ink.textPrimary
    var border: Color = Thermyx.Tint.neutralBorder

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(ThermyxFont.buttonLabel)
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 56)
            .padding(.horizontal, Thermyx.Space.xl)
            .overlay {
                RoundedRectangle(cornerRadius: Thermyx.Radius.action, style: .continuous)
                    .strokeBorder(border, lineWidth: Thermyx.Stroke.hairline)
            }
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(SiteMotion.press, value: configuration.isPressed)
            .contentShape(RoundedRectangle(cornerRadius: Thermyx.Radius.action, style: .continuous))
    }
}

// MARK: - Screen scaffold

/// A tab-level screen: a 30 pt title with an optional accessory, then the
/// content, over the scaffold's topography (so it draws no background).
struct ThermyxScreen<Content: View, Accessory: View>: View {
    let title: String
    var accessory: Accessory
    var horizontalPadding: CGFloat = Thermyx.Space.screen
    @ViewBuilder var content: Content

    init(
        title: String,
        horizontalPadding: CGFloat = Thermyx.Space.screen,
        @ViewBuilder accessory: () -> Accessory = { EmptyView() },
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.horizontalPadding = horizontalPadding
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: Thermyx.Space.xl) {
                HStack(alignment: .center, spacing: Thermyx.Space.m) {
                    Text(title)
                        .font(ThermyxFont.screenTitle)
                        .tracking(ThermyxTracking.screenTitle)
                        .foregroundStyle(Thermyx.Ink.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: Thermyx.Space.xs)
                    accessory
                }
                .padding(.top, Thermyx.Space.titleTop)

                content
                Color.clear.frame(height: 1).id("end")
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.bottom, Thermyx.Space.xxl)
        }
        .debugScroll(proxy)
        }
        .scrollIndicators(.hidden)
        .thermyxTopScrim()
    }
}

/// A pushed screen: a back link, then a 30 pt title, as in the design's
/// Device screen. Draws the topography itself, since a navigation stack
/// covers the scaffold's.
struct ThermyxDetailScreen<Content: View>: View {
    let title: String
    var caption: String?
    var horizontalPadding: CGFloat = Thermyx.Space.screen
    /// What the back link says: the screen it returns to.
    var backTitle: String = "Back"
    @ViewBuilder var content: Content

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: Thermyx.Space.xl) {
                VStack(alignment: .leading, spacing: 6) {
                    Button {
                        dismiss()
                    } label: {
                        HStack(spacing: 2) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 18, weight: .semibold))
                            Text(backTitle)
                                .font(.custom(ThermyxFont.Family.medium, size: 17, relativeTo: .body))
                        }
                        .foregroundStyle(Thermyx.Ink.ice)
                        .frame(minHeight: 44)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, -6)
                    .accessibilityLabel("Back")

                    HStack(alignment: .firstTextBaseline, spacing: Thermyx.Space.m) {
                        Text(title)
                            .font(ThermyxFont.detailTitle)
                            .tracking(ThermyxTracking.screenTitle)
                            .foregroundStyle(Thermyx.Ink.textPrimary)
                            .accessibilityAddTraits(.isHeader)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: Thermyx.Space.xs)
                        if let caption {
                            Text(caption)
                                .font(ThermyxFont.statusPill)
                                .foregroundStyle(Thermyx.Ink.textMuted)
                        }
                    }
                }

                content
                Color.clear.frame(height: 1).id("end")
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.bottom, Thermyx.Space.xxl)
        }
        .debugScroll(proxy)
        }
        .scrollIndicators(.hidden)
        .thermyxBackground()
        .thermyxTopScrim()
        .navigationBarBackButtonHidden()
        .toolbar(.hidden, for: .navigationBar)
    }
}

extension View {
    /// Debug builds: scrolls to `-ThermyxScrollTo <id>` once laid out.
    @ViewBuilder
    func debugScroll(_ proxy: ScrollViewProxy) -> some View {
        #if DEBUG
        task {
            guard let target = ThermyxPreviewHarness.scrollTarget else { return }
            try? await Task.sleep(for: .seconds(1.5))
            proxy.scrollTo(target, anchor: target == "end" ? .bottom : .top)
        }
        #else
        self
        #endif
    }
}

// MARK: - Background

extension View {
    /// Black with the topographic contours, for screens and sheets the tab
    /// scaffold doesn't sit behind.
    func thermyxBackground() -> some View {
        background {
            ZStack {
                Color.black
                TopographyBackground().opacity(ThermyxBackdrop.opacity)
            }
            .ignoresSafeArea()
        }
    }

    /// The root of a tab's navigation stack: lets the scaffold's topography
    /// show through (iOS 18+), or draws its own on iOS 17.
    @ViewBuilder
    func thermyxNavigationRoot() -> some View {
        if #available(iOS 18.0, *) {
            containerBackground(.clear, for: .navigation)
        } else {
            thermyxBackground()
        }
    }

    /// A sheet's background: the same black and contours.
    func thermyxSheetBackground() -> some View {
        thermyxBackground()
            .presentationBackground(.black)
    }
}

/// How strongly the contours show behind app screens: enough to read as
/// the website's ground, quiet enough that numbers stay the loudest thing.
enum ThermyxBackdrop {
    static let opacity = 0.5
}

// MARK: - Empty state

/// The honest empty state. Shown wherever a value is missing, in place of a
/// number — never alongside a guessed one.
struct ThermyxEmptyState: View {
    let title: String
    let message: String
    var systemImage: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.s) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(Thermyx.Ink.textFaint)
                    .padding(.bottom, 2)
            }
            Text(title)
                .font(ThermyxFont.sectionTitle)
                .foregroundStyle(Thermyx.Ink.textPrimary)
            Text(message)
                .font(ThermyxFont.bodySmall)
                .foregroundStyle(Thermyx.Ink.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(ThermyxSecondaryButtonStyle())
                    .padding(.top, Thermyx.Space.xs)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Thermyx.Space.xl)
        .overlay(alignment: .top) { ThermyxDivider() }
        .accessibilityElement(children: .combine)
    }
}
