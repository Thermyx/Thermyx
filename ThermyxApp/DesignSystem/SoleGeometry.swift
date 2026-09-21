import SwiftUI

// MARK: - Foot

enum Foot: String, CaseIterable, Identifiable, Codable, Hashable {
    case left
    case right

    var id: String { rawValue }

    var label: String { self == .left ? "Left" : "Right" }
    var shortLabel: String { self == .left ? "L" : "R" }
    var other: Foot { self == .left ? .right : .left }

    /// Encoded in the telemetry flags byte so an insole can say which foot it
    /// is on. `0` means unspecified, and the app asks the user to assign it.
    var protocolValue: UInt8 { self == .left ? 1 : 2 }

    static func from(flags: UInt8) -> Foot? {
        switch flags & 0b11 {
        case 1: return .left
        case 2: return .right
        default: return nil
        }
    }
}

// MARK: - Sole shape

/// The sole outline, in a normalised space where **y runs 0 at the heel to 1
/// at the toe** and **x is a fraction of the same foot length**, centred on
/// the outline's bounding-box centreline.
///
/// The geometry is traced from measured US 11–12 sole templates. All three
/// sizes share the same profile to within 0.1% of aspect ratio, so one path
/// scaled by foot length is accurate for the whole supported range — see
/// `SoleSize`.
///
/// The traced template is a **left** foot; the right is its mirror. Both are
/// drawn as seen looking down at the top of the insole, which is how they sit
/// in the shoe, so the medial (big toe) side of each foot faces the other.
struct SoleShape: Shape {
    var foot: Foot = .left

    /// Width as a fraction of length. Used wherever a frame has to be sized
    /// to the sole without measuring the path.
    static let widthRatio: CGFloat = 0.42139

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: unit(0.06964, 0.99975, in: rect))
        path.addCurve(to: unit(-0.15685, 0.84056, in: rect),
                      control1: unit(-0.04369, 0.99109, in: rect),
                      control2: unit(-0.10731, 0.93646, in: rect))
        path.addCurve(to: unit(-0.20452, 0.57882, in: rect),
                      control1: unit(-0.21225, 0.73333, in: rect),
                      control2: unit(-0.21810, 0.63290, in: rect))
        path.addCurve(to: unit(-0.09961, 0.16512, in: rect),
                      control1: unit(-0.16872, 0.43625, in: rect),
                      control2: unit(-0.10633, 0.24098, in: rect))
        path.addCurve(to: unit(0.05508, 0.00186, in: rect),
                      control1: unit(-0.08916, 0.04699, in: rect),
                      control2: unit(-0.03445, -0.01146, in: rect))
        path.addCurve(to: unit(0.17082, 0.12083, in: rect),
                      control1: unit(0.13372, 0.01357, in: rect),
                      control2: unit(0.16890, 0.06658, in: rect))
        path.addCurve(to: unit(0.14887, 0.37565, in: rect),
                      control1: unit(0.17341, 0.19415, in: rect),
                      control2: unit(0.14819, 0.28764, in: rect))
        path.addCurve(to: unit(0.20027, 0.68520, in: rect),
                      control1: unit(0.14954, 0.46366, in: rect),
                      control2: unit(0.19150, 0.61515, in: rect))
        path.addCurve(to: unit(0.20241, 0.89161, in: rect),
                      control1: unit(0.20911, 0.75583, in: rect),
                      control2: unit(0.21744, 0.82111, in: rect))
        path.addCurve(to: unit(0.06964, 0.99975, in: rect),
                      control1: unit(0.18445, 0.97591, in: rect),
                      control2: unit(0.11153, 1.00295, in: rect))
        path.closeSubpath()
        return path
    }

    /// Maps sole space into the frame: y is flipped because the heel is at
    /// y = 0 anatomically but at the bottom of the view, and x is mirrored for
    /// the right foot.
    private func unit(_ x: CGFloat, _ y: CGFloat, in rect: CGRect) -> CGPoint {
        SoleGeometry.point(x: x, y: y, foot: foot, in: rect)
    }
}

// MARK: - Coordinate system

/// The bridge between anatomy, hardware, and pixels.
///
/// Everything the app draws on a sole — heat blooms, pressure dots, fault
/// markers — is positioned in **sole space**: `y` is the fraction of foot
/// length from the heel, `x` is the offset from the centreline in the same
/// units, positive toward the **medial** (big toe) side of whichever foot is
/// being drawn. That keeps every position anatomical rather than per-foot, so
/// a sensor site is written once and renders correctly mirrored on both feet.
enum SoleGeometry {

    /// Converts sole space to view space for a given foot.
    static func point(x: CGFloat, y: CGFloat, foot: Foot, in rect: CGRect) -> CGPoint {
        // The traced template is a left foot with medial toward +x. Mirroring
        // for the right foot keeps medial anatomically correct on both.
        let mirrored = foot == .left ? x : -x
        return CGPoint(
            x: rect.midX + mirrored * rect.height,
            y: rect.maxY - y * rect.height
        )
    }

    // MARK: Sensor sites
    //
    // The eight FSR positions from the prototype: medial and lateral heel,
    // medial and lateral midfoot, first, third and fifth metatarsal heads, and
    // the hallux. Coordinates were placed against the measured width profile
    // of the traced outline; every site clears the edge by at least 0.054 of
    // foot length, which is about 16 mm at US 12 — enough for an FSR 402.

    enum SensorSite: String, CaseIterable, Identifiable {
        case heelLateral, heelMedial
        case midfootLateral, midfootMedial
        case metatarsal5, metatarsal3, metatarsal1
        case hallux

        var id: String { rawValue }

        var label: String {
            switch self {
            case .heelLateral: return "Lateral heel"
            case .heelMedial: return "Medial heel"
            case .midfootLateral: return "Lateral midfoot"
            case .midfootMedial: return "Medial midfoot"
            case .metatarsal5: return "5th metatarsal"
            case .metatarsal3: return "3rd metatarsal"
            case .metatarsal1: return "1st metatarsal"
            case .hallux: return "Hallux"
            }
        }

        /// Position in sole space.
        var position: CGPoint {
            switch self {
            case .heelLateral: return CGPoint(x: -0.022, y: 0.13)
            case .heelMedial: return CGPoint(x: 0.096, y: 0.13)
            case .midfootLateral: return CGPoint(x: -0.094, y: 0.42)
            case .midfootMedial: return CGPoint(x: 0.083, y: 0.44)
            case .metatarsal5: return CGPoint(x: -0.137, y: 0.66)
            case .metatarsal3: return CGPoint(x: -0.001, y: 0.70)
            case .metatarsal1: return CGPoint(x: 0.140, y: 0.72)
            case .hallux: return CGPoint(x: 0.143, y: 0.90)
            }
        }

        /// Which thermal zone this site sits in.
        var zone: FootZone {
            switch self {
            case .heelLateral, .heelMedial: return .heel
            case .midfootLateral, .midfootMedial: return .arch
            case .metatarsal5, .metatarsal3, .metatarsal1, .hallux: return .forefoot
            }
        }
    }

    // MARK: Thermal zones

    /// Where each zone's heat bloom is centred, in sole space.
    static func zoneCentre(_ zone: FootZone) -> CGPoint {
        switch zone {
        case .heel: return CGPoint(x: 0.035, y: 0.15)
        case .arch: return CGPoint(x: 0.000, y: 0.45)
        case .forefoot: return CGPoint(x: 0.013, y: 0.75)
        }
    }

    /// How far each zone's bloom reaches, as a fraction of foot length. Sized
    /// from the sole's measured width at that height so a bloom fills its
    /// region without spilling into the next one.
    static func zoneRadius(_ zone: FootZone) -> CGFloat {
        switch zone {
        case .heel: return 0.150
        case .arch: return 0.140
        case .forefoot: return 0.185
        }
    }

}

// MARK: - Sizes

/// The supported sole sizes.
///
/// The prototype platform is built for US men's 11–12. Other sizes appear in
/// the picker but are disabled: the trim lines, the no-cut zone, and the
/// thermal cassette are cut for this range, and offering a size we cannot
/// build would be a promise the hardware does not keep.
struct SoleSize: Identifiable, Equatable, Hashable, Codable {
    /// US men's size.
    let usMens: Double
    /// Measured template length in millimetres.
    let lengthMM: Double

    var id: Double { usMens }

    var widthMM: Double { lengthMM * Double(SoleShape.widthRatio) }

    var label: String {
        usMens == usMens.rounded()
            ? "US \(Int(usMens))"
            : String(format: "US %.1f", usMens)
    }

    /// Converts a sole-space distance into millimetres for this size.
    func millimetres(_ soleSpace: CGFloat) -> Double { Double(soleSpace) * lengthMM }

    /// The sizes the prototype actually fits, measured from the templates.
    static let supported: [SoleSize] = [
        SoleSize(usMens: 11, lengthMM: 290.9),
        SoleSize(usMens: 11.5, lengthMM: 295.5),
        SoleSize(usMens: 12, lengthMM: 298.7)
    ]

    /// Every size the picker shows. Only `supported` can be selected.
    static let all: [SoleSize] = stride(from: 6.0, through: 15.0, by: 0.5).map { size in
        supported.first { $0.usMens == size }
            // Unsupported sizes still need a plausible length for the label;
            // the standard US progression is about a third of an inch a size.
            ?? SoleSize(usMens: size, lengthMM: 298.7 - (12 - size) * 8.46)
    }

    var isSupported: Bool {
        SoleSize.supported.contains { $0.usMens == usMens }
    }

    static let `default` = SoleSize(usMens: 11.5, lengthMM: 295.5)
}
