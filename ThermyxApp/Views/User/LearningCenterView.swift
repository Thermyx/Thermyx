import SwiftUI

/// The Learn tab: one topic per card, with room between them.
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
                .navigationDestination(for: InsightsDestination.self) { destination in
                    if case .article(let id) = destination, let article = ThermyxLearningLibrary.article(id: id) {
                        ArticleView(article: article)
                    }
                }
        }
    }
}

struct LearningCenterView: View {
    /// True on the Learn tab (a top-level screen); false when pushed.
    var isTab = false
    var settings: ThermyxSettingsStore?
    @State private var filter: LearningFilter = .all

    private var articles: [LearningArticle] {
        ThermyxLearningLibrary.articles.filter { filter.matches($0) }
    }

    private var featured: LearningArticle? {
        articles.first(where: \.featured)
    }

    private var rest: [LearningArticle] {
        articles.filter { !$0.featured }
    }

    /// When every article is still an outline, one notice says so better than
    /// a badge on every row.
    private var allDrafts: Bool {
        !ThermyxLearningLibrary.articles.isEmpty
            && ThermyxLearningLibrary.articles.allSatisfy { $0.status == .placeholder }
    }

    var body: some View {
        Group {
            if isTab {
                ThermyxScreen(title: "Learn") { content }
            } else {
                ThermyxDetailScreen(title: "Learn") { content }
            }
        }
        .hidesThermalControlBar()
    }

    @ViewBuilder
    private var content: some View {
        if let settings { LearnSuggestionsSection(settings: settings) }

        SectionLabel("Topics")
        filterPills

        if allDrafts { draftNotice }

        VStack(spacing: Thermyx.Space.xl) {
            if let featured {
                NavigationLink(value: InsightsDestination.article(featured.id)) {
                    FeaturedArticleCard(article: featured, showsBadge: !allDrafts)
                }
                .buttonStyle(.plain)
            }

            ForEach(rest) { article in
                NavigationLink(value: InsightsDestination.article(article.id)) {
                    LearnTopicCard(article: article, showsBadge: !allDrafts)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, Thermyx.Space.xs)

        if articles.isEmpty {
            ThermyxEmptyState(
                title: "Nothing in this category yet",
                message: "Try another filter.",
                systemImage: "book.closed"
            )
        }
    }

    private var draftNotice: some View {
        ThermyxCard(padding: Thermyx.Space.l, radius: Thermyx.Radius.compact, fill: Thermyx.Tint.amberFill, border: Thermyx.Tint.amberBorder) {
            VStack(alignment: .leading, spacing: 4) {
                SectionLabel("Draft library", color: Thermyx.Ink.amber)
                Text("These articles are written but their sources have not been checked yet. Each one is marked as a draft until it is.")
                    .font(ThermyxFont.caption)
                    .foregroundStyle(Thermyx.Ink.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var filterPills: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Thermyx.Space.xs) {
                ForEach(LearningFilter.allCases) { option in
                    let isSelected = option == filter
                    Button {
                        filter = option
                    } label: {
                        Text(option.label)
                            .narrowLabel(
                                ThermyxFont.statusPill,
                                tracking: ThermyxTracking.statusPill,
                                color: isSelected ? Thermyx.Ink.textPrimary : Thermyx.Ink.textSupporting
                            )
                            .padding(.horizontal, 14)
                            .frame(minHeight: Thermyx.minimumTapTarget)
                            .background(
                                isSelected ? Thermyx.Ink.elevated : Thermyx.Tint.neutralFill,
                                in: Capsule()
                            )
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                }
            }
            .padding(.horizontal, 1)
        }
        .scrollIndicators(.hidden)
    }
}

/// The gradient hero card at the top of the Learning Center.
struct FeaturedArticleCard: View {
    let article: LearningArticle
    var showsBadge: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.s) {
            Text("Start here · \(article.readMinutes) min")
                .narrowLabel(ThermyxFont.sectionLabel, tracking: ThermyxTracking.sectionLabel, color: Thermyx.Ink.amber)

            Text(article.title)
                .font(ThermyxFont.featureHeadline)
                .tracking(-0.8)
                .foregroundStyle(Thermyx.Ink.textPrimary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            Text(article.deck)
                .font(ThermyxFont.bodySmall)
                .foregroundStyle(Thermyx.Ink.textMuted)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            if showsBadge, article.status == .placeholder { DraftBadge() }
        }
        .padding(Thermyx.Space.screen)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            LinearGradient(
                colors: [Color(hex: 0x1B3552), Thermyx.Ink.deck],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .overlay(alignment: .topTrailing) {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color(hex: 0xFF6A13, opacity: 0.32), Color(hex: 0xFF6A13, opacity: 0)],
                            center: .center,
                            startRadius: 0,
                            endRadius: 100
                        )
                    )
                    .frame(width: 200, height: 200)
                    .offset(x: 50, y: -40)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Thermyx.Radius.hero, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Thermyx.Radius.hero, style: .continuous)
                .strokeBorder(Color(hex: 0xFF6A13, opacity: 0.3), lineWidth: Thermyx.Stroke.hairline)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

/// One topic per card: a large icon, the title, a short line on what it
/// covers, and how long it takes to read.
struct LearnTopicCard: View {
    let article: LearningArticle
    var showsBadge: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.m) {
            HStack(alignment: .center, spacing: Thermyx.Space.m) {
                RoundedRectangle(cornerRadius: Thermyx.Radius.control, style: .continuous)
                    .fill(article.category.iconFill)
                    .frame(width: 56, height: 56)
                    .overlay {
                        Image(systemName: article.symbol)
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(article.category.tint)
                    }
                VStack(alignment: .leading, spacing: 2) {
                    Text(article.category.label)
                        .narrowLabel(ThermyxFont.sectionLabel, tracking: ThermyxTracking.sectionLabel, color: article.category.tint)
                    Text("\(article.readMinutes) min read")
                        .font(ThermyxFont.captionSmall)
                        .foregroundStyle(Thermyx.Ink.textSupporting)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Thermyx.Ink.textFaint)
            }

            Text(article.title)
                .font(ThermyxFont.cardTitle)
                .foregroundStyle(Thermyx.Ink.textPrimary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            Text(article.deck)
                .font(ThermyxFont.body)
                .foregroundStyle(Thermyx.Ink.textMuted)
                .lineSpacing(3)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            if showsBadge, article.status == .placeholder { DraftBadge(compact: true) }
        }
        .padding(Thermyx.Space.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Thermyx.Ink.deck, in: RoundedRectangle(cornerRadius: Thermyx.Radius.section, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Thermyx.Radius.section, style: .continuous)
                .strokeBorder(Thermyx.Ink.hairline, lineWidth: Thermyx.Stroke.hairline)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

struct ArticleRow: View {
    let article: LearningArticle
    var showsBadge: Bool = true

    var body: some View {
        HStack(spacing: Thermyx.Space.m) {
            RoundedRectangle(cornerRadius: Thermyx.Radius.control, style: .continuous)
                .fill(article.category.iconFill)
                .frame(width: 54, height: 54)
                .overlay {
                    Image(systemName: article.category.symbol)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(article.category.tint)
                }

            VStack(alignment: .leading, spacing: 3) {
                Text(article.title)
                    .font(ThermyxFont.rowTitle)
                    .foregroundStyle(Thermyx.Ink.textPrimary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Text(article.meta)
                        .font(ThermyxFont.captionSmall)
                        .foregroundStyle(Thermyx.Ink.textSupporting)
                    if showsBadge, article.status == .placeholder { DraftBadge(compact: true) }
                }
            }

            Spacer(minLength: Thermyx.Space.xs)

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Thermyx.Ink.textFaint)
        }
        .padding(Thermyx.Space.l)
        .frame(minHeight: Thermyx.minimumTapTarget)
        .background(Thermyx.Ink.deck, in: RoundedRectangle(cornerRadius: Thermyx.Radius.list, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Thermyx.Radius.list, style: .continuous)
                .strokeBorder(Thermyx.Ink.hairline, lineWidth: Thermyx.Stroke.hairline)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

/// Marks copy that is structural only. The headlines are real; the bodies are
/// outlines waiting on writing and citations, and the app says so plainly
/// rather than shipping invented statistics.
struct DraftBadge: View {
    var compact: Bool = false

    var body: some View {
        Text(compact ? "Draft" : "Draft · sources unchecked")
            .narrowLabel(ThermyxFont.axisLabel, tracking: ThermyxTracking.axisLabel, color: Thermyx.Ink.amber)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Thermyx.Tint.amberFill, in: Capsule())
            .overlay { Capsule().strokeBorder(Thermyx.Tint.amberBorder, lineWidth: Thermyx.Stroke.hairline) }
    }
}

/// "For you": up to three tips from today's data and the profile, each with
/// a visual and a link to the article that explains more.
struct LearnSuggestionsSection: View {
    @EnvironmentObject private var viewModel: ThermyxViewModel
    @ObservedObject var settings: ThermyxSettingsStore

    var body: some View {
        let calendar = Calendar.current
        let samples = viewModel.history.hourSamples.filter { calendar.isDateInToday($0.start) }
        let today = samples.isEmpty ? nil : ThermyxDailySummary.summary(
            day: calendar.startOfDay(for: .now), samples: samples,
            events: viewModel.history.events.filter { calendar.isDateInToday($0.timestamp) }
        )
        let tips = LearnSuggestion.make(
            today: today,
            calibrated: viewModel.baseline.model != nil,
            profile: settings.profile,
            current: viewModel.reading,
            usualSteadiness: viewModel.baseline.model?.walkingSteadiness?.mean
        )
        VStack(alignment: .leading, spacing: Thermyx.Space.m) {
            SectionLabel("For you")
            ForEach(tips) { tip in
                if let id = tip.articleID {
                    NavigationLink(value: InsightsDestination.article(id)) { SuggestionCard(tip: tip, showsLink: true) }
                        .buttonStyle(.plain)
                } else {
                    SuggestionCard(tip: tip, showsLink: false)
                }
            }
            Text("Based on your readings and profile, worked out on this phone.")
                .font(ThermyxFont.captionSmall)
                .foregroundStyle(Thermyx.Ink.textFaint)
        }
    }
}

struct SuggestionCard: View {
    let tip: LearnSuggestion
    let showsLink: Bool

    private var tint: Color {
        switch tip.tone {
        case .neutral: return Thermyx.Ink.ice
        case .warm: return Thermyx.Ink.ember
        case .cool: return Thermyx.Ink.signal
        case .caution: return Thermyx.Ink.amber
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: Thermyx.Space.m) {
            ZStack {
                RoundedRectangle(cornerRadius: Thermyx.Radius.control, style: .continuous)
                    .fill(LinearGradient(colors: [tint.opacity(0.35), tint.opacity(0.08)], startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: tip.symbol)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(tint)
            }
            .frame(width: 64, height: 64)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(tip.title)
                        .font(ThermyxFont.rowTitle)
                        .foregroundStyle(Thermyx.Ink.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if let figure = tip.figure {
                        Text(figure)
                            .narrowLabel(ThermyxFont.statusPill, tracking: 0.6, color: tint)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(tint.opacity(0.14), in: Capsule())
                    }
                }
                Text(tip.text)
                    .font(ThermyxFont.caption)
                    .foregroundStyle(Thermyx.Ink.textSecondary)
                    .lineSpacing(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if showsLink {
                    Text("Learn more")
                        .font(ThermyxFont.captionSmall.weight(.semibold))
                        .foregroundStyle(Thermyx.Ink.ice)
                }
            }
        }
        .padding(Thermyx.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Thermyx.Ink.deck, in: RoundedRectangle(cornerRadius: Thermyx.Radius.section, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Thermyx.Radius.section, style: .continuous)
                .strokeBorder(tint.opacity(0.35), lineWidth: Thermyx.Stroke.hairline)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}
