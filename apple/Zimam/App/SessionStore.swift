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
    /// The settings as the server last returned them: what a save that failed goes back to.
    @ObservationIgnored private var confirmedSettings: User.Settings?
    /// Settings saves go out one at a time, in order, so the server ends with the last one. Nil
    /// once the last one has answered.
    @ObservationIgnored private var settingsSave: Task<User?, Never>?
    /// Counts settings changes; only the latest one's answer updates `user`.
    @ObservationIgnored private var settingsRevision = 0

    init() {
        let signedIn: Bool
        do {
            signedIn = try Keychain.value(Self.tokenAccount) != nil
        } catch {
            // The Keychain cannot answer for now (on the Mac, a refused prompt): still signed in,
            // and requests wait until it can rather than go out without the token (`APIClient`).
            signedIn = true
        }
        isSignedIn = signedIn
        let cached = signedIn ? Self.loadCachedUser() : nil
        user = cached
        confirmedSettings = cached?.settings
        let configured = Bundle.main.object(forInfoDictionaryKey: "ZimamAPIURL") as? String
        let baseURL = configured.flatMap(URL.init(string:)) ?? URL(string: "https://api.zimam.work")!
        api = APIClient(baseURL: baseURL) { try Keychain.value(SessionStore.tokenAccount) }
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
            // The server requires the nonce the request was made with.
            guard let nonce = pendingNonce,
                  let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
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
                    identityToken: identityToken, nonce: nonce, name: name, device: Self.deviceName,
                    authorizationCode: authorizationCode)
                _ = begin(response)
            } catch {
                errorMessage = "تعذّر الاتصال بزمام. تحقّق من الإنترنت وحاول مرة أخرى."
            }
            // A second attempt started meanwhile keeps its own nonce.
            if pendingNonce == nonce { pendingNonce = nil }
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
            guard begin(response) else { return }
            // The Google account's photo becomes the account's, once, if it has none yet. The
            // device downloads it; the server never fetches outside links.
            if response.user.avatarVersion == nil, result.user.profile?.hasImage == true,
               let url = result.user.profile?.imageURL(withDimension: UInt(AvatarImage.side)) {
                Task {
                    guard let (data, _) = try? await URLSession.shared.data(from: url) else { return }
                    _ = await AvatarStore.shared.upload(data, session: self)
                }
            }
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

    /// Keeps a new session from either provider. False, still signed out, if the Keychain did not
    /// keep the token: every request would go out without it.
    private func begin(_ response: SignInResponse) -> Bool {
        guard Keychain.write(response.token, for: Self.tokenAccount) else {
            errorMessage = "تعذّر تسجيل الدخول. حاول مرة أخرى."
            return false
        }
        setUser(response.user)
        isSignedIn = true
        return true
    }

    /// The account and its settings as the server has them: at launch and on each return to the
    /// app, so settings changed on another device or on the web reach this one. Not while a
    /// settings save is on its way, or once one starts before the answer: the server may read the
    /// account before that save lands, and the save's own answer brings the whole account anyway.
    func loadUser() async {
        guard settingsSave == nil else { return }
        let revision = settingsRevision
        guard let loaded = try? await api.me(), revision == settingsRevision else { return }
        confirmedSettings = loaded.settings
        // Unchanged, as on most returns: nothing to save, and the widgets need no reload.
        if loaded != user { setUser(loaded) }
    }

    /// Replaces the signed-in user, e.g. after the server returns an updated account.
    func setUser(_ newUser: User) {
        user = newUser
        confirmedSettings = newUser.settings
        Self.saveCachedUser(newUser)
    }

    /// Applies new settings right away (the date formatter switches calendars at once), then
    /// saves what changed with `PATCH /v1/me`: only those keys, so what another device changed
    /// meanwhile stays. Saves go out one at a time, in order. Returns false if the server could
    /// not be reached; the settings then go back to what the server last returned.
    @discardableResult
    func updateSettings(_ settings: User.Settings) async -> Bool {
        guard var updated = user else { return false }
        let changes = settings.changes(from: updated.settings)
        guard !changes.isEmpty else { return true }
        updated.settings = settings
        user = updated
        settingsRevision += 1
        let revision = settingsRevision
        let previous = settingsSave
        let save = Task { [api] () async -> User? in
            _ = await previous?.value
            return try? await api.updateMe(settings: changes)
        }
        settingsSave = save
        let saved = await save.value
        if let saved { confirmedSettings = saved.settings }
        // A newer change is on its way: its answer, or its failure, decides what `user` shows.
        guard revision == settingsRevision else { return saved != nil }
        // The last save has answered (saves run in order), so `loadUser` may read again.
        settingsSave = nil
        if let saved {
            setUser(saved)
            return true
        }
        // An expired session is handled by the next sync, which signs out.
        if var current = user, let confirmedSettings {
            current.settings = confirmedSettings
            user = current
        }
        return false
    }

    /// Saves the account's name (`PATCH /v1/me`); an empty name clears it. False if the server
    /// could not be reached, and the name stays as it was.
    func updateName(_ name: String) async -> Bool {
        do {
            setUser(try await api.updateMe(name: name))
            return true
        } catch {
            return false
        }
    }

    /// Where each device kept «أوقات الصلاة في كلود وChatGPT» before the switch became the
    /// account's (a location in its settings). Read once to carry an «on» over, then removed.
    private static let legacyShareKey = "location.shareWithServer"

    /// Whether the account keeps an approximate location on the server (off by default): the
    /// switch is the account's, the same on every device and on the web.
    var sharesPlace: Bool { user?.settings.location != nil }

    /// Saves the device's time zone on the server, so agendas built for Claude and ChatGPT start
    /// on the right day, and, while the account shares it, this device's city-level location
    /// (one decimal, about 10 km) for its prayer times. `share` turns sharing on or off (the
    /// switch); nil keeps the account's choice, so a device that opens or moves never starts or
    /// stops sharing on its own. Does nothing when the server already has these values.
    func sharePlace(latitude: Double?, longitude: Double?, share: Bool? = nil) async {
        guard let current = user?.settings else { return }
        let legacy = UserDefaults.standard.object(forKey: Self.legacyShareKey) as? Bool
        var settings = current
        settings.timeZone = TimeZone.current.identifier
        if share ?? (current.location != nil || legacy == true) {
            if let latitude, let longitude {
                settings.location = User.Settings.Coordinate(latitude: (latitude * 10).rounded() / 10,
                                                             longitude: (longitude * 10).rounded() / 10)
            }
        } else {
            settings.location = nil
        }
        if settings != current {
            guard await updateSettings(settings) else { return }
        }
        if legacy != nil { UserDefaults.standard.removeObject(forKey: Self.legacyShareKey) }
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
        // Not carried over to the next account on this device.
        UserDefaults.standard.removeObject(forKey: Self.legacyShareKey)
        // Attachment lists and files opened under this account (TaskAttachmentsSection.swift).
        AttachmentCache.clearAll()
        AvatarStore.shared.clear()
        user = nil
        confirmedSettings = nil
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
