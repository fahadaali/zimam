import SwiftUI
import ZimamKit

struct RootView: View {
    @Environment(SessionStore.self) private var session
    @Environment(SyncEngine.self) private var sync
    @Environment(NotificationScheduler.self) private var notifications
    @Environment(LocationProvider.self) private var location
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
                        await session.sharePlace(latitude: location.coordinate?.latitude,
                                                 longitude: location.coordinate?.longitude)
                        await sync.sync()
                    }
                    .onChange(of: scenePhase) { _, phase in
                        // Each return also moves the rolling notification window forward.
                        if phase == .active {
                            notifications.reschedule()
                            Task { await sync.sync() }
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
                    // Signing out replaces this view, and its socket closes with it.
                    .onDisappear { sync.stopRealtime() }
                    // Shared projects' members are kept in memory for the signed-in account only.
                    .onDisappear { ProjectMembers.shared.clear() }
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
        .environment(\.dateFormatterZimam, DualDateFormatter(primary: session.user?.settings.calendar ?? .hijri, locale: ZimamLocale.current))
        .onAppear {
            // Weak: the engine owns this closure. A local, so the weak capture is of it rather than
            // of the strong one this closure already holds.
            let engine = sync
            engine.onUnauthorized = { [session, weak engine] in
                session.endSession()
                engine?.reset()
            }
        }
    }
}
