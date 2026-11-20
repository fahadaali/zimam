import Foundation
import ZimamKit
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Registers for remote notifications and sends the APNs token to the server, which
/// pushes the reminders beyond the local window that `NotificationScheduler` schedules
/// (iOS keeps only 64 pending local notifications). The pushes carry the same category
/// and `taskId` as the local ones, so «إنجاز» and «تأجيل ساعة» work on them too.
///
/// It also tells the server how far the local notifications reach (`reportSchedule`), so the task
/// reminders that did not fit in the budget come as pushes.
@MainActor
final class PushRegistration {
    static let shared = PushRegistration()

    /// The last token the server accepted, so sign-out can remove it.
    private static let tokenKey = "push.deviceToken"

    /// Set at launch; the token is sent with the signed-in session.
    var api: APIClient?

    /// How far the local notifications reach, for one token and account: the instant in Unix ms
    /// (what the server keeps), or nil for the whole window.
    private struct Horizon: Equatable {
        let token: String
        let account: UUID?
        let milliseconds: Int64?
    }

    /// The latest plan's horizon, waiting to be sent.
    private var planned: (account: UUID?, scheduledThrough: Date?)?
    /// What the server last accepted in this run. Kept in memory only: each launch registers the
    /// token again, which may start its row afresh, so the first plan after it is always sent.
    private var reported: Horizon?
    private var isSending = false
    /// The token was registered while a send was out: send again once it is back.
    private var sendAgain = false

    private init() {}

    /// Asks the system for a device token. The answer arrives in the app delegate,
    /// on every launch, so the server always has the current one.
    func register() {
        #if os(iOS)
        UIApplication.shared.registerForRemoteNotifications()
        #elseif os(macOS)
        NSApplication.shared.registerForRemoteNotifications()
        #endif
    }

    func didRegister(deviceToken: Data) async {
        guard let api else { return }
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        do {
            try await api.registerDevice(token: token, platform: Self.platform, environment: Self.environment,
                                         bundleId: Bundle.main.bundleIdentifier ?? "app.zimam.ios")
            UserDefaults.standard.set(token, forKey: Self.tokenKey)
            // The row may be new: send the horizon again, including one refused before it existed.
            reported = nil
            sendAgain = isSending
            sendSchedule()
        } catch {
            // Signed out or offline: the next launch registers again.
        }
    }

    /// After each replan (`NotificationScheduler`): the server pushes the task reminders firing
    /// after `scheduledThrough` (nil: none, the whole local window is scheduled). Sent only when it
    /// changed for this token and account, in the background; a failure waits for the next plan.
    func reportSchedule(through scheduledThrough: Date?, account: UUID?) {
        planned = (account, scheduledThrough)
        sendSchedule()
    }

    private static func milliseconds(_ date: Date?) -> Int64? {
        date.map { Int64(($0.timeIntervalSince1970 * 1000).rounded(.down)) }
    }

    private func sendSchedule() {
        guard !isSending, let api, let planned, let token = UserDefaults.standard.string(forKey: Self.tokenKey) else { return }
        let through = planned.scheduledThrough
        let wanted = Horizon(token: token, account: planned.account, milliseconds: Self.milliseconds(through))
        guard wanted != reported else { return }
        isSending = true
        sendAgain = false
        Task {
            var accepted = false
            do {
                try await api.updateDeviceSchedule(token: token, scheduledThrough: through)
                accepted = true
            } catch {
                // 404: the token is not registered for this session yet; `didRegister` sends it
                // again once it is. Offline or signed out: the next plan tries again.
            }
            self.isSending = false
            if accepted { self.reported = wanted }
            // A newer plan arrived meanwhile: send it too. The same one is not retried until then.
            if let latest = self.planned,
               self.sendAgain || latest.account != wanted.account || Self.milliseconds(latest.scheduledThrough) != wanted.milliseconds {
                self.sendSchedule()
            }
        }
    }

    /// Before signing out, while the session is still valid. Signing out on the server
    /// removes the device too, so a failure here is harmless.
    func unregister() async {
        guard let api, let token = UserDefaults.standard.string(forKey: Self.tokenKey) else { return }
        try? await api.unregisterDevice(token: token)
        UserDefaults.standard.removeObject(forKey: Self.tokenKey)
        planned = nil
        reported = nil
        sendAgain = false
    }

    private static var platform: APIClient.DevicePlatform {
        #if os(macOS)
        .macos
        #else
        .ios
        #endif
    }

    /// Debug builds are signed with the development `aps-environment`; TestFlight and the
    /// App Store use production.
    private static var environment: APIClient.PushEnvironment {
        #if DEBUG
        .sandbox
        #else
        .production
        #endif
    }
}

#if os(iOS)
/// Receives the APNs token, which SwiftUI has no hook for.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { await PushRegistration.shared.didRegister(deviceToken: deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // No push entitlement (e.g. the simulator without one): local notifications still work.
    }
}
#elseif os(macOS)
/// Receives the APNs token, which SwiftUI has no hook for.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { await PushRegistration.shared.didRegister(deviceToken: deviceToken) }
    }

    func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // No push entitlement: local notifications still work.
    }
}
#endif
