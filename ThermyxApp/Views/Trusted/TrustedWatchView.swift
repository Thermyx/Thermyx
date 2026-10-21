import SwiftUI
import UIKit

/// The watcher needs one answer: is this person okay, and do I act?
/// Status first, the instruction second, the numbers third.
struct TrustedWatchView: View {
    @ObservedObject var roles: ThermyxRoleStore
    @ObservedObject var member: TrustedMemberViewModel
    @ObservedObject var settings: ThermyxSettingsStore

    private var unit: TemperatureUnit { settings.temperatureUnit }
    private var event: ThermyxAlertEvent? { member.displayedEvent(deviceID: settings.deviceID) }
    private var card: ThermyxAlertAPIClient.WatchState? { member.card }
    private var level: ThermyxRiskLevel { event.flatMap { ThermyxRiskLevel(rawValue: $0.level) } ?? .unavailable }
    /// The name the wearer chose, else the one this watcher saved.
    private var name: String { card?.detail?.name ?? roles.watchedUserName }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Thermyx.Space.l) {
                    header

                    if let event {
                        silenceWarning
                        HandoffStatusCard(level: level, card: card, updated: event.timestamp, unit: unit)
                        NextStepCard(level: level, card: card, name: name, phone: contactNumber)
                        if let timeline = card?.timeline, !timeline.isEmpty {
                            EventTimeline(entries: timeline)
                        }
                        Text("You see what Thermyx sees right now, never their history or a live feed, and you can't change their insoles.")
                            .font(ThermyxFont.captionSmall)
                            .foregroundStyle(Thermyx.Ink.textFaint)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Spacer(minLength: Thermyx.Space.xxl)
                        ThermyxEmptyState(
                            title: emptyTitle,
                            message: emptyMessage,
                            systemImage: member.access == .pending ? "hourglass" : "antenna.radiowaves.left.and.right"
                        )
                        Spacer(minLength: Thermyx.Space.xxl)
                    }

                    if let error = member.lastError {
                        Text(error)
                            .font(ThermyxFont.captionSmall)
                            .foregroundStyle(Thermyx.Ink.amber)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, Thermyx.Space.screen)
                .padding(.bottom, Thermyx.Space.xxl)
                .frame(maxHeight: .infinity)
                .animation(SiteMotion.settle, value: card)
                Color.clear.frame(height: 1).id("end")
            }
            .debugScroll(proxy)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
            .background(Thermyx.Ink.midnight)
            .thermyxTopScrim()
        }
    }

    private var emptyTitle: String {
        switch member.access {
        case .notConnected: return "Not connected"
        case .pending: return "Waiting for approval"
        case .removed: return "Access removed"
        case .approved: return "No status shared yet"
        }
    }

    private var emptyMessage: String {
        switch member.access {
        case .notConnected:
            return "Ask \(roles.watchedUserName) to invite you from their Safety screen, then enter the code under Settings → Relay."
        case .pending:
            return "\(roles.watchedUserName) needs to approve you on their phone. You'll see nothing until they do."
        case .removed:
            return "\(roles.watchedUserName) removed your access, or it expired. Ask them for a new invite."
        case .approved:
            return "You're approved. Their status appears here once their insoles connect and their phone shares it."
        }
    }

    private var header: some View {
        HStack(spacing: Thermyx.Space.m) {
            Circle()
                .fill(Thermyx.Ink.elevated)
                .frame(width: 42, height: 42)
                .overlay {
                    Text(name.thermyxInitials)
                        .font(ThermyxFont.rowTitle)
                        .foregroundStyle(Thermyx.Ink.ice)
                }

            VStack(alignment: .leading, spacing: 1) {
                Text("Trusted circle")
                    .narrowLabel(ThermyxFont.zoneLabel, tracking: 2.4, color: Thermyx.Ink.ice)
                Text(name)
                    .font(ThermyxFont.cardTitle)
                    .tracking(-0.3)
                    .foregroundStyle(Thermyx.Ink.textPrimary)
            }

            Spacer(minLength: Thermyx.Space.xs)

            if member.isConnected {
                StatusPill.live()
            } else {
                StatusPill.offline()
            }
        }
        .padding(.top, Thermyx.Space.m)
    }

    /// Shown when the wearer's phone has gone quiet. Their app posts at least
    /// once a minute while an insole is connected, so silence is itself news.
    private var silenceWarning: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            if let silence = member.silence(now: context.date), silence >= TrustedMemberViewModel.silenceWarning {
                ThermyxCard(fill: Thermyx.Tint.amberFill, border: Thermyx.Tint.amberBorder) {
                    VStack(alignment: .leading, spacing: Thermyx.Space.header) {
                        SectionLabel("No update for \(Int(silence / 60)) min", color: Thermyx.Ink.amber)
                        Text("Their phone, signal, or insoles may be off. What's below is the last status received, not a live one. Check in with them directly.")
                            .font(ThermyxFont.caption)
                            .foregroundStyle(Thermyx.Ink.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var contactNumber: String? {
        let number = roles.watchedUserPhone.trimmingCharacters(in: .whitespacesAndNewlines)
        return number.isEmpty ? nil : number
    }
}

// MARK: - Status

/// The handoff: how serious, what the insoles saw and on which foot, the
/// temperature and its direction, whether the data can be relied on, how
/// fresh it is, and whether they've checked in.
struct HandoffStatusCard: View {
    let level: ThermyxRiskLevel
    let card: ThermyxAlertAPIClient.WatchState?
    let updated: Date
    let unit: TemperatureUnit

    private var detail: ThermyxCircleDetail? { card?.detail }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: Thermyx.Radius.readout, style: .continuous) }

    var body: some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.l) {
            HStack(alignment: .firstTextBaseline, spacing: Thermyx.Space.s) {
                Image(systemName: level.severity >= 1 ? "exclamationmark.triangle.fill" : "checkmark.shield.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(level.tint)
                Text(level.rawValue)
                    .narrowLabel(ThermyxFont.riskHeadline, tracking: ThermyxTracking.riskHeadline, color: level.tint)
                Spacer(minLength: Thermyx.Space.xs)
                if let since = card?.sinceDate, level.severity >= 1 {
                    Text("since \(since.formatted(date: .omitted, time: .shortened))")
                        .font(ThermyxFont.monoCaption)
                        .foregroundStyle(Thermyx.Ink.textMuted)
                }
            }
            .accessibilityElement(children: .combine)

            Text(headline)
                .font(ThermyxFont.bodyLarge)
                .lineSpacing(3)
                .foregroundStyle(Thermyx.Ink.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            if let detail, detail.footC != nil || detail.foot != nil {
                readout(detail)
            }

            if let checkIn = latestCheckIn {
                Label("Checked in at \(checkIn.formatted(date: .omitted, time: .shortened)): says they're OK", systemImage: "hand.thumbsup.fill")
                    .font(ThermyxFont.caption)
                    .foregroundStyle(Thermyx.Ink.ice)
                    .padding(.horizontal, Thermyx.Space.m)
                    .frame(minHeight: 36)
                    .background(Thermyx.Tint.liveFill, in: Capsule())
            }

            facts
        }
        .padding(Thermyx.Space.hero)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(level.fill, in: shape)
        .overlay { shape.strokeBorder(level.border, lineWidth: Thermyx.Stroke.hairline) }
    }

    private var headline: String {
        if let headline = ThermyxCircleMessage.headline(detail) { return headline }
        if isRecovering { return "Recovering: readings are easing." }
        switch level {
        case .normal: return "All readings look normal."
        case .caution: return "Readings deserve a check-in."
        case .high: return "Readings are at High risk."
        case .critical: return "Readings are at Critical."
        case .unavailable: return "Waiting for readings from their insoles."
        }
    }

    /// Both soles, the affected one tinted by its temperature, and the
    /// number beside them. The other foot is only an outline: a watcher is
    /// told about the foot that matters, not given both feet's readings.
    private func readout(_ d: ThermyxCircleDetail) -> some View {
        HStack(alignment: .center, spacing: Thermyx.Space.l) {
            HStack(spacing: 5) {
                ForEach(Foot.allCases) { foot in
                    let lit = d.foot == "both" || d.affectedFoot == foot
                    VStack(spacing: 4) {
                        FootMap(foot: foot, content: lit ? .temperature(d.footC) : .outline(dimmed: true))
                            .frame(width: 34, height: 74)
                        Text(foot == .left ? "L" : "R")
                            .font(ThermyxFont.monoCaption)
                            .foregroundStyle(lit ? Thermyx.Ink.textSecondary : Thermyx.Ink.textFaint)
                    }
                }
            }
            .accessibilityHidden(true)

            if let c = d.footC {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(TemperatureFormat.value(c, in: unit))
                            .font(ThermyxFont.statNumeral)
                            .monospacedDigit()
                            .foregroundStyle(FootScale.thermalColor(c))
                            .contentTransition(.numericText())
                        Text(unit.symbol)
                            .font(ThermyxFont.caption)
                            .foregroundStyle(Thermyx.Ink.textMuted)
                    }
                    HStack(spacing: 5) {
                        if let trend = d.trend {
                            Image(systemName: trend == "rising" ? "arrow.up.right" : trend == "falling" ? "arrow.down.right" : "arrow.right")
                                .font(.system(size: 12, weight: .bold))
                            Text(trend)
                        }
                        Text(d.trend == nil ? "at the insole" : "· at the insole")
                            .foregroundStyle(Thermyx.Ink.textFaint)
                    }
                    .font(ThermyxFont.caption)
                    .foregroundStyle(trendTint(d.trend))
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(placeLabel(d)) temperature at the insole")
                .accessibilityValue("\(TemperatureFormat.full(c, in: unit))\(d.trend.map { ", \($0)" } ?? "")")
            }
            Spacer(minLength: 0)
        }
    }

    private func placeLabel(_ d: ThermyxCircleDetail) -> String {
        if d.foot == "both" { return "Both feet" }
        return [d.affectedFoot?.label, d.footZone?.label.lowercased()].compactMap { $0 }.joined(separator: " ")
    }

    private func trendTint(_ trend: String?) -> Color {
        switch trend {
        case "rising": return level.severity >= 1 ? Thermyx.Ink.ember : Thermyx.Ink.textSecondary
        case "falling": return Thermyx.Ink.ice
        default: return Thermyx.Ink.textSecondary
        }
    }

    /// Confidence and freshness always; battery and connection only when
    /// they matter.
    private var facts: some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.s) {
            ThermyxDivider()
            TimelineView(.periodic(from: .now, by: 5)) { context in
                HStack(spacing: Thermyx.Space.s) {
                    if let detail, detail.confidence != nil {
                        fact(detail.isConfirmed ? "checkmark.seal.fill" : "exclamationmark.circle",
                             detail.isConfirmed ? "Data confirmed" : "Limited data · check with them directly",
                             detail.isConfirmed ? Thermyx.Ink.ice : Thermyx.Ink.amber)
                    }
                    Spacer(minLength: 0)
                    Text(freshness(now: context.date))
                        .font(ThermyxFont.monoCaption)
                        .foregroundStyle(Thermyx.Ink.textMuted)
                        .monospacedDigit()
                }
            }
            if let battery = detail?.battery {
                fact(battery.percent <= ThermyxBattery.critical ? "battery.0percent" : "battery.25percent",
                     "\(battery.foot.capitalized) insole battery \(battery.percent)%", ThermyxBattery.tint(battery.percent))
            }
            if detail?.connection == "oneInsole" {
                fact("shoeprints.fill", "Only one insole connected", Thermyx.Ink.amber)
            } else if detail?.connection == "stale" {
                fact("clock.badge.exclamationmark", "Readings more than a minute old", Thermyx.Ink.amber)
            }
        }
    }

    private func fact(_ symbol: String, _ text: String, _ tint: Color) -> some View {
        Label {
            Text(text).foregroundStyle(Thermyx.Ink.textSecondary)
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
        .font(ThermyxFont.caption)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func freshness(now: Date) -> String {
        let age = max(0, now.timeIntervalSince(updated))
        if age < 60 { return "Updated \(Int(age)) s ago" }
        if age < 3600 { return "Updated \(Int(age / 60)) min ago" }
        return "Updated \(updated.formatted(date: .omitted, time: .shortened))"
    }

    private var isRecovering: Bool { card?.timeline?.last?.update == "recovering" && level.severity >= 1 }

    /// A check-in after the most recent alert, SOS or follow-up.
    private var latestCheckIn: Date? {
        guard let timeline = card?.timeline,
              let ok = timeline.lastIndex(where: { $0.kind == "ok" }) else { return nil }
        let laterAlarm = timeline[(ok + 1)...].contains { $0.kind == "alert" || $0.kind == "sos" }
        return laterAlarm ? nil : timeline[ok].date
    }
}

// MARK: - Next step

/// What to do now, by level, and what the wearer was asked to do, with the
/// buttons to do it.
struct NextStepCard: View {
    let level: ThermyxRiskLevel
    let card: ThermyxAlertAPIClient.WatchState?
    let name: String
    let phone: String?

    private var hadSOS: Bool { (card?.timeline ?? []).contains { $0.kind == "sos" || $0.kind == "help" } && card?.timeline?.last?.kind != "ok" }
    private var urgent: Bool { hadSOS || level.severity >= ThermyxRiskLevel.high.severity }
    /// Easing after an alert: the last word was "recovering".
    private var recovering: Bool { !urgent && card?.timeline?.last?.update == "recovering" }

    var body: some View {
        ThermyxCard(padding: Thermyx.Space.xl) {
            VStack(alignment: .leading, spacing: Thermyx.Space.m) {
                SectionLabel("Next step", color: urgent ? Thermyx.Ink.ember : Thermyx.Ink.ice)

                Text(action)
                    .font(.custom(ThermyxFont.Family.semibold, size: 19, relativeTo: .title3))
                    .lineSpacing(2)
                    .foregroundStyle(Thermyx.Ink.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                if let asked = ThermyxCircleMessage.wearerWasAsked(level: level.rawValue) {
                    Text(asked)
                        .font(ThermyxFont.bodySmall)
                        .foregroundStyle(Thermyx.Ink.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: Thermyx.Space.xs) {
                    if urgent {
                        Button { open("tel") } label: { Label("Call \(firstName)", systemImage: "phone.fill") }
                            .buttonStyle(ThermyxPrimaryButtonStyle())
                        Button { open("sms") } label: { Label("Message", systemImage: "message.fill") }
                            .buttonStyle(ThermyxSecondaryButtonStyle())
                    } else {
                        Button { open("sms") } label: { Label("Message", systemImage: "message.fill") }
                            .buttonStyle(ThermyxPrimaryButtonStyle())
                        Button { open("tel") } label: { Label("Call", systemImage: "phone.fill") }
                            .buttonStyle(ThermyxSecondaryButtonStyle())
                    }
                }
                .disabled(phone == nil)
                .opacity(phone == nil ? 0.5 : 1)

                if phone == nil {
                    Text("Add their number under Settings to call or message from here.")
                        .font(ThermyxFont.captionSmall)
                        .foregroundStyle(Thermyx.Ink.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if urgent { location }
            }
        }
    }

    private var firstName: String { name.split(separator: " ").first.map(String.init) ?? name }

    private var action: String {
        if level.severity < ThermyxRiskLevel.caution.severity && !hadSOS {
            return "Nothing to do right now. Thermyx will tell you if that changes."
        }
        if recovering {
            return "It's easing. Check in when you can; Thermyx will tell you if it rises again."
        }
        return ThermyxCircleMessage.action(level: level.rawValue, kind: hadSOS ? "sos" : "alert",
                                           hasLocation: card?.location != nil)
            ?? "Check in with them."
    }

    @ViewBuilder
    private var location: some View {
        if let mapsURL = card?.location?.mapsURL {
            Link(destination: mapsURL) {
                Label("Open their location in Maps", systemImage: "mappin.and.ellipse")
            }
            .buttonStyle(ThermyxSecondaryButtonStyle(tint: Thermyx.Ink.ice, border: Thermyx.Tint.liveBorder))
            if let expires = card?.location?.expiresAt.flatMap(ThermyxAlertAPIClient.parseDate) {
                Text("Shared for this emergency until \(expires.formatted(date: .omitted, time: .shortened)) at the latest.")
                    .font(ThermyxFont.captionSmall)
                    .foregroundStyle(Thermyx.Ink.textFaint)
            }
        } else {
            Label("Location not shared", systemImage: "location.slash")
                .font(ThermyxFont.caption)
                .foregroundStyle(Thermyx.Ink.textMuted)
        }
    }

    private func open(_ scheme: String) {
        guard let phone else { return }
        let digits = phone.filter { $0.isNumber || $0 == "+" }
        guard let url = URL(string: "\(scheme)://\(digits)"), UIApplication.shared.canOpenURL(url) else { return }
        UIApplication.shared.open(url)
    }
}

// MARK: - Timeline

/// The current event, oldest first: the alert, follow-ups, an SOS, a
/// check-in, the recovery. Times are the watcher's own.
struct EventTimeline: View {
    let entries: [ThermyxAlertAPIClient.TimelineEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.header) {
            SectionLabel("This event")
            VStack(alignment: .leading, spacing: 0) {
                let shown = Array(entries.suffix(8))
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, entry in
                    row(entry, isFirst: index == 0, isLast: index == shown.count - 1)
                }
            }
        }
    }

    private func row(_ entry: ThermyxAlertAPIClient.TimelineEntry, isFirst: Bool, isLast: Bool) -> some View {
        let tint = tint(entry)
        return HStack(alignment: .top, spacing: Thermyx.Space.m) {
            Text(entry.date?.formatted(date: .omitted, time: .shortened) ?? "")
                .font(ThermyxFont.monoCaption)
                .foregroundStyle(Thermyx.Ink.textMuted)
                .monospacedDigit()
                .frame(width: 72, alignment: .trailing)
                .padding(.top, 1)
            VStack(spacing: 0) {
                Rectangle().fill(isFirst ? .clear : Thermyx.Ink.hairline).frame(width: 1, height: 6)
                Circle()
                    .fill(tint)
                    .frame(width: isLast ? 10 : 8, height: isLast ? 10 : 8)
                    .overlay { if isLast { Circle().stroke(tint.opacity(0.35), lineWidth: 4) } }
                Rectangle().fill(isLast ? .clear : Thermyx.Ink.hairline).frame(width: 1).frame(maxHeight: .infinity)
            }
            .frame(width: 12)
            Text(label(entry))
                .font(isLast ? ThermyxFont.rowTitle : ThermyxFont.body)
                .foregroundStyle(isLast ? Thermyx.Ink.textPrimary : Thermyx.Ink.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, isLast ? 0 : Thermyx.Space.l)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private func label(_ e: ThermyxAlertAPIClient.TimelineEntry) -> String {
        switch e.kind {
        case "alert": return "\(e.level) alert"
        case "sos": return "SOS sent"
        case "help": return "Asked for help"
        case "ok": return "Checked in: says they're OK"
        case "silence": return "No update from their phone\(e.minutes.map { " for \($0) min" } ?? "")"
        case "update":
            switch e.update {
            case "recovering": return "Recovering · now \(e.level)"
            case "resolved": return "Back to Normal"
            default: return "Still \(e.level)"
            }
        default: return "Now \(e.level)"
        }
    }

    private func tint(_ e: ThermyxAlertAPIClient.TimelineEntry) -> Color {
        switch e.kind {
        case "ok": return Thermyx.Ink.ice
        case "sos": return Thermyx.Ink.ember
        case "help": return Thermyx.Ink.amber
        case "silence": return Thermyx.Ink.amber
        default:
            if e.update == "resolved" { return Thermyx.Ink.ice }
            return (ThermyxRiskLevel(rawValue: e.level) ?? .unavailable).tint
        }
    }
}

// MARK: - Sample banner

extension String {
    /// Up to two initials from a display name.
    var thermyxInitials: String {
        let letters = split(separator: " ").prefix(2).compactMap { $0.first.map(String.init) }.joined().uppercased()
        return letters.isEmpty ? "?" : letters
    }
}
