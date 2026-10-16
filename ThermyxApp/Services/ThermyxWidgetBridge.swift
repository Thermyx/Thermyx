import ActivityKit
import Foundation
import UIKit
import WidgetKit

/// Feeds the widgets, the Live Activity and the Dynamic Island from live
/// readings: the warmer foot's temperature and a 30-minute curve of it, each
/// foot's temperature, arch load and steadiness (for the soles), both
/// batteries, the risk level, the top concern and the thermal setting.
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

    /// The last half hour of the warmer foot, about one point a second.
    private var samples: [(time: Date, c: Double)] = []
    private var lastSaved = Date.distantPast
    private var lastReload = Date.distantPast
    private var lastSnapshot: ThermyxWidgetSnapshot?
    private var activity: Activity<ThermyxActivityAttributes>?
    private var endTask: Task<Void, Never>?

    private static let window = TimeInterval(ThermyxWidgetSnapshot.windowMinutes * 60)
    private static let points = 40

    init() {
        adoptActivities()
    }

    /// Picks up the activity left running by an earlier launch, and ends any
    /// others straight away: one Lock Screen card, never two.
    private func adoptActivities() {
        let all = Activity<ThermyxActivityAttributes>.activities
        activity = all.first { $0.activityState == .active }
        endActivities(except: activity?.id)
    }

    /// Ends every Live Activity but one, with no lingering card. An ended
    /// activity otherwise stays on the Lock Screen for minutes, which is how
    /// a stale "Not connected" card ended up above the live one.
    private func endActivities(except keep: String?) {
        for other in Activity<ThermyxActivityAttributes>.activities where other.id != keep {
            Task { await other.end(nil, dismissalPolicy: .immediate) }
        }
    }

    func update(reading: BilateralReading, isDemo: Bool, setting: ThermalSetting, assessment: ThermyxRiskAssessment) {
        let now = Date.now
        let live = !reading.present.isEmpty
        if let c = reading.peakFootTemperatureC, samples.last.map({ now.timeIntervalSince($0.time) >= 1 }) ?? true {
            samples.append((now, c))
        }
        samples.removeAll { now.timeIntervalSince($0.time) > Self.window }

        let mode = Self.mode(setting)
        let level = live ? Self.level(assessment.level) : .waiting
        // A change people would notice goes out at once; otherwise every
        // few seconds is plenty.
        let lowNow = [reading[.left]?.batteryPercent, reading[.right]?.batteryPercent].compactMap { $0 }.min()
            .map { $0 <= ThermyxWidgetSnapshot.batteryCritical ? 2 : $0 <= ThermyxWidgetSnapshot.batteryLow ? 1 : 0 } ?? 0
        let lowBefore = lastSnapshot.map { $0.batteryIsCritical ? 2 : $0.lowBattery != nil ? 1 : 0 } ?? 0
        let significant = lastSnapshot.map { $0.live != live || $0.mode != mode || $0.level != level } ?? true || lowNow != lowBefore
        guard significant || now.timeIntervalSince(lastSaved) >= 5 else { return }
        lastSaved = now

        var snapshot = ThermyxWidgetSnapshot(
            updated: now, live: live, isDemo: isDemo, fahrenheit: fahrenheit, mode: mode,
            footC: reading.peakFootTemperatureC ?? lastSnapshot?.footC,
            leftC: reading[.left]?.footTemperatureC, rightC: reading[.right]?.footTemperatureC,
            leftLoad: reading[.left]?.pressureBalance, rightLoad: reading[.right]?.pressureBalance,
            leftSteady: reading[.left]?.gaitStability, rightSteady: reading[.right]?.gaitStability,
            level: level,
            concern: level.isConcern ? assessment.reasons.first : nil,
            temps: [],
            batteryLeft: reading[.left]?.batteryPercent,
            batteryRight: reading[.right]?.batteryPercent
        )
        if let start = samples.first?.time {
            snapshot.temps = Self.bucket(samples.map { ($0.time.timeIntervalSince(start), $0.c) })
        }
        // A disconnect keeps the last curve on show, marked not live.
        if !live, let last = lastSnapshot {
            snapshot.temps = last.temps
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
        // iOS greys a Live Activity out at its stale date. Insoles report every
        // second, so five minutes of silence is real; the demo can't update
        // while iOS has the app suspended, so it gets longer.
        let staleAfter: TimeInterval = snapshot.isDemo ? 30 * 60 : 5 * 60
        let content = ActivityContent(state: snapshot, staleDate: snapshot.updated.addingTimeInterval(staleAfter),
                                      relevanceScore: snapshot.level.isConcern ? 100 : 50)
        if snapshot.live {
            endTask?.cancel()
            endTask = nil
            if let activity, activity.activityState == .active {
                Task { await activity.update(content) }
            } else if ActivityAuthorizationInfo().areActivitiesEnabled,
                      UIApplication.shared.applicationState != .background {
                // Live Activities can only start while the app is open. Clear
                // out any old one first so the new card isn't stacked on it.
                endActivities(except: nil)
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
