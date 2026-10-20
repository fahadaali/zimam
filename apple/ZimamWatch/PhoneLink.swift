import Foundation
import WatchConnectivity
import WidgetKit

/// Receives the session from the iPhone app over WatchConnectivity, and asks for it
/// when the watch has none. Calls back on the main actor. WatchConnectivity calls the delegate
/// on its own queue, so this is not tied to the main actor (a call from that queue would stop
/// the app). `onSession` is set once, before `start()`.
nonisolated final class PhoneLink: NSObject, WCSessionDelegate {
    /// The token (empty after sign-out on the phone) and the primary calendar, if sent.
    var onSession: (@MainActor (String, String?) -> Void)?

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

    private nonisolated static func deliver(_ payload: [String: Any], to handler: (@MainActor (String, String?) -> Void)?) {
        guard let token = payload[WatchPayload.token] as? String else { return }
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

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        guard activationState == .activated else { return }
        let latest = session.receivedApplicationContext
        if latest.isEmpty {
            requestSession()
        } else {
            Self.deliver(latest, to: onSession)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Self.deliver(applicationContext, to: onSession)
    }
}
