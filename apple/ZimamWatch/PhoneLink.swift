import Foundation
import WatchConnectivity

/// Receives the session from the iPhone app over WatchConnectivity, and asks for it
/// when the watch has none. Calls back on the main actor.
final class PhoneLink: NSObject, WCSessionDelegate {
    /// The token (empty after sign-out on the phone) and the primary calendar, if sent.
    var onSession: (@MainActor (String, String?) -> Void)?

    func start() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Asks the phone for the session; the phone app answers even from the background.
    func requestSession() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else { return }
        session.sendMessage([WatchPayload.request: true], replyHandler: { [weak self] reply in
            self?.deliver(reply)
        }, errorHandler: nil)
    }

    private func deliver(_ payload: [String: Any]) {
        guard let token = payload[WatchPayload.token] as? String else { return }
        let calendar = payload[WatchPayload.calendar] as? String
        let handler = onSession
        Task { @MainActor in handler?(token, calendar) }
    }

    // MARK: WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        guard activationState == .activated else { return }
        let latest = session.receivedApplicationContext
        if latest.isEmpty {
            requestSession()
        } else {
            deliver(latest)
        }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        deliver(applicationContext)
    }
}
