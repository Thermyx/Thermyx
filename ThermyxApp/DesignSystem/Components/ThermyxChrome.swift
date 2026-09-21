import SwiftUI

// MARK: - Card container

/// The standard Deck card: a filled surface, a hairline border, and a radius.
struct ThermyxCard<Content: View>: View {
    var padding: CGFloat = Thermyx.Space.xl
    var radius: CGFloat = Thermyx.Radius.section
    var fill: Color = Thermyx.Ink.deck
    var border: Color = Thermyx.Ink.hairline
    var borderWidth: CGFloat = Thermyx.Stroke.hairline
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(fill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(border, lineWidth: borderWidth)
            }
    }
}

// MARK: - Section label

/// `THERMAL MODE`, `EVENTS`, `TRUSTED CIRCLE` — Archivo Narrow, tracked, caps.
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
                .narrowLabel(ThermyxFont.sectionLabel, tracking: ThermyxTracking.sectionLabel, color: color)
            if let trailing {
                Spacer(minLength: Thermyx.Space.xs)
                trailing
            }
        }
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Status pill

/// A dot plus a tracked caps label on a tinted ground — `LIVE`, `OFFLINE`, `ON`.
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
        HStack(spacing: 7) {
            if showsDot {
                Circle()
                    .fill(tint)
                    .frame(width: 7, height: 7)
                    .opacity(isPulsing && !reduceMotion ? (pulse ? 1 : 0.45) : 1)
                    .onAppear {
                        guard isPulsing, !reduceMotion else { return }
                        withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                            pulse = true
                        }
                    }
            }
            Text(text)
                .narrowLabel(ThermyxFont.statusPill, tracking: ThermyxTracking.statusPill, color: tint)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(fill, in: Capsule())
        .overlay { Capsule().strokeBorder(border, lineWidth: Thermyx.Stroke.hairline) }
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
        ThermyxCard(padding: Thermyx.Space.m, radius: Thermyx.Radius.control) {
            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .narrowLabel(ThermyxFont.zoneLabel, tracking: 1.4, color: Thermyx.Ink.textSupporting)
                Text(value ?? "—")
                    .font(numeralFont)
                    .tracking(ThermyxTracking.metricNumeral)
                    .monospacedDigit()
                    .foregroundStyle(value == nil ? Thermyx.Ink.textFaint : tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(accessibilityValue ?? value ?? "No reading")
    }
}

// MARK: - Segmented control

/// The pill segmented control used for °C/°F and DAY/WEEK/MONTH.
struct ThermyxSegmentedControl<Value: Hashable>: View {
    let options: [Value]
    let label: (Value) -> String
    @Binding var selection: Value
    var font: Font = ThermyxFont.statusPill
    var tracking: CGFloat = 1.4
    var uppercase: Bool = true
    var accessibilityPrefix: String = ""

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { option in
                let isSelected = option == selection
                Button {
                    selection = option
                } label: {
                    Text(label(option))
                        .font(font)
                        .tracking(tracking)
                        .textCase(uppercase ? .uppercase : nil)
                        .foregroundStyle(isSelected ? Thermyx.Ink.textPrimary : Thermyx.Ink.textSupporting)
                        .padding(.horizontal, 12)
                        .frame(maxHeight: .infinity)
                        .background(isSelected ? Thermyx.Ink.elevated : .clear)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(accessibilityPrefix)\(label(option))")
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .frame(height: Thermyx.minimumTapTarget * 0.75)
        .clipShape(Capsule())
        .overlay { Capsule().strokeBorder(Thermyx.Tint.neutralBorder, lineWidth: Thermyx.Stroke.hairline) }
    }
}

// MARK: - Rows

/// A tappable list row with an icon tile, a title, optional detail, and a chevron.
struct ThermyxNavigationRow: View {
    let title: String
    var detail: String?
    var systemImage: String?
    var iconTint: Color = Thermyx.Ink.ice
    var iconFill: Color = Thermyx.Tint.iceWash
    var iconSize: CGFloat = 42
    var emphasized: Bool = false

    var body: some View {
        HStack(spacing: Thermyx.Space.l) {
            if let systemImage {
                RoundedRectangle(cornerRadius: Thermyx.Radius.button, style: .continuous)
                    .fill(iconFill)
                    .frame(width: iconSize, height: iconSize)
                    .overlay {
                        Image(systemName: systemImage)
                            .font(.system(size: iconSize * 0.45, weight: .semibold))
                            .foregroundStyle(iconTint)
                    }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(ThermyxFont.rowTitle)
                    .foregroundStyle(Thermyx.Ink.textPrimary)
                    .multilineTextAlignment(.leading)
                if let detail {
                    Text(detail)
                        .font(ThermyxFont.caption)
                        .foregroundStyle(Thermyx.Ink.textMuted)
                        .multilineTextAlignment(.leading)
                }
            }
            Spacer(minLength: Thermyx.Space.xs)
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(emphasized ? Thermyx.Ink.ice : Thermyx.Ink.textFaint)
        }
        .padding(Thermyx.Space.xl)
        .frame(minHeight: Thermyx.minimumTapTarget)
        .background(
            emphasized ? Thermyx.Tint.signalFill : Thermyx.Ink.deck,
            in: RoundedRectangle(cornerRadius: Thermyx.Radius.list, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: Thermyx.Radius.list, style: .continuous)
                .strokeBorder(emphasized ? Thermyx.Tint.signalBorder : Thermyx.Ink.hairline, lineWidth: Thermyx.Stroke.hairline)
        }
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
                .foregroundStyle(Thermyx.Ink.textSupporting)
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
            .foregroundStyle(Thermyx.Ink.textPrimary)
            .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, Thermyx.Space.xl)
        .padding(.vertical, 13)
        .accessibilityElement(children: .combine)
    }
}

/// Wraps rows in a bordered card with hairline dividers between them.
struct ThermyxGroupedCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(Thermyx.Ink.deck, in: RoundedRectangle(cornerRadius: Thermyx.Radius.list, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Thermyx.Radius.list, style: .continuous)
                    .strokeBorder(Thermyx.Ink.hairline, lineWidth: Thermyx.Stroke.hairline)
            }
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

/// The Signal Blue primary action. Ink-on-blue label, 48pt minimum.
struct ThermyxPrimaryButtonStyle: ButtonStyle {
    var fill: Color = Thermyx.Ink.signal
    var foreground: Color = Thermyx.Ink.onSignal

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(ThermyxFont.buttonLabel)
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity)
            .frame(minHeight: Thermyx.minimumTapTarget)
            .padding(.horizontal, Thermyx.Space.xl)
            .background(fill, in: RoundedRectangle(cornerRadius: Thermyx.Radius.control, style: .continuous))
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// The outlined secondary action.
struct ThermyxSecondaryButtonStyle: ButtonStyle {
    var tint: Color = Thermyx.Ink.textSecondary
    var border: Color = Thermyx.Tint.neutralBorder

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(ThermyxFont.controlLabel)
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .frame(minHeight: Thermyx.minimumTapTarget)
            .padding(.horizontal, Thermyx.Space.xl)
            .overlay {
                RoundedRectangle(cornerRadius: Thermyx.Radius.button + 1, style: .continuous)
                    .strokeBorder(border, lineWidth: Thermyx.Stroke.emphasis)
            }
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Screen scaffold

/// A dark screen with the standard gutters and a large title.
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
        ScrollView {
            VStack(alignment: .leading, spacing: Thermyx.Space.l) {
                HStack(alignment: .center, spacing: Thermyx.Space.m) {
                    Text(title)
                        .font(ThermyxFont.screenTitle)
                        .tracking(ThermyxTracking.screenTitle)
                        .foregroundStyle(Thermyx.Ink.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: Thermyx.Space.xs)
                    accessory
                }
                .padding(.top, Thermyx.Space.m)

                content
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.bottom, Thermyx.Space.xxl)
        }
        .scrollIndicators(.hidden)
        .background(Thermyx.Ink.midnight)
        .thermyxTopScrim()
    }
}

/// A pushed detail screen: back chevron, title, optional trailing caption.
struct ThermyxDetailScreen<Content: View>: View {
    let title: String
    var caption: String?
    var horizontalPadding: CGFloat = Thermyx.Space.screen
    @ViewBuilder var content: Content

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Thermyx.Space.l) {
                HStack(spacing: Thermyx.Space.m) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(Thermyx.Ink.ice)
                            .frame(width: Thermyx.minimumTapTarget, height: Thermyx.minimumTapTarget)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Back")

                    Text(title)
                        .font(ThermyxFont.detailTitle)
                        .tracking(ThermyxTracking.screenTitle)
                        .foregroundStyle(Thermyx.Ink.textPrimary)
                        .accessibilityAddTraits(.isHeader)

                    Spacer(minLength: Thermyx.Space.xs)

                    if let caption {
                        Text(caption)
                            .narrowLabel(ThermyxFont.statusPill, tracking: ThermyxTracking.statusPill, color: Thermyx.Ink.textSupporting)
                    }
                }
                // The chevron's 48pt frame supplies its own leading inset.
                .padding(.leading, -Thermyx.minimumTapTarget / 3)

                content
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.bottom, Thermyx.Space.xxl)
        }
        .scrollIndicators(.hidden)
        .background(Thermyx.Ink.midnight)
        .thermyxTopScrim()
        .navigationBarBackButtonHidden()
        .toolbar(.hidden, for: .navigationBar)
    }
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
        VStack(spacing: Thermyx.Space.m) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 26, weight: .regular))
                    .foregroundStyle(Thermyx.Ink.textSupporting)
            }
            Text(title)
                .font(ThermyxFont.rowTitle)
                .foregroundStyle(Thermyx.Ink.textPrimary)
                .multilineTextAlignment(.center)
            Text(message)
                .font(ThermyxFont.caption)
                .foregroundStyle(Thermyx.Ink.textMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(ThermyxSecondaryButtonStyle(tint: Thermyx.Ink.ice, border: Thermyx.Tint.liveBorder))
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Thermyx.Space.xxl)
        .padding(.horizontal, Thermyx.Space.xl)
        .background(Thermyx.Ink.deck, in: RoundedRectangle(cornerRadius: Thermyx.Radius.section, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Thermyx.Radius.section, style: .continuous)
                .strokeBorder(Thermyx.Ink.hairline, lineWidth: Thermyx.Stroke.hairline)
        }
        .accessibilityElement(children: .combine)
    }
}
