import Foundation

/// Retains enough telemetry for the day, week, and month ranges on Insights.
///
/// Nothing was retained before this; charts had no history to draw. Readings
/// fold into minute buckets (kept a week) and hour buckets (kept six months),
/// which keeps the whole store to a few hundred kilobytes and avoids pulling
/// SwiftData into the build for what is a flat append-only series.
///
/// Storage is a single JSON file in Application Support. Writes are debounced
/// and run off the main actor.
@MainActor
final class ThermyxHistoryStore: ObservableObject {

    @Published private(set) var minuteSamples: [ThermyxHistorySample] = []
    @Published private(set) var hourSamples: [ThermyxHistorySample] = []
    @Published private(set) var events: [ThermyxRiskEvent] = []
    /// Per-minute history of the single-sensor test board, in each sensor's
    /// own units. Kept apart from the body samples: it never feeds risk,
    /// trends, alerts, or Apple Health.
    @Published private(set) var sensorMinutes: [SensorMinute] = []

    private static let minuteRetention: TimeInterval = 7 * 24 * 3600
    private static let hourRetention: TimeInterval = 180 * 24 * 3600
    private static let eventRetention: TimeInterval = 30 * 24 * 3600

    private var openEvent: [Foot: ThermyxRiskEvent] = [:]
    /// Each foot's previous reading time, for crediting elapsed time.
    private var lastReadingAt: [Foot: Date] = [:]
    /// A gap longer than this is a disconnection, not time worn.
    static let maxCreditedGap: TimeInterval = 5
    private var saveTask: Task<Void, Never>?
    private var isLoaded = false
    private var lastPrune: Date = .distantPast

    private struct Archive: Codable {
        var minuteSamples: [ThermyxHistorySample]
        var hourSamples: [ThermyxHistorySample]
        var events: [ThermyxRiskEvent]
        /// Optional so archives written before the test board still load.
        var sensorMinutes: [SensorMinute]?
    }

    private static var fileURL: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL.temporaryDirectory
        let directory = base.appendingPathComponent("Thermyx", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("history.json")
    }

    // MARK: - Lifecycle

    func loadIfNeeded() async {
        guard !isLoaded else { return }
        isLoaded = true
        let url = Self.fileURL
        let archive: Archive? = await Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(Archive.self, from: data)
        }.value
        guard let archive else { return }
        minuteSamples = archive.minuteSamples
        hourSamples = archive.hourSamples
        events = archive.events
        sensorMinutes = archive.sensorMinutes ?? []
        prune()
    }

    // MARK: - Recording

    /// Fold a live reading into the current minute and hour buckets.
    func record(_ reading: ThermyxReading, assessment: ThermyxRiskAssessment) {
        guard reading.hasSensorData else { return }
        let risk: ThermyxRiskLevel? = assessment.level == .unavailable ? nil : assessment.level
        let gap = lastReadingAt[reading.foot].map { reading.timestamp.timeIntervalSince($0) } ?? 0
        let elapsed = gap > 0 && gap <= Self.maxCreditedGap ? gap : 0
        lastReadingAt[reading.foot] = reading.timestamp

        append(reading, risk: risk, elapsed: elapsed, into: &minuteSamples, granularity: 60)
        append(reading, risk: risk, elapsed: elapsed, into: &hourSamples, granularity: 3600)
        trackEvent(assessment, reading: reading)
        // Telemetry arrives several times a second; sweeping three arrays on
        // every packet is wasted work when the retention windows are days
        // long. Once a minute is far more often than anything can expire.
        if Date.now.timeIntervalSince(lastPrune) > 60 { prune() }
        scheduleSave()
    }

    private func append(
        _ reading: ThermyxReading,
        risk: ThermyxRiskLevel?,
        elapsed: TimeInterval,
        into samples: inout [ThermyxHistorySample],
        granularity: TimeInterval
    ) {
        let bucketStart = Date(
            timeIntervalSince1970: (reading.timestamp.timeIntervalSince1970 / granularity).rounded(.down) * granularity
        )
        // Two insoles interleave, so the matching bucket is not necessarily the
        // last one — find this foot's bucket for this interval.
        if let index = samples.lastIndex(where: { $0.foot == reading.foot && $0.start == bucketStart }) {
            samples[index].accumulate(reading, risk: risk, elapsed: elapsed)
        } else {
            var sample = ThermyxHistorySample(foot: reading.foot, start: bucketStart)
            sample.accumulate(reading, risk: risk, elapsed: elapsed)
            samples.append(sample)
        }
    }

    /// Opens an event when risk rises above normal and closes it when it
    /// returns, so the temperature detail can say how long a state was held.
    private func trackEvent(_ assessment: ThermyxRiskAssessment, reading: ThermyxReading) {
        let level = assessment.level
        let foot = reading.foot
        guard level != .unavailable else { return }

        if level == .normal {
            if var open = openEvent[foot] {
                open.endedAt = reading.timestamp
                replaceOrAppend(open)
                openEvent[foot] = nil
            }
            return
        }

        if let open = openEvent[foot], open.riskLevel == level {
            return // same state continuing
        }

        if var previous = openEvent[foot] {
            previous.endedAt = reading.timestamp
            replaceOrAppend(previous)
        }
        let event = ThermyxRiskEvent(
            foot: foot,
            timestamp: reading.timestamp,
            level: level,
            reasons: assessment.reasons,
            footTemperatureC: reading.footTemperatureC
        )
        openEvent[foot] = event
        events.append(event)
    }

    private func replaceOrAppend(_ event: ThermyxRiskEvent) {
        if let index = events.firstIndex(where: { $0.id == event.id }) {
            events[index] = event
        } else {
            events.append(event)
        }
    }

    /// Folds one test-board value into its minute bucket. `key` is
    /// `TYPE#CHANNEL`; `value` is already in the sensor's units.
    func recordSensor(key: String, value: Double, at time: Date = .now) {
        guard value.isFinite else { return }
        let start = Date(timeIntervalSince1970: (time.timeIntervalSince1970 / 60).rounded(.down) * 60)
        if let index = sensorMinutes.lastIndex(where: { $0.key == key && $0.start == start }) {
            sensorMinutes[index].add(value)
        } else {
            var minute = SensorMinute(key: key, start: start)
            minute.add(value)
            sensorMinutes.append(minute)
        }
        if Date.now.timeIntervalSince(lastPrune) > 60 { prune() }
        scheduleSave()
    }

    /// One sensor's minutes, oldest first, newest `limit`.
    func sensorHistory(key: String, limit: Int = 60) -> [SensorMinute] {
        Array(sensorMinutes.filter { $0.key == key }.suffix(limit))
    }

    // MARK: - Reading

    func samples(
        for range: InsightsRange,
        style: InsightsPeriodStyle = .standard,
        foot: Foot? = nil,
        now: Date = .now
    ) -> [ThermyxHistorySample] {
        let window = range.window(style: style, now: now)
        let source = range.usesHourlyTier ? hourSamples : minuteSamples
        return source.filter { sample in
            sample.start >= window.start && sample.start <= window.end
                && (foot == nil || sample.foot == foot)
        }
    }

    /// Which feet have retained history in this window.
    func feetWithHistory(
        for range: InsightsRange,
        style: InsightsPeriodStyle = .standard,
        now: Date = .now
    ) -> [Foot] {
        let all = samples(for: range, style: style, now: now)
        return Foot.allCases.filter { foot in all.contains { $0.foot == foot } }
    }

    func events(
        for range: InsightsRange,
        style: InsightsPeriodStyle = .standard,
        foot: Foot? = nil,
        now: Date = .now
    ) -> [ThermyxRiskEvent] {
        let window = range.window(style: style, now: now)
        return events
            .filter { event in
                event.timestamp >= window.start && event.timestamp <= window.end
                    && (foot == nil || event.foot == foot)
            }
            .sorted { $0.timestamp > $1.timestamp }
    }

    struct Trend: Equatable {
        /// Signed change in °C over the window.
        let delta: Double
        var isRising: Bool { delta >= 0 }
    }

    /// Change in foot temperature across a window, for the Home delta chip.
    /// Returns nil until there is a bucket old enough to compare against —
    /// the chip says "building trend" rather than showing a made-up arrow.
    func footTrend(over window: TimeInterval, current: Double?, foot: Foot? = nil, now: Date = .now) -> Trend? {
        guard let current else { return nil }
        let cutoff = now.addingTimeInterval(-window)
        // The oldest bucket at or before the cutoff, so the comparison spans
        // the full window rather than whatever happens to be retained. With
        // two insoles the baseline averages whichever feet were reporting.
        let candidates = minuteSamples.filter { $0.start <= cutoff && (foot == nil || $0.foot == foot) }
        guard let last = candidates.last?.start else { return nil }
        let atCutoff = candidates.filter { $0.start == last }.compactMap(\.footMeanC)
        guard !atCutoff.isEmpty else { return nil }
        let baseline = atCutoff.reduce(0, +) / Double(atCutoff.count)
        return Trend(delta: current - baseline)
    }

    /// True once there is enough history to draw a chart that means anything.
    /// Below this the Insights cards show their empty state instead of a line
    /// through two points.
    func hasEnoughHistory(
        for range: InsightsRange,
        style: InsightsPeriodStyle = .standard,
        foot: Foot? = nil,
        now: Date = .now
    ) -> Bool {
        samples(for: range, style: style, foot: foot, now: now).count >= 3
    }

    // MARK: - Maintenance

    func deleteAll() {
        minuteSamples.removeAll()
        hourSamples.removeAll()
        events.removeAll()
        sensorMinutes.removeAll()
        openEvent.removeAll()
        lastReadingAt.removeAll()
        scheduleSave()
    }

    private func prune() {
        let now = Date.now
        lastPrune = now
        minuteSamples.removeAll { $0.start < now.addingTimeInterval(-Self.minuteRetention) }
        hourSamples.removeAll { $0.start < now.addingTimeInterval(-Self.hourRetention) }
        events.removeAll { $0.timestamp < now.addingTimeInterval(-Self.eventRetention) }
        sensorMinutes.removeAll { $0.start < now.addingTimeInterval(-Self.minuteRetention) }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self else { return }
            await self.save()
        }
    }

    func save() async {
        let archive = Archive(
            minuteSamples: minuteSamples,
            hourSamples: hourSamples,
            events: events,
            sensorMinutes: sensorMinutes
        )
        let url = Self.fileURL
        await Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(archive) else { return }
            try? data.write(to: url, options: .atomic)
        }.value
    }
}
