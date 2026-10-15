import CoreBluetooth
import CoreLocation
import SwiftUI
import UIKit

/// A permission asked for right where it's needed: a row with a button that
/// shows iOS's prompt, or opens Settings once it's been declined. It goes
/// away as soon as the permission is granted.
struct PermissionPrompt: View {
    enum Status {
        case notAsked, denied, allowed
    }

    let symbol: String
    let title: String
    let detail: String
    let status: Status
    let onAllow: () -> Void

    @Environment(\.openURL) private var openURL

    var body: some View {
        if status != .allowed {
            HStack(spacing: Thermyx.Space.m) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Thermyx.Ink.ice)
                    .frame(width: 36, height: 36)
                    .background(Thermyx.Tint.iceWash, in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(ThermyxFont.rowTitle)
                        .foregroundStyle(Thermyx.Site.text)
                    Text(status == .denied ? "Turned off for Thermyx. Turn it on in Settings." : detail)
                        .font(ThermyxFont.captionSmall)
                        .foregroundStyle(Thermyx.Site.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button(status == .denied ? "Settings" : "Allow") {
                    if status == .denied {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    } else {
                        onAllow()
                    }
                }
                .buttonStyle(AllowButtonStyle())
            }
            .padding(Thermyx.Space.m)
            .siteGlass(radius: Thermyx.Radius.compact)
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
        }
    }

    private struct AllowButtonStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .font(ThermyxFont.controlLabel)
                .foregroundStyle(Thermyx.Ink.onSignal)
                .padding(.horizontal, Thermyx.Space.m)
                .frame(height: 34)
                .background(Thermyx.Ink.signal, in: Capsule())
                .frame(minHeight: Thermyx.minimumTapTarget)
                .scaleEffect(configuration.isPressed ? 0.95 : 1)
                .opacity(configuration.isPressed ? 0.85 : 1)
                .animation(SiteMotion.press, value: configuration.isPressed)
                .contentShape(Capsule())
        }
    }
}

extension PermissionPrompt.Status {
    init(_ bluetooth: CBManagerAuthorization) {
        switch bluetooth {
        case .notDetermined: self = .notAsked
        case .allowedAlways: self = .allowed
        default: self = .denied
        }
    }

    init(_ location: CLAuthorizationStatus) {
        switch location {
        case .notDetermined: self = .notAsked
        case .authorizedWhenInUse, .authorizedAlways: self = .allowed
        default: self = .denied
        }
    }
}
