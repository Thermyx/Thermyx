import ActivityKit
import Foundation
import UIKit
import WidgetKit

/// Feeds the widgets, the Live Activity and the Dynamic Island from live
/// readings: the warmer foot's temperature, its rate of change (dT/dt), the
/// change over the last 10 minutes (∫ dT/dt dt), both as curves, plus the
/// risk level, the top concern and the thermal setting.
///
/// Home Screen and Lock Screen widgets read the snapshot from the App Group
/// and only redraw when iOS reloads them (often while the app is open,
/// rationed in the background). The Live Activity is updated directly, so
/// it stays live while the insoles are connected.
@MainActor
final class ThermyxWidgetBridge {
    var fahrenheit = false {
        didSet { if fahrenheit != oldValue { lastSaved = .distantPast } }
    }

    /// The last 10 minutes of the warmer foot, one point per reading.
    private var samples: [CalibrationSample] = []
    private var lastSaved = Date.distantPast
    private var lastReload = Date.distantPast
    private var lastSnapshot: ThermyxWidgetSnapshot?
    private var activity: Activity<ThermyxActivityAttributes>?
    private var endTask: Task<Void, Never>?

    private static let window: TimeInterval = 10 * 60
    private static let points = 30

    init() {
        // Pick up an activity left running by an earlier launch.
        activity = Activity<ThermyxActivityAttributes>.activities.first
    }

    func update(reading: BilateralReading, isDemo: Bool, setting: ThermalSetting, assessment: ThermyxRiskAssessment) {
        let now = Date.now
        let live = !reading.present.isEmpty
        if let c = reading.peakFootTemperatureC {
            samples.append(CalibrationSample(time: now, footC: c, ambientC: nil, load: nil, gait: nil, cadence: nil, standing: nil))
        }
        samples.removeAll { now.timeIntervalSince($0.time) > Self.window }

        let mode = Self.mode(setting)
        let level = live ? Self.level(assessment.level) : .waiting
        // A change people would notice goes out at once; otherwise every
        // few seconds is plenty.
        let significant = lastSnapshot.map { $0.live != live || $0.mode != mode || $0.level != level } ?? true
        guard significant || now.timeIntervalSince(lastSaved) >= 5 else { return }
        lastSaved = now

        let rates = ThermalCalculus.rateSeries(samples)
        var snapshot = ThermyxWidgetSnapshot(
            updated: now, live: live, isDemo: isDemo, fahrenheit: fahrenheit, mode: mode,
            footC: reading.peakFootTemperatureC ?? lastSnapshot?.footC,
            ratePerMinute: live ? ThermalCalculus.rate(samples) : nil,
            changeC: ThermalCalculus.accumulatedChange(samples),
            level: level,
            concern: level.isConcern ? assessment.reasons.first : nil,
            temps: [], rates: [],
            battery: reading.batteryPercent
        )
        if let start = samples.first?.time {
            snapshot.temps = Self.bucket(samples.compactMap { s in s.footC.map { (s.time.timeIntervalSince(start), $0) } })
            snapshot.rates = Self.bucket(rates.map { ($0.t, $0.perMinute) })
        }
        // A disconnect keeps the last curves on show, marked not live.
        if !live, let last = lastSnapshot {
            snapshot.temps = last.temps
            snapshot.rates = last.rates
            snapshot.changeC = last.changeC
        }
        lastSnapshot = snapshot
        snapshot.save()
        reloadWidgets(significant: significant)
        updateActivity(snapshot, significant: significant)
    }

    // MARK: Widgets

    private func reloadWidgets(significant: Bool) {
        // Reloads are free while the app is open; in the background iOS
        // rations them, so space them out.
        let active = UIApplication.shared.applicationState == .active
        let spacing: TimeInterval = active ? 30 : 10 * 60
        guard significant || Date.now.timeIntervalSince(lastReload) >= spacing else { return }
        lastReload = .now
        WidgetCenter.shared.reloadTimelines(ofKind: ThermyxShared.widgetKind)
    }

    // MARK: Live Activity

    private func updateActivity(_ snapshot: ThermyxWidgetSnapshot, significant: Bool) {
        let content = ActivityContent(state: snapshot, staleDate: snapshot.updated.addingTimeInterval(120),
                                      relevanceScore: snapshot.level.isConcern ? 100 : 50)
        if snapshot.live {
            endTask?.cancel()
            endTask = nil
            if let activity, activity.activityState == .active {
                Task { await activity.update(content) }
            } else if ActivityAuthorizationInfo().areActivitiesEnabled,
                      UIApplication.shared.applicationState != .background {
                // Live Activities can only start while the app is open.
                do {
                    activity = try Activity.request(attributes: ThermyxActivityAttributes(startedAt: .now),
                                                    content: content, pushType: nil)
                } catch {
                    print("Thermyx Live Activity didn't start: \(error)")
                }
            }
        } else if let activity, endTask == nil {
            Task { await activity.update(content) }
            // Give a dropped connection a minute to come back before ending.
            endTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled, let self, self.lastSnapshot?.live == false else { return }
                await activity.end(content, dismissalPolicy: .after(.now + 10 * 60))
                self.activity = nil
                self.endTask = nil
            }
        }
    }

    // MARK: Helpers

    /// Averages a series into `points` even slices of the window, dropping
    /// empty ones.
    private static func bucket(_ series: [(t: TimeInterval, y: Double)]) -> [Float] {
        guard let first = series.first?.t, let last = series.last?.t, last > first else {
            return series.map { Float($0.y) }
        }
        let width = (last - first) / Double(points)
        var sums = [Double](repeating: 0, count: points), counts = [Int](repeating: 0, count: points)
        for p in series {
            let i = min(points - 1, Int((p.t - first) / width))
            sums[i] += p.y
            counts[i] += 1
        }
        return zip(sums, counts).compactMap { $1 > 0 ? Float($0 / Double($1)) : nil }
    }

    private static func mode(_ setting: ThermalSetting) -> ThermyxWidgetMode {
        switch setting {
        case .auto: return .auto
        case .cool: return .cool
        case .heat: return .heat
        case .off: return .off
        }
    }

    private static func level(_ level: ThermyxRiskLevel) -> ThermyxWidgetSnapshot.Level {
        switch level {
        case .unavailable: return .waiting
        case .normal: return .normal
        case .caution: return .caution
        case .high: return .high
        case .critical: return .critical
        }
    }
}
