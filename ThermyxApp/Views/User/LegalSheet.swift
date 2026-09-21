import SwiftUI

/// The Privacy Policy and Terms of Service, as a sheet.
///
/// Presented rather than pushed, so it can be reached from anywhere without
/// disturbing the navigation stack underneath — and so it reads as a reference
/// document you dismiss, not a destination you navigate out of.
struct LegalSheet: View {
    @State var selection: LegalDocument.Kind
    @Environment(\.dismiss) private var dismiss

    @State private var documents: [LegalDocument.Kind: LegalDocument] = [:]

    private var document: LegalDocument? { documents[selection] }

    var body: some View {
        NavigationStack {
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(alignment: .leading, spacing: Thermyx.Space.m) {
                        Color.clear.frame(height: 1).id("top")

                        header

                        if let document {
                            ForEach(document.blocks) { block in
                                blockView(block)
                            }
                        } else {
                            ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                        }

                        placeholderNotice
                    }
                    .padding(.horizontal, Thermyx.Space.wide)
                    .padding(.bottom, 40)
                }
                .scrollIndicators(.visible)
                .onChange(of: selection) { _, _ in
                    load(selection)
                    withAnimation { scroll.scrollTo("top", anchor: .top) }
                }
            }
            .background(Thermyx.Ink.midnight)
            .navigationTitle(selection.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task {
            load(.privacy)
            load(.terms)
        }
    }

    private func load(_ kind: LegalDocument.Kind) {
        guard documents[kind] == nil else { return }
        documents[kind] = LegalDocument.load(kind)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.l) {
            HStack(spacing: Thermyx.Space.m) {
                Image("ThermyxBadge")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 64, height: 64)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Thermyx")
                        .narrowLabel(ThermyxFont.wordmark, tracking: ThermyxTracking.wordmark, color: Thermyx.Ink.textPrimary)
                    Text("Legal and privacy")
                        .font(ThermyxFont.caption)
                        .foregroundStyle(Thermyx.Ink.textSupporting)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, Thermyx.Space.s)

            ThermyxSegmentedControl(
                options: LegalDocument.Kind.allCases,
                label: \.shortTitle,
                selection: $selection,
                font: ThermyxFont.statusPill,
                tracking: ThermyxTracking.statusPill,
                accessibilityPrefix: "Show "
            )
        }
    }

    /// The documents ship with bracketed fields that only the operator can
    /// fill. Saying so in the app is better than letting a reader trip over
    /// `[CONTACT EMAIL]` and wonder whether the whole thing is fake.
    private var placeholderNotice: some View {
        ThermyxCard(padding: Thermyx.Space.l, radius: Thermyx.Radius.compact, fill: Thermyx.Tint.amberFill, border: Thermyx.Tint.amberBorder) {
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel("Before release", color: Thermyx.Ink.amber)
                Text("Fields shown in brackets — legal entity, contact email, mailing address, governing state, and the effective dates — still need to be filled in. The substance of these documents is final.")
                    .font(ThermyxFont.captionSmall)
                    .foregroundStyle(Thermyx.Ink.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, Thermyx.Space.m)
    }

    // MARK: - Blocks

    @ViewBuilder
    private func blockView(_ block: LegalDocument.Block) -> some View {
        switch block {
        case .title(let text):
            Text(text)
                .font(ThermyxFont.articleHeadline)
                .tracking(-1.1)
                .foregroundStyle(Thermyx.Ink.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Thermyx.Space.xs)
                .accessibilityAddTraits(.isHeader)

        case .heading(let text):
            Text(text)
                .font(ThermyxFont.cardTitle)
                .foregroundStyle(Thermyx.Ink.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Thermyx.Space.m)
                .accessibilityAddTraits(.isHeader)

        case .subheading(let text):
            Text(text)
                .narrowLabel(ThermyxFont.sectionLabel, tracking: ThermyxTracking.sectionLabel, color: Thermyx.Ink.ice)
                .padding(.top, Thermyx.Space.xs)
                .accessibilityAddTraits(.isHeader)

        case .paragraph(let text):
            Text(text.thermyxInlineMarkdown)
                .font(ThermyxFont.bodySmall)
                .lineSpacing(4)
                .foregroundStyle(Thermyx.Ink.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

        case .legalese(let text):
            Text(text.thermyxInlineMarkdown)
                .font(ThermyxFont.captionSmall)
                .lineSpacing(3)
                .foregroundStyle(Thermyx.Ink.textMuted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(Thermyx.Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Thermyx.Tint.neutralFill, in: RoundedRectangle(cornerRadius: Thermyx.Radius.button, style: .continuous))

        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: Thermyx.Space.s) {
                Circle()
                    .fill(Thermyx.Ink.textFaint)
                    .frame(width: 4, height: 4)
                    .offset(y: -3)
                Text(text.thermyxInlineMarkdown)
                    .font(ThermyxFont.bodySmall)
                    .lineSpacing(4)
                    .foregroundStyle(Thermyx.Ink.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, 2)

        case .rule:
            ThermyxDivider().padding(.vertical, Thermyx.Space.xs)

        case .table(let header, let rows):
            legalTable(header: header, rows: rows)
        }
    }

    private func legalTable(header: [String], rows: [[String]]) -> some View {
        ThermyxGroupedCard {
            HStack(alignment: .top, spacing: Thermyx.Space.m) {
                ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                    Text(cell)
                        .narrowLabel(ThermyxFont.axisLabel, tracking: ThermyxTracking.axisLabel, color: Thermyx.Ink.textSupporting)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, Thermyx.Space.l)
            .padding(.vertical, Thermyx.Space.s)

            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                ThermyxDivider()
                HStack(alignment: .top, spacing: Thermyx.Space.m) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        Text(cell.thermyxInlineMarkdown)
                            .font(ThermyxFont.captionSmall)
                            .foregroundStyle(Thermyx.Ink.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, Thermyx.Space.l)
                .padding(.vertical, Thermyx.Space.s)
            }
        }
        .accessibilityElement(children: .contain)
    }
}
