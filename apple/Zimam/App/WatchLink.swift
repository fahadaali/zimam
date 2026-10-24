#if os(iOS)
import Foundation
import os
import WatchConnectivity
import ZimamKit

/// Hands the session to the Apple Watch app, which talks to the API itself, with the place for
/// prayer times. They travel over WatchConnectivity (encrypted between the paired devices).
/// The application context, which WatchConnectivity keeps on disk on both devices, carries only
/// whether the phone is signed in (and as whom, `WatchPayload.account`), the calendar and the place: it is sent on launch, after sign-in
/// and sign-out, and when the place or the prayer settings change. The token itself goes only in
/// the reply to the watch's request, which is not kept, and the watch saves it in its Keychain.
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

    /// Sends whether the phone is signed in, and the calendar and place; signed out signs the watch
    /// out, and signed in makes a watch without a token ask for it.
    nonisolated func sendSession() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return }
        do {
            try session.updateApplicationContext(Self.payload(includingToken: false))
        } catch {
            // The watch asks for the session when it starts, so it still gets it then.
            Self.logger.error("Sending the session to the watch failed: \(error.localizedDescription)")
        }
    }

    private nonisolated static func payload(includingToken: Bool) -> [String: Any] {
        var payload: [String: Any] = [WatchPayload.sentAt: Date().timeIntervalSince1970]
        do {
            let token = try Keychain.value(SessionStore.tokenAccount)
            payload[WatchPayload.signedIn] = token != nil
            if let token { payload[WatchPayload.account] = WatchPayload.account(of: token) }
            if includingToken { payload[WatchPayload.token] = token ?? "" }
        } catch {
            // The Keychain cannot answer for now: neither key, which the watch ignores, rather than
            // signed out, which signs it out.
        }
        if let calendar = SharedSettings.user()?.settings.calendar {
            payload[WatchPayload.calendar] = calendar.rawValue
        }
        // The watch's prayer complications compute the times themselves from this.
        if let place = SharedSettings.prayerPlace(), let data = try? JSONEncoder().encode(place) {
            payload[WatchPayload.prayerPlace] = data
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
        replyHandler(Self.payload(includingToken: true))
    }
}
#endif
