import SwiftUI
import WidgetKit

struct StatusEntry: TimelineEntry {
    let date: Date
    /// Nil until the app has written one: the widget never shows made-up
    /// numbers.
    let snapshot: ThermyxWidgetSnapshot?
}

struct StatusProvider: TimelineProvider {
    func placeholder(in context: Context) -> StatusEntry { StatusEntry(date: .now, snapshot: nil) }

    func getSnapshot(in context: Context, completion: @escaping (StatusEntry) -> Void) {
        completion(StatusEntry(date: .now, snapshot: ThermyxWidgetSnapshot.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StatusEntry>) -> Void) {
        let snapshot = ThermyxWidgetSnapshot.load()
        var entries = [StatusEntry(date: .now, snapshot: snapshot)]
        // A second entry for when the reading goes stale, so the widget
        // stops calling it live even if the app hasn't reloaded it.
        if let snapshot, snapshot.live {
            let stale = snapshot.updated.addingTimeInterval(ThermyxWidgetSnapshot.staleAfter)
            if stale > .now { entries.append(StatusEntry(date: stale, snapshot: snapshot)) }
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
        .description("Foot temperature, how fast it's changing, and anything flagged.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryCircular, .accessoryInline])
    }
}

struct StatusWidgetView: View {
    let entry: StatusEntry
    @Environment(\.widgetFamily) private var family

    private var snapshot: ThermyxWidgetSnapshot? { entry.snapshot }
    private var live: Bool { snapshot?.isLive(at: entry.date) ?? false }

    var body: some View {
        switch family {
        case .systemMedium: medium
        case .accessoryRectangular: rectangular
        case .accessoryCircular: circular
        case .accessoryInline: inline
        default: small
        }
    }

    // MARK: Home Screen

    private var small: some View {
        VStack(alignment: .leading, spacing: 4) {
            WidgetEyebrow(snapshot: snapshot)
            Text(snapshot?.footText ?? "—")
                .font(WidgetFont.serif(42))
                .foregroundStyle(live ? ThermyxWidgetInk.text : ThermyxWidgetInk.faint)
                .contentTransition(.numericText())
                .minimumScaleFactor(0.7)
            if let snapshot, live {
                RateLine(snapshot: snapshot)
                Sparkline(values: snapshot.temps)
                LevelLine(snapshot: snapshot)
            } else {
                Spacer(minLength: 0)
                NotLiveLine(snapshot: snapshot)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var medium: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                WidgetEyebrow(snapshot: snapshot)
                Text(snapshot?.footText ?? "—")
                    .font(WidgetFont.serif(44))
                    .foregroundStyle(live ? ThermyxWidgetInk.text : ThermyxWidgetInk.faint)
                    .contentTransition(.numericText())
                    .minimumScaleFactor(0.7)
                if let snapshot, live {
                    RateLine(snapshot: snapshot)
                    HStack(spacing: 3) {
                        Text("∫").font(.system(size: 11, design: .serif).italic())
                        Text("\(snapshot.changeText) in 10 min").font(WidgetFont.body(11)).monospacedDigit()
                    }
                    .foregroundStyle(ThermyxWidgetInk.muted)
                    Spacer(minLength: 0)
                    LevelLine(snapshot: snapshot)
                } else {
                    Spacer(minLength: 0)
                    NotLiveLine(snapshot: snapshot)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let snapshot, live {
                VStack(spacing: 8) {
                    LabelledCurve(label: "T(t)", values: snapshot.temps, color: ThermyxWidgetInk.ember)
                    LabelledCurve(label: "dT/dt", values: snapshot.rates, color: ThermyxWidgetInk.ice, zeroLine: true)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Lock Screen

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let snapshot, live {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(snapshot.footText).font(.system(size: 17, weight: .semibold)).widgetAccentable()
                    Image(systemName: snapshot.rateSymbol).font(.system(size: 10, weight: .bold))
                    Text(snapshot.rateText).font(.system(size: 12)).monospacedDigit()
                }
                Sparkline(values: snapshot.temps, color: .primary)
                Text(snapshot.concern ?? "\(snapshot.mode.label) · \(snapshot.level.label)")
                    .font(.system(size: 12, weight: snapshot.level.isConcern ? .semibold : .regular))
                    .lineLimit(1)
            } else {
                Text("Thermyx").font(.system(size: 15, weight: .semibold)).widgetAccentable()
                Text(snapshot == nil ? "Open to connect" : "Not connected").font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                if let snapshot, live {
                    Text(snapshot.footText).font(.system(size: 15, weight: .semibold)).minimumScaleFactor(0.6)
                    Image(systemName: snapshot.level.isConcern ? "exclamationmark.triangle.fill" : snapshot.rateSymbol)
                        .font(.system(size: 11, weight: .bold))
                        .widgetAccentable()
                } else {
                    Image(systemName: "shoeprints.fill").font(.system(size: 16))
                    Text("—").font(.system(size: 11))
                }
            }
            .padding(4)
        }
    }

    @ViewBuilder
    private var inline: some View {
        if let snapshot, live {
            Text("\(snapshot.footText) \(snapshot.rateText) · \(snapshot.concern == nil ? snapshot.level.label : "Check feet")")
        } else {
            Text("Thermyx · not connected")
        }
    }
}
