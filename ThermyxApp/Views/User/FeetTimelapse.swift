import SwiftUI

/// One moment in the feet timelapse: each foot's temperature, arch load and
/// steadiness, averaged over a short window of worn time.
struct FeetFrame: Identifiable, Equatable {
    let start: Date
    var temperatureC: [Foot: Double] = [:]
    var zones: [Foot: FootZoneTemperatures] = [:]
    var load: [Foot: Double] = [:]
    var steadiness: [Foot: Double] = [:]
    var id: Date { start }
}

extension InsightsRange {
    /// How much worn time one timelapse frame covers.
    var timelapseWindow: TimeInterval {
        switch self {
        case .day: return 10 * 60
        case .week: return 3600
        case .month: return 86_400
        }
    }
}

extension BilateralDigest {
    /// The feet through the window, a frame per stretch of worn time. Time
    /// the insoles weren't worn has no frame, so the timelapse skips it
    /// rather than showing empty feet.
    func timelapse(for filter: FootFilter, calendar: Calendar = .current) -> [FeetFrame] {
        let window = range.timelapseWindow
        func key(_ date: Date) -> Date {
            if range == .month { return calendar.startOfDay(for: date) }
            return Date(timeIntervalSince1970: (date.timeIntervalSince1970 / window).rounded(.down) * window)
        }
        var frames: [Date: FeetFrame] = [:]
        for (foot, digest) in digests(for: filter) {
            let groups = Dictionary(grouping: digest.samples, by: { key($0.start) })
            for (start, group) in groups {
                func mean(_ value: (ThermyxHistorySample) -> Double?) -> Double? {
                    let values = group.compactMap(value)
                    return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
                }
                var frame = frames[start] ?? FeetFrame(start: start)
                frame.temperatureC[foot] = mean(\.footMeanC)
                frame.load[foot] = mean(\.balanceMean)
                frame.steadiness[foot] = mean(\.gaitMean)
                if let f = mean(\.forefootMeanC), let a = mean(\.archMeanC), let h = mean(\.heelMeanC) {
                    frame.zones[foot] = FootZoneTemperatures(forefootC: f, archC: a, heelC: h)
                }
                frames[start] = frame
            }
        }
        return frames.values
            .filter { !$0.temperatureC.isEmpty || !$0.load.isEmpty || !$0.steadiness.isEmpty }
            .sorted { $0.start < $1.start }
    }
}

/// The feet over the chosen day, week or month: temperature, pressure and
/// gait side by side, playing through the worn time like a timelapse. Each
/// foot shows the same honest single values as Home (one temperature, the
/// arch sensor, steadiness) — the trend, not new detail.
struct FeetTimelapse: View {
    let frames: [FeetFrame]
    let feet: [Foot]
    let range: InsightsRange
    let unit: TemperatureUnit

    @State private var position: Double = 0
    @State private var playing = false
    @State private var player: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var index: Int { min(max(Int(position.rounded()), 0), max(frames.count - 1, 0)) }
    private var frame: FeetFrame? { frames.isEmpty ? nil : frames[index] }

    var body: some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.header) {
            SectionLabel("Your feet over time") {
                Text(frame.map(timeLabel) ?? "—")
                    .monospacedDigit()
                    .foregroundStyle(Thermyx.Ink.textMuted)
                    .contentTransition(.numericText())
            }
            HStack(alignment: .top, spacing: 0) {
                group(.temperature)
                Spacer(minLength: Thermyx.Space.xs)
                group(.pressure)
                Spacer(minLength: Thermyx.Space.xs)
                group(.gait)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Your feet at \(frame.map(timeLabel) ?? "no time")")
            .accessibilityValue(accessibilityValue)
            controls
            Text(caption)
                .font(ThermyxFont.captionSmall)
                .foregroundStyle(Thermyx.Ink.textFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { restart() }
        .onDisappear { stop() }
        .onChange(of: frames.first?.start) { _, _ in restart() }
        .onChange(of: frames.count) { old, new in
            // Live data: a timelapse resting on the latest frame follows it.
            if !playing, index >= old - 1 { position = Double(max(new - 1, 0)) }
        }
    }

    // MARK: Feet

    private func group(_ kind: HomeMap) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                ForEach(feet) { foot in
                    FootMap(foot: foot, content: content(kind, foot))
                        .frame(width: feet.count == 1 ? 46 : 38, height: 92)
                }
            }
            Text(kind.label)
                .font(ThermyxFont.captionSmall)
                .foregroundStyle(Thermyx.Ink.textMuted)
            Text(value(kind))
                .font(ThermyxFont.monoCaption)
                .monospacedDigit()
                .foregroundStyle(valueTint(kind))
                .contentTransition(.numericText())
        }
        .frame(minWidth: 96)
    }

    private func content(_ kind: HomeMap, _ foot: Foot) -> FootMap.Content {
        guard let frame else { return .outline(dimmed: true) }
        switch kind {
        case .temperature:
            if let zones = frame.zones[foot] { return .zones(zones) }
            return frame.temperatureC[foot].map { .temperature($0) } ?? .outline(dimmed: true)
        case .pressure:
            // Three-zone boards report the forefoot's share; today's insoles
            // report the one arch sensor.
            return frame.zones[foot] != nil ? .forefootShare(frame.load[foot]) : .archLoad(frame.load[foot])
        case .gait:
            return .steadiness(frame.steadiness[foot])
        }
    }

    private func value(_ kind: HomeMap) -> String {
        guard let frame else { return "—" }
        switch kind {
        case .temperature:
            return frame.temperatureC.values.max().map { TemperatureFormat.degrees($0, in: unit) } ?? "—"
        case .pressure:
            let loads = Array(frame.load.values)
            return loads.isEmpty ? "—" : "\(Int((loads.reduce(0, +) / Double(loads.count) * 100).rounded()))%"
        case .gait:
            return frame.steadiness.values.min().map { "\(Int(($0 * 100).rounded()))%" } ?? "—"
        }
    }

    private func valueTint(_ kind: HomeMap) -> Color {
        guard let frame else { return Thermyx.Ink.textFaint }
        switch kind {
        case .temperature: return frame.temperatureC.values.max().map(FootScale.thermalColor) ?? Thermyx.Ink.textFaint
        case .pressure:
            let loads = Array(frame.load.values)
            return loads.isEmpty ? Thermyx.Ink.textFaint : FootScale.loadColor(loads.reduce(0, +) / Double(loads.count))
        case .gait: return frame.steadiness.values.min().map { ChartValueScale.steadiness.color(at: $0 * 100) } ?? Thermyx.Ink.textFaint
        }
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: Thermyx.Space.m) {
            Button {
                playing ? stop() : play(fromStart: index >= frames.count - 1)
            } label: {
                Image(systemName: playing ? "pause.fill" : (index >= frames.count - 1 ? "arrow.counterclockwise" : "play.fill"))
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Thermyx.Ink.onPrimary)
                    .frame(width: 40, height: 40)
                    .background(Thermyx.Ink.textPrimary, in: Circle())
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(PressableStyle())
            .frame(minWidth: Thermyx.minimumTapTarget, minHeight: Thermyx.minimumTapTarget)
            .disabled(frames.count < 2)
            .accessibilityLabel(playing ? "Pause" : "Play the timelapse")

            if frames.count >= 2 {
                Slider(value: Binding(get: { position }, set: { stop(); position = $0 }),
                       in: 0...Double(frames.count - 1), step: 1)
                    .tint(Thermyx.Ink.ice)
                    .accessibilityLabel("Time")
                    .accessibilityValue(frame.map(timeLabel) ?? "")
            } else {
                Text("Wear the insoles a while longer to see the trend.")
                    .font(ThermyxFont.captionSmall)
                    .foregroundStyle(Thermyx.Ink.textFaint)
            }
        }
    }

    // MARK: Playback

    /// Plays once from the start (unless Reduce Motion is on, which leaves
    /// it on the latest frame for the wearer to scrub).
    private func restart() {
        stop()
        position = Double(max(frames.count - 1, 0))
        guard !reduceMotion, frames.count >= 2 else { return }
        play(fromStart: true)
    }

    private func play(fromStart: Bool) {
        guard frames.count >= 2 else { return }
        stop()
        if fromStart { position = 0 }
        playing = true
        // About seven seconds for the whole window, whatever its length.
        let step = min(0.35, max(0.06, 7.0 / Double(frames.count)))
        player = Task { @MainActor in
            while !Task.isCancelled, index < frames.count - 1 {
                try? await Task.sleep(for: .seconds(step))
                guard !Task.isCancelled else { return }
                position = Double(index + 1)
            }
            playing = false
        }
    }

    private func stop() {
        player?.cancel()
        player = nil
        playing = false
    }

    // MARK: Words

    private func timeLabel(_ frame: FeetFrame) -> String {
        switch range {
        case .day: return frame.start.formatted(.dateTime.hour().minute())
        case .week: return frame.start.formatted(.dateTime.weekday(.abbreviated).hour())
        case .month: return frame.start.formatted(.dateTime.month(.abbreviated).day())
        }
    }

    private var caption: String {
        let every: String = switch range {
        case .day: "every 10 minutes"
        case .week: "every hour"
        case .month: "every day"
        }
        return "Trends only: each foot's one temperature, arch sensor and steadiness, averaged \(every) of wear."
    }

    private var accessibilityValue: String {
        ["Temperature \(value(.temperature))", "pressure \(value(.pressure))", "steadiness \(value(.gait))"].joined(separator: ", ")
    }
}
