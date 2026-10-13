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
                        await session.loadUser()
                        await session.sharePlace(latitude: location.coordinate?.latitude,
                                                 longitude: location.coordinate?.longitude)
                        await sync.sync()
                    }
                    .onChange(of: scenePhase) { _, phase in
                        // Each return also moves the rolling notification window forward.
                        if phase == .active { Task { await sync.sync() } }
                    }
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

struct MainView: View {
    var body: some View {
        TabView {
            Tab("اليوم", systemImage: "sun.max") {
                NavigationStack { TodayView().taskDetailDestination() }
            }
            Tab("القادم", systemImage: "calendar") {
                NavigationStack { UpcomingView().taskDetailDestination() }
            }
            Tab("المشاريع", systemImage: "folder") {
                NavigationStack { ProjectsView().taskDetailDestination() }
            }
            Tab(role: .search) {
                NavigationStack { SearchView().taskDetailDestination() }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
    }
}
