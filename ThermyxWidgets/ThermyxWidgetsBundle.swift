import SwiftUI
import WidgetKit

@main
struct ThermyxWidgetsBundle: WidgetBundle {
    var body: some Widget {
        ThermyxStatusWidget()
        ThermyxReadinessWidget()
        ThermyxSafetyWidget()
        ThermyxLiveActivity()
    }
}
