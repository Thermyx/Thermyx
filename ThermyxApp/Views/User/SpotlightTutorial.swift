import SwiftUI

/// The first-run tutorial (design O5): it walks through all five tabs,
/// dimming everything but one control at a time and saying what it is. For
/// the mode button it waits for the wearer to try it. Replay from Safety →
/// Device.
///
/// The card is measured and placed where it fits whole — below the
/// highlighted control, else above it — so it never covers the thing it's
/// talking about.
struct SpotlightTutorial: View {
    let anchors: [SpotlightTarget: Anchor<CGRect>]
    @ObservedObject var viewModel: ThermyxViewModel
    @ObservedObject var center: TutorialCenter

    @AppStorage("thermyx.home.map") private var homeMap = HomeMap.pressure.rawValue
    @State private var step = 0
    @State private var startSetting: ThermalSetting?
    @State private var cardHeight: CGFloat = 170
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    struct Step {
        let tab: UserTab
        let target: SpotlightTarget
        let title: String
        let text: String
        /// Waits for the wearer to use the control instead of a Next button.
        var acts = false
    }

    private var steps: [Step] {
        [
            Step(tab: .home, target: .hero, title: "Home",
                 text: "Your warmer foot's temperature, live, and where it sits on the four risk levels."),
            Step(tab: .home, target: .maps, title: "Your feet",
                 text: "Your feet, live, in their real shape. Pressure lights the arch, where each insole's sensor sits; nothing else is guessed."),
            Step(tab: .home, target: .mapTabs, title: "Temperature",
                 text: "Tap Temperature to see each foot's temperature.", acts: true),
            Step(tab: .home, target: .thermalMode, title: "Heating and cooling",
                 text: viewModel.isControlAvailable
                    ? "Tap to step through Auto, Cool, Heat and Off, or touch and hold for all four. Try it now."
                    : "Auto, Cool, Heat or Off. It works once your insoles are connected.",
                 acts: viewModel.isControlAvailable),
            Step(tab: .home, target: .targetStepper, title: "Auto's target",
                 text: "Where Auto holds your feet. Calibration suggests one; − and + change it."),
            Step(tab: .insights, target: .insightsSummary, title: "Insights",
                 text: "Today, this week and your streak. Every card opens into the detail behind it."),
            Step(tab: .learn, target: .learnLead, title: "Learn",
                 text: "Short, sourced reads on heat, cold and your feet, with one picked for what's happening now."),
            Step(tab: .safety, target: .holdToCall, title: "Safety",
                 text: "Hold for two seconds to call 911. Your trusted circle and your device settings live here too."),
        ]
    }

    private var current: Step { steps[min(step, steps.count - 1)] }
    private var isLast: Bool { step >= steps.count - 1 }

    var body: some View {
        GeometryReader { proxy in
            let frame = holeFrame(current.target, proxy: proxy)
            ZStack(alignment: .topLeading) {
                scrim(size: proxy.size, hole: frame)
                if let frame {
                    RoundedRectangle(cornerRadius: radius(current.target), style: .continuous)
                        .strokeBorder(Thermyx.Ink.textPrimary.opacity(0.85), lineWidth: 1.5)
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                        .allowsHitTesting(false)
                }
                card
                    .frame(width: proxy.size.width - 40)
                    .background {
                        GeometryReader { card in
                            Color.clear.preference(key: CardHeightKey.self, value: card.size.height)
                        }
                    }
                    .offset(x: 20, y: cardY(frame: frame, proxy: proxy))
            }
            .animation(reduceMotion ? SiteMotion.fade : .spring(response: 0.45, dampingFraction: 0.9), value: step)
        }
        .ignoresSafeArea()
        .onPreferenceChange(CardHeightKey.self) { cardHeight = $0 }
        .onAppear {
            step = 0
            startSetting = viewModel.thermalSetting
            homeMap = HomeMap.pressure.rawValue
            center.requestedTab = steps[0].tab
            #if DEBUG
            // `-ThermyxTutorialStep <n>`: opens part-way through, for review.
            let arguments = ProcessInfo.processInfo.arguments
            if let i = arguments.firstIndex(of: "-ThermyxTutorialStep"), i + 1 < arguments.count,
               let n = Int(arguments[i + 1]), (0..<steps.count).contains(n) {
                step = n
                go()
            }
            #endif
        }
        .onChange(of: homeMap) { _, map in
            if current.target == .mapTabs, map == HomeMap.temperature.rawValue { advance() }
        }
        .onChange(of: viewModel.thermalSetting) { _, setting in
            if current.target == .thermalMode, current.acts, setting != startSetting { advance() }
        }
        .accessibilityAddTraits(.isModal)
    }

    private func radius(_ target: SpotlightTarget) -> CGFloat {
        switch target {
        case .tabBar: return 0
        case .thermalMode, .targetStepper: return 18
        case .mapTabs: return 12
        case .holdToCall: return 26
        default: return 20
        }
    }

    /// Black over everything but the hole. Taps outside the hole are
    /// swallowed; taps in it reach the control underneath.
    private func scrim(size: CGSize, hole: CGRect?) -> some View {
        var path = Path(CGRect(origin: .zero, size: size))
        if let hole {
            path.addRoundedRect(in: hole, cornerSize: CGSize(width: 18, height: 18), style: .continuous)
        }
        return path
            .fill(Color.black.opacity(0.78), style: FillStyle(eoFill: true))
            .contentShape(path, eoFill: true)
            .onTapGesture { }
            .accessibilityHidden(true)
    }

    /// The target's frame, padded, and kept above the thermal control so a
    /// tall target doesn't run under it.
    private func holeFrame(_ target: SpotlightTarget, proxy: GeometryProxy) -> CGRect? {
        guard var frame = anchors[target].map({ proxy[$0] })?.insetBy(dx: -8, dy: -8) else { return nil }
        let pinned: Set<SpotlightTarget> = [.thermalMode, .targetStepper, .tabBar]
        if !pinned.contains(target), let bar = anchors[.thermalMode].map({ proxy[$0] }) {
            frame.size.height = max(44, min(frame.height, bar.minY - 6 - frame.minY))
        }
        return frame
    }

    /// Where the card's top goes: below the hole if the whole card fits
    /// there, else above it, else on whichever side has more room, always
    /// inside the screen.
    private func cardY(frame: CGRect?, proxy: GeometryProxy) -> CGFloat {
        let top = proxy.safeAreaInsets.top + 8
        let bottom = proxy.size.height - proxy.safeAreaInsets.bottom - 8
        let gap: CGFloat = 14
        guard let frame else { return (proxy.size.height - cardHeight) * 0.4 }
        let below = frame.maxY + gap
        let above = frame.minY - gap - cardHeight
        if below + cardHeight <= bottom { return below }
        if above >= top { return above }
        let roomBelow = bottom - frame.maxY, roomAbove = frame.minY - top
        return roomBelow >= roomAbove ? max(top, bottom - cardHeight) : top
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.m) {
            HStack(spacing: Thermyx.Space.s) {
                Text(current.title)
                    .font(.custom(ThermyxFont.Family.bold, size: 15, relativeTo: .subheadline))
                    .foregroundStyle(Thermyx.Ink.onPrimary)
                Text("\(step + 1) of \(steps.count)")
                    .font(ThermyxFont.monoCaption)
                    .foregroundStyle(Color(hex: 0x5A606A))
                Spacer()
                Button("Skip") { center.finish() }
                    .font(.custom(ThermyxFont.Family.medium, size: 14, relativeTo: .subheadline))
                    .foregroundStyle(Thermyx.Ink.linkOnLight)
                    .frame(minWidth: 44, minHeight: 44)
            }
            progress
            Text(current.text)
                .font(.custom(ThermyxFont.Family.medium, size: 17, relativeTo: .body))
                .lineSpacing(2)
                .foregroundStyle(Thermyx.Ink.onPrimary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if step > 0 {
                    Button("Back") { back() }
                        .font(.custom(ThermyxFont.Family.semibold, size: 15, relativeTo: .subheadline))
                        .foregroundStyle(Thermyx.Ink.linkOnLight)
                        .frame(minWidth: 44, minHeight: 44)
                }
                Spacer()
                if current.acts {
                    HStack(spacing: 8) {
                        Circle().fill(Thermyx.Ink.signal).frame(width: 8, height: 8)
                        Text("Tap the highlighted control")
                            .font(.custom(ThermyxFont.Family.semibold, size: 14, relativeTo: .subheadline))
                            .foregroundStyle(Color(hex: 0x0E5C99))
                    }
                } else {
                    Button(isLast ? "Finish" : "Next") { isLast ? center.finish() : advance() }
                        .font(.custom(ThermyxFont.Family.semibold, size: 15, relativeTo: .subheadline))
                        .foregroundStyle(Thermyx.Ink.textPrimary)
                        .padding(.horizontal, 22)
                        .frame(height: 44)
                        .background(Thermyx.Ink.onPrimary, in: Capsule())
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .background(Thermyx.Ink.textPrimary, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.4), radius: 20, y: 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tutorial, \(current.title), step \(step + 1) of \(steps.count)")
    }

    /// One segment per step, filled up to this one.
    private var progress: some View {
        HStack(spacing: 4) {
            ForEach(0..<steps.count, id: \.self) { i in
                Capsule()
                    .fill(i <= step ? Thermyx.Ink.onPrimary : Color(hex: 0xC9CDD3))
                    .frame(height: 3)
            }
        }
        .accessibilityHidden(true)
    }

    private func advance() {
        guard !isLast else { center.finish(); return }
        step += 1
        go()
    }

    private func back() {
        guard step > 0 else { return }
        step -= 1
        go()
    }

    private func go() {
        center.requestedTab = current.tab
        if current.target == .thermalMode { startSetting = viewModel.thermalSetting }
    }

    private struct CardHeightKey: PreferenceKey {
        static let defaultValue: CGFloat = 170
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
    }
}
