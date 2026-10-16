import Foundation

/// Runs the Thermal Recovery Test: opens it when an alert is up, takes the
/// readings during the hold, finishes it on time (or early), and hands back
/// the result to save to the safety plan.
///
/// It only watches and advises. It never changes the risk level, never
/// delays an alert or a call, and sets the insoles to Cool only when the
/// wearer taps the button for it.
@MainActor
final class RecoveryCoach: ObservableObject {
    @Published private(set) var session: RecoverySession?
    private var timer: Timer?
    private var lastSampleAt = Date.distantPast

    var isActive: Bool { session != nil }

    /// Opens the test on the steps screen.
    func start(level: ThermyxRiskLevel, reading: BilateralReading, now: Date = .now) {
        stopTimer()
        var s = RecoverySession(startedAt: now, startLevel: level)
        s.startFootC = reading.peakFootTemperatureC
        session = s
    }

    func toggle(_ step: RecoveryStep) {
        guard var s = session, s.phase == .steps else { return }
        if s.done.contains(step) { s.done.remove(step) } else { s.done.insert(step) }
        session = s
    }

    /// The wearer used the button to switch the insoles to Cool.
    func switchedToCool() {
        guard var s = session else { return }
        s.switchedToCool = true
        s.done.insert(.coolDown)
        session = s
    }

    func beginHold(now: Date = .now) {
        guard var s = session, s.canStartHold else { return }
        s.startHold(now: now)
        session = s
        lastSampleAt = .distantPast
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    /// Feeds a reading in during the hold, at most once a second.
    func observe(_ reading: BilateralReading, level: ThermyxRiskLevel, now: Date = .now) {
        guard var s = session, s.holdStartedAt != nil, now.timeIntervalSince(lastSampleAt) >= 1 else { return }
        lastSampleAt = now
        s.add(reading, level: level, now: now)
        session = s
        if s.remaining(now: now) <= 0 { finish(now: now) }
    }

    private func tick(now: Date = .now) {
        guard let s = session, s.holdStartedAt != nil, s.remaining(now: now) <= 0 else { return }
        finish(now: now)
    }

    /// Ends the hold, on time or early, and measures it.
    func finish(now: Date = .now) {
        guard var s = session, s.holdStartedAt != nil else { return }
        stopTimer()
        _ = s.finish(now: now)
        session = s
    }

    /// Another hold, after one that didn't settle it.
    func again(now: Date = .now) {
        guard var s = session else { return }
        s.phase = .steps
        s.samples = []
        session = s
        beginHold(now: now)
    }

    func close() {
        stopTimer()
        session = nil
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}
