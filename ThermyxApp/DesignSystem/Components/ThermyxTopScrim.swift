import SwiftUI

/// Keeps the status bar and Dynamic Island legible over scrolling content.
///
/// The app's screens scroll edge to edge, which is right — content should run
/// under the island rather than stopping short of it. But a headline scrolling
/// behind the clock makes both unreadable. This caps the top safe area with the
/// same solid bar treatment used by the bottom thermal controls, separated
/// from the content with a thin hairline.
///
/// It sits above the scroll view and below the screen's own header, and never
/// takes touches.
struct ThermyxTopScrim: View {
    var body: some View {
        GeometryReader { proxy in
            let inset = proxy.safeAreaInsets.top
            Thermyx.Ink.bar
                .frame(height: inset)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(Thermyx.Ink.hairline)
                        .frame(height: Thermyx.Stroke.hairline)
                }
            .frame(maxHeight: .infinity, alignment: .top)
            .ignoresSafeArea(edges: .top)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension View {
    /// Applies the top scrim above this view's content.
    func thermyxTopScrim() -> some View {
        overlay(alignment: .top) { ThermyxTopScrim() }
    }
}
