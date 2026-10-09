import SwiftUI

/// The Thermyx tab bar.
///
/// This started as a native `TabView` themed through `UITabBarAppearance`,
/// which is the better default — it brings tap-to-top, VoiceOver ordering and
/// safe-area handling for free. On iOS 26 the system tab bar ignores that
/// appearance and renders its own floating bar with system-font labels, which
/// breaks the Archivo Narrow type system the rest of the app is built on.
///
/// So the bar is drawn here instead, to the handoff spec, with the
/// accessibility affordances a native bar would have supplied: each tab is a
/// button carrying `.isSelected`, targets clear 48pt, and the whole bar is one
/// tab-bar container for VoiceOver.
struct ThermyxTabBar<Tab: Hashable>: View {
    struct Item: Identifiable {
        let tab: Tab
        let label: String
        let systemImage: String
        var id: Tab { tab }

        init(_ tab: Tab, label: String, systemImage: String) {
            self.tab = tab
            self.label = label
            self.systemImage = systemImage
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
                    VStack(spacing: 5) {
                        Image(systemName: item.systemImage)
                            .font(.system(size: 20, weight: .semibold))
                            .frame(height: 22)
                        Text(item.label)
                            .narrowLabel(
                                ThermyxFont.tabLabel,
                                tracking: ThermyxTracking.tabLabel,
                                color: isSelected ? Thermyx.Ink.ice : Thermyx.Ink.textFaint
                            )
                    }
                    .foregroundStyle(isSelected ? Thermyx.Ink.ice : Thermyx.Ink.textFaint)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: Thermyx.minimumTapTarget)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.label)
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(.top, Thermyx.Space.s)
        .padding(.bottom, 2)
        .background {
            Thermyx.Ink.bar
                .overlay(alignment: .top) {
                    Rectangle().fill(Thermyx.Ink.divider).frame(height: 1)
                }
                .ignoresSafeArea(edges: .bottom)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tabs")
    }
}

/// Hosts the tab content and pins the bar — and, for the wearer, the thermal
/// control bar — beneath it.
struct ThermyxTabScaffold<Tab: Hashable, Content: View, Accessory: View>: View {
    let items: [ThermyxTabBar<Tab>.Item]
    @Binding var selection: Tab
    @ViewBuilder var content: (Tab) -> Content
    @ViewBuilder var accessory: Accessory

    @State private var accessoryHidden = false

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
                        // Only the visible tab decides whether the control
                        // bar shows; a screen in a background tab can't hide it.
                        .transformPreference(ThermalControlBarHidden.self) { hidden in
                            if item.tab != selection { hidden = false }
                        }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onPreferenceChange(ThermalControlBarHidden.self) { hidden in
                accessoryHidden = hidden
            }

            if !accessoryHidden { accessory }
            ThermyxTabBar(items: items, selection: $selection)
        }
        .background(Thermyx.Ink.midnight)
        .ignoresSafeArea(.keyboard, edges: .bottom)
    }
}
