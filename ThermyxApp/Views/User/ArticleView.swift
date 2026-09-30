import SwiftUI

struct ArticleView: View {
    let article: LearningArticle

    var body: some View {
        ThermyxDetailScreen(title: "", caption: article.kicker, horizontalPadding: Thermyx.Space.wide) {
            VStack(alignment: .leading, spacing: Thermyx.Space.m) {
                Text(article.category.label)
                    .narrowLabel(ThermyxFont.sectionLabel, tracking: 2.4, color: article.category.tint)

                Text(article.title)
                    .font(ThermyxFont.articleHeadline)
                    .tracking(-1.1)
                    .foregroundStyle(Thermyx.Ink.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)

                ThermyxDivider()

                if article.status == .placeholder { draftNotice }

                ForEach(Array(article.sections.enumerated()), id: \.offset) { _, section in
                    sectionView(section)
                }

                Text(article.sources)
                    .font(ThermyxFont.captionSmall)
                    .foregroundStyle(Thermyx.Ink.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .hidesThermalControlBar()
    }

    private var draftNotice: some View {
        ThermyxCard(padding: Thermyx.Space.l, radius: Thermyx.Radius.compact, fill: Thermyx.Tint.amberFill, border: Thermyx.Tint.amberBorder) {
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel("Draft", color: Thermyx.Ink.amber)
                Text("Written, but not yet checked: every source and figure below must be checked against the original publication before this ships.")
                    .font(ThermyxFont.caption)
                    .foregroundStyle(Thermyx.Ink.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func sectionView(_ section: LearningArticle.Section) -> some View {
        switch section.kind {
        case .body:
            Text(section.text)
                .font(ThermyxFont.body)
                .lineSpacing(5)
                .foregroundStyle(Thermyx.Ink.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

        case .pullStat:
            HStack(spacing: 0) {
                Rectangle()
                    .fill(Thermyx.Ink.ember)
                    .frame(width: 3)
                Text(section.text)
                    .font(ThermyxFont.bodySmall)
                    .lineSpacing(3)
                    .foregroundStyle(Thermyx.Ink.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, Thermyx.Space.xl)
            }
            .padding(.vertical, 4)
            .fixedSize(horizontal: false, vertical: true)

        case .action:
            ThermyxCard(padding: Thermyx.Space.xl, radius: Thermyx.Radius.list) {
                VStack(alignment: .leading, spacing: Thermyx.Space.xs) {
                    SectionLabel("What to do with this", color: Thermyx.Ink.ice)
                    Text(section.text)
                        .font(ThermyxFont.bodySmall)
                        .lineSpacing(4)
                        .foregroundStyle(Thermyx.Ink.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
