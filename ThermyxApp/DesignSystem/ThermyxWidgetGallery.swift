#if DEBUG
import SwiftUI

/// Debug only (`-ThermyxUIPreview widgets`): every widget surface drawn at
/// its real size from sample snapshots, so the layouts can be reviewed
/// without adding widgets on a device. The data is obviously made up.
struct WidgetGallery: View {
    private static func curve(from a: Double, peak: Double, to b: Double) -> [Float] {
        (0..<40).map { i in
            let t = Double(i) / 39
            let base = t < 0.65 ? a + (peak - a) * (t / 0.65) : peak + (b - peak) * ((t - 0.65) / 0.35)
            return Float(base + 0.22 * sin(Double(i) * 0.85) + 0.12 * sin(Double(i) * 2.3))
        }
    }

    private static func snapshot(_ build: (inout ThermyxWidgetSnapshot) -> Void = { _ in }) -> ThermyxWidgetSnapshot {
        var s = ThermyxWidgetSnapshot(
            updated: .now, live: true, isDemo: false, fahrenheit: true, mode: .auto,
            footC: 34.4, leftC: 33.8, rightC: 34.4, leftLoad: 0.52, rightLoad: 0.46, leftSteady: 0.88, rightSteady: 0.84,
            level: .normal, concern: nil, temps: curve(from: 31.2, peak: 35.4, to: 34.4),
            batteryLeft: 61, batteryRight: 55)
        build(&s)
        return s
    }

    private let normal = snapshot()
    private let caution = snapshot { s in
        s.mode = .cool; s.footC = 38.4; s.leftC = 37.6; s.rightC = 38.4; s.level = .caution
        s.concern = "Foot-contact temperature is elevated."
        s.temps = curve(from: 33.8, peak: 38.9, to: 38.4)
        s.batteryLeft = 8; s.batteryRight = 54
    }
    private let hot = snapshot { s in
        s.mode = .cool; s.footC = 39.1; s.leftC = 38.2; s.rightC = 39.1; s.level = .high
        s.concern = "Movement stability is below baseline."
        s.temps = curve(from: 34, peak: 39.4, to: 39.1)
        s.leftSteady = 0.64; s.rightSteady = 0.58
        s.batteryLeft = 4; s.batteryRight = 40
    }
    private let off = snapshot { s in
        s.live = false; s.mode = .off; s.updated = .now.addingTimeInterval(-420)
    }

    private func context(_ s: ThermyxWidgetSnapshot?, _ view: ThermyxSoleView = .temperature) -> WidgetContext {
        WidgetContext(snapshot: s, now: .now, soleView: view)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    Text("Widget gallery · sample data").font(.headline).foregroundStyle(.white)
                    group("Small · 158×158") {
                        HStack(spacing: 14) {
                            widget(158, 158) { WidgetSmallLayout(context: context(normal)) }
                            widget(158, 158) { WidgetSmallLayout(context: context(caution, .pressure)) }
                        }
                        HStack(spacing: 14) {
                            widget(158, 158) { WidgetSmallLayout(context: context(hot, .gait)) }
                            widget(158, 158) { WidgetSmallLayout(context: context(off)) }
                        }
                    }.id("small")
                    group("Medium · 338×158") {
                        widget(338, 158) { WidgetMediumLayout(context: context(normal)) }
                        widget(338, 158) { WidgetMediumLayout(context: context(caution, .pressure)) }
                        widget(338, 158) { WidgetMediumLayout(context: context(hot, .gait)) }
                        widget(338, 158) { WidgetMediumLayout(context: context(off)) }
                    }.id("medium")
                    group("Large · 338×354") {
                        widget(338, 354) { WidgetLargeLayout(context: context(normal)) }
                        widget(338, 354) { WidgetLargeLayout(context: context(caution, .pressure)) }
                        widget(338, 354) { WidgetLargeLayout(context: context(off)) }
                    }.id("large")
                    group("Lock Screen") {
                        HStack(spacing: 14) {
                            accessory(170, 72) { WidgetRectangularLayout(context: context(normal)) }
                            accessory(76, 76) { WidgetCircularLayout(context: context(normal)) }
                        }
                        HStack(spacing: 14) {
                            accessory(170, 72) { WidgetRectangularLayout(context: context(caution)) }
                            accessory(76, 76) { WidgetCircularLayout(context: context(caution)) }
                        }
                        accessory(280, 22) { WidgetInlineLayout(context: context(normal)) }
                        widget(362, 158) { WidgetMediumLayout(context: context(normal)) }
                    }.id("lock")
                    group("Dynamic Island") {
                        compactIsland(normal)
                        compactIsland(caution)
                        HStack(spacing: 10) {
                            minimal(normal); minimal(caution)
                        }
                        expandedIsland(normal)
                        expandedIsland(hot)
                    }.id("island")
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.horizontal, 20)
                .padding(.top, 64)
                .padding(.bottom, 24)
            }
            .debugScroll(proxy)
        }
        .background(Color(white: 0.06).ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.footnote.weight(.semibold)).foregroundStyle(.gray)
            content()
        }
    }

    private func widget<Content: View>(_ w: CGFloat, _ h: CGFloat, @ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(16)
            .frame(width: w, height: h)
            .background(Color.black, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.white.opacity(0.12)) }
    }

    private func accessory<Content: View>(_ w: CGFloat, _ h: CGFloat, @ViewBuilder content: () -> Content) -> some View {
        content()
            .foregroundStyle(.white)
            .padding(6)
            .frame(width: w, height: h)
            .background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func compactIsland(_ s: ThermyxWidgetSnapshot) -> some View {
        let c = context(s)
        return HStack(spacing: 0) {
            IslandCompactLeading(context: c).frame(width: 52, alignment: .trailing)
            Spacer(minLength: 76)
            IslandModeDot(context: c).frame(width: 52, alignment: .leading)
        }
        .frame(width: 230, height: 37)
        .background(Color.black, in: Capsule())
        .overlay { Capsule().strokeBorder(Color.white.opacity(0.15)) }
    }

    private func minimal(_ s: ThermyxWidgetSnapshot) -> some View {
        IslandModeDot(context: context(s), showsBattery: false)
            .frame(width: 37, height: 37)
            .background(Color.black, in: Circle())
            .overlay { Circle().strokeBorder(Color.white.opacity(0.15)) }
    }

    private func expandedIsland(_ s: ThermyxWidgetSnapshot) -> some View {
        let c = context(s)
        return VStack(spacing: 6) {
            HStack(alignment: .top) {
                IslandLeading(context: c)
                Spacer(minLength: 110)
                IslandTrailing(context: c)
            }
            IslandBottom(context: c)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 16)
        .frame(width: 371)
        .background(Color.black, in: RoundedRectangle(cornerRadius: 44, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 44, style: .continuous).strokeBorder(Color.white.opacity(0.15)) }
    }
}
#endif
