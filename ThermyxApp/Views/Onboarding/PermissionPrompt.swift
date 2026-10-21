import CoreBluetooth
import CoreLocation
import SwiftUI
import UIKit

/// A permission asked for right where it's needed: a row with the one
/// button that fixes it. "Allow" shows iOS's prompt; once declined, "Open
/// Settings" goes to Thermyx's page in Settings; when the switch is off
/// for the whole phone (Bluetooth), "Turn On" asks iOS to turn it on. It
/// goes away as soon as the permission is granted.
struct PermissionPrompt: View {
    enum Status: Equatable {
        case notAsked, denied, off, allowed
    }

    /// An SF Symbol, or a brand mark from the asset catalogue.
    enum Icon {
        case symbol(String)
        case asset(String)
    }

    let icon: Icon
    let title: String
    let detail: String
    let status: Status
    /// Shown instead of `detail` when the phone-wide switch is off.
    var offDetail: String?
    /// Opens a place other than Settings for a declined permission (the
    /// Health app manages Health's).
    var deniedAction: (title: String, run: () -> Void)?
    let onAllow: () -> Void
    var onTurnOn: (() -> Void)?

    init(symbol: String, title: String, detail: String, status: Status, offDetail: String? = nil,
         onAllow: @escaping () -> Void, onTurnOn: (() -> Void)? = nil) {
        self.icon = .symbol(symbol)
        self.title = title
        self.detail = detail
        self.status = status
        self.offDetail = offDetail
        self.onAllow = onAllow
        self.onTurnOn = onTurnOn
    }

    init(asset: String, title: String, detail: String, status: Status, offDetail: String? = nil,
         deniedAction: (title: String, run: () -> Void)? = nil,
         onAllow: @escaping () -> Void, onTurnOn: (() -> Void)? = nil) {
        self.icon = .asset(asset)
        self.title = title
        self.detail = detail
        self.status = status
        self.offDetail = offDetail
        self.deniedAction = deniedAction
        self.onAllow = onAllow
        self.onTurnOn = onTurnOn
    }

    var body: some View {
        if status != .allowed {
            HStack(spacing: Thermyx.Space.m) {
                PermissionIcon(icon: icon)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(ThermyxFont.rowTitle)
                        .foregroundStyle(Thermyx.Site.text)
                    Text(message)
                        .font(ThermyxFont.captionSmall)
                        .foregroundStyle(status == .notAsked ? Thermyx.Site.textMuted : Thermyx.Ink.amber)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                // Nothing to press when the phone simply can't do it.
                if status != .off || onTurnOn != nil {
                    Button(buttonTitle, action: act)
                        .buttonStyle(PermissionButtonStyle(prominent: status != .denied))
                        .accessibilityHint(accessibilityHint)
                }
            }
            .padding(Thermyx.Space.m)
            .siteGlass(radius: Thermyx.Radius.compact)
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
        }
    }

    private var message: String {
        switch status {
        case .denied: return deniedAction == nil ? "Turned off for Thermyx. Turn it on in Settings." : "Turned off for Thermyx."
        case .off: return offDetail ?? "Turned off on this iPhone."
        default: return detail
        }
    }

    private var buttonTitle: String {
        switch status {
        case .denied: return deniedAction?.title ?? "Open Settings"
        case .off: return "Turn On"
        default: return "Allow"
        }
    }

    private var accessibilityHint: String {
        switch status {
        case .denied: return deniedAction == nil ? "Opens Thermyx's settings." : "Opens where this is managed."
        case .off: return "Asks iOS to turn it on."
        default: return "Shows the iOS permission prompt."
        }
    }

    private func act() {
        switch status {
        case .denied:
            if let deniedAction { deniedAction.run() } else { ThermyxPermissions.openSettings() }
        case .off:
            (onTurnOn ?? ThermyxPermissions.openSettings)()
        default:
            onAllow()
        }
    }
}

/// The 36 pt mark at the start of a permission row: a brand logo as it is
/// drawn, or a symbol on an ice wash.
struct PermissionIcon: View {
    let icon: PermissionPrompt.Icon

    var body: some View {
        Group {
            switch icon {
            case .symbol(let name):
                Image(systemName: name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Thermyx.Ink.ice)
                    .frame(width: 36, height: 36)
                    .background(Thermyx.Tint.iceWash, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            case .asset(let name):
                Image(name)
                    .renderingMode(.original)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 36, height: 36)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Allow and Turn On are filled; Open Settings is outlined, since it leaves
/// the app.
struct PermissionButtonStyle: ButtonStyle {
    var prominent = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(ThermyxFont.controlLabel)
            .foregroundStyle(prominent ? Thermyx.Ink.onSignal : Thermyx.Ink.ice)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, Thermyx.Space.m)
            .frame(height: 34)
            .background {
                if prominent { Capsule().fill(Thermyx.Ink.signal) } else { Capsule().strokeBorder(Thermyx.Tint.liveBorder, lineWidth: 1) }
            }
            .frame(minHeight: Thermyx.minimumTapTarget)
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(SiteMotion.press, value: configuration.isPressed)
            .contentShape(Capsule())
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

    /// Bluetooth as a whole: allowed for Thermyx, and the radio on.
    init(_ bluetooth: CBManagerAuthorization, state: CBManagerState) {
        self.init(bluetooth)
        if self == .allowed, state == .poweredOff || state == .unsupported { self = .off }
    }

    init(_ location: CLAuthorizationStatus) {
        switch location {
        case .notDetermined: self = .notAsked
        case .authorizedWhenInUse, .authorizedAlways: self = .allowed
        default: self = .denied
        }
    }
}
