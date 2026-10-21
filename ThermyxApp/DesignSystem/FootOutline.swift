import SwiftUI

/// The real left and right foot outlines from the v2 design. The point data
/// lives in `ThermyxFootShape` (shared with the widgets); this is the app's
/// `Foot`-typed face of it.
enum FootOutline {
    /// Width over height of the outline's box.
    static let aspect: CGFloat = ThermyxFootShape.aspect
    static let width: CGFloat = ThermyxFootShape.width

    static let left: [CGPoint] = ThermyxFootShape.left
    static let right: [CGPoint] = ThermyxFootShape.right

    static func points(_ foot: Foot) -> [CGPoint] { ThermyxFootShape.points(isLeft: foot == .left) }

    /// The outline fitted (aspect kept) and centred in `rect`.
    static func path(_ foot: Foot, in rect: CGRect) -> Path {
        ThermyxFootShape.path(isLeft: foot == .left, in: rect)
    }

    /// The outline's box, fitted and centred in `rect`.
    static func fitted(in rect: CGRect) -> CGRect { ThermyxFootShape.fitted(in: rect) }

    /// A point given as (medial-ness, toe-to-heel), both 0...1, for `foot`.
    static func point(m: CGFloat, v: CGFloat, foot: Foot, in rect: CGRect) -> CGPoint {
        ThermyxFootShape.point(m: m, v: v, isLeft: foot == .left, in: rect)
    }
}
