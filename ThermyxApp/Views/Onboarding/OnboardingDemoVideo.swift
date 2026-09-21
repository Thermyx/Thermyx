import AVFoundation
import SwiftUI

/// The looping walkthrough on the first onboarding screen.
///
/// A drawing of an insole tells someone what the product *is*. A recording of
/// the app being used tells them what it *does* — and that is the harder thing
/// to convey in four seconds before they decide whether to keep going.
///
/// Three behaviours matter:
///
/// - **It degrades.** If the asset is missing from the bundle the screen falls
///   back to the animated sole rather than showing a black rectangle. Shipping
///   a broken hero is worse than shipping the old one.
/// - **It respects Reduce Motion.** A looping video is exactly the kind of
///   motion that setting exists to stop, so it holds on the poster frame.
/// - **It is silent and cannot be controlled.** No audio session is activated,
///   so it never interrupts music, and there is no scrubber to fiddle with.
struct OnboardingDemoVideo: View {
    /// Bundled resource name, without extension.
    static let resourceName = "onboarding-walkthrough"
    static let resourceExtension = "mp4"

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var poster: Image?

    private static var url: URL? {
        Bundle.main.url(forResource: resourceName, withExtension: resourceExtension)
    }

    var body: some View {
        Group {
            if let url = Self.url {
                if reduceMotion {
                    posterView(for: url)
                } else {
                    LoopingVideoView(url: url)
                }
            } else {
                // No recording bundled yet: the original animated sole still
                // does the job, so the screen is never empty.
                FloatingSole()
            }
        }
        .aspectRatio(0.45, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: Thermyx.Radius.hero, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Thermyx.Radius.hero, style: .continuous)
                .strokeBorder(Thermyx.Tint.neutralBorder, lineWidth: Thermyx.Stroke.hairline)
        }
        .accessibilityElement()
        .accessibilityLabel("A walkthrough of the Thermyx app showing live insole readings")
    }

    @ViewBuilder
    private func posterView(for url: URL) -> some View {
        ZStack {
            Thermyx.Ink.deck
            if let poster {
                poster.resizable().scaledToFill()
            }
        }
        .task { poster = await Self.posterFrame(for: url) }
    }

    /// First frame, used when motion is reduced.
    private static func posterFrame(for url: URL) async -> Image? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        guard let cgImage = try? await generator.image(at: .zero).image else { return nil }
        return Image(decorative: cgImage, scale: 1)
    }
}

/// A muted, looping, chrome-free video layer.
private struct LoopingVideoView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.configure(with: url)
        return view
    }

    func updateUIView(_ uiView: PlayerView, context: Context) {}

    static func dismantleUIView(_ uiView: PlayerView, coordinator: ()) {
        uiView.stop()
    }
}

private final class PlayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    private var looper: AVPlayerLooper?
    private var queuePlayer: AVQueuePlayer?

    private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    func configure(with url: URL) {
        let item = AVPlayerItem(url: url)
        let player = AVQueuePlayer()
        // Never activate an audio session: the walkthrough must not duck or
        // stop whatever the user is listening to.
        player.isMuted = true
        player.actionAtItemEnd = .advance
        looper = AVPlayerLooper(player: player, templateItem: item)
        queuePlayer = player

        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspectFill
        backgroundColor = UIColor(Thermyx.Ink.deck)

        player.play()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(resume),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    @objc private func resume() { queuePlayer?.play() }

    func stop() {
        queuePlayer?.pause()
        NotificationCenter.default.removeObserver(self)
    }

    deinit { NotificationCenter.default.removeObserver(self) }
}

/// The original hero, kept as the fallback.
struct FloatingSole: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var floating = false

    var body: some View {
        SoleShape(foot: .left)
            .fill(
                LinearGradient(
                    stops: [
                        .init(color: Thermyx.Ink.ember.opacity(0.22), location: 0),
                        .init(color: Thermyx.Ink.deck, location: 0.45),
                        .init(color: Thermyx.Ink.signal.opacity(0.22), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay {
                SoleShape(foot: .left)
                    .stroke(
                        LinearGradient(
                            colors: [Thermyx.Ink.ember, Thermyx.Ink.signal, Thermyx.Ink.ice],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 2.5
                    )
            }
            .aspectRatio(SoleShape.widthRatio, contentMode: .fit)
            .offset(y: floating ? -14 : 0)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 6).repeatForever(autoreverses: true)) {
                    floating = true
                }
            }
            .accessibilityHidden(true)
    }
}
