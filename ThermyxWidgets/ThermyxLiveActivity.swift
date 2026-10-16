import ActivityKit
import SwiftUI
import WidgetKit

/// While the insoles are connected: a live banner on the Lock Screen, and in
/// the Dynamic Island the soles and a mode dot that open out to the readings,
/// the trend and the mode buttons.
struct ThermyxLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ThermyxActivityAttributes.self) { context in
            WidgetMediumLayout(context: ctx(context))
                .padding(16)
                .activityBackgroundTint(ThermyxWidgetInk.bg)
                .activitySystemActionForegroundColor(ThermyxWidgetInk.text)
        } dynamicIsland: { context in
            let c = ctx(context)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { IslandLeading(context: c) }
                DynamicIslandExpandedRegion(.trailing) { IslandTrailing(context: c) }
                DynamicIslandExpandedRegion(.bottom) { IslandBottom(context: c) }
            } compactLeading: {
                IslandCompactLeading(context: c)
            } compactTrailing: {
                IslandModeDot(context: c)
            } minimal: {
                IslandModeDot(context: c, showsBattery: false)
            }
            .keylineTint(ThermyxWidgetInk.color(context.state.level))
        }
    }

    private func ctx(_ context: ActivityViewContext<ThermyxActivityAttributes>) -> WidgetContext {
        WidgetContext(snapshot: context.state, now: .now, soleView: ThermyxSoleView.current, stale: context.isStale)
    }
}
