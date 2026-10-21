import Foundation

/// A month of believable history for demos and previews, built by running
/// `DemoWearer` minute by minute through the same buckets and risk engine
/// the live app uses. Time worn, heating and cooling, steps, sitting,
/// standing and walking are all credited the way real readings would be, so
/// every Insights card has something true-to-life to show.
///
/// It only ever exists in memory while the demo runs (see
/// `ThermyxHistoryStore.enterDemo`), and only admin accounts and debug
/// previews can start the demo. It is never saved over real history.
enum ThermyxDemoHistory {
    struct Result {
        var minutes: [ThermyxHistorySample]
        var hours: [ThermyxHistorySample]
        var events: [ThermyxRiskEvent]
        /// Each foot's last reading, for the live insoles to carry on from.
        var last: [Foot: ThermyxReading]
        /// When today's shift began, for the live insoles' activity cycle.
        var shiftStart: Date
        /// How hot today is (0…1), for the live insoles' air temperature.
        var todayHeat: Double
        /// The last hour of each insole's charge, so time left can be
        /// estimated from the moment the demo opens.
        var batteryTrail: [Foot: [ThermyxReading]] = [:]
    }

    /// Days off, counted back from today, so the streak reads 7 and the
    /// weekly report has a previous week to compare against.
    private static let daysOff: Set<Int> = [7, 8, 13, 14, 20, 21, 27, 28]

    /// How hot each day was, 0…1, warmest over the last few days.
    static func heat(daysAgo: Int) -> Double {
        let base = 0.45 + 0.28 * sin(Double(daysAgo) * 1.3) + (daysAgo < 3 ? 0.2 : 0)
        return min(max(base, 0.1), 1)
    }

    static func make(now: Date = .now, feet: [Foot], targetC: Double, zones: Bool,
                     days: Int = 30, calendar: Calendar = .current) -> Result {
        var minuteBuckets: [String: ThermyxHistorySample] = [:]
        var hourBuckets: [String: ThermyxHistorySample] = [:]
        var events: [ThermyxRiskEvent] = []
        var last: [Foot: ThermyxReading] = [:]
        var trail: [Foot: [ThermyxReading]] = [:]

        let todayShiftMinutes = 480
        let todayStart = now.addingTimeInterval(-Double(todayShiftMinutes) * 60)
        let todayHeat = 0.8

        for daysAgo in stride(from: days - 1, through: 0, by: -1) where !daysOff.contains(daysAgo) {
            let isToday = daysAgo == 0
            let start: Date
            let shiftMinutes: Int
            if isToday {
                start = Date(timeIntervalSince1970: (todayStart.timeIntervalSince1970 / 60).rounded(.down) * 60)
                shiftMinutes = todayShiftMinutes
            } else {
                let day = calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: now)) ?? now
                start = calendar.date(bySettingHour: 7, minute: 0, second: 0, of: day) ?? day
                shiftMinutes = 510
            }
            let heat = isToday ? todayHeat : heat(daysAgo: daysAgo)

            var contact: [Foot: Double] = [:]
            var active: [Foot: ThermalMode] = [:]
            var battery: [Foot: Double] = [:]
            var gait: [Foot: Double] = [:]
            var open: [Foot: ThermyxRiskEvent] = [:]
            for foot in feet {
                let natural = DemoWearer.naturalContactC(ambientC: DemoWearer.ambientC(progress: 0, heat: heat),
                                                          activity: .walking, foot: foot)
                contact[foot] = natural - 0.8
                active[foot] = .ventilation
                battery[foot] = foot == .left ? 100 : 97
                gait[foot] = 0.92
            }

            for minute in 0..<shiftMinutes {
                let progress = Double(minute) / Double(shiftMinutes)
                let activity = DemoWearer.activity(minute: minute, shiftMinutes: shiftMinutes)
                let ambient = DemoWearer.ambientC(progress: progress, heat: heat)
                let minuteStart = start.addingTimeInterval(Double(minute) * 60)
                if isToday, minuteStart >= now { break }

                for foot in feet {
                    let natural = DemoWearer.naturalContactC(ambientC: ambient, activity: activity, foot: foot, fatigue: progress)
                    for step in 0..<6 {
                        let seconds = Double(minute * 60 + step * 10)
                        var mode = DemoWearer.autoDecision(contactC: contact[foot]!, targetC: targetC, previous: active[foot]!)
                        if mode == .heating, contact[foot]! >= ThermyxRiskEngine.burnLimitC { mode = .ventilation }
                        active[foot] = mode
                        let settle = DemoWearer.settlingC(natural: natural, active: mode)
                        contact[foot]! += (settle - contact[foot]!) * 0.25
                        battery[foot] = max(4, battery[foot]! - DemoWearer.drainPerMinute(mode) / 6)
                        if activity == .walking {
                            gait[foot] = DemoWearer.steadiness(progress: progress, heat: heat, seconds: seconds)
                                - (foot == .right ? 0.01 : 0)
                        }

                        let c = contact[foot]!
                        var reading = ThermyxReading(
                            foot: foot,
                            timestamp: minuteStart.addingTimeInterval(Double(step) * 10),
                            footTemperatureC: c,
                            ambientTemperatureC: ambient,
                            pressureBalance: DemoWearer.archLoad(activity, seconds: seconds, foot: foot),
                            gaitStability: gait[foot],
                            batteryPercent: Int(battery[foot]!.rounded()),
                            thermalMode: mode,
                            zones: zones ? FootZoneTemperatures(forefootC: c + 1.3, archC: c + 0.6, heelC: c - 1.9) : nil,
                            cadenceStepsPerMinute: DemoWearer.cadence(activity, minute: Double(minute)),
                            standingFraction: DemoWearer.standingFraction(activity)
                        )
                        reading.loadIsArchLevel = !zones
                        reading.footDetected = true
                        let assessment = ThermyxRiskEngine.assess(reading)
                        let risk: ThermyxRiskLevel? = assessment.level == .unavailable ? nil : assessment.level
                        let elapsed: TimeInterval = (minute == 0 && step == 0) ? 0 : 10

                        // Minute buckets are kept a week, like the live store's.
                        if daysAgo < 7 {
                            accumulate(reading, risk: risk, elapsed: elapsed, granularity: 60, into: &minuteBuckets)
                        }
                        accumulate(reading, risk: risk, elapsed: elapsed, granularity: 3600, into: &hourBuckets)

                        if step == 0 {
                            track(assessment, reading: reading, open: &open, events: &events)
                        }
                        if isToday {
                            last[foot] = reading
                            if step == 0, now.timeIntervalSince(reading.timestamp) <= 3600 { trail[foot, default: []].append(reading) }
                        }
                    }
                }
            }
            // Close what's still open: the shift ended, or (today) the live
            // store takes over and opens its own events from here.
            let end = isToday ? now : start.addingTimeInterval(Double(shiftMinutes) * 60)
            for (_, var event) in open {
                event.endedAt = end
                replace(event, in: &events)
            }
        }

        return Result(
            minutes: minuteBuckets.values.sorted { ($0.start, $0.foot.rawValue) < ($1.start, $1.foot.rawValue) },
            hours: hourBuckets.values.sorted { ($0.start, $0.foot.rawValue) < ($1.start, $1.foot.rawValue) },
            events: events.sorted { $0.timestamp < $1.timestamp },
            last: last,
            shiftStart: todayStart,
            todayHeat: todayHeat,
            batteryTrail: trail
        )
    }

    private static func accumulate(_ reading: ThermyxReading, risk: ThermyxRiskLevel?, elapsed: TimeInterval,
                                   granularity: TimeInterval, into buckets: inout [String: ThermyxHistorySample]) {
        let start = Date(timeIntervalSince1970: (reading.timestamp.timeIntervalSince1970 / granularity).rounded(.down) * granularity)
        let key = "\(reading.foot.rawValue)-\(start.timeIntervalSince1970)"
        var sample = buckets[key] ?? ThermyxHistorySample(foot: reading.foot, start: start)
        sample.accumulate(reading, risk: risk, elapsed: elapsed)
        buckets[key] = sample
    }

    /// Opens an event when the level rises above Normal and closes it when
    /// it changes or returns, as the live store does.
    private static func track(_ assessment: ThermyxRiskAssessment, reading: ThermyxReading,
                              open: inout [Foot: ThermyxRiskEvent], events: inout [ThermyxRiskEvent]) {
        let foot = reading.foot
        let level = assessment.level
        guard level != .unavailable else { return }
        if let current = open[foot], current.riskLevel == level { return }
        if var previous = open[foot] {
            previous.endedAt = reading.timestamp
            replace(previous, in: &events)
            open[foot] = nil
        }
        guard level != .normal else { return }
        let event = ThermyxRiskEvent(foot: foot, timestamp: reading.timestamp, level: level,
                                     reasons: assessment.reasons, footTemperatureC: reading.footTemperatureC)
        open[foot] = event
        events.append(event)
    }

    private static func replace(_ event: ThermyxRiskEvent, in events: inout [ThermyxRiskEvent]) {
        if let index = events.firstIndex(where: { $0.id == event.id }) { events[index] = event }
    }
}
