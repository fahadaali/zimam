import SwiftUI
import ZimamKit

struct RootView: View {
    @Environment(SessionStore.self) private var session
    @Environment(SyncEngine.self) private var sync
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if session.isSignedIn {
                MainView()
                    .task {
                        await session.loadUser()
                        await sync.sync()
                    }
                    .onChange(of: scenePhase) { _, phase in
                        if phase == .active { Task { await sync.sync() } }
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
                NavigationStack { TodayView() }
            }
            Tab("القادم", systemImage: "calendar") {
                NavigationStack { UpcomingView() }
            }
            Tab("المشاريع", systemImage: "folder") {
                NavigationStack { ProjectsView() }
            }
            Tab(role: .search) {
                NavigationStack { SearchView() }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
    }
}
