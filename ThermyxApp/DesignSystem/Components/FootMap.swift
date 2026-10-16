import SwiftUI

// MARK: - Colour scales

// `FootScale` (the thermal and load ramps) lives in Shared/ThermyxScales.swift
// so the widgets use the same colours.
extension FootScale {
    static var steadinessGradient: [Color] {
        stride(from: 40.0, through: 100, by: 10).map { ChartValueScale.steadiness.color(at: $0) }
    }
}

// MARK: - Fields

/// A scalar field over the foot, 0...1, rendered into a small image the map
/// stretches over the outline. `m` runs from the outer edge (0) to the
/// big-toe side (1); `v` from the toes (0) to the heel (1).
struct FootField {
    /// Nil leaves a cell as unsensed.
    let value: (_ m: Double, _ v: Double) -> Double?
    var scale: Scale
    /// Steps the colour into bands, as the design does, so a map reads as
    /// levels rather than a blur.
    var bands = 16

    enum Scale { case thermal, load }

    static let gridWidth = 48
    static let gridHeight = 115

    func image(foot: Foot) -> CGImage? {
        let w = Self.gridWidth, h = Self.gridHeight
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let empty: FootScale.RGB = (20, 24, 30)
        for y in 0..<h {
            let v = Double(y) / Double(h - 1)
            for x in 0..<w {
                let u = Double(x) / Double(w - 1)
                let m = foot == .left ? u : 1 - u
                var rgb = empty
                if let raw = value(m, v) {
                    let q = (min(max(raw, 0), 1) * Double(bands)).rounded() / Double(bands)
                    switch scale {
                    case .thermal: rgb = FootScale.ramp(FootScale.thermal, q)
                    case .load: rgb = q < 0.05 ? empty : FootScale.jet(q)
                    }
                }
                let i = (y * w + x) * 4
                pixels[i] = UInt8(rgb.r); pixels[i + 1] = UInt8(rgb.g); pixels[i + 2] = UInt8(rgb.b); pixels[i + 3] = 255
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

// MARK: - Map

/// One foot, drawn inside its real outline.
///
/// Live screens only ever pass what the insole measured: one temperature
/// (or three zones on hardware that has them), and the arch sensor's level.
/// Anything finer — a full pressure field, a centre-of-pressure trace — is
/// for the Simulator, which labels it simulated.
struct FootMap: View {
    let foot: Foot
    var content: Content

    enum Content {
        /// The sole tinted by one measured temperature, or nil for no reading.
        case temperature(Double?)
        /// Forefoot, arch and heel temperatures.
        case zones(FootZoneTemperatures)
        /// The arch sensor's level, 0...1; the rest of the sole is unsensed.
        case archLoad(Double?)
        /// The forefoot's share of three sensors' load, 0...1.
        case forefootShare(Double?)
        /// Just the outline (a foot with no insole).
        case outline(dimmed: Bool)
        /// Walking steadiness, 0…1, from the motion sensor: one value for
        /// the whole foot, tinted on the steadiness scale.
        case steadiness(Double?)
        /// Battery as a fill rising from the heel.
        case battery(percent: Int?, tint: Color)
        /// A computed field: the Simulator's.
        case field(FootField, centreOfPressure: [CGPoint]?, copProgress: Double?)
    }

    /// The arch sensor's site, as the firmware's GPIO34 FSR sits.
    static let archSite = (m: 0.6, v: 0.58)

    var body: some View {
        Canvas(rendersAsynchronously: false) { ctx, size in
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: 2, dy: 2)
            let path = FootOutline.path(foot, in: rect)
            let box = FootOutline.fitted(in: rect)
            let line = max(1, size.width / 90)

            ctx.drawLayer { layer in
                layer.clip(to: path)
                draw(in: &layer, box: box, rect: rect, line: line)
            }
            ctx.stroke(path, with: .color(.white.opacity(outlineOpacity)), lineWidth: line)
            overlays(in: &ctx, rect: rect, line: line)
        }
        .aspectRatio(FootOutline.aspect, contentMode: .fit)
        .accessibilityHidden(true)
    }

    private var outlineOpacity: Double {
        if case .outline(let dimmed) = content { return dimmed ? 0.18 : 0.4 }
        return 0.3
    }

    private func draw(in ctx: inout GraphicsContext, box: CGRect, rect: CGRect, line: CGFloat) {
        let all = Path(box.insetBy(dx: -4, dy: -4))
        switch content {
        case .temperature(let c):
            ctx.fill(all, with: .color(c.map(FootScale.thermalColor) ?? FootScale.unsensed))
        case .zones(let z):
            let field = FootField(value: { _, v in
                // Forefoot to arch to heel along the length, blended at the
                // seams: three measurements, interpolated between.
                let s1 = 1 / (1 + exp(-(v - 0.42) / 0.035)), s2 = 1 / (1 + exp(-(v - 0.7) / 0.035))
                let c = z.forefootC * (1 - s1) + z.archC * (s1 - s2) + z.heelC * s2
                return FootScale.thermalPosition(c)
            }, scale: .thermal, bands: 12)
            if let image = field.image(foot: foot) {
                ctx.draw(Image(decorative: image, scale: 1).interpolation(.high), in: box)
            }
        case .archLoad(let level):
            ctx.fill(all, with: .color(FootScale.unsensed))
            if let level, level > 0.02 {
                let c = FootOutline.point(m: Self.archSite.m, v: Self.archSite.v, foot: foot, in: rect)
                let r = box.width * (0.3 + 0.12 * level)
                let color = FootScale.loadColor(min(1, level))
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r * 1.3, width: r * 2, height: r * 2.6)),
                         with: .radialGradient(Gradient(colors: [color, color.opacity(0.55), color.opacity(0)]),
                                               center: c, startRadius: 0, endRadius: r * 1.3))
            }
        case .forefootShare(let share):
            ctx.fill(all, with: .color(FootScale.unsensed))
            if let share {
                blob(&ctx, m: 0.52, v: 0.24, level: share, box: box, rect: rect)
                blob(&ctx, m: 0.5, v: 0.86, level: 1 - share, box: box, rect: rect)
            }
        case .outline:
            ctx.fill(all, with: .color(FootScale.unsensed.opacity(0.6)))
        case .steadiness(let value):
            ctx.fill(all, with: .color(value.map { ChartValueScale.steadiness.color(at: $0 * 100) } ?? FootScale.unsensed))
        case .battery(let percent, let tint):
            ctx.fill(all, with: .color(Color(hex: 0x111317)))
            if let percent {
                let top = box.minY + box.height * (1 - Double(percent) / 100)
                ctx.fill(Path(CGRect(x: box.minX - 4, y: top, width: box.width + 8, height: box.maxY - top + 4)), with: .color(tint))
            }
        case .field(let field, _, _):
            if let image = field.image(foot: foot) {
                ctx.draw(Image(decorative: image, scale: 1).interpolation(.high), in: box)
            }
        }
    }

    private func blob(_ ctx: inout GraphicsContext, m: Double, v: Double, level: Double, box: CGRect, rect: CGRect) {
        guard level > 0.02 else { return }
        let c = FootOutline.point(m: m, v: v, foot: foot, in: rect)
        let r = box.width * (0.32 + 0.15 * level)
        let color = FootScale.loadColor(min(1, level))
        ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                 with: .radialGradient(Gradient(colors: [color, color.opacity(0)]), center: c, startRadius: 0, endRadius: r))
    }

    private func overlays(in ctx: inout GraphicsContext, rect: CGRect, line: CGFloat) {
        switch content {
        case .archLoad:
            // Mark where the one sensor is, so an unlit sole reads as
            // "not sensed", not "no load".
            let c = FootOutline.point(m: Self.archSite.m, v: Self.archSite.v, foot: foot, in: rect)
            let r = line * 3.2
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                       with: .color(.white.opacity(0.85)), style: StrokeStyle(lineWidth: line * 1.2, dash: [line * 1.6, line * 1.2]))
        case .field(_, let cop?, let progress):
            let points = cop.map { FootOutline.point(m: $0.x, v: $0.y, foot: foot, in: rect) }
            var trace = Path()
            for (i, p) in points.enumerated() { if i == 0 { trace.move(to: p) } else { trace.addLine(to: p) } }
            ctx.stroke(trace, with: .color(.white.opacity(0.9)), style: StrokeStyle(lineWidth: line * 1.4, lineCap: .round, lineJoin: .round))
            if let progress, progress <= 1, points.count > 1 {
                let f = progress * Double(points.count - 1)
                let i = min(points.count - 2, Int(f)), r = f - Double(i)
                let q = CGPoint(x: points[i].x + (points[i + 1].x - points[i].x) * r, y: points[i].y + (points[i + 1].y - points[i].y) * r)
                let d = line * 3.6
                let dot = Path(ellipseIn: CGRect(x: q.x - d, y: q.y - d, width: d * 2, height: d * 2))
                ctx.fill(dot, with: .color(.white))
                ctx.stroke(dot, with: .color(.black), lineWidth: line * 1.4)
            }
        default:
            break
        }
    }
}

// MARK: - Legend

/// The vertical colour key beside the maps: top and bottom labels.
struct FootScaleLegend: View {
    let colors: [Color]
    let top: String
    let bottom: String
    var height: CGFloat = 180

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Text(top)
            Capsule()
                .fill(LinearGradient(colors: colors, startPoint: .bottom, endPoint: .top))
                .frame(width: 6, height: height)
            Text(bottom)
        }
        .font(ThermyxFont.monoSmall)
        .foregroundStyle(Thermyx.Ink.textMuted)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Colour scale from \(bottom) to \(top)")
    }
}
