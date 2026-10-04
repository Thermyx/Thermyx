import SwiftUI

/// Both insoles, side by side, medial edges facing each other — the way the
/// feet actually sit.
///
/// The layout adapts to what is connected rather than treating one insole as
/// a failure state:
///
/// - **Both connected**: equal soles, each with its own zone readouts.
/// - **One connected**: the live foot takes the space it needs to stay
///   readable, and the missing one shrinks to a tab at the screen edge. It
///   stays visible and stays tappable, so pairing the second insole is one
///   gesture away rather than buried in a settings screen.
/// - **Neither**: both sit at equal small size with a single pairing prompt,
///   because there is nothing to favour.
struct BilateralSoleView: View {
    @EnvironmentObject private var viewModel: ThermyxViewModel
    let unit: TemperatureUnit
    /// Called when the user asks to pair a specific foot.
    var onScan: (Foot) -> Void
    /// The slot a single-sensor test board occupies while no insole is
    /// connected. That sole draws active; the other stays dimmed.
    var boardFoot: Foot?
    /// The zone an FSR on the board is pressing, and how hard (0…1).
    var boardPressedZone: FootZone?
    var boardPressStrength: Double = 0

    private var connected: [Foot] { viewModel.connectedFeet }

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            sole(.left)
            sole(.right)
        }
        .frame(maxWidth: .infinity)
        .animation(.spring(response: 0.42, dampingFraction: 0.86), value: connected)
    }

    @ViewBuilder
    private func sole(_ foot: Foot) -> some View {
        if connected.isEmpty, let boardFoot {
            if foot == boardFoot {
                BoardSoleColumn(foot: foot, pressedZone: boardPressedZone, pressStrength: boardPressStrength)
                    .frame(maxWidth: .infinity)
            } else {
                DormantSoleColumn(foot: foot, isCompact: false) { onScan(foot) }
                    .opacity(0.45)
                    .frame(maxWidth: .infinity)
            }
        } else if viewModel.isConnected(foot) {
            LiveSoleColumn(foot: foot, reading: viewModel.reading[foot], unit: unit)
                .frame(maxWidth: .infinity)
        } else if connected.isEmpty {
            // Nothing connected: neither foot is more important, so both get
            // the same treatment and one prompt covers the pair.
            DormantSoleColumn(foot: foot, isCompact: false) { onScan(foot) }
                .frame(maxWidth: .infinity)
        } else {
            MinimisedSoleTab(foot: foot) { onScan(foot) }
        }
    }
}

// MARK: - Live

private struct LiveSoleColumn: View {
    let foot: Foot
    let reading: ThermyxReading?
    let unit: TemperatureUnit

    var body: some View {
        // Readouts sit on the lateral side so the two soles stay adjacent and
        // the labels fall on the outside of the pair.
        HStack(alignment: .center, spacing: Thermyx.Space.xs) {
            if foot == .left { SoleZoneReadouts(foot: foot, reading: reading, unit: unit) }
            VStack(spacing: 6) {
                SoleView(foot: foot, reading: reading, unit: unit)
                    .frame(maxHeight: 250)
                Text(foot.label)
                    .narrowLabel(ThermyxFont.axisLabel, tracking: ThermyxTracking.axisLabel, color: Thermyx.Ink.textSupporting)
            }
            if foot == .right { SoleZoneReadouts(foot: foot, reading: reading, unit: unit) }
        }
    }
}

// MARK: - Test board

/// The slot the single-sensor test board fills: a solid sole with no heat
/// drawn, since the board doesn't report foot temperature.
private struct BoardSoleColumn: View {
    let foot: Foot
    let pressedZone: FootZone?
    let pressStrength: Double

    var body: some View {
        VStack(spacing: 6) {
            SoleView(foot: foot, reading: nil, unit: .celsius, isActive: true,
                     pressedZone: pressedZone, pressStrength: pressStrength)
                .frame(maxHeight: 230)
            Text("Sensor")
                .narrowLabel(ThermyxFont.axisLabel, tracking: ThermyxTracking.axisLabel, color: Thermyx.Ink.textSupporting)
        }
    }
}

// MARK: - Dormant

private struct DormantSoleColumn: View {
    let foot: Foot
    let isCompact: Bool
    let onScan: () -> Void

    var body: some View {
        Button(action: onScan) {
            VStack(spacing: 6) {
                SoleView(foot: foot, reading: nil, unit: .celsius)
                    .frame(maxHeight: isCompact ? 150 : 230)
                Text(foot.label)
                    .narrowLabel(ThermyxFont.axisLabel, tracking: ThermyxTracking.axisLabel, color: Thermyx.Ink.textFaint)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(foot.label) insole, not connected")
        .accessibilityHint("Double tap to scan for it")
    }
}

// MARK: - Minimised

/// The unconnected foot when its partner is live: a slim tab pinned to the
/// screen margin.
///
/// It is deliberately still a sole and still labelled, not an icon — the point
/// is that the user can see at a glance which foot is missing. Tapping scans;
/// so does dragging it inward, which is the gesture people reach for when
/// something is tucked against an edge.
private struct MinimisedSoleTab: View {
    let foot: Foot
    let onScan: () -> Void

    @State private var drag: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Dragging the tab toward the centre of the screen triggers a scan.
    private var pullDirection: CGFloat { foot == .left ? 1 : -1 }

    var body: some View {
        Button(action: onScan) {
            VStack(spacing: 5) {
                SoleView(foot: foot, reading: nil, unit: .celsius)
                    .frame(height: 96)
                    .opacity(0.75)
                Text(foot.shortLabel)
                    .narrowLabel(ThermyxFont.axisLabel, tracking: ThermyxTracking.axisLabel, color: Thermyx.Ink.textFaint)
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Thermyx.Ink.ice)
            }
            .padding(.vertical, Thermyx.Space.m)
            .padding(.horizontal, Thermyx.Space.s)
            .frame(minWidth: 56, minHeight: Thermyx.minimumTapTarget)
            .background(
                Thermyx.Tint.neutralFill,
                in: UnevenRoundedRectangle(
                    topLeadingRadius: foot == .left ? 0 : Thermyx.Radius.compact,
                    bottomLeadingRadius: foot == .left ? 0 : Thermyx.Radius.compact,
                    bottomTrailingRadius: foot == .left ? Thermyx.Radius.compact : 0,
                    topTrailingRadius: foot == .left ? Thermyx.Radius.compact : 0,
                    style: .continuous
                )
            )
            .overlay(alignment: foot == .left ? .trailing : .leading) {
                Rectangle()
                    .fill(Thermyx.Tint.neutralBorder)
                    .frame(width: 1)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .offset(x: drag)
        .gesture(
            DragGesture(minimumDistance: 8)
                .onChanged { value in
                    // Only follow a pull toward the centre, and damp it so the
                    // tab reads as attached to the edge.
                    let travel = value.translation.width * pullDirection
                    drag = max(0, min(44, travel)) * pullDirection * (reduceMotion ? 0 : 1)
                }
                .onEnded { value in
                    let travel = value.translation.width * pullDirection
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { drag = 0 }
                    if travel > 28 { onScan() }
                }
        )
        // Pinned to the very edge: the tab is the screen margin, so it gives
        // back the gutter the live sole needs.
        .padding(foot == .left ? .leading : .trailing, -Thermyx.Space.screen)
        .accessibilityLabel("\(foot.label) insole, not connected")
        .accessibilityHint("Double tap to scan for it")
    }
}
