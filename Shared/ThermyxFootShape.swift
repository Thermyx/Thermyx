import SwiftUI

/// The real left and right foot outlines from the v2 design (traced from
/// scans), in a 41.9 x 100 box with the toes at the top. Shared by the app's
/// foot maps and the widgets, so a sole in a widget is the same shape as the
/// one on Home.
enum ThermyxFootShape {
    static let width: CGFloat = 41.9
    /// Width over height of the outline's box.
    static let aspect: CGFloat = width / 100

    static let left: [CGPoint] = parse("27.3,0 19.8,1.7 16.2,3.4 13.7,5.1 11.7,6.8 10.2,8.5 8.8,10.2 7.6,11.9 6.6,13.6 5.6,15.3 4.8,16.9 4.1,18.6 3.4,20.3 2.7,22 2.1,23.7 1.7,25.4 1.3,27.1 0.8,28.8 0.6,30.5 0.3,32.2 0.1,33.9 0,35.6 0.1,37.3 0.1,39 0.4,40.7 0.8,42.4 1.3,44.1 1.7,45.8 2.1,47.5 2.7,49.2 3.1,50.8 3.7,52.5 4.2,54.2 4.7,55.9 5.2,57.6 5.6,59.3 6.2,61 6.8,62.7 7.2,64.4 7.8,66.1 8.2,67.8 8.8,69.5 9.2,71.2 9.6,72.9 10.2,74.6 10.6,76.3 10.9,78 11.3,79.7 11.6,81.4 11.9,83.1 12.1,84.7 12.4,86.4 12.7,88.1 13.1,89.8 13.8,91.5 14.5,93.2 15.5,94.9 16.9,96.6 19.1,98.3 23.6,100 27.5,100 31.1,99.2 34.3,97.5 36.3,95.8 37.4,94.1 38.3,92.4 38.7,90.7 39,89 38.8,87.3 38.7,85.6 38.6,83.9 38.4,82.2 38.3,80.5 38.1,78.8 37.9,77.1 37.7,75.4 37.6,73.7 37.4,72 37.3,70.3 37.1,68.6 37,66.9 37,65.3 36.9,63.6 36.9,61.9 36.9,60.2 37,58.5 37.1,56.8 37.3,55.1 37.6,53.4 37.7,51.7 38,50 38.3,48.3 38.6,46.6 38.8,44.9 39.1,43.2 39.5,41.5 39.8,39.8 40.1,38.1 40.4,36.4 40.7,34.7 41,33.1 41.1,31.4 41.2,29.7 41.5,28 41.7,26.3 41.8,24.6 41.8,22.9 41.9,21.2 41.9,19.5 41.8,17.8 41.7,16.1 41.5,14.4 41.2,12.7 41,11 40.5,9.3 39.8,7.6 39,5.9 37.7,4.2 35.9,2.5 32.8,0.8")
    static let right: [CGPoint] = parse("12.6,0 7.3,1.7 5.1,3.4 3.5,5.1 2.5,6.8 1.7,8.5 1.3,10.2 0.8,11.9 0.6,13.6 0.3,15.3 0.1,16.9 0.1,18.6 0,20.3 0.1,22 0.1,23.7 0.3,25.4 0.4,27.1 0.6,28.8 0.7,30.5 0.8,32.2 1.1,33.9 1.4,35.6 1.7,37.3 2,39 2.3,40.7 2.5,42.4 3,44.1 3.2,45.8 3.5,47.5 3.8,49.2 4.1,50.8 4.2,52.5 4.5,54.2 4.7,55.9 4.9,57.6 4.9,59.3 5.1,61 5.1,62.7 4.9,64.4 4.9,66.1 4.8,67.8 4.7,69.5 4.5,71.2 4.4,72.9 4.2,74.6 4.1,76.3 4,78 3.8,79.7 3.7,81.4 3.4,83.1 3.2,84.7 3.1,86.4 3,88.1 3.1,89.8 3.4,91.5 4.1,93.2 5.1,94.9 6.5,96.6 8.9,98.3 14.4,100 18.4,100 21.3,99.2 24,97.5 25.7,95.8 26.8,94.1 27.8,92.4 28.5,90.7 29,89 29.4,87.3 29.7,85.6 29.9,83.9 30.2,82.2 30.5,80.5 30.8,78.8 31.2,77.1 31.6,75.4 32.1,73.7 32.5,72 33.1,70.3 33.5,68.6 34,66.9 34.5,65.3 35,63.6 35.5,61.9 36,60.2 36.4,58.5 37,56.8 37.6,55.1 38,53.4 38.6,51.7 39,50 39.5,48.3 40,46.6 40.5,44.9 41,43.2 41.4,41.5 41.7,39.8 41.8,38.1 41.9,36.4 41.8,34.7 41.7,33.1 41.5,31.4 41.2,29.7 41,28 40.5,26.3 40.1,24.6 39.5,22.9 38.8,21.2 38.3,19.5 37.4,17.8 36.7,16.1 35.7,14.4 34.9,12.7 33.8,11 32.5,9.3 31.1,7.6 29.2,5.9 27.1,4.2 24.2,2.5 19.5,0.8")

    static func points(isLeft: Bool) -> [CGPoint] { isLeft ? left : right }

    /// The outline fitted (aspect kept) and centred in `rect`.
    static func path(isLeft: Bool, in rect: CGRect) -> Path {
        let box = fitted(in: rect)
        var path = Path()
        for (i, p) in points(isLeft: isLeft).enumerated() {
            let q = CGPoint(x: box.minX + p.x / width * box.width, y: box.minY + p.y / 100 * box.height)
            if i == 0 { path.move(to: q) } else { path.addLine(to: q) }
        }
        path.closeSubpath()
        return path
    }

    /// The outline's box, fitted and centred in `rect`.
    static func fitted(in rect: CGRect) -> CGRect {
        let scale = min(rect.width / width, rect.height / 100)
        let size = CGSize(width: width * scale, height: 100 * scale)
        return CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
    }

    /// A point given as (medial-ness, toe-to-heel), both 0...1. `m` = 1 is
    /// the big-toe side, so the same `m` lands on the inside of either foot.
    static func point(m: CGFloat, v: CGFloat, isLeft: Bool, in rect: CGRect) -> CGPoint {
        let box = fitted(in: rect)
        let u = isLeft ? m : 1 - m
        return CGPoint(x: box.minX + u * box.width, y: box.minY + v * box.height)
    }

    /// Where each insole's one arch pressure sensor sits.
    static let archSite = (m: 0.6, v: 0.58)

    private static func parse(_ text: String) -> [CGPoint] {
        text.split(separator: " ").compactMap { pair in
            let xy = pair.split(separator: ",").compactMap { Double($0) }
            return xy.count == 2 ? CGPoint(x: xy[0], y: xy[1]) : nil
        }
    }
}
