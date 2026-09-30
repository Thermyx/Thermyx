import SwiftUI

struct LearningCenterView: View {
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
        ThermyxDetailScreen(title: "Learn") {
            filterPills

            if allDrafts { draftNotice }

            if let featured {
                NavigationLink(value: InsightsDestination.article(featured.id)) {
                    FeaturedArticleCard(article: featured, showsBadge: !allDrafts)
                }
                .buttonStyle(.plain)
            }

            ForEach(rest) { article in
                NavigationLink(value: InsightsDestination.article(article.id)) {
                    ArticleRow(article: article, showsBadge: !allDrafts)
                }
                .buttonStyle(.plain)
            }

            if articles.isEmpty {
                ThermyxEmptyState(
                    title: "Nothing in this category yet",
                    message: "Try another filter.",
                    systemImage: "book.closed"
                )
            }
        }
        .hidesThermalControlBar()
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
