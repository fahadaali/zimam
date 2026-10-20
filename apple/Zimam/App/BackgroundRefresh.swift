#if os(iOS)
import BackgroundTasks
#endif
import Foundation
import os

/// Renews the rolling window of notifications while the app is closed. The adhan and iqama
/// alerts cover two days (`PrayerAlertPlanner.windowDays`), so someone who does not open Zimam
/// for a while still gets them: the system wakes the app now and then (`.backgroundTask` in
/// `ZimamApp`), and each wake replans the window and asks for the next one. The Mac keeps its
/// notifications while the app runs, and replans on every launch.
@MainActor
enum BackgroundRefresh {
    /// Listed in `BGTaskSchedulerPermittedIdentifiers` (project.yml).
    static let identifier = "app.zimam.ios.refresh"
    /// The soonest the system may wake the app again; it decides when, often later.
    private static let interval: TimeInterval = 6 * 3600

    static weak var scheduler: NotificationScheduler?

    private static let logger = Logger(subsystem: "app.zimam.ios", category: "refresh")

    /// Asks for the next wake. Called when the app goes to the background and after each wake.
    static func schedule() {
        #if os(iOS)
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date().addingTimeInterval(interval)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // The simulator, or Background App Refresh turned off: the next launch replans.
            logger.info("Background refresh not scheduled: \(error.localizedDescription, privacy: .public)")
        }
        #endif
    }

    /// One wake: the next one first, so a wake cut short still leaves one asked for.
    static func run() async {
        schedule()
        // Reminders said to Siri while the app was closed (`ReminderBridge`), then the window.
        await ReminderBridge.shared.run()
        await scheduler?.rescheduleNow()
        ZimamShared.reloadWidgets()
    }
}
