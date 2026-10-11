import AVFoundation
import SwiftUI

// MARK: - Content

/// One welcome slide. Edit the copy and video names here.
struct WelcomeSlide: Identifiable {
    let id: Int
    let title: String
    let body: String
    /// A bundled `.mp4` in Resources/Media. Missing files show an empty frame.
    let video: String?

    static let all: [WelcomeSlide] = [
        .init(id: 0, title: "Built for *construction workers.*",
              body: "Long shifts on hot sites. Thermyx cools each foot, watches for heat strain, and tells your crew before it turns into an emergency.",
              video: "slide-construction"),
        .init(id: 1, title: "Built for *athletes.*",
              body: "Warm up faster, stay comfortable longer. Every step reports cadence, balance and steadiness, learned against your own normal.",
              video: "slide-athletes"),
        .init(id: 2, title: "Built for *soldiers.*",
              body: "Cold mornings, hot afternoons, heavy loads. Hard safety limits run on the insole itself, so protection never depends on a signal.",
              video: "slide-soldiers"),
        .init(id: 3, title: "Built for *convenience.*",
              body: "Twenty parts, one insole. Take it apart, turn it, and tap any piece to see what it does.",
              video: nil),
    ]
}

// MARK: - Slides

/// The first screen: four slides, the endorsements running across the top,
/// and sign-in on the last one with the insole you can take apart.
struct WelcomeSlides: View {
    @EnvironmentObject private var account: ThermyxAccountStore
    let onContinue: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var page: Int = {
        #if DEBUG
        // `-ThermyxSlide <n>` opens on a slide, for review.
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-ThermyxSlide"), i + 1 < args.count, let n = Int(args[i + 1]) { return n }
        #endif
        return 0
    }()
    @State private var drag: CGFloat = 0
    @State private var modelFrame: CGRect = .zero
    @State private var exploded: Bool = {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-ThermyxExplode")
        #else
        return false
        #endif
    }()
    @State private var selected: InsolePart?
    @State private var legal: LegalDocument.Kind?

    private let slides = WelcomeSlide.all
    private var isLast: Bool { page == slides.count - 1 }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.top, Thermyx.Space.xs)

            GeometryReader { proxy in
                HStack(spacing: 0) {
                    ForEach(slides) { slide in
                        slideView(slide)
                            .frame(width: proxy.size.width)
                    }
                }
                .offset(x: -CGFloat(page) * proxy.size.width + drag)
                .gesture(pager(width: proxy.size.width))
            }
            .clipped()

            footer
                .padding(.horizontal, Thermyx.Space.wide)
                .padding(.bottom, Thermyx.Space.xs)
        }
        .sheet(item: $legal) { kind in LegalSheet(selection: kind) }
        .sensoryFeedback(.selection, trigger: page)
    }

    // MARK: Paging

    private func pager(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .onChanged { value in
                // The model takes its own swipes.
                guard !(isLast && modelFrame.contains(value.startLocation)) else { return }
                let dx = value.translation.width
                let atEdge = (page == 0 && dx > 0) || (isLast && dx < 0)
                drag = atEdge ? dx * 0.3 : dx
            }
            .onEnded { value in
                defer { withAnimation(SiteMotion.settle) { drag = 0 } }
                guard !(isLast && modelFrame.contains(value.startLocation)) else { return }
                let projected = value.predictedEndTranslation.width
                if projected < -width * 0.35 { go(page + 1) } else if projected > width * 0.35 { go(page - 1) }
            }
    }

    private func go(_ index: Int) {
        let next = min(max(index, 0), slides.count - 1)
        withAnimation(reduceMotion ? SiteMotion.fade : .spring(response: 0.45, dampingFraction: 1)) { page = next }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: Thermyx.Space.m) {
            Image("ThermyxLogoLight")
                .resizable()
                .scaledToFit()
                .frame(height: 24)
                .accessibilityLabel("Thermyx")
            EndorsementLoop()
        }
    }

    // MARK: Slides

    @ViewBuilder
    private func slideView(_ slide: WelcomeSlide) -> some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.l) {
            if slide.video != nil {
                SlideVideo(name: slide.video!, isPlaying: page == slide.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                convenience
            }
            VStack(alignment: .leading, spacing: Thermyx.Space.s) {
                RevealHeadline(text: slide.title, font: ThermyxFont.display, italicFont: ThermyxFont.displayItalic)
                    .id("\(slide.id)-\(page == slide.id)")
                Text(slide.body)
                    .font(ThermyxFont.bodyLarge)
                    .lineSpacing(3)
                    .foregroundStyle(Thermyx.Site.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, Thermyx.Space.wide)
        .padding(.top, Thermyx.Space.l)
        .accessibilityElement(children: .contain)
    }

    /// The last slide's model: the button takes it apart, a drag turns
    /// it, a tap picks a part.
    private var convenience: some View {
        ZStack(alignment: .bottom) {
            InsoleStack(exploded: exploded, selected: $selected)
                // A faint ice halo that follows the model's outline.
                .shadow(color: Thermyx.Ink.ice.opacity(0.28), radius: 22)
                .padding(.horizontal, -Thermyx.Space.wide)
                .padding(.bottom, 36)
                .background {
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear { modelFrame = proxy.frame(in: .global) }
                            .onChange(of: proxy.frame(in: .global)) { _, frame in modelFrame = frame }
                    }
                }
                .accessibilityLabel("The Thermyx insole and power pack, \(exploded ? "taken apart" : "assembled"). Drag to turn it.")

            ExplodeButton(exploded: $exploded)
                .padding(.bottom, -4)
        }
        // The picked part's card sits in the space above the model, so it
        // never covers the stack.
        .overlay(alignment: .top) {
            if let part = selected {
                PartCallout(part: part) { selected = nil }
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(SiteMotion.settle, value: selected)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Footer

    @ViewBuilder
    private var footer: some View {
        VStack(spacing: Thermyx.Space.m) {
            PageDots(count: slides.count, page: page) { go($0) }
            if isLast {
                signIn
            } else {
                Button { go(page + 1) } label: {
                    Label("Next", systemImage: "arrow.right").labelStyle(TrailingIconLabelStyle())
                }
                .buttonStyle(SitePrimaryButtonStyle())
            }
        }
        .padding(.top, Thermyx.Space.m)
        .animation(SiteMotion.settle, value: isLast)
    }

    @ViewBuilder
    private var signIn: some View {
        if let current = account.account {
            Button(action: onContinue) {
                Label(current.displayName.map { "Continue as \($0.components(separatedBy: " ").first ?? $0)" } ?? "Continue",
                      systemImage: "arrow.right")
                    .labelStyle(TrailingIconLabelStyle())
            }
            .buttonStyle(SitePrimaryButtonStyle())
            Button("Not you? Sign out") { account.signOut() }
                .buttonStyle(SiteTextButtonStyle())
        } else {
            Button {
                Task {
                    await account.signInWithGoogle()
                    if account.isSignedIn { onContinue() }
                }
            } label: {
                HStack(spacing: Thermyx.Space.s) {
                    Image("GoogleG").resizable().scaledToFit().frame(width: 20, height: 20)
                    Text("Continue with Google")
                }
                .opacity(account.isWorking ? 0 : 1)
                .overlay { if account.isWorking { ProgressView().tint(.black) } }
            }
            .buttonStyle(GoogleButtonStyle())
            .disabled(account.isWorking)

            if let error = account.errorMessage {
                Text(error)
                    .font(ThermyxFont.captionSmall)
                    .foregroundStyle(Thermyx.Ink.amber)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("By continuing you agree to the [Terms](thermyx://legal/terms) and [Privacy Policy](thermyx://legal/privacy).")
                .font(ThermyxFont.captionSmall)
                .foregroundStyle(Thermyx.Site.textFaint)
                .tint(Thermyx.Site.textMuted)
                .multilineTextAlignment(.center)
                .environment(\.openURL, OpenURLAction { url in
                    legal = url.lastPathComponent == "terms" ? .terms : .privacy
                    return .handled
                })
        }
    }
}

// MARK: - Pieces

/// The page indicator: the current page is a longer bar. Tappable.
private struct PageDots: View {
    let count: Int
    let page: Int
    let onSelect: (Int) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(i == page ? Thermyx.Site.text : Thermyx.Site.hairlineStrong)
                    .frame(width: i == page ? 22 : 7, height: 7)
                    .frame(height: 28)
                    .contentShape(Rectangle())
                    .onTapGesture { onSelect(i) }
            }
        }
        .animation(SiteMotion.settle, value: page)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Page \(page + 1) of \(count)")
        .accessibilityAdjustableAction { direction in
            onSelect(direction == .increment ? page + 1 : page - 1)
        }
    }
}

/// What a tapped part is, from the website's component copy.
private struct PartCallout: View {
    let part: InsolePart
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Thermyx.Space.m) {
            VStack(alignment: .leading, spacing: 4) {
                SiteEyebrow(part.product, color: Thermyx.Ink.ice)
                Text(part.label)
                    .font(ThermyxFont.cardTitle)
                    .foregroundStyle(Thermyx.Site.text)
                Text(part.role)
                    .font(ThermyxFont.caption)
                    .foregroundStyle(Thermyx.Site.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = part.detail {
                    Text(detail)
                        .font(ThermyxFont.captionSmall)
                        .foregroundStyle(Thermyx.Site.textFaint)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Thermyx.Site.textMuted)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(Thermyx.Space.l)
        .siteGlass(radius: Thermyx.Radius.list)
        .accessibilityElement(children: .combine)
    }
}

/// Takes the model apart and puts it back: a small ember pill, so it reads
/// as the one action on the slide without competing with sign-in.
private struct ExplodeButton: View {
    @Binding var exploded: Bool

    var body: some View {
        Button {
            exploded.toggle()
        } label: {
            Label(exploded ? "Put together" : "Take apart",
                  systemImage: exploded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                .contentTransition(.interpolate)
        }
        .buttonStyle(Pill())
        .sensoryFeedback(.impact(weight: .medium), trigger: exploded)
        .accessibilityLabel(exploded ? "Put the insole back together" : "Take the insole apart")
    }

    private struct Pill: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .font(ThermyxFont.controlLabel)
                .foregroundStyle(Thermyx.Ink.ember)
                .padding(.horizontal, Thermyx.Space.l)
                .frame(height: 36)
                .background(Thermyx.Tint.emberFill, in: Capsule())
                .overlay { Capsule().strokeBorder(Thermyx.Tint.emberBorder, lineWidth: 1) }
                .shadow(color: Thermyx.Ink.ember.opacity(0.25), radius: 12)
                .frame(minHeight: Thermyx.minimumTapTarget)
                .scaleEffect(configuration.isPressed ? 0.96 : 1)
                .opacity(configuration.isPressed ? 0.8 : 1)
                .animation(SiteMotion.press, value: configuration.isPressed)
                .contentShape(Capsule())
        }
    }
}

/// White pill with Google's "G", per Google's sign-in branding.
private struct GoogleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(ThermyxFont.buttonLabel)
            .foregroundStyle(Color(hex: 0x1F1F1F))
            .frame(maxWidth: .infinity)
            .frame(minHeight: 56)
            .background(Color.white, in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(SiteMotion.press, value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

// MARK: - Endorsements

/// The endorsements, running across the top on a loop like React Bits'
/// Logo Loop, in gold. Add an organisation to `items` as more come in.
struct EndorsementLoop: View {
    enum Item: Hashable {
        case siteGuardian
        case congressionalAppChallenge
    }

    var items: [Item] = [.siteGuardian, .congressionalAppChallenge]
    /// Points per second.
    var speed: Double = 32

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var width: CGFloat = 0

    static let gold = LinearGradient(
        colors: [Color(hex: 0xF7E7B0), Color(hex: 0xD9A84B), Color(hex: 0xF2D68A), Color(hex: 0xB8862E)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    var body: some View {
        HStack(spacing: Thermyx.Space.m) {
            Text("Endorsed by")
                .narrowLabel(ThermyxFont.zoneLabel, tracking: ThermyxTracking.zoneLabel, color: Color(hex: 0xD9B56A))
                .fixedSize()
            // An overlay, so the long strip never widens the layout.
            Color.clear
                .frame(maxWidth: .infinity)
                .overlay(alignment: .leading) {
                    TimelineView(.animation(paused: reduceMotion)) { context in
                        let t = context.date.timeIntervalSinceReferenceDate
                        let shift = width > 0 && !reduceMotion ? CGFloat((t * speed).truncatingRemainder(dividingBy: Double(width))) : 0
                        HStack(spacing: 0) {
                            row.onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
                            row
                            row
                        }
                        .offset(x: -shift)
                    }
                }
                .clipped()
            .mask {
                HStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing).frame(width: 24)
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 24)
                }
            }
        }
        .frame(height: 34)
        .padding(.horizontal, Thermyx.Space.l)
        .siteGlass(radius: 17)
        .padding(.horizontal, Thermyx.Space.wide)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Endorsed by SiteGuardian US and the Congressional App Challenge")
    }

    private var row: some View {
        HStack(spacing: 28) {
            ForEach(items, id: \.self) { item in
                logo(item)
            }
        }
        .padding(.trailing, 28)
        .fixedSize()
    }

    @ViewBuilder
    private func logo(_ item: Item) -> some View {
        switch item {
        case .siteGuardian:
            Self.gold.mask {
                Image("SiteGuardianLogo").resizable().scaledToFit()
            }
            .frame(width: 112, height: 15)
        case .congressionalAppChallenge:
            HStack(spacing: 7) {
                Self.gold.mask { Image("CongressionalAppChallenge").resizable().scaledToFit() }
                    .frame(width: 20, height: 20)
                Self.gold.mask {
                    Text("Congressional App Challenge")
                        .font(.custom(ThermyxFont.Family.semibold, size: 13))
                        .fixedSize()
                }
                .frame(width: 186, height: 16)
            }
        }
    }
}

// MARK: - Video

/// A slide's video: silent, looping, playing by itself while its slide is
/// shown. The clips are portrait (600 × 1080), so the frame takes their
/// shape and nothing is cut off. Until a file is bundled, an empty frame
/// holds its place.
struct SlideVideo: View {
    let name: String
    var isPlaying: Bool

    /// The bundled clips' width over height.
    static let aspect: CGFloat = 600.0 / 1080.0

    var body: some View {
        if let url = Bundle.main.url(forResource: name, withExtension: "mp4") {
            framed(LoopingVideo(url: url, isPlaying: isPlaying))
                .overlay { ThermalBorder(radius: Thermyx.Radius.readout, isRunning: isPlaying) }
                .aspectRatio(Self.aspect, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            framed(Color.clear)
        }
    }

    private func framed<Content: View>(_ content: Content) -> some View {
        content
            .background(Thermyx.Site.surface)
            .clipShape(RoundedRectangle(cornerRadius: Thermyx.Radius.readout, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Thermyx.Radius.readout, style: .continuous)
                    .strokeBorder(Thermyx.Site.hairline, lineWidth: 1)
            }
            .accessibilityHidden(true)
    }
}

/// The video's border: half ember orange, half ice blue, soft where they
/// meet, the two halves circling the frame. Under it, a blurred copy for a
/// glow. Holds still under Reduce Motion or while its slide is off screen.
private struct ThermalBorder: View {
    let radius: CGFloat
    var isRunning: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Seconds per full turn.
    private static let period = 6.0

    var body: some View {
        TimelineView(.animation(paused: reduceMotion || !isRunning)) { context in
            let turn = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.period) / Self.period
            let gradient = AngularGradient(
                stops: [
                    .init(color: Thermyx.Ink.ice, location: 0),
                    .init(color: Thermyx.Ink.signal, location: 0.38),
                    .init(color: Thermyx.Ink.ember, location: 0.5),
                    .init(color: Thermyx.Ink.amber, location: 0.88),
                    .init(color: Thermyx.Ink.ice, location: 1),
                ],
                center: .center,
                angle: .degrees(turn * 360)
            )
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            ZStack {
                shape.strokeBorder(gradient, lineWidth: 6)
                    .blur(radius: 10)
                    .opacity(0.55)
                shape.strokeBorder(gradient, lineWidth: 2)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct LoopingVideo: UIViewRepresentable {
    let url: URL
    var isPlaying: Bool

    func makeUIView(context: Context) -> PlayerView {
        // Never interrupts what the wearer is listening to.
        try? AVAudioSession.sharedInstance().setCategory(.ambient, options: .mixWithOthers)
        let item = AVPlayerItem(url: url)
        let player = AVQueuePlayer()
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        context.coordinator.looper = AVPlayerLooper(player: player, templateItem: item)
        let view = PlayerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ view: PlayerView, context: Context) {
        context.coordinator.player = view.playerLayer.player
        context.coordinator.isPlaying = isPlaying
        if isPlaying { view.playerLayer.player?.play() } else { view.playerLayer.player?.pause() }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Keeps the loop alive, and picks playback back up when the app
    /// returns to the foreground, which pauses every player.
    final class Coordinator {
        var looper: AVPlayerLooper?
        weak var player: AVPlayer?
        var isPlaying = false
        private var observer: NSObjectProtocol?

        init() {
            observer = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                guard let self, self.isPlaying else { return }
                self.player?.play()
            }
        }

        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    }

    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
