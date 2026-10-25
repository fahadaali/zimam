import Foundation
import WatchConnectivity
import WidgetKit

/// Receives the session from the iPhone app over WatchConnectivity, and asks for it
/// when the watch has none: the token comes only in the reply, while the application context
/// says whether the phone is signed in (`WatchPayload`). Calls back on the main actor. WatchConnectivity calls the delegate
/// on its own queue, so this is not tied to the main actor (a call from that queue would stop
/// the app). `onSession` is set once, before `start()`.
nonisolated final class PhoneLink: NSObject, WCSessionDelegate {
    /// The token (empty after sign-out on the phone; nil when none came, the token being unchanged)
    /// and the primary calendar, if sent.
    var onSession: (@MainActor (String?, String?) -> Void)?

    nonisolated func start() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Asks the phone for the session; the phone app answers even from the background.
    nonisolated func requestSession() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else { return }
        let handler = onSession
        session.sendMessage([WatchPayload.request: true], replyHandler: { reply in
            Self.deliver(reply, to: handler)
        }, errorHandler: nil)
    }

    private nonisolated static func deliver(_ payload: [String: Any], to handler: (@MainActor (String?, String?) -> Void)?) {
        let token: String?
        if let sent = payload[WatchPayload.token] as? String {
            token = sent
        } else if payload[WatchPayload.signedIn] as? Bool == false {
            token = ""
        } else if payload[WatchPayload.signedIn] as? Bool == true {
            token = nil
        } else {
            // Neither key: the phone could not read its Keychain, so nothing here is certain.
            return
        }
        // The place for prayer times, for the complications and the prayer screen. Kept after
        // sign-out like the iPhone keeps it; a payload without one (no place yet) forgets it.
        let place = (payload[WatchPayload.prayerPlace] as? Data).flatMap { try? JSONDecoder().decode(PrayerPlace.self, from: $0) }
        if WatchPrayerStore.write(place) {
            WidgetCenter.shared.reloadAllTimelines()
        }
        let calendar = payload[WatchPayload.calendar] as? String
        Task { @MainActor in handler?(token, calendar) }
    }

    // MARK: WCSessionDelegate

    /// Asks for the token when the phone says it is signed in and the watch has none, or has
    /// another session's (`WatchPayload.account`): the phone signed out and in to another account
    /// while the watch was away, so only the last context came.
    private nonisolated func requestIfMissing(_ context: [String: Any]) {
        guard Self.needsToken(context) else { return }
        requestSession()
    }

    private nonisolated static func needsToken(_ context: [String: Any]) -> Bool {
        guard context[WatchPayload.signedIn] as? Bool == true else { return false }
        guard let token = Keychain.read(WatchModel.tokenAccount) else { return true }
        guard let account = context[WatchPayload.account] as? String else { return false }
        return account != WatchPayload.account(of: token)
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        guard activationState == .activated else { return }
        let latest = session.receivedApplicationContext
        if latest.isEmpty {
            requestSession()
        } else {
            Self.deliver(latest, to: onSession)
            requestIfMissing(latest)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Self.deliver(applicationContext, to: onSession)
        requestIfMissing(applicationContext)
    }

    /// The iPhone came into range: ask again if the watch still has no session, or not the phone's.
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        guard session.isReachable else { return }
        guard Keychain.read(WatchModel.tokenAccount) == nil || Self.needsToken(session.receivedApplicationContext) else { return }
        requestSession()
    }
}
