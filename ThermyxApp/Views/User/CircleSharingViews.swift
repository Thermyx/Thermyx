import SwiftUI

// What the wearer's trusted circle gets, and when: the one-time explanation
// shown when they add their first contact or invite their first watcher, the
// settings that shape every alert (their name, location), and the text
// itself, drawn as the contact will see it.

/// A text from Thermyx, drawn as it lands on a contact's phone: the first
/// line bold, a map link tinted, nothing else styled.
struct CircleMessageBubble: View {
    let text: String
    var caption: String? = "Text from Thermyx"

    private var lines: [String] { text.components(separatedBy: "\n") }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let caption {
                Text(caption)
                    .font(ThermyxFont.captionSmall)
                    .foregroundStyle(Thermyx.Ink.textFaint)
                    .padding(.leading, 4)
            }
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    Text(line)
                        .font(index == 0 ? .custom(ThermyxFont.Family.semibold, size: 15, relativeTo: .body) : ThermyxFont.bodySmall)
                        .foregroundStyle(line.contains("https://") ? Color(hex: 0x0B3D1A) : Color(hex: 0x06210E))
                        .lineLimit(line.contains("https://") ? 1 : nil)
                        .truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: !line.contains("https://"))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(Color(hex: 0x39FF5A), in: BubbleShape())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Example text: \(text)")
    }

    /// A message bubble: rounded on every corner except the bottom left,
    /// which comes to a point, like a text message.
private struct BubbleShape: Shape {
    func path(in rect: CGRect) -> Path {
        let r: CGFloat = 18
        let tailWidth: CGFloat = 13
        let tailHeight: CGFloat = 7
        
        var p = Path()
        
        // Top edge and upper-right corner
        p.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        p.addArc(
            center: CGPoint(x: rect.maxX - r, y: rect.minY + r),
            radius: r,
            startAngle: .degrees(-90),
            endAngle: .degrees(0),
            clockwise: false
        )
        
        // Right edge and lower-right corner
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        p.addArc(
            center: CGPoint(x: rect.maxX - r, y: rect.maxY - r),
            radius: r,
            startAngle: .degrees(0),
            endAngle: .degrees(90),
            clockwise: false
        )
        
        // Bottom edge into a smooth, tapered left tail
        p.addLine(to: CGPoint(
            x: rect.minX + tailWidth,
            y: rect.maxY
        ))
        
        p.addQuadCurve(
            to: CGPoint(
                x: rect.minX - 2,
                y: rect.maxY + tailHeight
            ),
            control: CGPoint(
                x: rect.minX + 5,
                y: rect.maxY + 1
            )
        )
        
        p.addQuadCurve(
            to: CGPoint(
                x: rect.minX + 1,
                y: rect.maxY - tailHeight - 3
            ),
            control: CGPoint(
                x: rect.minX + 1,
                y: rect.maxY - 2
            )
        )
        
        // Left edge and upper-left corner
        p.addLine(to: CGPoint(
            x: rect.minX,
            y: rect.minY + r
        ))
        p.addArc(
            center: CGPoint(x: rect.minX + r, y: rect.minY + r),
            radius: r,
            startAngle: .degrees(180),
            endAngle: .degrees(270),
            clockwise: false
        )
        
        p.closeSubpath()
        return p
    }
    }
}

/// "What your circle gets": when Thermyx tells them, what it says, where
/// location fits in and when it stops, and what happens if the wearer's phone
/// goes quiet. Shown once before anyone is added, and any time after from
/// Safety.
struct CircleSharingSheet: View {
    @ObservedObject var settings: ThermyxSettingsStore
    @ObservedObject var alerts: ThermyxAlertCoordinator
    let reading: BilateralReading
    /// Runs after "Got it" the first time (e.g. to go on to the invite).
    var onAcknowledge: () -> Void = {}

    @EnvironmentObject private var account: ThermyxAccountStore
    @Environment(\.dismiss) private var dismiss
    @State private var shareLocation = true
    @FocusState private var nameFocused: Bool

    private var firstTime: Bool { !settings.circlePrivacyAcknowledged }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Thermyx.Space.xl) {
                    VStack(alignment: .leading, spacing: Thermyx.Space.xs) {
                        Text("What your circle gets")
                            .font(ThermyxFont.sectionTitle)
                            .foregroundStyle(Thermyx.Ink.textPrimary)
                            .accessibilityAddTraits(.isHeader)
                        Text("Your trusted contacts get texts. Watchers you approve see the same facts in their Thermyx app.")
                            .font(ThermyxFont.bodySmall)
                            .foregroundStyle(Thermyx.Ink.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: 0) {
                        point("bell.badge", "When",
                              "At High risk and Critical, when you press Call 911, and when you don't answer a Critical alert. Caution too, if you turn it on. Then a follow-up if it lasts, when it eases, and when you tap I'm OK.")
                        point("text.bubble", "What",
                              "Your name, the level, which foot, its temperature at the insole and whether it's rising, whether the data is solid, and a low battery. Never your history, a live feed or your controls.")
                        point("antenna.radiowaves.left.and.right.slash", "If your phone goes quiet",
                              "During an emergency, if your phone stops updating for 3 minutes, Thermyx tells them so they can check on you.",
                              isLast: true)
                    }

                    nameField

                    locationCard

                    CircleMessageBubble(text: alerts.previewMessage(reading: reading, settings: settings, shareLocation: shareLocation),
                                        caption: "Example text")
                }
                .padding(.horizontal, Thermyx.Space.screen)
                .padding(.top, Thermyx.Space.m)
                .padding(.bottom, Thermyx.Space.xxl)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom) {
                Button(firstTime ? "Got it" : "Done") { finish() }
                    .buttonStyle(ThermyxPrimaryButtonStyle())
                    .padding(.horizontal, Thermyx.Space.screen)
                    .padding(.vertical, Thermyx.Space.m)
                    .background(Thermyx.Ink.midnight)
            }
            .toolbar {
                if !firstTime {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Close") { finish() }
                    }
                }
            }
        }
        .interactiveDismissDisabled(firstTime)
        .onAppear {
            shareLocation = firstTime ? true : settings.shareLocationDuringEvents
            if settings.circleName.trimmingCharacters(in: .whitespaces).isEmpty,
               let first = account.account?.displayName?.split(separator: " ").first {
                settings.circleName = String(first)
            }
        }
    }

    private func point(_ symbol: String, _ title: String, _ detail: String, isLast: Bool = false) -> some View {
        HStack(alignment: .top, spacing: Thermyx.Space.m) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Thermyx.Ink.ice)
                .frame(width: 32, height: 32)
                .background(Thermyx.Tint.liveFill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(ThermyxFont.rowTitle)
                    .foregroundStyle(Thermyx.Ink.textPrimary)
                Text(detail)
                    .font(ThermyxFont.bodySmall)
                    .foregroundStyle(Thermyx.Ink.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, Thermyx.Space.m)
        .overlay(alignment: .bottom) { if !isLast { ThermyxDivider().padding(.leading, 44) } }
        .accessibilityElement(children: .combine)
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.xs) {
            SectionLabel("Your name in alerts")
            TextField("First name", text: $settings.circleName)
                .textContentType(.givenName)
                .textInputAutocapitalization(.words)
                .submitLabel(.done)
                .focused($nameFocused)
                .font(ThermyxFont.body)
                .foregroundStyle(Thermyx.Ink.textPrimary)
                .padding(.horizontal, Thermyx.Space.l)
                .frame(minHeight: 50)
                .background(Thermyx.Ink.deck, in: RoundedRectangle(cornerRadius: Thermyx.Radius.control, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Thermyx.Radius.control, style: .continuous)
                        .strokeBorder(nameFocused ? Thermyx.Tint.liveBorder : Thermyx.Ink.hairline, lineWidth: 1)
                }
            Text(settings.circleName.trimmingCharacters(in: .whitespaces).isEmpty
                 ? "Without a name, texts say \"your contact\"."
                 : "Texts start \"Thermyx High-Risk Alert - \(settings.circleName.trimmingCharacters(in: .whitespaces))\".")
                .font(ThermyxFont.captionSmall)
                .foregroundStyle(Thermyx.Ink.textFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var locationCard: some View {
        ThermyxGroupedCard {
            VStack(alignment: .leading, spacing: Thermyx.Space.s) {
                Toggle(isOn: $shareLocation.animation(SiteMotion.settle)) {
                    Text("Share my location in emergencies")
                        .font(ThermyxFont.body)
                        .foregroundStyle(Thermyx.Ink.textPrimary)
                }
                .tint(Thermyx.Ink.signal)
                Text(shareLocation
                     ? "Only at High risk, Critical and SOS: a map link in the text, and on watchers' screens until the emergency ends or for an hour at most. Never at other times, never stored after."
                     : "Texts will say \"Location not shared\". Your circle won't know where to find you in an emergency.")
                    .font(ThermyxFont.captionSmall)
                    .foregroundStyle(shareLocation ? Thermyx.Ink.textSupporting : Thermyx.Ink.amber)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
            }
            .padding(.horizontal, Thermyx.Space.xl)
            .padding(.vertical, Thermyx.Space.m)
        }
    }

    private func finish() {
        let wasFirst = firstTime
        if shareLocation {
            settings.shareLocationDuringEvents = true
            alerts.location.requestPermission()
        } else if settings.shareLocationDuringEvents || wasFirst {
            alerts.stopSharingLocation(level: .normal, settings: settings)
        }
        settings.circleName = settings.circleName.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.circlePrivacyAcknowledged = true
        dismiss()
        if wasFirst { onAcknowledge() }
    }
}

/// Below the contacts on Safety: the name alerts carry, whether location is
/// shared, and the way back to the full explanation.
struct CircleSettingsRows: View {
    @ObservedObject var settings: ThermyxSettingsStore
    @ObservedObject var alerts: ThermyxAlertCoordinator
    let level: ThermyxRiskLevel
    let onExplain: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.s) {
            Button(action: onExplain) {
                HStack(spacing: Thermyx.Space.m) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("What your circle gets")
                            .font(ThermyxFont.rowTitle)
                            .foregroundStyle(Thermyx.Ink.textPrimary)
                        Text(summary)
                            .font(ThermyxFont.captionSmall)
                            .foregroundStyle(Thermyx.Ink.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: Thermyx.Space.xs)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Thermyx.Ink.textFaint)
                }
                .padding(.vertical, Thermyx.Space.m)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Your name in alerts, location, and an example text.")

            if settings.shareLocationDuringEvents && level.severity >= ThermyxRiskLevel.high.severity {
                Button {
                    alerts.stopSharingLocation(level: level, settings: settings)
                } label: {
                    Label("Stop sharing location", systemImage: "location.slash.fill")
                }
                .buttonStyle(ThermyxPrimaryButtonStyle(fill: Thermyx.Ink.amber, foreground: Thermyx.Ink.onEmber))
            }
        }
    }

    private var summary: String {
        let name = settings.circleName.trimmingCharacters(in: .whitespaces)
        let who = name.isEmpty ? "No name set" : "As \(name)"
        return "\(who) · location in emergencies \(settings.shareLocationDuringEvents ? "on" : "off")"
    }
}
