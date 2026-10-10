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

                if let visual = article.visual { ArticleVisual(kind: visual) }

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

// MARK: - Diagrams

/// Drawn diagrams for Learn articles. No images to ship, and they follow
/// the app's colours.
struct ArticleVisual: View {
    let kind: String

    var body: some View {
        ThermyxCard {
            switch kind {
            case "peltier": PeltierDiagram()
            case "modes": ModesDiagram()
            case "comfortBand": ComfortBandDiagram()
            default: EmptyView()
            }
        }
    }
}

/// The Peltier tile between the foot and the fan, with heat moving one way
/// or the other. Tap Cool or Heat to swap.
struct PeltierDiagram: View {
    @State private var cooling = true

    var body: some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.m) {
            Picker("Mode", selection: $cooling) {
                Text("Cool").tag(true)
                Text("Heat").tag(false)
            }
            .pickerStyle(.segmented)

            VStack(spacing: 6) {
                plate(cooling ? "Foot side gets cold" : "Foot side gets warm", color: cooling ? Thermyx.Ink.signal : Thermyx.Ink.ember)
                HStack(spacing: Thermyx.Space.l) {
                    ForEach(0..<3, id: \.self) { _ in
                        Image(systemName: cooling ? "arrow.down" : "arrow.up")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(Thermyx.Ink.amber)
                    }
                    Text("heat moves")
                        .font(ThermyxFont.captionSmall)
                        .foregroundStyle(Thermyx.Ink.textSupporting)
                }
                RoundedRectangle(cornerRadius: 4)
                    .fill(Thermyx.Ink.elevated)
                    .frame(height: 22)
                    .overlay(Text("Peltier tile").font(ThermyxFont.captionSmall).foregroundStyle(Thermyx.Ink.textSecondary))
                plate(cooling ? "Fan side gets hot · fan carries it away" : "Fan side gets cool", color: cooling ? Thermyx.Ink.ember : Thermyx.Ink.signal)
                HStack(spacing: 6) {
                    Image(systemName: "fan.fill").foregroundStyle(Thermyx.Ink.ice)
                    Text("Fan runs whenever it heats or cools")
                        .font(ThermyxFont.captionSmall)
                        .foregroundStyle(Thermyx.Ink.textSupporting)
                }
            }
            .animation(.easeOut(duration: 0.25), value: cooling)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(cooling
            ? "Cooling: the tile moves heat away from your foot to the fan side, where the fan removes it."
            : "Heating: current flows the other way and the tile moves heat toward your foot.")
    }

    private func plate(_ label: String, color: Color) -> some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(color.opacity(0.85))
            .frame(height: 34)
            .overlay(Text(label).font(ThermyxFont.caption.weight(.semibold)).foregroundStyle(.white))
    }
}

/// The four modes at a glance.
struct ModesDiagram: View {
    private let rows: [(String, String, Color, String)] = [
        ("snowflake", "Cool", Thermyx.Ink.signal, "Draws heat away from your foot"),
        ("a.circle", "Auto", Thermyx.Ink.ice, "Holds your target: heats below, cools above, rests near it"),
        ("flame.fill", "Heat", Thermyx.Ink.ember, "Warms your foot; stops at 40 °C (104 °F)"),
        ("power", "Off", Thermyx.Ink.textSupporting, "Tile and fan off; still sensing"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.m) {
            ForEach(rows, id: \.1) { symbol, name, tint, detail in
                HStack(spacing: Thermyx.Space.m) {
                    RoundedRectangle(cornerRadius: Thermyx.Radius.control, style: .continuous)
                        .fill(tint.opacity(0.18))
                        .frame(width: 44, height: 44)
                        .overlay(Image(systemName: symbol).font(.system(size: 18, weight: .semibold)).foregroundStyle(tint))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name).font(ThermyxFont.rowTitle).foregroundStyle(Thermyx.Ink.textPrimary)
                        Text(detail).font(ThermyxFont.caption).foregroundStyle(Thermyx.Ink.textSupporting)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The temperature bands as one coloured bar.
struct ComfortBandDiagram: View {
    private let bands: [(ThermyxTemperatureScale.Band, String)] = [
        (.cool, "under 30 °C"), (.comfort, "30–34 °C"), (.warm, "34–37 °C"), (.hot, "37 °C +"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.s) {
            HStack(spacing: 3) {
                ForEach(bands, id: \.0) { band, _ in
                    RoundedRectangle(cornerRadius: 4).fill(band.color).frame(height: 18)
                }
            }
            HStack(alignment: .top, spacing: 3) {
                ForEach(bands, id: \.0) { band, range in
                    VStack(spacing: 2) {
                        Text(band.label).font(ThermyxFont.captionSmall.weight(.semibold)).foregroundStyle(band.color)
                        Text(range).font(ThermyxFont.captionSmall).foregroundStyle(Thermyx.Ink.textSupporting)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            Text("Foot-contact temperature. The comfort band is shaded on your charts.")
                .font(ThermyxFont.captionSmall)
                .foregroundStyle(Thermyx.Ink.textFaint)
        }
        .accessibilityElement(children: .combine)
    }
}
