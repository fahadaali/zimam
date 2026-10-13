import SwiftData
import SwiftUI
import ZimamKit

@main
struct ZimamApp: App {
    private let container: ModelContainer
    @State private var session: SessionStore
    @State private var sync: SyncEngine
    @State private var location: LocationProvider
    @State private var notifications: NotificationScheduler

    init() {
        // Settings the widgets read moved to the App Group; copy them over before anything reads them.
        SharedSettings.migrateFromStandardDefaults()
        // The store lives in the App Group, shared with the widgets and with the intents in this process.
        container = ZimamStore.shared
        let session = SessionStore()
        let sync = SyncEngine(api: session.api, context: container.mainContext)
        let location = LocationProvider()
        // Created at launch so the notification delegate is set before any action arrives.
        let notifications = NotificationScheduler(context: container.mainContext, sync: sync, session: session, location: location)
        sync.onDataChanged = { [notifications] in
            notifications.reschedule()
            ZimamShared.reloadWidgets()
        }
        location.onChange = { [notifications, session, location] in
            notifications.reschedule()
            let coordinate = location.coordinate
            Task { await session.sharePlace(latitude: coordinate?.latitude, longitude: coordinate?.longitude) }
        }
        // Siri and Shortcuts run their intents in this process; their edits sync through the same engine.
        LiveSync.engine = sync
        #if os(iOS)
        // Hands the session to the Apple Watch app.
        WatchLink.shared.start()
        #endif
        _session = State(initialValue: session)
        _sync = State(initialValue: sync)
        _location = State(initialValue: location)
        _notifications = State(initialValue: notifications)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
                .environment(sync)
                .environment(location)
                .environment(notifications)
                .environment(\.layoutDirection, .rightToLeft)
                .environment(\.locale, ZimamLocale.current)
                .font(ZimamType.body)
                .foregroundStyle(ZimamColor.ink)
                .tint(ZimamColor.brand)
        }
        .modelContainer(container)
    }
}
