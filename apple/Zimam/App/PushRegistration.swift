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
@MainActor
final class PushRegistration {
    static let shared = PushRegistration()

    /// The last token the server accepted, so sign-out can remove it.
    private static let tokenKey = "push.deviceToken"

    /// Set at launch; the token is sent with the signed-in session.
    var api: APIClient?

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
                                         bundleId: Bundle.main.bundleIdentifier ?? "app.zimam.Zimam")
            UserDefaults.standard.set(token, forKey: Self.tokenKey)
        } catch {
            // Signed out or offline: the next launch registers again.
        }
    }

    /// Before signing out, while the session is still valid. Signing out on the server
    /// removes the device too, so a failure here is harmless.
    func unregister() async {
        guard let api, let token = UserDefaults.standard.string(forKey: Self.tokenKey) else { return }
        try? await api.unregisterDevice(token: token)
        UserDefaults.standard.removeObject(forKey: Self.tokenKey)
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
