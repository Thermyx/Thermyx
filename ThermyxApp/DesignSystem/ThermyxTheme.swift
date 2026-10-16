import SwiftUI

/// The single source of truth for Thermyx colour, spacing, and shape.
/// Every value here comes from the design handoff token table — no view
/// should ever reach for a literal hex.
enum Thermyx {

    // MARK: - Colour

    enum Ink {
        /// App background: true black, under the topography.
        static let midnight = Color.black
        /// The few surfaces that still fill: sheets' grouped rows, sliders.
        static let deck = Color(hex: 0x0F1013)
        /// Tab bar background.
        static let bar = Color(hex: 0x0A0A0B)
        /// Avatars, selected segments.
        static let elevated = Color(hex: 0x16304C)

        /// Cooling, active toggles, the Auto target fill.
        static let signal = Color(hex: 0x2C9CF0)
        /// Normal, live data, links, accents.
        static let ice = Color(hex: 0x5BD2FF)
        /// Heat, High risk and Critical, hot-zone fills.
        static let ember = Color(hex: 0xFF6A13)
        /// Caution, warm values.
        static let amber = Color(hex: 0xFF9B3D)
        /// Emergency red: the hold-to-call button and nothing else.
        static let emergency = Color(hex: 0xE5262B)
        static let emergencyDeep = Color(hex: 0x9E0F16)

        /// AI Insights, the one feature that asks an outside model, gets
        /// its own colour so it is never mistaken for a reading. Deep for
        /// the switch, light for type on black.
        static let aiDeep = Color(hex: 0x5A2BD6)
        static let ai = Color(hex: 0xB7A2FF)

        static let textPrimary = Color(hex: 0xF2F4F7)
        static let textSecondary = Color(hex: 0xD3D8DF)
        static let textMuted = Color(hex: 0xA1A8B3)
        static let textSupporting = Color(hex: 0xA1A8B3)
        static let textFaint = Color(hex: 0x7C848F)

        /// Label on a Signal Blue fill.
        static let onSignal = Color(hex: 0x00111F)
        /// Label on an Ember fill.
        static let onEmber = Color(hex: 0x1A0800)
        /// Label on the white primary fill.
        static let onPrimary = Color(hex: 0x0A0A0B)

        /// The v2 hairline: what separates sections in place of cards.
        static let hairline = Color(hex: 0x1C1E22)
        static let divider = Color(hex: 0x1C1E22)

        static let alarmGradient = LinearGradient(
            colors: [Color(hex: 0xC0341F), Color(hex: 0x8A1F10)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// The same black-and-hairline palette, named for the surfaces the
    /// website and onboarding use.
    enum Site {
        static let bg = Color.black
        static let surface = Color(hex: 0x0B0B0C)
        static let raised = Color(hex: 0x111215)
        /// Glass over the topography: a dark wash under a material.
        static let glass = Color(hex: 0x0B0B0C, opacity: 0.6)
        static let hairline = Color(hex: 0x1C1E22)
        static let hairlineStrong = Color(hex: 0x2A2D33)
        static let text = Color(hex: 0xF2F4F7)
        static let textMuted = Color(hex: 0xA1A8B3)
        static let textFaint = Color(hex: 0x7C848F)
    }

    /// Tinted fills: a translucent wash plus a matching border.
    enum Tint {
        static let cautionFill = Color(hex: 0xFF6A13, opacity: 0.12)
        static let cautionBorder = Color(hex: 0xFF6A13, opacity: 0.40)

        static let liveFill = Color(hex: 0x5BD2FF, opacity: 0.10)
        static let liveBorder = Color(hex: 0x5BD2FF, opacity: 0.35)

        /// Control wells: segmented controls, the thermal bar, steppers.
        static let neutralFill = Color(hex: 0x111215)
        static let neutralBorder = Color(hex: 0x2A2D33)

        static let signalFill = Color(hex: 0x2C9CF0, opacity: 0.12)
        static let signalBorder = Color(hex: 0x2C9CF0, opacity: 0.32)

        static let emberFill = Color(hex: 0xFF6A13, opacity: 0.14)
        static let emberBorder = Color(hex: 0xFF6A13, opacity: 0.35)

        static let amberFill = Color(hex: 0xFF9B3D, opacity: 0.10)
        static let amberBorder = Color(hex: 0xFF9B3D, opacity: 0.35)

        static let iceWash = Color(hex: 0x5BD2FF, opacity: 0.14)

        static let aiFill = Color(hex: 0x6B3DF0, opacity: 0.14)
        static let aiBorder = Color(hex: 0x8B6BFF, opacity: 0.42)
        /// The rectangle behind the comfort range on temperature charts.
        static let comfortBand = Color(hex: 0x2C9CF0, opacity: 0.12)
        /// The comfort band's swatch in a legend, strong enough to see small.
        static let comfortKey = Color(hex: 0x2C9CF0, opacity: 0.5)
        /// Track behind progress bars, sliders and the risk scale.
        static let track = Color(hex: 0x24272C)
    }

    // MARK: - Metrics

    enum Space {
        /// Screen horizontal padding.
        static let screen: CGFloat = 20
        /// Wider gutter used by onboarding and the article reader.
        static let wide: CGFloat = 24
        /// Top padding under the status bar.
        static let underStatusBar: CGFloat = 12

        static let xs: CGFloat = 8
        static let s: CGFloat = 10
        static let m: CGFloat = 12
        static let l: CGFloat = 14
        static let xl: CGFloat = 16
        static let xxl: CGFloat = 18
        /// Hero card padding.
        static let hero: CGFloat = 22

        // The vertical rhythm every screen follows, on a 4-point grid.

        /// Between a screen's title and its first section.
        static let titleGap: CGFloat = 20
        /// Between sections on a screen.
        static let section: CGFloat = 32
        /// Between groups on a form or an onboarding page.
        static let group: CGFloat = 24
        /// Above a tab's title, under the status bar.
        static let titleTop: CGFloat = 10
        /// From a section's title to its content.
        static let header: CGFloat = 12
        /// Between stacked items inside a section.
        static let item: CGFloat = 8
        /// Vertical padding inside a list row.
        static let row: CGFloat = 14
    }

    enum Radius {
        /// Primary and secondary buttons, the thermal bar's wells.
        static let action: CGFloat = 16
        static let button: CGFloat = 12
        static let control: CGFloat = 14
        static let compact: CGFloat = 16
        static let list: CGFloat = 18
        static let section: CGFloat = 20
        static let hero: CGFloat = 22
        static let readout: CGFloat = 24
        static let pill: CGFloat = 999
    }

    enum Stroke {
        static let hairline: CGFloat = 1
        static let emphasis: CGFloat = 1.5
    }

    /// The primary audience wears gloves in direct sunlight. Nothing tappable
    /// is allowed below this.
    static let minimumTapTarget: CGFloat = 48
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}
