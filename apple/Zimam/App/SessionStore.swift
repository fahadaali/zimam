import AuthenticationServices
import CryptoKit
import Foundation
import GoogleSignIn
import Observation
import ZimamKit
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Sign in with Apple or Google, the Zimam session token, and the API client that uses it.
@MainActor
@Observable
final class SessionStore {
    /// The Keychain account of the session token. The watch link reads it too.
    nonisolated static let tokenAccount = "token"

    private(set) var isSignedIn: Bool
    private(set) var user: User?
    var errorMessage: String?
    /// True while Google's sign-in sheet or the server exchange is running, so the button waits.
    private(set) var isSigningInWithGoogle = false
    let api: APIClient

    @ObservationIgnored private var pendingNonce: String?

    init() {
        let signedIn = Keychain.read(Self.tokenAccount) != nil
        isSignedIn = signedIn
        user = signedIn ? Self.loadCachedUser() : nil
        let configured = Bundle.main.object(forInfoDictionaryKey: "ZimamAPIURL") as? String
        let baseURL = configured.flatMap(URL.init(string:)) ?? URL(string: "https://zimam.fahad2ao.workers.dev")!
        api = APIClient(baseURL: baseURL) { Keychain.read(SessionStore.tokenAccount) }
    }

    /// Fills the Apple request: name and email, and the SHA-256 of a fresh nonce.
    func prepare(_ request: ASAuthorizationAppleIDRequest) {
        let nonce = Self.randomNonce()
        pendingNonce = nonce
        request.requestedScopes = [.fullName, .email]
        request.nonce = Self.sha256(nonce)
    }

    func complete(_ result: Result<ASAuthorization, Error>) async {
        errorMessage = nil
        switch result {
        case .failure(let error):
            if (error as? ASAuthorizationError)?.code == .canceled { return }
            errorMessage = "تعذّر تسجيل الدخول. حاول مرة أخرى."
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let identityToken = String(data: tokenData, encoding: .utf8) else {
                errorMessage = "تعذّر تسجيل الدخول. حاول مرة أخرى."
                return
            }
            let name = credential.fullName
                .map { PersonNameComponentsFormatter.localizedString(from: $0, style: .default) }
                .flatMap { $0.isEmpty ? nil : $0 }
            // The server exchanges it for Apple's refresh token, revoked when the account is deleted.
            let authorizationCode = credential.authorizationCode.flatMap { String(data: $0, encoding: .utf8) }
            do {
                let response = try await api.signInWithApple(
                    identityToken: identityToken, nonce: pendingNonce, name: name, device: Self.deviceName,
                    authorizationCode: authorizationCode)
                begin(response)
            } catch {
                errorMessage = "تعذّر الاتصال بزمام. تحقّق من الإنترنت وحاول مرة أخرى."
            }
            pendingNonce = nil
        }
    }

    // MARK: Sign in with Google

    /// Whether Sign in with Google is set up: `GIDClientID` in Info.plist, from the
    /// `GOOGLE_IOS_CLIENT_ID` build setting in project.yml. Empty hides the button.
    nonisolated static var isGoogleConfigured: Bool {
        let clientID = Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String
        return !(clientID ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Presents Google's sign-in (a web sheet over the current window), then exchanges the ID
    /// token for a Zimam session. As with Apple, Google signs the SHA-256 of a fresh nonce and
    /// the server checks it against the raw one. A first Google sign-in whose verified email
    /// matches an existing account joins that account on the server.
    func signInWithGoogle() async {
        guard Self.isGoogleConfigured, !isSigningInWithGoogle else { return }
        errorMessage = nil
        isSigningInWithGoogle = true
        defer { isSigningInWithGoogle = false }

        let nonce = Self.randomNonce()
        let result: GIDSignInResult
        do {
            #if os(iOS)
            guard let presenter = Self.presentingViewController() else {
                errorMessage = "تعذّر تسجيل الدخول بحساب قوقل. حاول مرة أخرى."
                return
            }
            result = try await GIDSignIn.sharedInstance.signIn(
                withPresenting: presenter, hint: nil, additionalScopes: nil, nonce: Self.sha256(nonce))
            #else
            guard let window = NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first(where: \.isVisible) else {
                errorMessage = "تعذّر تسجيل الدخول بحساب قوقل. حاول مرة أخرى."
                return
            }
            result = try await GIDSignIn.sharedInstance.signIn(
                withPresenting: window, hint: nil, additionalScopes: nil, nonce: Self.sha256(nonce))
            #endif
        } catch {
            if (error as? GIDSignInError)?.code == .canceled { return }
            errorMessage = "تعذّر تسجيل الدخول بحساب قوقل. حاول مرة أخرى."
            return
        }

        guard let idToken = result.user.idToken?.tokenString else {
            errorMessage = "تعذّر تسجيل الدخول بحساب قوقل. حاول مرة أخرى."
            return
        }
        do {
            let response = try await api.signInWithGoogle(
                idToken: idToken, nonce: nonce, name: result.user.profile?.name, device: Self.deviceName)
            begin(response)
        } catch {
            errorMessage = "تعذّر الاتصال بزمام. تحقّق من الإنترنت وحاول مرة أخرى."
        }
    }

    /// Google's sign-in page returns to the app through the reversed client ID URL scheme.
    @discardableResult
    nonisolated static func handleOpenURL(_ url: URL) -> Bool {
        GIDSignIn.sharedInstance.handle(url)
    }

    #if os(iOS)
    /// The front-most view controller of the active window, which Google presents its sheet over.
    private static func presentingViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        var controller = scene?.keyWindow?.rootViewController ?? scene?.windows.first?.rootViewController
        while let presented = controller?.presentedViewController {
            controller = presented
        }
        return controller
    }
    #endif

    /// Keeps a new session from either provider.
    private func begin(_ response: SignInResponse) {
        Keychain.write(response.token, for: Self.tokenAccount)
        user = response.user
        Self.saveCachedUser(response.user)
        isSignedIn = true
    }

    func loadUser() async {
        if let loaded = try? await api.me() { setUser(loaded) }
    }

    /// Replaces the signed-in user, e.g. after the server returns an updated account.
    func setUser(_ newUser: User) {
        user = newUser
        Self.saveCachedUser(newUser)
    }

    /// Applies new settings right away (the date formatter switches calendars at once),
    /// then saves them with `PATCH /v1/me`. Returns false and restores the old
    /// settings if the server could not be reached.
    @discardableResult
    func updateSettings(_ settings: User.Settings) async -> Bool {
        guard var updated = user else { return false }
        let previous = updated
        updated.settings = settings
        user = updated
        do {
            let saved = try await api.updateMe(settings: settings)
            setUser(saved)
            return true
        } catch {
            // An expired session is handled by the next sync, which signs out.
            user = previous
            return false
        }
    }

    /// Whether the user chose to keep an approximate location on the server (off by default).
    nonisolated static let shareLocationKey = "location.shareWithServer"

    /// Saves the device's time zone on the server, so agendas built for Claude and ChatGPT
    /// start on the right day, and, only when the user turned sharing on, a city-level
    /// location (one decimal, about 10 km) for their prayer times. Turning sharing off
    /// clears it. Does nothing when the server already has these values.
    func sharePlace(latitude: Double?, longitude: Double?) async {
        guard var settings = user?.settings else { return }
        var location: User.Settings.Coordinate?
        if UserDefaults.standard.bool(forKey: Self.shareLocationKey), let latitude, let longitude {
            location = User.Settings.Coordinate(latitude: (latitude * 10).rounded() / 10,
                                                longitude: (longitude * 10).rounded() / 10)
        }
        let zone = TimeZone.current.identifier
        guard settings.timeZone != zone || settings.location != location else { return }
        settings.timeZone = zone
        settings.location = location
        await updateSettings(settings)
    }

    /// Ends the session here and on the server; local data is wiped by the caller.
    func signOut() async {
        await PushRegistration.shared.unregister()
        try? await api.signOut()
        endSession()
    }

    /// Deletes the account on the server, then ends the session here; local data is wiped
    /// by the caller, as on sign-out. Returns false, still signed in, if the server did not
    /// confirm the deletion (an expired session is handled by the next sync, which signs out).
    func deleteAccount() async -> Bool {
        do {
            try await api.deleteAccount()
        } catch {
            return false
        }
        // Also ends Zimam's access to the Google account, if this device signed in with Google.
        try? await GIDSignIn.sharedInstance.disconnect()
        endSession()
        return true
    }

    /// Called when the server rejects the token (expired or revoked).
    func endSession() {
        // Forgets the Google account on this device, so the next Google sign-in asks again.
        GIDSignIn.sharedInstance.signOut()
        Keychain.delete(Self.tokenAccount)
        // Attachment lists and files opened under this account (TaskAttachmentsSection.swift).
        AttachmentCache.clearAll()
        user = nil
        Self.saveCachedUser(nil)
        isSignedIn = false
    }

    /// The account and its settings, kept so the app opens with the right calendar offline.
    /// It lives in the App Group, where the widgets read the calendar and prayer method too.
    private static func loadCachedUser() -> User? {
        SharedSettings.user()
    }

    /// Saves the account after sign-in, sign-out and settings changes, then tells the
    /// widgets and the watch (which gets the token and calendar with it).
    private static func saveCachedUser(_ user: User?) {
        SharedSettings.saveUser(user)
        ZimamShared.reloadWidgets()
        #if os(iOS)
        WatchLink.shared.sendSession()
        #endif
    }

    private static var deviceName: String {
        #if os(iOS)
        UIDevice.current.model
        #else
        "Mac"
        #endif
    }

    private static func randomNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
    }

    private static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
