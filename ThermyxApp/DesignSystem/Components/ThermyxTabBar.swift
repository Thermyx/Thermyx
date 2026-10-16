import SwiftUI

/// The Thermyx tab bar.
///
/// Drawn rather than a system `TabView`: on iOS 26 the system bar floats and
/// sets its own type, which breaks the design's flat #0A0A0B bar with Geist
/// labels. The affordances a native bar would supply are kept: each tab is a
/// button carrying `.isSelected`, targets clear 48 pt, and the bar is one
/// container for VoiceOver.
struct ThermyxTabBar<Tab: Hashable>: View {
    struct Item: Identifiable {
        let tab: Tab
        let label: String
        let systemImage: String
        /// The filled variant shown while selected.
        let selectedImage: String
        var id: Tab { tab }

        init(_ tab: Tab, label: String, systemImage: String, selectedImage: String? = nil) {
            self.tab = tab
            self.label = label
            self.systemImage = systemImage
            self.selectedImage = selectedImage ?? systemImage
        }
    }

    let items: [Item]
    @Binding var selection: Tab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items) { item in
                let isSelected = item.tab == selection
                Button {
                    guard !isSelected else { return }
                    selection = item.tab
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: isSelected ? item.selectedImage : item.systemImage)
                            .font(.system(size: 20, weight: isSelected ? .semibold : .regular))
                            .frame(height: 26)
                        Text(item.label)
                            .font(ThermyxFont.tabLabel)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(isSelected ? Thermyx.Ink.textPrimary : Thermyx.Ink.textFaint)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: Thermyx.minimumTapTarget)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .sensoryFeedback(.selection, trigger: isSelected) { _, now in now }
                .accessibilityLabel(item.label)
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                .accessibilityIdentifier("tab.\(item.label)")
            }
        }
        .padding(.top, 6)
        .padding(.bottom, 2)
        .background {
            Thermyx.Ink.bar
                .overlay(alignment: .top) { ThermyxDivider() }
                .ignoresSafeArea(edges: .bottom)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tabs")
    }
}

/// Hosts the tab content over one shared topography, and pins the bar —
/// and, for the wearer, the thermal control — beneath it.
struct ThermyxTabScaffold<Tab: Hashable, Content: View, Accessory: View>: View {
    let items: [ThermyxTabBar<Tab>.Item]
    @Binding var selection: Tab
    @ViewBuilder var content: (Tab) -> Content
    @ViewBuilder var accessory: Accessory

    init(
        items: [ThermyxTabBar<Tab>.Item],
        selection: Binding<Tab>,
        @ViewBuilder accessory: () -> Accessory = { EmptyView() },
        @ViewBuilder content: @escaping (Tab) -> Content
    ) {
        self.items = items
        self._selection = selection
        self.accessory = accessory()
        self.content = content
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                ForEach(items) { item in
                    content(item.tab)
                        .opacity(item.tab == selection ? 1 : 0)
                        // Keeping every tab alive preserves its navigation
                        // stack and scroll position across switches, which is
                        // what a native TabView does.
                        .allowsHitTesting(item.tab == selection)
                        .accessibilityHidden(item.tab != selection)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            accessory
            ThermyxTabBar(items: items, selection: $selection)
                .spotlightTarget(.tabBar)
        }
        .background {
            ZStack {
                Color.black
                TopographyBackground().opacity(ThermyxBackdrop.opacity)
            }
            .ignoresSafeArea()
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
    }
}
