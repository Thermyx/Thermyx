import ActivityKit
import SwiftUI
import WidgetKit

/// While the insoles are connected: a live banner on the Lock Screen, and in
/// the Dynamic Island a dot in the mode's colour that opens out to the
/// readings and curves.
struct ThermyxLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ThermyxActivityAttributes.self) { context in
            LockScreenBanner(snapshot: context.state, isStale: context.isStale)
                .activityBackgroundTint(ThermyxWidgetInk.bg)
                .activitySystemActionForegroundColor(ThermyxWidgetInk.text)
        } dynamicIsland: { context in
            let s = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            ThermyxModeDot(mode: s.mode, size: 9)
                            Text(s.mode.label.uppercased())
                                .font(WidgetFont.label(10)).tracking(1.1)
                                .foregroundStyle(ThermyxWidgetInk.muted)
                        }
                        Text(s.footText)
                            .font(WidgetFont.serif(34))
                            .foregroundStyle(ThermyxWidgetInk.text)
                            .contentTransition(.numericText())
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 4) {
                        RateLine(snapshot: s)
                        HStack(spacing: 3) {
                            Text("∫").font(.system(size: 11, design: .serif).italic())
                            Text("\(s.changeText) /10 min").font(WidgetFont.body(11)).monospacedDigit()
                        }
                        .foregroundStyle(ThermyxWidgetInk.muted)
                    }
                    .padding(.trailing, 4)
                    .padding(.top, 14)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 10) {
                            LabelledCurve(label: "T(t)", values: s.temps, color: ThermyxWidgetInk.ember)
                            LabelledCurve(label: "dT/dt", values: s.rates, color: ThermyxWidgetInk.ice, zeroLine: true)
                        }
                        .frame(height: 50)
                        LevelLine(snapshot: s)
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                ThermyxModeDot(mode: s.mode, size: 12)
                    .padding(.leading, 2)
            } compactTrailing: {
                EmptyView()
            } minimal: {
                ThermyxModeDot(mode: s.mode, size: 12)
            }
            .keylineTint(ThermyxWidgetInk.color(s.level))
        }
    }
}

/// The Lock Screen banner: the reading, its rate and change, both curves,
/// and any concern.
private struct LockScreenBanner: View {
    let snapshot: ThermyxWidgetSnapshot
    let isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    WidgetEyebrow(snapshot: snapshot)
                    Text(snapshot.footText)
                        .font(WidgetFont.serif(40))
                        .foregroundStyle(snapshot.live ? ThermyxWidgetInk.text : ThermyxWidgetInk.faint)
                        .contentTransition(.numericText())
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 4) {
                    RateLine(snapshot: snapshot)
                    HStack(spacing: 3) {
                        Text("∫").font(.system(size: 11, design: .serif).italic())
                        Text("\(snapshot.changeText) in 10 min").font(WidgetFont.body(11)).monospacedDigit()
                    }
                    .foregroundStyle(ThermyxWidgetInk.muted)
                    if let battery = snapshot.battery {
                        Label("\(battery)%", systemImage: "battery.75percent")
                            .font(WidgetFont.body(11))
                            .foregroundStyle(ThermyxWidgetInk.faint)
                    }
                }
                .padding(.top, 2)
            }
            HStack(spacing: 12) {
                LabelledCurve(label: "T(t)", values: snapshot.temps, color: ThermyxWidgetInk.ember)
                LabelledCurve(label: "dT/dt", values: snapshot.rates, color: ThermyxWidgetInk.ice, zeroLine: true)
            }
            .frame(height: 54)
            if isStale || !snapshot.live {
                NotLiveLine(snapshot: snapshot)
            } else {
                LevelLine(snapshot: snapshot)
            }
        }
        .padding(16)
    }
}
