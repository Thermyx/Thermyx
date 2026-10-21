import SwiftUI

/// AI Insights, on or off. It sits apart in deep purple because it's the
/// one feature that asks an outside model, and it says so up front: what it
/// uses (a Claude API key, through the relay), what it sends, and which
/// documents cover it.
struct AIInsightsToggle: View {
    @Binding var isOn: Bool
    /// Opens the Privacy Policy or Terms of Service.
    let onOpenLegal: (LegalDocument.Kind) -> Void

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: Thermyx.Radius.list, style: .continuous) }

    var body: some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.m) {
            Toggle(isOn: $isOn.animation(SiteMotion.settle)) {
                HStack(spacing: Thermyx.Space.m) {
                    AIMark(size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("AI Insights")
                            .font(ThermyxFont.rowTitle)
                            .foregroundStyle(Thermyx.Ink.textPrimary)
                        Text("Daily summaries and next steps, written by AI")
                            .font(ThermyxFont.captionSmall)
                            .foregroundStyle(Thermyx.Ink.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .tint(Thermyx.Ink.aiDeep)
            .sensoryFeedback(.selection, trigger: isOn)

            ClaudeKeyFlag()

            Text("Runs on Anthropic's Claude API through the Thermyx relay. Only a day's totals and averages are sent, never live readings, your name or where you are, and nothing is sent while this is off. Covered in the [Privacy Policy](thermyx://legal/privacy) and [Terms of Service](thermyx://legal/terms).")
                .font(ThermyxFont.captionSmall)
                .foregroundStyle(Thermyx.Ink.textMuted)
                .tint(Thermyx.Ink.ai)
                .fixedSize(horizontal: false, vertical: true)
                .environment(\.openURL, OpenURLAction { url in
                    onOpenLegal(url.lastPathComponent == "terms" ? .terms : .privacy)
                    return .handled
                })
        }
        .padding(Thermyx.Space.l)
        .background {
            shape.fill(LinearGradient(colors: [Thermyx.Tint.aiFill, Thermyx.Tint.aiFill.opacity(0.25)],
                                      startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        .overlay { shape.strokeBorder(isOn ? Thermyx.Tint.aiBorder : Thermyx.Tint.aiBorder.opacity(0.45), lineWidth: 1) }
        .shadow(color: Thermyx.Ink.aiDeep.opacity(isOn ? 0.35 : 0), radius: 18)
        .animation(SiteMotion.settle, value: isOn)
    }
}

/// The AI Insights mark: sparkles on a deep purple tile.
struct AIMark: View {
    var size: CGFloat = 36

    var body: some View {
        Image(systemName: "sparkles")
            .font(.system(size: size * 0.44, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background {
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    .fill(LinearGradient(colors: [Color(hex: 0x8B5CF6), Thermyx.Ink.aiDeep, Color(hex: 0x3B1A9E)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
            }
            .accessibilityHidden(true)
    }
}

/// "Uses a Claude API key", with Claude's mark: the flag that this feature
/// talks to an outside model.
struct ClaudeKeyFlag: View {
    var body: some View {
        HStack(spacing: 7) {
            Image("ClaudeLogo")
                .renderingMode(.original)
                .resizable()
                .scaledToFit()
                .frame(width: 14, height: 14)
                .accessibilityHidden(true)
            Text("Uses a Claude API key")
                .font(.custom(ThermyxFont.Family.medium, size: 13, relativeTo: .caption))
                .foregroundStyle(Thermyx.Ink.ai)
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(Thermyx.Tint.aiFill, in: Capsule())
        .overlay { Capsule().strokeBorder(Thermyx.Tint.aiBorder, lineWidth: 1) }
        .accessibilityElement(children: .combine)
    }
}
