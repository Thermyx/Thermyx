import SwiftUI

/// AI Insights: pick a day, see exactly what goes to the AI, confirm, then
/// read that day's summary and ask about it. Reached from the top of Learn,
/// from a day's summary, and from the 8:30 pm notification.
struct AIInsightsView: View {
    @EnvironmentObject private var viewModel: ThermyxViewModel
    @ObservedObject var settings: ThermyxSettingsStore

    @State private var day: Date
    @State private var confirmed = false
    @State private var summary: String?
    @State private var messages: [ThermyxAlertAPIClient.ChatMessage] = []
    @State private var draft = ""
    @State private var loading = false
    @State private var error: String?
    @State private var legal: LegalDocument.Kind?
    @FocusState private var typing: Bool

    init(settings: ThermyxSettingsStore, day: Date = .now, confirmed: Bool = false) {
        self.settings = settings
        _day = State(initialValue: Calendar.current.startOfDay(for: day))
        _confirmed = State(initialValue: confirmed)
    }

    private var unit: TemperatureUnit { settings.temperatureUnit }

    private var daySummary: ThermyxDailySummary? {
        let calendar = Calendar.current
        let samples = viewModel.history.hourSamples.filter { calendar.isDate($0.start, inSameDayAs: day) }
        guard !samples.isEmpty else { return nil }
        let s = ThermyxDailySummary.summary(day: day, samples: samples,
                                            events: viewModel.history.events.filter { calendar.isDate($0.timestamp, inSameDayAs: day) })
        return s.wornSeconds > 0 ? s : nil
    }

    private var earliest: Date {
        Calendar.current.startOfDay(for: viewModel.history.hourSamples.map(\.start).min() ?? .now)
    }

    private var canAsk: Bool { settings.aiInsightsEnabled && settings.isPairedWithRelay && settings.relayRole == "wearer" }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Thermyx.Space.xl) {
                    if confirmed, let s = daySummary { conversation(s) } else { picker }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, Thermyx.Space.screen)
                .padding(.vertical, Thermyx.Space.l)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: messages.count) { _, _ in
                withAnimation(SiteMotion.settle) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .safeAreaInset(edge: .bottom) {
                if confirmed, daySummary != nil, canAsk { inputBar }
            }
        }
        .background(Thermyx.Ink.midnight.ignoresSafeArea())
        .navigationTitle("AI Insights")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $legal) { kind in
            LegalSheet(selection: kind).presentationDetents([.large])
        }
    }

    // MARK: Step 1: the day, and what's shared

    private var picker: some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.xl) {
            VStack(alignment: .leading, spacing: Thermyx.Space.xs) {
                Text("Pick a day")
                    .font(ThermyxFont.display)
                    .foregroundStyle(Thermyx.Ink.textPrimary)
                Text("Check what goes to the AI, then read your insights and ask anything about that day.")
                    .font(ThermyxFont.bodySmall)
                    .foregroundStyle(Thermyx.Ink.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            DatePicker("Day", selection: $day, in: earliest...Date.now, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .tint(Thermyx.Ink.ai)
                .padding(Thermyx.Space.s)
                .background(Thermyx.Ink.deck, in: RoundedRectangle(cornerRadius: Thermyx.Radius.control, style: .continuous))
                .onChange(of: day) { _, _ in summary = nil; messages = []; error = nil }

            if let s = daySummary { shared(s) } else {
                Text("No wear recorded on \(day.formatted(.dateTime.weekday(.wide).day().month(.wide))). Pick a day you wore your insoles.")
                    .font(ThermyxFont.body)
                    .foregroundStyle(Thermyx.Ink.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !settings.aiInsightsEnabled {
                AIInsightsToggle(isOn: $settings.aiInsightsEnabled) { legal = $0 }
            } else if !settings.isPairedWithRelay {
                Text("Connect to the relay in Safety → Device → Advanced to use AI Insights.")
                    .font(ThermyxFont.caption)
                    .foregroundStyle(Thermyx.Ink.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                withAnimation(SiteMotion.settle) { confirmed = true }
                Task { await loadSummary() }
            } label: {
                Text("Looks right, show my insights")
            }
            .buttonStyle(ThermyxPrimaryButtonStyle(fill: Thermyx.Ink.aiDeep, foreground: .white))
            .disabled(daySummary == nil || !canAsk)
            .opacity(daySummary == nil || !canAsk ? 0.5 : 1)
        }
    }

    /// Exactly the numbers the AI gets for this day.
    private func shared(_ s: ThermyxDailySummary) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("What the AI will see")
                .font(ThermyxFont.rowTitle)
                .foregroundStyle(Thermyx.Ink.textPrimary)
                .padding(.bottom, Thermyx.Space.s)
            row("Time worn", DurationFormat.long(s.wornSeconds))
            s.averageFootC.map { row("Usual foot temperature", TemperatureFormat.degrees($0, in: unit)) }
            s.peakFootC.map { row("Warmest", TemperatureFormat.degrees($0, in: unit)) }
            s.steps.map { row("Steps in the insoles", Int($0).formatted()) }
            s.walkingSeconds.map { row("Walking", DurationFormat.long($0)) }
            s.gaitAverage.map { row("Steadiness", "\(Int(($0 * 100).rounded()))%") }
            row("Highest level", s.peakRisk?.rawValue ?? "Normal")
            row("Alerts", s.events == 0 ? "None" : "\(s.events)")
            Text("Only these totals. Never your readings moment to moment, your name, contacts or where you are.")
                .font(ThermyxFont.captionSmall)
                .foregroundStyle(Thermyx.Ink.textFaint)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Thermyx.Space.s)
        }
        .padding(Thermyx.Space.l)
        .background(Thermyx.Ink.deck, in: RoundedRectangle(cornerRadius: Thermyx.Radius.control, style: .continuous))
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(ThermyxFont.bodySmall).foregroundStyle(Thermyx.Ink.textSecondary)
            Spacer()
            Text(value).font(ThermyxFont.rowTitleRegular).foregroundStyle(Thermyx.Ink.textPrimary).monospacedDigit()
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    // MARK: Step 2: insights and chat

    private func conversation(_ s: ThermyxDailySummary) -> some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.l) {
            HStack {
                Label(day.formatted(.dateTime.weekday(.wide).day().month(.wide)), systemImage: "calendar")
                    .font(ThermyxFont.controlLabel)
                    .foregroundStyle(Thermyx.Ink.textSecondary)
                Spacer()
                Button("Change day") { withAnimation(SiteMotion.settle) { confirmed = false } }
                    .font(ThermyxFont.controlLabel)
                    .foregroundStyle(Thermyx.Ink.link)
                    .frame(minHeight: Thermyx.minimumTapTarget)
            }

            VStack(alignment: .leading, spacing: Thermyx.Space.s) {
                HStack(spacing: Thermyx.Space.xs) {
                    AIMark(size: 22)
                    Text("Your day").font(ThermyxFont.rowTitle).foregroundStyle(Thermyx.Ink.textPrimary)
                }
                if let summary {
                    Text(summary)
                        .font(ThermyxFont.body)
                        .lineSpacing(3)
                        .foregroundStyle(Thermyx.Ink.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if loading, messages.isEmpty {
                    ProgressView().tint(Thermyx.Ink.ai)
                }
            }
            .padding(Thermyx.Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Thermyx.Tint.aiFill, in: RoundedRectangle(cornerRadius: Thermyx.Radius.control, style: .continuous))

            if messages.isEmpty, summary != nil {
                VStack(alignment: .leading, spacing: Thermyx.Space.xs) {
                    ForEach(["What stood out today?", "Did the heat get to my feet?", "What should I do differently tomorrow?"], id: \.self) { q in
                        Button { send(q) } label: {
                            Text(q)
                                .font(ThermyxFont.bodySmall)
                                .foregroundStyle(Thermyx.Ink.textPrimary)
                                .padding(.horizontal, Thermyx.Space.m)
                                .frame(minHeight: 44)
                                .background(Thermyx.Ink.deck, in: Capsule())
                                .overlay { Capsule().strokeBorder(Thermyx.Tint.aiBorder, lineWidth: 1) }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            ForEach(messages) { m in bubble(m) }
            if loading, !messages.isEmpty {
                HStack { ProgressView().tint(Thermyx.Ink.ai); Spacer() }
            }

            if let error {
                Text(error).font(ThermyxFont.caption).foregroundStyle(Thermyx.Ink.amber)
            }
            Text("Written by AI from this day's totals. Not medical advice; if you feel unwell, get help.")
                .font(ThermyxFont.captionSmall)
                .foregroundStyle(Thermyx.Ink.textFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task(id: day) { if summary == nil { await loadSummary() } }
    }

    private func bubble(_ m: ThermyxAlertAPIClient.ChatMessage) -> some View {
        let mine = m.role == "user"
        return HStack {
            if mine { Spacer(minLength: 40) }
            Text(m.content)
                .font(ThermyxFont.body)
                .foregroundStyle(mine ? .white : Thermyx.Ink.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(mine ? Thermyx.Ink.aiDeep : Thermyx.Ink.elevated,
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .textSelection(.enabled)
            if !mine { Spacer(minLength: 40) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(mine ? "You: \(m.content)" : "AI: \(m.content)")
    }

    private var inputBar: some View {
        HStack(spacing: Thermyx.Space.s) {
            TextField("Ask about this day", text: $draft, axis: .vertical)
                .lineLimit(1...4)
                .focused($typing)
                .font(ThermyxFont.body)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Thermyx.Ink.deck, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .submitLabel(.send)
                .onSubmit { send(draft) }
            Button { send(draft) } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Thermyx.Ink.aiDeep, in: Circle())
            }
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || loading)
            .accessibilityLabel("Send")
        }
        .padding(.horizontal, Thermyx.Space.screen)
        .padding(.vertical, Thermyx.Space.s)
        .background(.bar)
    }

    // MARK: Talking to the relay

    private func request(_ s: ThermyxDailySummary) -> ThermyxAlertAPIClient.SummaryRequest {
        .init(s, unit: unit, focus: settings.profile.focus, usage: settings.usage)
    }

    private func loadSummary() async {
        guard let s = daySummary, canAsk else { return }
        if let stored = ThermyxAlertCoordinator.storedSummary(for: day) { summary = stored; return }
        loading = true
        defer { loading = false }
        do {
            let text = try await ThermyxAlertAPIClient().summary(request(s), baseURL: settings.backendURL, token: settings.backendToken)
            ThermyxAlertCoordinator.store(text, for: day)
            summary = text
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func send(_ text: String) {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !loading, let s = daySummary else { return }
        draft = ""
        messages.append(.init(role: "user", content: question))
        let history = Array(messages.suffix(15))
        loading = true
        Task {
            defer { loading = false }
            do {
                let reply = try await ThermyxAlertAPIClient().chat(day: request(s), messages: history,
                                                                   baseURL: settings.backendURL, token: settings.backendToken)
                messages.append(.init(role: "assistant", content: reply))
                error = nil
            } catch {
                self.error = error.localizedDescription
                messages.removeLast()
                draft = question
            }
        }
    }
}

/// The top of Learn: the way into AI Insights.
struct AIInsightsEntry: View {
    @ObservedObject var settings: ThermyxSettingsStore

    var body: some View {
        NavigationLink(value: InsightsDestination.aiInsights(nil)) {
            HStack(spacing: Thermyx.Space.m) {
                AIMark(size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("AI Insights")
                        .font(ThermyxFont.rowTitle)
                        .foregroundStyle(Thermyx.Ink.textPrimary)
                    Text(ThermyxAlertCoordinator.storedSummary(for: .now) != nil
                         ? "Today's insights are ready. Ask about any day."
                         : "Your day in plain words, and answers to your questions.")
                        .font(ThermyxFont.captionSmall)
                        .foregroundStyle(Thermyx.Ink.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Thermyx.Ink.textFaint)
            }
            .padding(Thermyx.Space.l)
            .background {
                RoundedRectangle(cornerRadius: Thermyx.Radius.list, style: .continuous)
                    .fill(LinearGradient(colors: [Thermyx.Tint.aiFill, Thermyx.Tint.aiFill.opacity(0.25)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            .overlay {
                RoundedRectangle(cornerRadius: Thermyx.Radius.list, style: .continuous)
                    .strokeBorder(Thermyx.Tint.aiBorder, lineWidth: 1)
            }
        }
        .buttonStyle(PressableStyle())
    }
}
