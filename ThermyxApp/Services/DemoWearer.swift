import Foundation

/// The person behind every simulated reading: a shift on their feet, in a
/// day that warms toward the afternoon, with Thermyx regulating as the real
/// firmware does. The simulated insoles and the back-filled demo history
/// both use it, so the history and the live readings meet without a jump.
///
/// Nothing here is a measurement. It exists so a demo behaves the way the
/// product does: Auto warms a foot that's below the target and cools one
/// that's above it, cooling has a limit on a hot afternoon, and the wearer
/// walks, stands and sits.
enum DemoWearer {

    // MARK: Activity

    /// What the wearer is doing `minute` minutes into the shift: a 45-minute
    /// round of walking, standing and sitting, with a sit-down lunch midway.
    static func activity(minute: Int, shiftMinutes: Int = 480) -> CalibrationActivity {
        let progress = Double(minute) / Double(max(shiftMinutes, 1))
        if (0.48..<0.54).contains(progress) { return .sitting }
        switch minute % 45 {
        case 0..<15: return .walking
        case 15..<30: return .standing
        default: return .sitting
        }
    }

    /// Steps per minute while walking, varying gently; zero otherwise.
    static func cadence(_ activity: CalibrationActivity, minute: Double) -> Double {
        activity == .walking ? 104 + 7 * sin(minute / 6.5) : 0
    }

    /// Share of the reporting window spent loaded without stepping.
    static func standingFraction(_ activity: CalibrationActivity) -> Double {
        switch activity {
        case .walking: return 0.12
        case .standing: return 0.92
        case .sitting: return 0.04
        }
    }

    /// The arch sensor's level, 0…1 of full scale: barely loaded sitting,
    /// half loaded standing, rising and falling with each step walking.
    static func archLoad(_ activity: CalibrationActivity, seconds: Double, foot: Foot) -> Double {
        let side = foot == .right ? 0.03 : 0
        switch activity {
        case .sitting: return 0.06 + side
        case .standing: return 0.48 + side + 0.02 * sin(seconds / 3)
        case .walking: return 0.55 + side + 0.16 * sin(seconds * 1.7 + (foot == .left ? 0 : .pi))
        }
    }

    // MARK: Temperature

    /// The air through the day: `heat` 0…1 says how hot a day it is, and the
    /// afternoon peaks at `progress` about 0.6.
    static func ambientC(progress: Double, heat: Double) -> Double {
        19 + heat * 10 + 9 * sin(.pi * min(max(progress * 0.95 + 0.03, 0), 1))
    }

    /// Where the foot would settle with the insole passive.
    static func naturalContactC(ambientC: Double, activity: CalibrationActivity, foot: Foot, fatigue: Double = 0) -> Double {
        let effort: Double = switch activity {
        case .walking: 0.6
        case .standing: 0.2
        case .sitting: -0.3
        }
        return 30.6 + (ambientC - 22) * 0.4 + effort + (foot == .right ? 0.35 : 0) + fatigue * 0.6
    }

    /// How far the Peltier can move the foot from where it would settle.
    static let coolingReachC = 2.8
    static let heatingReachC = 4.0

    /// What the firmware's Auto does: heat below the target, cool above it,
    /// fan only near it. `previous` gives it the firmware's hysteresis.
    static func autoDecision(contactC: Double, targetC: Double, previous: ThermalMode) -> ThermalMode {
        if contactC > targetC + 0.6 { return .cooling }
        if contactC < targetC - 0.6 { return .heating }
        if abs(contactC - targetC) < 0.2 { return .ventilation }
        return previous == .off ? .ventilation : previous
    }

    /// Where the foot is heading for a given actuator state.
    static func settlingC(natural: Double, active: ThermalMode) -> Double {
        switch active {
        case .heating: return min(natural + heatingReachC, 41)
        case .cooling: return natural - coolingReachC
        case .ventilation: return natural - 0.6
        case .off: return natural
        }
    }

    /// Battery drain, percent per minute: the Peltier is the big draw.
    static func drainPerMinute(_ active: ThermalMode) -> Double {
        switch active {
        case .heating, .cooling: return 0.16
        case .ventilation: return 0.06
        case .off: return 0.02
        }
    }

    /// Walking steadiness: high when fresh, easing as the shift and the heat
    /// wear on.
    static func steadiness(progress: Double, heat: Double, seconds: Double) -> Double {
        0.93 - 0.07 * progress - 0.05 * heat * progress + 0.012 * sin(seconds / 11)
    }
}
