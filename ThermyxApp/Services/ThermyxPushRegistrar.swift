import Combine
import Foundation
import UIKit
import UserNotifications

/// Gets this phone an APNs token so the relay can push to a watcher with the
/// app closed.
///
/// Registration needs the Push Notifications entitlement, which only a paid
/// Apple Developer team can sign (see Config/Thermyx.xcconfig). Without it iOS
/// refuses and the watcher falls back to what they had before: the status
/// screen and local alerts while the app is open. Nothing else changes.
@MainActor
final class ThermyxPushRegistrar: ObservableObject {
    static let shared = ThermyxPushRegistrar()

    enum State: Equatable {
        case idle
        case registering
        case registered
        /// iOS refused, usually because this build has no push entitlement.
        case unavailable(String)
    }

    @Published private(set) var deviceToken: String?
    @Published private(set) var state: State = .idle

    /// "development" for builds signed with a development profile (Xcode runs),
    /// "production" for TestFlight and the App Store. APNs keeps separate
    /// tokens for each.
    let environment: String

    private init() { environment = Self.detectEnvironment() }

    /// Asks iOS for a token. Safe to call every launch.
    func register() {
        guard !ThermyxPushRegistrar.isPreview else { return }
        state = .registering
        UIApplication.shared.registerForRemoteNotifications()
    }

    func didRegister(_ tokenData: Data) {
        deviceToken = tokenData.map { String(format: "%02x", $0) }.joined()
        state = .registered
    }

    func didFail(_ error: Error) {
        deviceToken = nil
        state = .unavailable(Self.explain(error))
    }

    static func explain(_ error: Error) -> String {
        let text = (error as NSError).localizedDescription
        if text.localizedCaseInsensitiveContains("aps-environment") || (error as NSError).code == 3000 {
            return "This build isn't signed for push notifications."
        }
        return text
    }

    private static var isPreview: Bool {
        #if DEBUG
        return ThermyxPreviewHarness.isActive
        #else
        return false
        #endif
    }

    /// Read from the provisioning profile when there is one: a development
    /// profile says `aps-environment` is `development`. TestFlight and App
    /// Store builds are production.
    static func detectEnvironment() -> String {
        guard let path = Bundle.main.path(forResource: "embedded", ofType: "mobileprovision"),
              let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .isoLatin1),
              let key = text.range(of: "<key>aps-environment</key>"),
              let open = text.range(of: "<string>", range: key.upperBound..<text.endIndex),
              let close = text.range(of: "</string>", range: open.upperBound..<text.endIndex)
        else {
            #if DEBUG
            return "development"
            #else
            return "production"
            #endif
        }
        return text[open.upperBound..<close.lowerBound] == "development" ? "development" : "production"
    }
}

/// Receives the push registration callbacks, which SwiftUI's App has no hook for.
final class ThermyxAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in ThermyxPushRegistrar.shared.didRegister(deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in ThermyxPushRegistrar.shared.didFail(error) }
    }
}
