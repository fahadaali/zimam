import Foundation

/// Keys of what the iPhone app sends the watch app over WatchConnectivity.
/// The Keychain and App Groups do not cross devices, so this is how the watch
/// gets the session: the phone sends it, and the watch keeps it in its own Keychain.
/// Plain constants, used from the WatchConnectivity delegates on their own queues.
nonisolated enum WatchPayload {
    /// The session token, or an empty string after sign-out.
    static let token = "token"
    /// The user's primary calendar, "hijri" or "gregorian".
    static let calendar = "calendar"
    /// When it was sent, so each send counts as a change and is delivered.
    static let sentAt = "sentAt"
    /// Sent by the watch, as a message, to ask the phone for the session.
    static let request = "request"
}
