import SwiftUI

/// The Learn tab.
struct LearnTab: View {
    @ObservedObject var settings: ThermyxSettingsStore
    @State private var path: [InsightsDestination] = {
        #if DEBUG
        return ThermyxPreviewHarness.initialLearnPath
        #else
        return []
        #endif
    }()

    var body: some View {
        NavigationStack(path: $path) {
            LearningCenterView(isTab: true, settings: settings)
                .thermyxNavigationRoot()
                .navigationDestination(for: InsightsDestination.self) { destination in
                    switch destination {
                    case .article(let id):
                        if let article = ThermyxLearningLibrary.article(id: id) {
                            ArticleView(article: article)
                        }
                    case .photoCredits:
                        PhotoCreditsView()
                    default:
                        EmptyView()
                    }
                }
        }
    }
}

/// Learn's front page: the lesson for right now, the lead story, then every
/// story by section. Every article is educational, not a diagnosis, and
/// cites its sources.
struct LearningCenterView: View {
    /// True on the Learn tab (a top-level screen); false when pushed.
    var isTab = false
    var settings: ThermyxSettingsStore?

    @EnvironmentObject private var viewModel: ThermyxViewModel
    @State private var section: LearningSection?
    @State private var air: ThermyxWeather.Current?

    private var articles: [LearningArticle] { ThermyxLearningLibrary.articles }
    private var unit: TemperatureUnit { settings?.temperatureUnit ?? .celsius }

    private var suggestion: LearningSuggestion? {
        let history = viewModel.history.minuteSamples
        let cutoff = Date.now.addingTimeInterval(-2 * 3600)
        let recentPeak = history.filter { $0.start >= cutoff }.compactMap(\.peakRiskLevel).max { $0.severity < $1.severity }
        let first = history.first?.start ?? viewModel.history.hourSamples.first?.start
        let days = first.map { Calendar.current.dateComponents([.day], from: $0, to: .now).day ?? 0 } ?? 0
        return LearningSuggestion.current(.init(
            reading: viewModel.reading,
            assessment: viewModel.assessment,
            connected: viewModel.connectedFeet,
            pairExpected: viewModel.pairExpected,
            trend10: viewModel.history.footTrend(over: 10 * 60, current: viewModel.reading.peakFootTemperatureC)?.delta,
            recentPeak: recentPeak,
            airC: air?.airC,
            daysOfHistory: days,
            unit: unit
        ))
    }

    private var lead: LearningArticle? {
        guard section == nil else { return nil }
        return articles.first { $0.id != suggestion?.article.id }
    }

    private var stories: [LearningArticle] {
        articles.filter { a in
            (section == nil || a.section == section) && a.id != lead?.id && a.id != suggestion?.article.id
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                masthead
                if articles.isEmpty {
                    ThermyxEmptyState(title: "Articles unavailable", message: "Learn's articles didn't load. Reinstalling the app restores them.",
                                      systemImage: "newspaper")
                        .padding(.top, Thermyx.Space.titleGap)
                } else {
                    if let suggestion, section == nil {
                        ForRightNow(suggestion: suggestion)
                            .padding(.top, Thermyx.Space.titleGap)
                    }
                    sections
                        .padding(.top, Thermyx.Space.group)
                    VStack(spacing: Thermyx.Space.titleGap) {
                        if let lead {
                            NavigationLink(value: InsightsDestination.article(lead.id)) {
                                ArticleCard(article: lead, prominent: true)
                            }
                            .buttonStyle(PressableStyle())
                            .spotlightTarget(.learnLead)
                        }
                        ForEach(stories) { article in
                            NavigationLink(value: InsightsDestination.article(article.id)) {
                                ArticleCard(article: article)
                            }
                            .buttonStyle(PressableStyle())
                        }
                    }
                    .padding(.top, Thermyx.Space.titleGap)
                    footer
                        .padding(.top, Thermyx.Space.section)
                }
            }
            .padding(.horizontal, Thermyx.Space.screen)
            .padding(.bottom, Thermyx.Space.xxl)
        }
        .scrollIndicators(.hidden)
        .thermyxTopScrim()
        .modifier(PushedBackground(isTab: isTab))
        .task {
            guard ThermyxWeather.shared.isAuthorized else { return }
            air = await ThermyxWeather.shared.current()
        }
    }

    /// The same title as every tab, with one line under it.
    private var masthead: some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.item) {
            Text("Learn")
                .font(ThermyxFont.screenTitle)
                .tracking(ThermyxTracking.screenTitle)
                .foregroundStyle(Thermyx.Ink.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text("Short, sourced reads on heat, cold and your feet. Educational, not medical advice.")
                .font(ThermyxFont.bodySmall)
                .foregroundStyle(Thermyx.Ink.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, Thermyx.Space.titleTop)
    }

    private var sections: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Thermyx.Space.xs) {
                sectionTab(nil, "All")
                ForEach(LearningSection.allCases.filter { s in articles.contains { $0.section == s } }) { s in
                    sectionTab(s, s.label)
                }
            }
        }
        .scrollIndicators(.hidden)
        .sensoryFeedback(.selection, trigger: section)
    }

    private func sectionTab(_ value: LearningSection?, _ label: String) -> some View {
        let selected = value == section
        return Button {
            withAnimation(SiteMotion.settle) { section = value }
        } label: {
            Text(label)
                .font(.custom(ThermyxFont.Family.medium, size: 14, relativeTo: .subheadline))
                .foregroundStyle(selected ? Thermyx.Ink.onPrimary : Thermyx.Ink.textPrimary)
                .padding(.horizontal, 16)
                .frame(height: 38)
                .background(selected ? Thermyx.Ink.textPrimary : .clear, in: Capsule())
                .overlay { Capsule().strokeBorder(selected ? .clear : Thermyx.Site.hairlineStrong, lineWidth: 1) }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Every article cites its sources in APA style at the end. Thermyx Learn is educational and is not a medical diagnosis tool. In an emergency, call 911.")
                .font(ThermyxFont.captionSmall)
                .foregroundStyle(Thermyx.Ink.textFaint)
                .fixedSize(horizontal: false, vertical: true)
            NavigationLink(value: InsightsDestination.photoCredits) {
                Text("Photo credits")
                    .font(ThermyxFont.controlLabel)
                    .foregroundStyle(Thermyx.Ink.ice)
                    .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 16)
        .overlay(alignment: .top) { ThermyxDivider() }
    }
}

/// When pushed (from Insights) the page draws its own background.
private struct PushedBackground: ViewModifier {
    let isTab: Bool
    func body(content: Content) -> some View {
        if isTab {
            content
        } else {
            content
                .thermyxBackground()
                .navigationBarBackButtonHidden(false)
        }
    }
}

// MARK: - Pieces

/// The lesson Thermyx picked for the moment, and the reading behind it.
private struct ForRightNow: View {
    let suggestion: LearningSuggestion

    var body: some View {
        NavigationLink(value: InsightsDestination.article(suggestion.article.id)) {
            HStack(alignment: .top, spacing: 14) {
                Rectangle()
                    .fill(Thermyx.Ink.ember)
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: Thermyx.Space.item) {
                    Text("For right now")
                        .font(.custom(ThermyxFont.Family.semibold, size: 13, relativeTo: .caption))
                        .foregroundStyle(Thermyx.Ink.ember)
                    Text(suggestion.reason)
                        .font(ThermyxFont.captionSmall)
                        .foregroundStyle(Thermyx.Ink.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(suggestion.article.title)
                        .font(.system(.title3, design: .serif).weight(.bold))
                        .foregroundStyle(Thermyx.Ink.textPrimary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(suggestion.article.meta) · Read now")
                        .font(ThermyxFont.captionSmall)
                        .foregroundStyle(Thermyx.Ink.ice)
                }
                Spacer(minLength: 0)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(Thermyx.Space.xl)
            .background(Thermyx.Tint.emberFill.opacity(0.5), in: RoundedRectangle(cornerRadius: Thermyx.Radius.list, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Thermyx.Radius.list, style: .continuous).strokeBorder(Thermyx.Tint.emberBorder, lineWidth: 1)
            }
            .contentShape(.rect)
        }
        .buttonStyle(PressableStyle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the article Thermyx suggests for what's happening now.")
    }
}

/// One article, one card: its photograph, the section, the headline, a
/// two-line dek and how long it takes. The first is larger.
private struct ArticleCard: View {
    let article: LearningArticle
    var prominent = false

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: Thermyx.Radius.list, style: .continuous) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear
                .frame(height: prominent ? 200 : 150)
                .overlay {
                    Image(article.image.asset)
                        .resizable()
                        .scaledToFill()
                }
                .clipped()
                .accessibilityLabel(article.image.alt)
            VStack(alignment: .leading, spacing: Thermyx.Space.item) {
                Kicker(section: article.section)
                Text(article.title)
                    .font(.system(prominent ? .title2 : .title3, design: .serif).weight(.bold))
                    .foregroundStyle(Thermyx.Ink.textPrimary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Text(article.dek)
                    .font(ThermyxFont.bodySmall)
                    .lineSpacing(2)
                    .foregroundStyle(Thermyx.Ink.textMuted)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                HStack {
                    Text(article.meta)
                        .font(ThermyxFont.captionSmall)
                        .foregroundStyle(Thermyx.Ink.textFaint)
                    Spacer()
                    Image(systemName: "arrow.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(article.section.tint)
                }
                .padding(.top, 2)
            }
            .padding(Thermyx.Space.xl)
        }
        .background(Thermyx.Site.surface, in: shape)
        .clipShape(shape)
        .overlay { shape.strokeBorder(Thermyx.Site.hairlineStrong, lineWidth: 1) }
        .contentShape(shape)
        .accessibilityElement(children: .combine)
    }
}

/// The section name over a headline, newspaper style.
struct Kicker: View {
    let section: LearningSection

    var body: some View {
        Text(section.label.uppercased())
            .font(.custom(ThermyxFont.Family.semibold, size: 11, relativeTo: .caption2))
            .tracking(1.2)
            .foregroundStyle(section.tint)
    }
}

// MARK: - Photo credits

struct PhotoCreditsView: View {
    var body: some View {
        ThermyxDetailScreen(title: "Photo credits", backTitle: "Learn") {
            Text("Photographs come from Wikimedia Commons. Public-domain images are U.S. government works. Images under Creative Commons licences are shown cropped and resized.")
                .font(ThermyxFont.bodySmall)
                .foregroundStyle(Thermyx.Ink.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                ForEach(PhotoCredit.all) { credit in
                    HStack(alignment: .top, spacing: 14) {
                        Image(credit.asset)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 64, height: 64)
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(credit.title)
                                .font(ThermyxFont.rowTitle)
                                .foregroundStyle(Thermyx.Ink.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("\(credit.author) · \(credit.license)\(credit.modified ? " · cropped" : "")")
                                .font(ThermyxFont.captionSmall)
                                .foregroundStyle(Thermyx.Ink.textMuted)
                                .fixedSize(horizontal: false, vertical: true)
                            if let url = URL(string: credit.source) {
                                Link("Source", destination: url)
                                    .font(ThermyxFont.captionSmall)
                                    .foregroundStyle(Thermyx.Ink.ice)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 12)
                    .overlay(alignment: .bottom) { ThermyxDivider() }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}
