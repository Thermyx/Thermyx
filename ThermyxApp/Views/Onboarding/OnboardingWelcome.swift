import AVKit
import SwiftUI

/// The first screen: the insole itself, to turn, take apart and tap, then
/// what Thermyx is and Google sign-in.
struct WelcomeScreen: View {
    @EnvironmentObject private var account: ThermyxAccountStore
    let onContinue: () -> Void

    @State private var exploded: Bool = {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-ThermyxExplode")
        #else
        return false
        #endif
    }()
    @State private var selected: InsolePart?
    @State private var legal: LegalDocument.Kind?
    @State private var showingVideo = false

    /// An app walkthrough video, if one has been added to Resources/Media
    /// (see the README there). Without it, the link doesn't appear.
    static var videoURL: URL? { Bundle.main.url(forResource: "onboarding-walkthrough", withExtension: "mp4") }

    var body: some View {
        VStack(spacing: 0) {
            model
                .frame(maxHeight: .infinity)
            brand
                .padding(.horizontal, Thermyx.Space.wide)
                .padding(.top, 14)
                .padding(.bottom, 8)
        }
        .sheet(item: $legal) { kind in LegalSheet(selection: kind) }
        .fullScreenCover(isPresented: $showingVideo) {
            if let url = Self.videoURL { WalkthroughVideo(url: url) }
        }
    }

    // MARK: Model

    /// The button takes it apart, a drag turns it, a tap picks a part.
    private var model: some View {
        ZStack(alignment: .bottom) {
            InsoleStack(exploded: exploded, selected: $selected)
                // A faint ice halo that follows the model's outline.
                .shadow(color: Thermyx.Ink.ice.opacity(0.28), radius: 22)
                .padding(.bottom, 64)
                .accessibilityLabel("The Thermyx insole and power pack, \(exploded ? "taken apart" : "assembled"). Drag to turn it; tap a part to see what it does.")

            VStack(spacing: 6) {
                ExplodeButton(exploded: $exploded)
                Text("Drag to turn · tap a part")
                    .font(ThermyxFont.captionSmall)
                    .foregroundStyle(Thermyx.Ink.textFaint)
                    .accessibilityHidden(true)
            }
            .padding(.bottom, 4)
        }
        // The picked part's card sits over the top of the model's space, so
        // it never hides the part it describes.
        .overlay(alignment: .top) {
            if let part = selected {
                PartCallout(part: part) { selected = nil }
                    .padding(.horizontal, Thermyx.Space.wide)
                    .padding(.top, 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(SiteMotion.settle, value: selected)
    }

    // MARK: Brand and sign-in

    private var brand: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image("ThermyxMark")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 30, height: 30)
                        .accessibilityHidden(true)
                    Text("Thermyx")
                        .font(.custom(ThermyxFont.Family.bold, size: 22, relativeTo: .title2))
                        .tracking(-0.4)
                        .foregroundStyle(Thermyx.Ink.textPrimary)
                }
                Text("Smart insoles that heat and cool your feet, and track temperature, load and steps under both of them, live.")
                    .font(ThermyxFont.body)
                    .lineSpacing(2)
                    .foregroundStyle(Thermyx.Ink.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                if Self.videoURL != nil {
                    Button {
                        showingVideo = true
                    } label: {
                        Label("Watch the walkthrough", systemImage: "play.circle")
                            .font(ThermyxFont.controlLabel)
                            .foregroundStyle(Thermyx.Ink.ice)
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                }
            }
            signIn
        }
    }

    @ViewBuilder
    private var signIn: some View {
        if let current = account.account {
            VStack(spacing: 6) {
                Button(action: onContinue) {
                    Text(current.displayName.map { "Continue as \($0.components(separatedBy: " ").first ?? $0)" } ?? "Continue")
                }
                .buttonStyle(ThermyxPrimaryButtonStyle())
                Button("Not you? Sign out") { account.signOut() }
                    .buttonStyle(SiteTextButtonStyle())
            }
        } else {
            VStack(spacing: 12) {
                Button {
                    Task {
                        await account.signInWithGoogle()
                        if account.isSignedIn { onContinue() }
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image("GoogleG").resizable().scaledToFit().frame(width: 20, height: 20)
                        Text("Continue with Google")
                    }
                    .opacity(account.isWorking ? 0 : 1)
                    .overlay { if account.isWorking { ProgressView().tint(.black) } }
                }
                .buttonStyle(ThermyxPrimaryButtonStyle())
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
                    .foregroundStyle(Thermyx.Ink.textFaint)
                    .tint(Thermyx.Ink.textMuted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .environment(\.openURL, OpenURLAction { url in
                        legal = url.lastPathComponent == "terms" ? .terms : .privacy
                        return .handled
                    })
            }
        }
    }
}

// MARK: - Pieces

/// What a tapped part is, from the website's component copy.
private struct PartCallout: View {
    let part: InsolePart
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Thermyx.Space.m) {
            VStack(alignment: .leading, spacing: 4) {
                Text(part.product)
                    .font(.custom(ThermyxFont.Family.medium, size: 13, relativeTo: .footnote))
                    .foregroundStyle(Thermyx.Ink.ice)
                Text(part.label)
                    .font(ThermyxFont.cardTitle)
                    .foregroundStyle(Thermyx.Ink.textPrimary)
                Text(part.role)
                    .font(ThermyxFont.caption)
                    .foregroundStyle(Thermyx.Ink.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = part.detail {
                    Text(detail)
                        .font(ThermyxFont.monoCaption)
                        .foregroundStyle(Thermyx.Ink.textFaint)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Thermyx.Ink.textMuted)
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
/// as the one action on the model without competing with sign-in.
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

/// The walkthrough, full screen with the system's player controls.
private struct WalkthroughVideo: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            if let player {
                VideoPlayer(player: player).ignoresSafeArea()
            }
            Button("Done") { dismiss() }
                .font(ThermyxFont.controlLabel)
                .foregroundStyle(Thermyx.Ink.textPrimary)
                .padding(.horizontal, 16)
                .frame(height: 40)
                .background(.black.opacity(0.6), in: Capsule())
                .padding(16)
        }
        .onAppear {
            let p = AVPlayer(url: url)
            player = p
            p.play()
        }
        .onDisappear { player?.pause() }
    }
}
