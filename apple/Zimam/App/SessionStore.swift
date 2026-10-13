import AuthenticationServices
import CryptoKit
import Foundation
import Observation
import ZimamKit
#if canImport(UIKit)
import UIKit
#endif

/// Sign in with Apple, the Zimam session token, and the API client that uses it.
@MainActor
@Observable
final class SessionStore {
    nonisolated private static let tokenAccount = "token"
    private static let cachedUserKey = "session.user"

    private(set) var isSignedIn: Bool
    private(set) var user: User?
    var errorMessage: String?
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
            do {
                let response = try await api.signInWithApple(
                    identityToken: identityToken, nonce: pendingNonce, name: name, device: Self.deviceName)
                Keychain.write(response.token, for: Self.tokenAccount)
                user = response.user
                Self.saveCachedUser(response.user)
                isSignedIn = true
            } catch {
                errorMessage = "تعذّر الاتصال بزمام. تحقّق من الإنترنت وحاول مرة أخرى."
            }
            pendingNonce = nil
        }
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
        try? await api.signOut()
        endSession()
    }

    /// Called when the server rejects the token (expired or revoked).
    func endSession() {
        Keychain.delete(Self.tokenAccount)
        user = nil
        Self.saveCachedUser(nil)
        isSignedIn = false
    }

    /// The account and its settings, kept so the app opens with the right calendar offline.
    private static func loadCachedUser() -> User? {
        guard let data = UserDefaults.standard.data(forKey: cachedUserKey) else { return nil }
        return try? JSONDecoder().decode(User.self, from: data)
    }

    private static func saveCachedUser(_ user: User?) {
        if let user, let data = try? JSONEncoder().encode(user) {
            UserDefaults.standard.set(data, forKey: cachedUserKey)
        } else {
            UserDefaults.standard.removeObject(forKey: cachedUserKey)
        }
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
