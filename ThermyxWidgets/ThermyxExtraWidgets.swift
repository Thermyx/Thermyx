import SwiftUI
import WidgetKit

/// "Today vs your normal": the Readiness profile on the Home and Lock Screen.
struct ThermyxReadinessWidget: Widget {
    static let kind = "ThermyxReadiness"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: StatusProvider()) { entry in
            ReadinessWidgetView(entry: entry)
                .containerBackground(for: .widget) { ThermyxWidgetInk.bg }
        }
        .configurationDisplayName("Readiness")
        .description("Whether your feet look like your usual today, with your normal range.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}

struct ReadinessWidgetView: View {
    let entry: StatusEntry
    @Environment(\.widgetFamily) private var family
    var body: some View { WidgetReadinessLayout(snapshot: entry.snapshot, family: family) }
}

/// I'm OK in one tap, and SOS that opens the app's hold-to-call.
struct ThermyxSafetyWidget: Widget {
    static let kind = "ThermyxSafety"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: StatusProvider()) { entry in
            SafetyWidgetView(entry: entry)
                .containerBackground(for: .widget) { ThermyxWidgetInk.bg }
        }
        .configurationDisplayName("Safety")
        .description("Tell your circle you're OK, or open SOS.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct SafetyWidgetView: View {
    let entry: StatusEntry
    @Environment(\.widgetFamily) private var family
    var body: some View { WidgetSafetyLayout(snapshot: entry.snapshot, family: family, now: entry.date) }
}
