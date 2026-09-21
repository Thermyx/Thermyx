import SwiftUI

/// The single source of truth for Thermyx colour, spacing, and shape.
/// Every value here comes from the design handoff token table — no view
/// should ever reach for a literal hex.
enum Thermyx {

    // MARK: - Colour

    enum Ink {
        /// App background.
        static let midnight = Color(hex: 0x06101E)
        /// Cards and list containers.
        static let deck = Color(hex: 0x0D1A2B)
        /// Control bar and tab bar background.
        static let bar = Color(hex: 0x0A1524)
        /// Selected segments, avatars.
        static let elevated = Color(hex: 0x16304C)

        /// Primary actions, cooling, active toggles.
        static let signal = Color(hex: 0x2C9CF0)
        /// Live data, links, active tab, accents.
        static let ice = Color(hex: 0x5BD2FF)
        /// Heat, high risk, hot-zone fills.
        static let ember = Color(hex: 0xFF6A13)
        /// Caution tier, warm values.
        static let amber = Color(hex: 0xFF9B3D)

        static let textPrimary = Color(hex: 0xEAF2FA)
        static let textSecondary = Color(hex: 0xD9E6F2)
        static let textMuted = Color(hex: 0x9FB6CE)
        static let textSupporting = Color(hex: 0x8FA6BF)
        static let textFaint = Color(hex: 0x7D93AB)

        /// Label on a Signal Blue fill.
        static let onSignal = Color(hex: 0x03121F)
        /// Label on an Ember fill.
        static let onEmber = Color(hex: 0x1A0800)

        static let hairline = Color(red: 120/255, green: 170/255, blue: 220/255, opacity: 0.16)
        static let divider = Color(red: 120/255, green: 170/255, blue: 220/255, opacity: 0.14)

        static let alarmGradient = LinearGradient(
            colors: [Color(hex: 0xC0341F), Color(hex: 0x8A1F10)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// Tinted fills: a translucent wash plus a matching border.
    enum Tint {
        static let cautionFill = Color(hex: 0xFF6A13, opacity: 0.12)
        static let cautionBorder = Color(hex: 0xFF6A13, opacity: 0.40)

        static let liveFill = Color(hex: 0x5BD2FF, opacity: 0.12)
        static let liveBorder = Color(hex: 0x5BD2FF, opacity: 0.35)

        static let neutralFill = Color(red: 120/255, green: 170/255, blue: 220/255, opacity: 0.10)
        static let neutralBorder = Color(red: 120/255, green: 170/255, blue: 220/255, opacity: 0.22)

        static let signalFill = Color(hex: 0x2C9CF0, opacity: 0.12)
        static let signalBorder = Color(hex: 0x2C9CF0, opacity: 0.32)

        static let emberFill = Color(hex: 0xFF6A13, opacity: 0.14)
        static let emberBorder = Color(hex: 0xFF6A13, opacity: 0.35)

        static let amberFill = Color(hex: 0xFF9B3D, opacity: 0.10)
        static let amberBorder = Color(hex: 0xFF9B3D, opacity: 0.35)

        static let iceWash = Color(hex: 0x5BD2FF, opacity: 0.16)
        /// The rectangle behind the comfort range on temperature charts.
        static let comfortBand = Color(hex: 0x2C9CF0, opacity: 0.12)
        /// Track behind progress bars and donut arcs.
        static let track = Color(red: 120/255, green: 170/255, blue: 220/255, opacity: 0.14)
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
    }

    enum Radius {
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
