import FirebaseAuth
import FirebaseCore
import GoogleSignIn
import SwiftUI

/// Who can use the test tools: Demo Mode, the fake insole, and sample data.
/// Everyone else only ever sees what their own insoles measure.
enum ThermyxAdmins {
    static let emails: Set<String> = [
        "aaronhanqin@gmail.com",
        "miheerparasnis@gmail.com",
        "reyanshmah@gmail.com",
    ]

    static func isAdmin(email: String?) -> Bool {
        guard let email = email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !email.isEmpty else { return false }
        return emails.contains(email)
    }
}

/// A signed-in Thermyx account.
struct ThermyxAccount: Codable, Equatable {
    /// The Firebase user ID.
    var uid: String
    var email: String?
    var displayName: String?

    var isAdmin: Bool { ThermyxAdmins.isAdmin(email: email) }
}

/// Sign in with Google, through Firebase Authentication.
///
/// The account says who the wearer is and whether they may use the test
/// tools. It holds no readings: the profile, history and calibration stay on
/// this phone, as the privacy policy promises.
@MainActor
final class ThermyxAccountStore: ObservableObject {
    @Published private(set) var account: ThermyxAccount?
    @Published private(set) var isWorking = false
    @Published var errorMessage: String?

    var isSignedIn: Bool { account != nil }
    var isAdmin: Bool { account?.isAdmin == true }

    /// Whether this build carries a Firebase configuration. Without one,
    /// nobody can sign in.
    private(set) static var isFirebaseConfigured = false

    /// Configures Firebase when GoogleService-Info.plist is in the bundle.
    /// Call once at launch, before the store is created.
    static func configureFirebase() {
        guard !isFirebaseConfigured,
              Bundle.main.url(forResource: "GoogleService-Info", withExtension: "plist") != nil
        else { return }
        FirebaseApp.configure()
        isFirebaseConfigured = true
    }

    init() {
        #if DEBUG
        // The preview harness signs in a stand-in account (or none).
        if ThermyxPreviewHarness.isActive {
            account = ThermyxPreviewHarness.account
            return
        }
        #endif
        // Firebase keeps the session in the Keychain across launches.
        account = Self.isFirebaseConfigured ? Auth.auth().currentUser.map(Self.account) : nil
    }

    // MARK: Sign in with Google

    func signInWithGoogle() async {
        errorMessage = nil
        isWorking = true
        defer { isWorking = false }
        do {
            let credential = try await googleCredential()
            let user = try await Auth.auth().signIn(with: credential).user
            account = Self.account(user)
        } catch {
            if (error as NSError).domain == kGIDSignInErrorDomain, (error as NSError).code == GIDSignInError.canceled.rawValue { return }
            errorMessage = (error as? AccountError)?.errorDescription ?? "Couldn't sign in. \(error.localizedDescription)"
        }
    }

    /// Shows Google's sign-in and turns the result into a Firebase credential.
    private func googleCredential() async throws -> AuthCredential {
        guard Self.isFirebaseConfigured, let clientID = FirebaseApp.app()?.options.clientID else {
            throw AccountError.notConfigured
        }
        guard let presenter = Self.topViewController() else { throw AccountError.noWindow }
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
        let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presenter)
        guard let idToken = result.user.idToken?.tokenString else { throw AccountError.missingToken }
        return GoogleAuthProvider.credential(withIDToken: idToken, accessToken: result.user.accessToken.tokenString)
    }

    /// Google hands control back through the app's URL scheme.
    func handle(_ url: URL) {
        _ = GIDSignIn.sharedInstance.handle(url)
    }

    func signOut() {
        if Self.isFirebaseConfigured { try? Auth.auth().signOut() }
        GIDSignIn.sharedInstance.signOut()
        account = nil
    }

    // MARK: Delete account

    /// Deletes the account, as App Review requires an app with sign-in to
    /// offer: Google confirms who it is, the Firebase user is deleted, and
    /// Thermyx's access to the Google account is revoked. The caller wipes
    /// the data on this phone once this returns without throwing.
    func deleteAccount() async throws {
        guard account != nil else { return }
        isWorking = true
        defer { isWorking = false }
        #if DEBUG
        if ThermyxPreviewHarness.isActive { account = nil; return }
        #endif
        guard let user = Auth.auth().currentUser else { account = nil; return }
        // Deleting needs a recent sign-in.
        try await user.reauthenticate(with: googleCredential())
        try await user.delete()
        try? await GIDSignIn.sharedInstance.disconnect()
        account = nil
    }

    enum AccountError: LocalizedError {
        case notConfigured, noWindow, missingToken
        var errorDescription: String? {
            switch self {
            case .notConfigured: return "Sign-in isn't set up in this build yet (GoogleService-Info.plist is missing)."
            case .noWindow: return "Couldn't show Google sign-in. Try again."
            case .missingToken: return "Google didn't return a sign-in token. Try again."
            }
        }
    }

    // MARK: Helpers

    private static func account(_ user: User) -> ThermyxAccount {
        ThermyxAccount(uid: user.uid, email: user.email, displayName: user.displayName)
    }

    private static func topViewController() -> UIViewController? {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
        var top = window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}

// MARK: - Admin in the environment

private struct ThermyxAdminKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True for the admin accounts in `ThermyxAdmins`. Test tools check it
    /// and stay hidden otherwise, including wherever it isn't set.
    var isThermyxAdmin: Bool {
        get { self[ThermyxAdminKey.self] }
        set { self[ThermyxAdminKey.self] = newValue }
    }
}
