import SwiftUI

/// One sole, drawn with whatever that foot is actually reporting.
///
/// Every overlay is positioned through `SoleGeometry`, so a heat bloom or a
/// sensor dot is written once in anatomical coordinates and lands correctly on
/// either foot without a second set of numbers.
struct SoleView: View {
    let foot: Foot
    /// Nil means this foot is not reporting: the sole draws as a dashed
    /// outline rather than an empty filled one, so "no data" never reads as
    /// "cold".
    let reading: ThermyxReading?
    let unit: TemperatureUnit
    var showsSensorSites = false
    /// A connected test board with no foot temperature: drawn solid, like a
    /// live sole, but with no heat, so nothing implies a reading it lacks.
    var isActive = false
    /// A zone being pressed (FSR on the test board), 0…1 strength. Drawn in
    /// ice, never in the temperature colours.
    var pressedZone: FootZone?
    var pressStrength: Double = 0

    private var zones: FootZoneTemperatures? { reading?.zones }
    private var averageC: Double? { reading?.footTemperatureC }
    private var isLive: Bool { reading != nil && averageC != nil }

    var body: some View {
        GeometryReader { proxy in
            let rect = CGRect(origin: .zero, size: proxy.size)

            ZStack {
                if isLive {
                    SoleShape(foot: foot)
                        .fill(Thermyx.Ink.deck)

                    blooms(in: rect)
                        .mask { SoleShape(foot: foot).fill(.black) }

                    if showsSensorSites { sensorSites(in: rect) }

                    SoleShape(foot: foot)
                        .stroke(
                            LinearGradient(
                                colors: [Thermyx.Ink.ember, Thermyx.Ink.signal, Thermyx.Ink.ice],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            style: StrokeStyle(lineWidth: 2.4)
                        )
                } else if isActive {
                    SoleShape(foot: foot)
                        .fill(Thermyx.Ink.deck)

                    if let pressedZone, pressStrength > 0 {
                        bloom(
                            tint: Thermyx.Ink.ice,
                            centre: SoleGeometry.zoneCentre(pressedZone),
                            radius: SoleGeometry.zoneRadius(pressedZone),
                            intensity: 0.35 + 0.5 * min(max(pressStrength, 0), 1),
                            in: rect
                        )
                        .mask { SoleShape(foot: foot).fill(.black) }
                    }

                    SoleShape(foot: foot)
                        .stroke(
                            LinearGradient(
                                colors: [Thermyx.Ink.ember, Thermyx.Ink.signal, Thermyx.Ink.ice],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            style: StrokeStyle(lineWidth: 2.4)
                        )
                } else {
                    SoleShape(foot: foot)
                        .stroke(
                            Thermyx.Ink.textSupporting.opacity(0.45),
                            style: StrokeStyle(lineWidth: 2.2, dash: [9, 7])
                        )
                }
            }
        }
        .aspectRatio(SoleShape.widthRatio, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(foot.label) insole")
        .accessibilityValue(accessibilitySummary)
    }

    // MARK: - Heat

    @ViewBuilder
    private func blooms(in rect: CGRect) -> some View {
        if let zones {
            ForEach(FootZone.allCases) { zone in
                bloom(
                    tint: ThermyxTemperatureScale.tint(for: zones[zone]),
                    centre: SoleGeometry.zoneCentre(zone),
                    radius: SoleGeometry.zoneRadius(zone),
                    // The arch sits between two stronger zones; at full
                    // strength all three merge into one smear.
                    intensity: zone == .arch ? 0.5 : 0.8,
                    in: rect
                )
            }
        } else if let averageC {
            // One sensor, one bloom. Nothing here implies a gradient the
            // hardware did not measure.
            bloom(
                tint: ThermyxTemperatureScale.tint(for: averageC),
                centre: CGPoint(x: 0.01, y: 0.5),
                radius: 0.34,
                intensity: 0.55,
                in: rect
            )
        }
    }

    private func bloom(tint: Color, centre: CGPoint, radius: CGFloat, intensity: Double, in rect: CGRect) -> some View {
        // Sole space is a fraction of foot length, and the frame's height is
        // the foot length, so a radius converts by height alone.
        let diameter = radius * 2 * rect.height
        let position = SoleGeometry.point(x: centre.x, y: centre.y, foot: foot, in: rect)
        return Circle()
            .fill(
                RadialGradient(
                    stops: [
                        .init(color: tint.opacity(intensity), location: 0),
                        .init(color: tint.opacity(intensity * 0.5), location: 0.45),
                        .init(color: tint.opacity(0), location: 1)
                    ],
                    center: .center,
                    startRadius: 0,
                    endRadius: diameter / 2
                )
            )
            .frame(width: diameter, height: diameter)
            .blur(radius: diameter * 0.05)
            .position(position)
    }

    // MARK: - Sensors

    private func sensorSites(in rect: CGRect) -> some View {
        ForEach(SoleGeometry.SensorSite.allCases) { site in
            Circle()
                .strokeBorder(Thermyx.Ink.textPrimary.opacity(0.35), lineWidth: 1)
                .background(Circle().fill(Thermyx.Ink.midnight.opacity(0.35)))
                .frame(width: rect.height * 0.045, height: rect.height * 0.045)
                .position(SoleGeometry.point(x: site.position.x, y: site.position.y, foot: foot, in: rect))
        }
        .accessibilityHidden(true)
    }

    private var accessibilitySummary: String {
        if reading == nil, isActive {
            return pressedZone != nil && pressStrength > 0
                ? "Test board connected, \(pressedZone!.label.lowercased()) pressed"
                : "Test board connected"
        }
        guard let reading else { return "Not connected" }
        if let zones {
            return FootZone.allCases
                .map { "\($0.label) \(TemperatureFormat.full(zones[$0], in: unit))" }
                .joined(separator: ", ")
        }
        guard let value = reading.footTemperatureC else { return "No reading" }
        return TemperatureFormat.full(value, in: unit)
    }
}

// MARK: - Zone readouts

/// The temperature labels beside a sole. Laid out on the lateral side of each
/// foot so the pair's labels sit on the outside and the soles stay adjacent.
struct SoleZoneReadouts: View {
    let foot: Foot
    let reading: ThermyxReading?
    let unit: TemperatureUnit

    private var zones: FootZoneTemperatures? { reading?.zones }

    var body: some View {
        VStack(alignment: foot == .left ? .trailing : .leading, spacing: Thermyx.Space.xl) {
            if let zones {
                // Top to bottom, matching the sole beside them: the toe is at
                // the top of the graphic, so the forefoot reading is too.
                ForEach(FootZone.allCases) { zone in
                    readout(zone.label, value: TemperatureFormat.degrees(zones[zone], in: unit),
                            tint: ThermyxTemperatureScale.tint(for: zones[zone]))
                }
            } else if let value = reading?.footTemperatureC {
                readout("Foot", value: TemperatureFormat.degrees(value, in: unit),
                        tint: ThermyxTemperatureScale.tint(for: value))
            }
        }
    }

    private func readout(_ label: String, value: String, tint: Color) -> some View {
        VStack(alignment: foot == .left ? .trailing : .leading, spacing: 0) {
            Text(label)
                .narrowLabel(ThermyxFont.axisLabel, tracking: ThermyxTracking.axisLabel, color: Thermyx.Ink.textSupporting)
            Text(value)
                .font(ThermyxFont.metricNumeralCompact)
                .tracking(ThermyxTracking.metricNumeral)
                .monospacedDigit()
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .accessibilityElement(children: .combine)
    }
}
