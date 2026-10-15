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
                        await notifications.prepare()
                        PushRegistration.shared.register()
                        await session.loadUser()
                        await session.sharePlace(latitude: location.coordinate?.latitude,
                                                 longitude: location.coordinate?.longitude)
                        await sync.sync()
                    }
                    .onChange(of: scenePhase) { _, phase in
                        // Each return also moves the rolling notification window forward.
                        if phase == .active { Task { await sync.sync() } }
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
                    .onChange(of: session.user?.settings.prayerMethod) { _, _ in
                        notifications.reschedule()
                    }
            } else {
                SignInView()
            }
        }
        .environment(\.dateFormatterZimam, DualDateFormatter(primary: session.user?.settings.calendar ?? .hijri, locale: ZimamLocale.current))
        .onAppear {
            sync.onUnauthorized = { [session, sync] in
                session.endSession()
                try? sync.reset()
            }
        }
    }
}
