#if os(iOS)
import Foundation
import os
import WatchConnectivity
import ZimamKit

/// Hands the session to the Apple Watch app, which talks to the API itself.
/// The token travels over WatchConnectivity (encrypted between the paired devices)
/// on launch, after sign-in and sign-out, and when the watch asks for it.
/// WatchConnectivity calls the delegate on its own queue, so this is not tied to the main actor
/// (with the main actor by default, a call from that queue would stop the app). It keeps no state.
nonisolated final class WatchLink: NSObject, WCSessionDelegate, Sendable {
    nonisolated static let shared = WatchLink()
    private nonisolated static let logger = Logger(subsystem: "app.zimam.ios", category: "watch")

    nonisolated func start() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Sends the current token and calendar; an empty token signs the watch out.
    nonisolated func sendSession() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return }
        do {
            try session.updateApplicationContext(Self.payload())
        } catch {
            // The watch asks for the session when it starts, so it still gets it then.
            Self.logger.error("Sending the session to the watch failed: \(error.localizedDescription)")
        }
    }

    private nonisolated static func payload() -> [String: Any] {
        var payload: [String: Any] = [
            WatchPayload.token: Keychain.read(SessionStore.tokenAccount) ?? "",
            WatchPayload.sentAt: Date().timeIntervalSince1970,
        ]
        if let calendar = SharedSettings.user()?.settings.calendar {
            payload[WatchPayload.calendar] = calendar.rawValue
        }
        return payload
    }

    // MARK: WCSessionDelegate

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if activationState == .activated { sendSession() }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // The user switched to another watch; activate again for the new one.
        session.activate()
    }

    /// The watch app was installed or the pairing changed.
    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        sendSession()
    }

    /// The watch asks for the session when it has none; this wakes the app in the background.
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        replyHandler(Self.payload())
    }
}
#endif
