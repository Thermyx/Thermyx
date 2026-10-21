import SwiftUI
import WidgetKit

struct StatusEntry: TimelineEntry {
    let date: Date
    /// Nil until the app has written one: the widget never shows made-up
    /// numbers.
    let snapshot: ThermyxWidgetSnapshot?
    let soleView: ThermyxSoleView

    var context: WidgetContext { WidgetContext(snapshot: snapshot, now: date, soleView: soleView) }
}

struct StatusProvider: TimelineProvider {
    func placeholder(in context: Context) -> StatusEntry {
        StatusEntry(date: .now, snapshot: nil, soleView: .temperature)
    }

    func getSnapshot(in context: Context, completion: @escaping (StatusEntry) -> Void) {
        completion(StatusEntry(date: .now, snapshot: ThermyxWidgetSnapshot.load(), soleView: ThermyxSoleView.current))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StatusEntry>) -> Void) {
        let snapshot = ThermyxWidgetSnapshot.load()
        let view = ThermyxSoleView.current
        var entries = [StatusEntry(date: .now, snapshot: snapshot, soleView: view)]
        // A second entry for when the reading goes stale, so the widget
        // stops calling it live even if the app hasn't reloaded it.
        if let snapshot, snapshot.live {
            let stale = snapshot.updated.addingTimeInterval(ThermyxWidgetSnapshot.staleAfter)
            if stale > .now { entries.append(StatusEntry(date: stale, snapshot: snapshot, soleView: view)) }
        }
        completion(Timeline(entries: entries, policy: .after(.now.addingTimeInterval(15 * 60))))
    }
}

struct ThermyxStatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: ThermyxShared.widgetKind, provider: StatusProvider()) { entry in
            StatusWidgetView(entry: entry)
                .containerBackground(for: .widget) { ThermyxWidgetInk.bg }
        }
        .configurationDisplayName("Thermyx")
        .description("Your feet live: temperature, the soles, battery and mode, with buttons to switch mode.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge,
                            .accessoryRectangular, .accessoryCircular, .accessoryInline])
    }
}

struct StatusWidgetView: View {
    let entry: StatusEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let context = entry.context
        switch family {
        case .systemLarge: WidgetLargeLayout(context: context)
        case .systemMedium: WidgetMediumLayout(context: context)
        case .accessoryRectangular: WidgetRectangularLayout(context: context)
        case .accessoryCircular: WidgetCircularLayout(context: context)
        case .accessoryInline: WidgetInlineLayout(context: context)
        default: WidgetSmallLayout(context: context)
        }
    }
}
