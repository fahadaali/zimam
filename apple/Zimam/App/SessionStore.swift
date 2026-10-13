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

    private(set) var isSignedIn: Bool
    private(set) var user: User?
    var errorMessage: String?
    let api: APIClient

    @ObservationIgnored private var pendingNonce: String?

    init() {
        isSignedIn = Keychain.read(Self.tokenAccount) != nil
        let configured = Bundle.main.object(forInfoDictionaryKey: "ZimamAPIURL") as? String
        let baseURL = configured.flatMap(URL.init(string:)) ?? URL(string: "https://api.zimam.app")!
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
                isSignedIn = true
            } catch {
                errorMessage = "تعذّر الاتصال بزمام. تحقّق من الإنترنت وحاول مرة أخرى."
            }
            pendingNonce = nil
        }
    }

    func loadUser() async {
        user = try? await api.me()
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
        isSignedIn = false
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
