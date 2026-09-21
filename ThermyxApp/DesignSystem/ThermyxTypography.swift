import SwiftUI

/// Archivo and Archivo Narrow, bundled as static instances cut from the
/// Google Fonts variable sources (SIL Open Font License — see
/// Resources/Fonts/OFL.txt).
///
/// The handoff type scale is expressed here as named roles. Views ask for a
/// role, never for a family and a point size.
enum ThermyxFont {

    enum Family {
        static let regular = "Archivo-Regular"
        static let medium = "Archivo-Medium"
        static let semibold = "Archivo-SemiBold"
        static let bold = "Archivo-Bold"
        static let extraBold = "Archivo-ExtraBold"
        static let narrowSemibold = "ArchivoNarrow-SemiBold"
        static let narrowBold = "ArchivoNarrow-Bold"
    }

    /// Scales with Dynamic Type but stops short of breaking the dense
    /// dashboard layouts at the largest accessibility sizes.
    private static func archivo(_ name: String, _ size: CGFloat, relativeTo style: Font.TextStyle) -> Font {
        .custom(name, size: size, relativeTo: style)
    }

    // Headlines and titles
    static let screenTitle = archivo(Family.extraBold, 32, relativeTo: .largeTitle)
    static let detailTitle = archivo(Family.extraBold, 28, relativeTo: .title)
    static let onboardingHeadline = archivo(Family.extraBold, 36, relativeTo: .largeTitle)
    static let onboardingHeadlineLarge = archivo(Family.extraBold, 40, relativeTo: .largeTitle)
    static let articleHeadline = archivo(Family.extraBold, 29, relativeTo: .title)
    static let featureHeadline = archivo(Family.extraBold, 26, relativeTo: .title2)

    // Numerals
    static let heroNumeral = archivo(Family.extraBold, 76, relativeTo: .largeTitle)
    static let heroDegree = archivo(Family.extraBold, 26, relativeTo: .title2)
    static let statNumeral = archivo(Family.extraBold, 34, relativeTo: .title)
    static let zoneNumeral = archivo(Family.extraBold, 26, relativeTo: .title2)
    static let pullStat = archivo(Family.extraBold, 36, relativeTo: .largeTitle)
    static let metricNumeral = archivo(Family.extraBold, 22, relativeTo: .title3)
    static let metricNumeralCompact = archivo(Family.extraBold, 19, relativeTo: .headline)
    static let rowNumeral = archivo(Family.extraBold, 17, relativeTo: .body)

    // Cards and body
    static let cardTitle = archivo(Family.bold, 18, relativeTo: .headline)
    static let rowTitle = archivo(Family.bold, 16, relativeTo: .callout)
    static let rowTitleRegular = archivo(Family.semibold, 16, relativeTo: .callout)
    static let body = archivo(Family.regular, 16, relativeTo: .body)
    static let bodyLarge = archivo(Family.regular, 17, relativeTo: .body)
    static let bodySmall = archivo(Family.regular, 15, relativeTo: .subheadline)
    static let caption = archivo(Family.regular, 14, relativeTo: .footnote)
    static let captionSmall = archivo(Family.regular, 13, relativeTo: .caption)
    static let buttonLabel = archivo(Family.bold, 17, relativeTo: .headline)
    static let controlLabel = archivo(Family.bold, 16, relativeTo: .callout)

    // Archivo Narrow — all-caps labels
    static let sectionLabel = archivo(Family.narrowBold, 12, relativeTo: .caption)
    static let zoneLabel = archivo(Family.narrowBold, 11, relativeTo: .caption2)
    static let tabLabel = archivo(Family.narrowBold, 11, relativeTo: .caption2)
    static let statusPill = archivo(Family.narrowBold, 12, relativeTo: .caption)
    static let statusPillLarge = archivo(Family.narrowBold, 14, relativeTo: .subheadline)
    static let riskHeadline = archivo(Family.narrowBold, 24, relativeTo: .title2)
    static let wordmark = archivo(Family.narrowBold, 16, relativeTo: .headline)
    static let axisLabel = archivo(Family.narrowSemibold, 11, relativeTo: .caption2)
}

/// Letter-spacing values from the handoff, kept next to the roles they belong to.
enum ThermyxTracking {
    static let screenTitle: CGFloat = -1.0
    static let onboardingHeadline: CGFloat = -1.4
    static let onboardingHeadlineLarge: CGFloat = -1.6
    static let heroNumeral: CGFloat = -3.5
    static let statNumeral: CGFloat = -1.4
    static let zoneNumeral: CGFloat = -1.0
    static let metricNumeral: CGFloat = -0.8
    static let cardTitle: CGFloat = -0.2

    static let sectionLabel: CGFloat = 2.2
    static let zoneLabel: CGFloat = 1.6
    static let axisLabel: CGFloat = 1.2
    static let tabLabel: CGFloat = 1.2
    static let statusPill: CGFloat = 1.6
    static let statusPillWide: CGFloat = 2.2
    static let riskHeadline: CGFloat = 2.6
    static let wordmark: CGFloat = 4
}

extension Text {
    /// A tracked, all-caps Archivo Narrow label — the workhorse of this design.
    func narrowLabel(_ font: Font, tracking: CGFloat, color: Color) -> some View {
        self.font(font)
            .tracking(tracking)
            .foregroundStyle(color)
            .textCase(.uppercase)
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
        let expected = [
            ThermyxFont.Family.regular, ThermyxFont.Family.medium,
            ThermyxFont.Family.semibold, ThermyxFont.Family.bold,
            ThermyxFont.Family.extraBold, ThermyxFont.Family.narrowSemibold,
            ThermyxFont.Family.narrowBold
        ]
        let missing = expected.filter { UIFont(name: $0, size: 12) == nil }
        if !missing.isEmpty {
            assertionFailure("Thermyx fonts not registered: \(missing.joined(separator: ", "))")
        }
        #endif
    }
}
