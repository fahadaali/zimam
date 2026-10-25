import SwiftUI
import ZimamKit

struct RootView: View {
    @Environment(SessionStore.self) private var session
    @Environment(SyncEngine.self) private var sync
    @Environment(NotificationScheduler.self) private var notifications
    @Environment(LocationProvider.self) private var location
    @Environment(SubscriptionStore.self) private var subscriptions
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if session.isSignedIn {
                MainView()
                    .task {
                        // Finish a wipe that failed at the last sign-out before the first sync.
                        sync.wipeIfPending()
                        await notifications.prepare()
                        PushRegistration.shared.register()
                        await session.loadUser()
                        await AvatarStore.shared.refresh(session: session)
                        await session.sharePlace(latitude: location.coordinate?.latitude,
                                                 longitude: location.coordinate?.longitude)
                        await sync.sync()
                        await ReminderBridge.shared.run()
                        // Day words in Spotlight («اليوم», «غداً») follow the date, even when the
                        // sync brought nothing new.
                        TaskSpotlight.shared.scheduleUpdate()
                    }
                    .onChange(of: scenePhase) { _, phase in
                        // Each return also moves the rolling notification window forward.
                        if phase == .active {
                            // A day that turned over while away moves the screens to it (DayClock).
                            DayClock.shared.refresh()
                            notifications.reschedule()
                            #if os(iOS)
                            // A focus ended from the Live Activity while away: Do Not Disturb ends now.
                            FocusDoNotDisturb.shared.catchUp()
                            #endif
                            TaskSpotlight.shared.scheduleUpdate()
                            Task {
                                await sync.sync()
                                // What was said to Siri («ذكرني …») while away.
                                await ReminderBridge.shared.run()
                                // Settings changed on another device or on the web meanwhile.
                                await session.loadUser()
                            }
                        }
                        // Leaving: ask the system to wake the app to renew the window while it is closed.
                        if phase == .background { BackgroundRefresh.schedule() }
                    }
                    // Realtime only while the app is in use; the pull on return catches up.
                    .onChange(of: scenePhase, initial: true) { _, phase in
                        switch phase {
                        case .active: sync.startRealtime()
                        case .background: sync.stopRealtime()
                        default: break
                        }
                    }
                    // Back online: what waited goes out now, not at the next edit or return.
                    .onChange(of: NetworkMonitor.shared.isOnline) { _, online in
                        if online { Task { await sync.sync() } }
                    }
                    // Signing out replaces this view, and its socket closes with it.
                    .onDisappear { sync.stopRealtime() }
                    // Shared projects' members are kept in memory for the signed-in account only.
                    .onDisappear { ProjectMembers.shared.clear() }
                    // A photo changed on another device.
                    .onChange(of: session.user?.avatarVersion) { _, _ in
                        Task { await AvatarStore.shared.refresh(session: session) }
                    }
                    // The method, the madhab and the alerts move the prayer alerts and the widgets.
                    .onChange(of: session.user?.settings) { _, _ in
                        notifications.reschedule()
                        ZimamShared.reloadWidgets()
                        #if os(iOS)
                        WatchLink.shared.sendSession()
                        #endif
                    }
            } else {
                SignInView()
            }
        }
        // In the zone DayClock read, so today moves with it when the zone changes.
        .environment(\.dateFormatterZimam, DualDateFormatter(primary: session.user?.settings.calendar ?? .hijri,
                                                              locale: ZimamLocale.current, timeZone: DayClock.shared.timeZone))
        .environment(\.prayerScheduleZimam, location.schedule(session.user?.settings))
        .onAppear {
            // Weak: the engine owns this closure. A local, so the weak capture is of it rather than
            // of the strong one this closure already holds.
            let engine = sync
            engine.onUnauthorized = { [session, subscriptions, weak engine] in
                session.endSession()
                // As a sign-out: the next account does not see this one's plan.
                subscriptions.signedOut()
                engine?.reset()
            }
        }
    }
}
