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
        do {
            container = try ModelContainer(for: Schema(zimamModelTypes))
        } catch {
            fatalError("Cannot open the local store: \(error)")
        }
        let session = SessionStore()
        let sync = SyncEngine(api: session.api, context: container.mainContext)
        let location = LocationProvider()
        // Created at launch so the notification delegate is set before any action arrives.
        let notifications = NotificationScheduler(context: container.mainContext, sync: sync, session: session, location: location)
        sync.onDataChanged = { [notifications] in notifications.reschedule() }
        location.onChange = { [notifications, session, location] in
            notifications.reschedule()
            let coordinate = location.coordinate
            Task { await session.sharePlace(latitude: coordinate?.latitude, longitude: coordinate?.longitude) }
        }
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
