import SwiftUI

/// The controls the tutorial points at. Screens mark them with
/// `.spotlightTarget(_:)`; the tutorial overlay reads their frames.
enum SpotlightTarget: Hashable {
    case hero
    case maps
    case mapTabs
    case thermalMode
    case targetStepper
    case insightsSummary
    case learnLead
    case simulatorControls
    case holdToCall
    case tabBar
}

struct SpotlightAnchors: PreferenceKey {
    static let defaultValue: [SpotlightTarget: Anchor<CGRect>] = [:]
    static func reduce(value: inout [SpotlightTarget: Anchor<CGRect>], nextValue: () -> [SpotlightTarget: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    /// Marks this view as something the tutorial can spotlight.
    func spotlightTarget(_ target: SpotlightTarget) -> some View {
        anchorPreference(key: SpotlightAnchors.self, value: .bounds) { [target: $0] }
    }
}
