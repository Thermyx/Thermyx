import SwiftUI

/// A section that folds away to one row: its name, a summary of what's
/// inside, and a chevron that turns as it opens. For checklists and detail
/// that matter once, so they don't take a screen's worth of space.
struct ThermyxDisclosure<Summary: View, Content: View>: View {
    let title: String
    @Binding var isExpanded: Bool
    @ViewBuilder var summary: Summary
    @ViewBuilder var content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: Thermyx.Radius.compact, style: .continuous) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduceMotion ? SiteMotion.fade : SiteMotion.settle) { isExpanded.toggle() }
            } label: {
                HStack(spacing: Thermyx.Space.m) {
                    Text(title)
                        .font(ThermyxFont.rowTitle)
                        .foregroundStyle(Thermyx.Site.text)
                    Spacer(minLength: Thermyx.Space.s)
                    summary
                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Thermyx.Site.textFaint)
                        .rotationEffect(.degrees(isExpanded ? -180 : 0))
                }
                .padding(.horizontal, Thermyx.Space.l)
                .frame(minHeight: 56)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .sensoryFeedback(.selection, trigger: isExpanded)
            .accessibilityElement(children: .combine)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint(isExpanded ? "Hides the list." : "Shows the list.")

            if isExpanded {
                Rectangle().fill(Thermyx.Site.hairline).frame(height: 1)
                VStack(alignment: .leading, spacing: Thermyx.Space.m) { content }
                    .padding(Thermyx.Space.l)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .clipShape(shape)
        .siteGlass(radius: Thermyx.Radius.compact)
    }
}

/// "2 of 3 ready": a count, a row of dots, ice when everything is done.
struct ChecklistSummary: View {
    let done: Int
    let total: Int

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 3) {
                ForEach(0..<total, id: \.self) { i in
                    Circle()
                        .fill(i < done ? Thermyx.Ink.ice : Thermyx.Site.hairlineStrong)
                        .frame(width: 6, height: 6)
                }
            }
            Text(done == total ? "Ready" : "\(done) of \(total) ready")
                .font(ThermyxFont.captionSmall)
                .foregroundStyle(done == total ? Thermyx.Ink.ice : Thermyx.Ink.amber)
                .contentTransition(.numericText())
        }
        .animation(SiteMotion.settle, value: done)
    }
}
