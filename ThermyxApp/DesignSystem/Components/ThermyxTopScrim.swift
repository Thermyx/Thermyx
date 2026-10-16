import SwiftUI

/// Keeps the status bar and Dynamic Island legible over scrolling content.
///
/// The app's screens scroll edge to edge, which is right — content should run
/// under the island rather than stopping short of it. But a headline scrolling
/// behind the clock makes both unreadable. This caps the top safe area with the
/// black as the background, fading into the content instead of a hard edge.
///
/// It sits above the scroll view and below the screen's own header, and never
/// takes touches.
struct ThermyxTopScrim: View {
    var body: some View {
        GeometryReader { proxy in
            let inset = proxy.safeAreaInsets.top
            VStack(spacing: 0) {
                Color.black.frame(height: inset)
                LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 14)
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
