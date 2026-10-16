import SwiftUI

/// Archivo (Omnibus Type, the website's face) for words and big numerals,
/// and Geist Mono (Vercel) for figures read against each other: timers,
/// rates, percentages. Both SIL Open Font License — see
/// Resources/Fonts/OFL.txt and OFL-Geist.txt. Sentence-case labels, tight
/// large numerals, as the v2 design sets them.
///
/// Views ask for a role, never for a family and a point size.
enum ThermyxFont {

    enum Family {
        static let regular = "Archivo-Regular"
        static let medium = "Archivo-Medium"
        static let semibold = "Archivo-SemiBold"
        static let bold = "Archivo-Bold"
        static let extraBold = "Archivo-ExtraBold"
        static let mono = "GeistMono-Regular"
        static let monoMedium = "GeistMono-Medium"
        static let monoSemibold = "GeistMono-SemiBold"

        static let all = [regular, medium, semibold, bold, extraBold, mono, monoMedium, monoSemibold]
    }

    /// Scales with Dynamic Type relative to `style`.
    private static func archivo(_ name: String, _ size: CGFloat, relativeTo style: Font.TextStyle) -> Font {
        .custom(name, size: size, relativeTo: style)
    }

    // MARK: Display

    /// Onboarding and reader headlines.
    static let display = archivo(Family.semibold, 34, relativeTo: .largeTitle)
    static let displayLarge = archivo(Family.semibold, 40, relativeTo: .largeTitle)
    static let displaySmall = archivo(Family.semibold, 28, relativeTo: .title)
    /// Large readout numerals outside the hero.
    static let displayNumeral = archivo(Family.semibold, 40, relativeTo: .title)

    // MARK: Titles

    /// Tab-level screen titles: 30 pt semibold, tracked in.
    static let screenTitle = archivo(Family.semibold, 30, relativeTo: .largeTitle)
    static let detailTitle = archivo(Family.semibold, 30, relativeTo: .largeTitle)
    static let onboardingHeadline = archivo(Family.semibold, 28, relativeTo: .title)
    static let onboardingHeadlineLarge = archivo(Family.semibold, 32, relativeTo: .largeTitle)
    static let articleHeadline = archivo(Family.semibold, 30, relativeTo: .title)
    static let featureHeadline = archivo(Family.semibold, 22, relativeTo: .title2)
    /// "What happens at each level", "Trusted circle": 17 pt semibold.
    static let sectionTitle = archivo(Family.semibold, 17, relativeTo: .headline)

    // MARK: Numerals

    static let heroNumeral = archivo(Family.bold, 72, relativeTo: .largeTitle)
    static let heroDegree = archivo(Family.medium, 26, relativeTo: .title2)
    static let statNumeral = archivo(Family.semibold, 34, relativeTo: .title)
    static let zoneNumeral = archivo(Family.semibold, 24, relativeTo: .title2)
    static let pullStat = archivo(Family.semibold, 30, relativeTo: .title)
    static let metricNumeral = mono(Family.monoMedium, 20, relativeTo: .title3)
    static let metricNumeralCompact = mono(Family.monoMedium, 18, relativeTo: .headline)
    static let rowNumeral = mono(Family.monoMedium, 16, relativeTo: .body)

    // MARK: Mono

    /// Big mono readouts: timers, the Auto target.
    static let monoDisplay = mono(Family.monoMedium, 52, relativeTo: .largeTitle)
    static let monoLarge = mono(Family.monoMedium, 28, relativeTo: .title)
    static let monoBody = mono(Family.monoMedium, 15, relativeTo: .body)
    static let monoCaption = mono(Family.monoMedium, 13, relativeTo: .footnote)
    static let monoSmall = mono(Family.monoMedium, 11, relativeTo: .caption2)

    private static func mono(_ name: String, _ size: CGFloat, relativeTo style: Font.TextStyle) -> Font {
        .custom(name, size: size, relativeTo: style)
    }

    // MARK: Body

    static let cardTitle = archivo(Family.semibold, 17, relativeTo: .headline)
    static let rowTitle = archivo(Family.semibold, 16, relativeTo: .callout)
    static let rowTitleRegular = archivo(Family.regular, 16, relativeTo: .callout)
    static let body = archivo(Family.regular, 16, relativeTo: .body)
    static let bodyLarge = archivo(Family.regular, 17, relativeTo: .body)
    static let bodySmall = archivo(Family.regular, 15, relativeTo: .subheadline)
    static let caption = archivo(Family.regular, 14, relativeTo: .footnote)
    static let captionSmall = archivo(Family.regular, 13, relativeTo: .caption)
    static let buttonLabel = archivo(Family.semibold, 16, relativeTo: .headline)
    static let controlLabel = archivo(Family.semibold, 15, relativeTo: .callout)

    // MARK: Labels
    //
    // v1 set these in tracked all-caps Archivo Narrow. v2 keeps the roles but
    // sets them in sentence case: 13 pt medium Archivo, quiet grey.

    static let sectionLabel = archivo(Family.medium, 13, relativeTo: .footnote)
    static let zoneLabel = archivo(Family.medium, 12, relativeTo: .caption)
    static let tabLabel = archivo(Family.medium, 11, relativeTo: .caption2)
    static let statusPill = archivo(Family.medium, 13, relativeTo: .caption)
    static let statusPillLarge = archivo(Family.semibold, 15, relativeTo: .subheadline)
    static let riskHeadline = archivo(Family.semibold, 20, relativeTo: .title3)
    static let wordmark = archivo(Family.bold, 17, relativeTo: .headline)
    static let axisLabel = mono(Family.mono, 11, relativeTo: .caption2)
}

/// Letter-spacing, kept next to the roles it belongs to.
enum ThermyxTracking {
    static let screenTitle: CGFloat = -1
    static let onboardingHeadline: CGFloat = -0.8
    static let onboardingHeadlineLarge: CGFloat = -1
    static let heroNumeral: CGFloat = -3.5
    static let statNumeral: CGFloat = -1.2
    static let zoneNumeral: CGFloat = -0.8
    static let metricNumeral: CGFloat = 0
    static let cardTitle: CGFloat = -0.2
    static let monoLarge: CGFloat = -1
    static let monoDisplay: CGFloat = -2

    // Sentence-case labels sit at their natural spacing; the caps-era values
    // are kept as names so call sites still read, but they no longer spread
    // the letters.
    static let sectionLabel: CGFloat = 0
    static let zoneLabel: CGFloat = 0
    static let axisLabel: CGFloat = 0
    static let tabLabel: CGFloat = 0
    static let statusPill: CGFloat = 0
    static let statusPillWide: CGFloat = 0
    static let riskHeadline: CGFloat = -0.2
    static let wordmark: CGFloat = -0.4

    static let display: CGFloat = -1
    static let displaySmall: CGFloat = -0.8
}

extension Text {
    /// The small label voice: sentence case, medium weight. (The name is
    /// from v1's tracked Archivo Narrow caps; the tracking argument is
    /// ignored now that labels are no longer spread.)
    func narrowLabel(_ font: Font, tracking: CGFloat, color: Color) -> some View {
        self.font(font)
            .foregroundStyle(color)
    }
}

// MARK: - Registration

enum ThermyxFontRegistration {
    /// Fonts ship as bundle resources and are declared in Info.plist under
    /// `UIAppFonts`. This verifies the declaration actually took effect —
    /// a silent fallback to the system font is the kind of thing that only
    /// shows up in a screenshot after the fact.
    static func verify() {
        #if DEBUG
        let missing = ThermyxFont.Family.all.filter { UIFont(name: $0, size: 12) == nil }
        if !missing.isEmpty {
            assertionFailure("Thermyx fonts not registered: \(missing.joined(separator: ", "))")
        }
        #endif
    }
}
