import CryptoKit
import Foundation

/// Keys of what the iPhone app sends the watch app over WatchConnectivity.
/// The Keychain and App Groups do not cross devices, so this is how the watch
/// gets the session: the token travels only in the phone's reply to the watch's request (never in
/// the application context, which WatchConnectivity keeps on disk), and the watch keeps it in its
/// own Keychain. Plain constants, used from the WatchConnectivity delegates on their own queues.
nonisolated enum WatchPayload {
    /// The session token, or an empty string after sign-out. Only in the reply to `request`.
    static let token = "token"
    /// Whether the phone has a session (a Bool): false signs the watch out, true makes a watch
    /// without a token ask for it.
    static let signedIn = "signedIn"
    /// Which session the phone has, next to `signedIn` (`account(of:)` of its token): a watch whose
    /// token gives another asks for the token again, as after signing in to another account on the
    /// phone while the watch was away.
    static let account = "account"
    /// The user's primary calendar, "hijri" or "gregorian".
    static let calendar = "calendar"
    /// The place and calculation for prayer times (`PrayerPlace` as JSON), or absent before the first location.
    static let prayerPlace = "prayerPlace"
    /// When it was sent, so each send counts as a change and is delivered.
    static let sentAt = "sentAt"
    /// Sent by the watch, as a message, to ask the phone for the session.
    static let request = "request"

    /// Eight bytes of the token's SHA-256 in hex: names the session without revealing it.
    static func account(of token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
